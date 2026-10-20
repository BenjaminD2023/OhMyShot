import Foundation
import Testing

/// The notices the app carries (App/Acknowledgments.md, shown in Settings › About › Acknowledgments…) are made by
/// Scripts/acknowledgments.py from the licenses of the packages the app is built with. These keep a package from being
/// added, or moved to another version, without the notices being made again for it.
struct AcknowledgmentsTests {
    /// A package as the build resolves it.
    private struct Resolved {
        let location: String
        let version: String
        let source: String
    }

    /// A `##` entry of the notices: its heading ("Sparkle 2.10.0"), the address on the line under it, and its text up
    /// to the next entry.
    private struct Entry {
        let heading: String
        let address: String
        let text: String
    }

    private static func read(_ path: String) throws -> String {
        // Packages/OhMyShotKit/Tests/OMSCoreTests/<this file>, five levels below the repository.
        var root = URL(filePath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// An address as SwiftPM compares them: without case, a trailing slash, or ".git".
    private static func normalized(_ location: String) -> String {
        var location = location.lowercased()
        if location.hasSuffix("/") { location.removeLast() }
        if location.hasSuffix(".git") { location.removeLast(4) }
        return location
    }

    /// Every package the app is built with: what the packages' Package.resolved files pin, and the remote packages
    /// project.yml adds for the app (Sparkle), which the generated Xcode project resolves but nothing committed records.
    private func resolvedPackages() throws -> [Resolved] {
        var found: [Resolved] = []
        for path in ["Packages/OhMyShotKit/Package.resolved", "Packages/OhMyShotVLM/Package.resolved"] {
            let resolved = try #require(try JSONSerialization.jsonObject(with: Data(Self.read(path).utf8)) as? [String: Any])
            for pin in try #require(resolved["pins"] as? [[String: Any]]) {
                let location = try #require(pin["location"] as? String)
                let state = try #require(pin["state"] as? [String: Any])
                let version = try #require(state["version"] as? String, "\(location) in \(path) is pinned to no version")
                found.append(Resolved(location: location, version: version, source: path))
            }
        }
        // project.yml's `packages:`: each entry two spaces in, its keys four.
        var inPackages = false
        var entries: [(name: String, url: String?, version: String?)] = []
        for line in try Self.read("project.yml").split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") {
                inPackages = line == "packages:"
            } else if inPackages, line.hasPrefix("  "), !line.hasPrefix("   ") {
                entries.append((String(trimmed.dropLast()), nil, nil))
            } else if inPackages, !entries.isEmpty {
                let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "url" { entries[entries.count - 1].url = parts[1] }
                if parts[0] == "exactVersion" { entries[entries.count - 1].version = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            }
        }
        for entry in entries {
            guard let url = entry.url else { continue }
            // A range would leave the notice's version to whatever Xcode resolved last.
            let version = try #require(entry.version, "\(entry.name) in project.yml has no exactVersion, so its notice can't name one")
            found.append(Resolved(location: url, version: version, source: "project.yml"))
        }
        return found
    }

    private func entries() throws -> [Entry] {
        var entries: [Entry] = []
        var heading: String?
        var address: String?
        var lines: [String] = []
        var fenced = false
        func close() {
            if let heading { entries.append(Entry(heading: heading, address: address ?? "", text: lines.joined(separator: "\n"))) }
        }
        for line in try Self.read("App/Acknowledgments.md").components(separatedBy: "\n") {
            if !fenced, line.hasPrefix("## ") {
                close()
                heading = String(line.dropFirst(3))
                address = nil
                lines = []
                continue
            }
            if line.hasPrefix("```") { fenced = line != "```" || !fenced }
            if heading != nil, address == nil, !line.isEmpty { address = line }
            lines.append(line)
        }
        close()
        return entries
    }

    @Test func everyPackageTheAppIsBuiltWithHasItsNotice() throws {
        let entries = try entries()
        let packages = try resolvedPackages()
        #expect(packages.contains { $0.location.contains("sparkle-project/Sparkle") })
        for package in packages {
            let entry = entries.first { Self.normalized($0.address) == Self.normalized(package.location) }
            #expect(entry != nil, "\(package.location) (\(package.source)) has no notice in App/Acknowledgments.md: build, then run Scripts/acknowledgments.py")
            if let entry {
                #expect(entry.heading.hasSuffix(" \(package.version)"), "\(package.location) is \(package.version) in \(package.source), but its notice is “\(entry.heading)”: build, then run Scripts/acknowledgments.py")
            }
        }
    }

    @Test func everyNoticeCarriesALicense() throws {
        for entry in try entries() where entry.heading != "OhMyShot" {
            let licenses = entry.text.components(separatedBy: "```text\n").dropFirst()
            #expect(!licenses.isEmpty, "\(entry.heading) has no license text")
            for license in licenses {
                #expect(license.components(separatedBy: "\n```").first?.contains(where: { !$0.isWhitespace }) == true, "\(entry.heading) has an empty license")
            }
        }
    }

    /// The app is distributed as object code, which the GPL asks to go with a copy of it: the notices end with it.
    @Test func theNoticesCarryOhMyShotsOwnLicense() throws {
        var license = try Self.read("LICENSE")
        while license.last?.isWhitespace == true { license.removeLast() }
        let last = try #require(try entries().last)
        #expect(last.heading == "GNU General Public License, version 3")
        #expect(last.text.contains("```text\n\(license)\n```"), "App/Acknowledgments.md doesn't end with LICENSE as it is: run Scripts/acknowledgments.py")
    }
}
