import AppKit
import Foundation
import OMSCore

extension UsageTelemetry {
    static func production(settings: SettingsStore) -> UsageTelemetry? {
        #if DEBUG
        return nil
        #else
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "io.github.fzlzjerry.ohmyshot",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: UsageTelemetrySessionDelegate(), delegateQueue: nil)
        let endpoint = URL(string: "https://www.ohmyshot.org/api/telemetry")!
        return UsageTelemetry(
            file: AppFolders.support.appending(path: "usage-telemetry.json"), version: version,
            context: { Context.current(settings: settings) }
        ) { data in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("OhMyShot/Telemetry", forHTTPHeaderField: "User-Agent")
            request.httpBody = data
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        #endif
    }
}

#if !DEBUG
private extension UsageTelemetry.Context {
    /// This Mac and the app as they are now. OhMyShot's support folder is made on its first launch, so its age is the
    /// app's on this Mac.
    static func current(settings: SettingsStore) -> Self {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let installed = try? AppFolders.support.resourceValues(forKeys: [.creationDateKey]).creationDate
        return Self(
            macOS: "\(system.majorVersion).\(system.minorVersion)",
            chip: chip(),
            language: Bundle.main.preferredLocalizations.first ?? "",
            displays: NSScreen.screens.count,
            installed: installed ?? .now,
            settings: [
                "quickAccess": settings.showQuickAccess ? "on" : "off",
                "copy": settings.copyAfterCapture ? "on" : "off",
                "save": settings.saveAfterCapture ? "on" : "off",
                "upload": settings.uploadAfterCapture ? "on" : "off",
                "format": settings.screenshotFormat.rawValue,
                "history": settings.historyRetention.rawValue,
            ]
        )
    }

    /// "M3 Pro", from the brand the kernel gives the CPU, "Apple M3 Pro".
    static func chip() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
        let brand = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return brand.hasPrefix("Apple ") ? String(brand.dropFirst("Apple ".count)) : brand
    }
}

private final class UsageTelemetrySessionDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
