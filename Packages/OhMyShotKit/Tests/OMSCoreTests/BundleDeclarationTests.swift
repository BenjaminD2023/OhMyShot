import Foundation
@testable import OMSCore
import Testing

/// What the app and its Share extension declare to the system lives in plists outside the package; these
/// keep the declarations the code relies on from being edited away.
struct BundleDeclarationTests {
    private func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.configURL(name))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static func configURL(_ name: String) -> URL {
        // Packages/OhMyShotKit/Tests/OMSCoreTests/<this file>, five levels below the repository.
        var root = URL(filePath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appending(path: "Config/\(name)")
    }

    /// The build settings a Config file ends up with: its includes first, later lines over earlier ones, and
    /// `$(NAME)` filled in from the rest. An optional include is Signing.local.xcconfig, a person's own signing,
    /// and is left out, so this reads the same on every machine.
    private func buildSettings(_ name: String) throws -> [String: String] {
        var raw: [String: String] = [:]
        func read(_ name: String) throws {
            for line in try String(contentsOf: Self.configURL(name), encoding: .utf8).split(separator: "\n") {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#include ") {
                    try read(line.dropFirst("#include ".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
                } else if !line.hasPrefix("//"), let equals = line.firstIndex(of: "=") {
                    raw[line[..<equals].trimmingCharacters(in: .whitespaces)] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        try read(name)
        func resolved(_ value: String, depth: Int = 0) -> String {
            guard depth < 10, let open = value.range(of: "$("), let close = value[open.upperBound...].firstIndex(of: ")") else { return value }
            let key = String(value[open.upperBound..<close])
            return resolved(value.replacingCharacters(in: open.lowerBound...close, with: raw[key] ?? ""), depth: depth + 1)
        }
        return raw.mapValues { resolved($0) }
    }

    @Test func theAppOffersItselfInOpenWithForEveryImageType() throws {
        let types = try #require(try plist("Info.plist")["CFBundleDocumentTypes"] as? [[String: Any]])
        let images = try #require(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.image") == true })
        // Editor, so it is offered to edit; Alternate, so it never takes a type from the app that has it.
        #expect(images["CFBundleTypeRole"] as? String == "Editor")
        #expect(images["LSHandlerRank"] as? String == "Alternate")
    }

    @Test func theAppOwnsItsProjectFiles() throws {
        let types = try #require(try plist("Info.plist")["CFBundleDocumentTypes"] as? [[String: Any]])
        let projects = try #require(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("$(OMS_BUNDLE_ID_PREFIX).ohmyshot.project") == true })
        #expect(projects["LSHandlerRank"] as? String == "Owner")
    }

    @Test func theShareExtensionIsAShareServiceForPictures() throws {
        let extensionKeys = try #require(try plist("ShareExtension-Info.plist")["NSExtension"] as? [String: Any])
        #expect(extensionKeys["NSExtensionPointIdentifier"] as? String == "com.apple.share-services")
        #expect(extensionKeys["NSExtensionPrincipalClass"] as? String == "OMSShareViewController")
        let attributes = try #require(extensionKeys["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(attributes["NSExtensionActivationRule"] as? String)
        #expect(rule.contains("UTI-CONFORMS-TO \"public.image\""))
    }

    @Test func theShareExtensionKnowsItsHostAndItsScheme() throws {
        let keys = try plist("ShareExtension-Info.plist")
        #expect(keys["OMSHostBundleIdentifier"] as? String == "$(OMS_HOST_BUNDLE_IDENTIFIER)")
        #expect(keys["OMSURLScheme"] as? String == "$(OMS_URL_SCHEME)")
    }

    /// The extension may write one folder, and it has to be the one the app reads.
    @Test func theShareExtensionMayWriteExactlyTheShareInbox() throws {
        let entitlements = try plist("ShareExtension.entitlements")
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        let paths = try #require(entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String])
        #expect(paths == ["/Library/Application Support/$(OMS_HOST_BUNDLE_IDENTIFIER)/\(ShareInbox.folderName)/"])
        #expect(ShareInbox.hosted(by: "io.example.host").directory.path(percentEncoded: false).hasSuffix("/Library/Application Support/io.example.host/\(ShareInbox.folderName)/"))
    }

    /// The extension opens the app by the bundle identifier and the URL scheme it was built with; if the two
    /// ever differ the share would fail without a word, so each configuration's pair must agree.
    @Test func theShareExtensionAnswersToTheAppOfItsOwnConfiguration() throws {
        for (app, share) in [("Debug.xcconfig", "ShareExtension-Debug.xcconfig"), ("Release.xcconfig", "ShareExtension-Release.xcconfig")] {
            let host = try buildSettings(app)
            let extensionSettings = try buildSettings(share)
            let hostIdentifier = try #require(host["PRODUCT_BUNDLE_IDENTIFIER"])
            #expect(!hostIdentifier.isEmpty && !hostIdentifier.contains("$("), "\(app)")
            #expect(extensionSettings["OMS_HOST_BUNDLE_IDENTIFIER"] == hostIdentifier, "\(share)")
            #expect(extensionSettings["PRODUCT_BUNDLE_IDENTIFIER"] == "\(hostIdentifier).share", "\(share)")
            let scheme = try #require(host["OMS_URL_SCHEME"])
            #expect(!scheme.isEmpty)
            #expect(extensionSettings["OMS_URL_SCHEME"] == scheme, "\(share)")
        }
        // The Debug app is its own app beside a release build, and the extension follows it there.
        #expect(try buildSettings("ShareExtension-Debug.xcconfig")["OMS_URL_SCHEME"] != buildSettings("ShareExtension-Release.xcconfig")["OMS_URL_SCHEME"])
    }

    @Test func theAppAnswersToTheSchemeItIsBuiltWith() throws {
        let types = try #require(try plist("Info.plist")["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == ["$(OMS_URL_SCHEME)"])
    }

    /// The app embeds the extension by its target, and Release once failed to embed what Debug had named
    /// differently; the name must not depend on the configuration.
    @Test func theShareExtensionIsNamedTheSameInEveryConfiguration() throws {
        let debug = try buildSettings("ShareExtension-Debug.xcconfig")
        let release = try buildSettings("ShareExtension-Release.xcconfig")
        #expect(debug["PRODUCT_NAME"] == release["PRODUCT_NAME"])
        #expect(debug["PRODUCT_NAME"] == "OhMyShot Share")
        #expect(debug["INFOPLIST_FILE"] == release["INFOPLIST_FILE"])
        #expect(debug["CODE_SIGN_ENTITLEMENTS"] == release["CODE_SIGN_ENTITLEMENTS"])
    }
}
