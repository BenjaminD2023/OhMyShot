import Foundation
import OMSCore

extension UsageTelemetry {
    static func production() -> UsageTelemetry? {
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
            file: AppFolders.support.appending(path: "usage-telemetry.json"),
            version: version, macOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
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
private final class UsageTelemetrySessionDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
