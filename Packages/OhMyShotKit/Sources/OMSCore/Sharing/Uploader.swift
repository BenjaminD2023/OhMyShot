import Foundation
import OSLog
import Synchronization
import UniformTypeIdentifiers

/// Sends a file to a destination and gives back the link.
///
/// Each upload holds an `ActiveResources` lease and its own `URLSession`, invalidated when the upload ends,
/// so nothing is left running between uploads. The file is sent from disk (`uploadTask(fromFile:)`) and
/// never read into memory; a form body is first written to a temporary file in chunks and removed after.
/// Cancelling the task that awaits `upload` cancels the transfer and removes the temporary file.
public final class Uploader: Sendable {
    let secrets: any SecretStore
    let resources: ActiveResources
    let makeConfiguration: @Sendable () -> URLSessionConfiguration
    let temporaryDirectory: URL
    /// Files over this size go to S3 in parts.
    let multipartThreshold: Int64
    /// The size of each part, at least; larger files get larger parts so they fit S3's limit of 10,000.
    let multipartPartSize: Int64

    /// - Parameters:
    ///   - sessionConfiguration: Builds the configuration of each upload's session; tests install a
    ///     `URLProtocol` here.
    ///   - temporaryDirectory: Where form bodies are written while they are sent.
    public init(
        secrets: any SecretStore,
        resources: ActiveResources = .shared,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = Uploader.defaultConfiguration,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        multipartThreshold: Int64 = 100 * 1024 * 1024,
        multipartPartSize: Int64 = 16 * 1024 * 1024
    ) {
        self.secrets = secrets
        self.resources = resources
        self.makeConfiguration = sessionConfiguration
        self.temporaryDirectory = temporaryDirectory
        self.multipartThreshold = multipartThreshold
        self.multipartPartSize = multipartPartSize
    }

    /// No cookies, no cache and no background session: an upload is one request and leaves nothing behind.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        return configuration
    }

    /// Uploads one file.
    ///
    /// - Parameters:
    ///   - originalName: The name the capture has for the person, used when the destination sends original
    ///     names. A capture in the history is stored under another name, so pass the one to show.
    ///   - progress: Called as bytes are sent with the fraction done, 0...1, at most about a hundred times.
    ///     It is called on a background queue.
    /// - Throws: `UploadError`, or `CancellationError` when the calling task is cancelled.
    @concurrent
    public func upload(
        fileAt fileURL: URL,
        to destination: UploadDestination,
        originalName: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadResult {
        let lease = resources.acquire(.upload)
        defer { lease.end() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        guard let size = (attributes?[.size] as? NSNumber)?.int64Value else { throw UploadError.fileUnreadable }
        let name = UploadNaming.name(for: fileURL, originalName: originalName, naming: destination.fileNaming)

        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let transport = Transport(session: session, progress: progress)

        Log.upload.notice("Upload to \(destination.kindName, privacy: .public) started, \(size, privacy: .public) bytes")
        do {
            let result: UploadResult
            switch destination.configuration {
            case .s3(let settings):
                result = try await uploadToS3(fileURL, size: size, name: name, destination: destination, settings: settings, transport: transport)
            case .webDAV(let settings):
                result = try await uploadToWebDAV(fileURL, name: name, destination: destination, settings: settings, transport: transport)
            case .customHTTP(let settings):
                result = try await uploadWithCustomHTTP(fileURL, size: size, name: name, destination: destination, settings: settings, transport: transport)
            }
            Log.upload.notice("Upload to \(destination.kindName, privacy: .public) finished")
            return result
        } catch is CancellationError {
            Log.upload.notice("Upload to \(destination.kindName, privacy: .public) cancelled")
            throw CancellationError()
        } catch {
            Log.upload.error("Upload to \(destination.kindName, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    /// Removes an uploaded file from its storage with a signed DELETE (S3, WebDAV). A file that is already
    /// gone counts as removed. Records of the other kinds are deleted by opening their deletion address.
    ///
    /// - Throws: `UploadError`, or `CancellationError` when the calling task is cancelled.
    @concurrent
    public func delete(_ record: UploadRecord, from destination: UploadDestination) async throws {
        guard let key = record.remoteKey else {
            throw UploadError.invalidConfiguration(String(localized: "this kind of destination can’t delete files itself"))
        }
        let lease = resources.acquire(.upload)
        defer { lease.end() }
        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let transport = Transport(session: session, progress: nil)
        Log.upload.notice("Delete from \(destination.kindName, privacy: .public) started")
        switch destination.configuration {
        case .s3(let settings):
            try await deleteFromS3(key: key, destination: destination, settings: settings, transport: transport)
        case .webDAV(let settings):
            try await deleteFromWebDAV(key: key, destination: destination, settings: settings, transport: transport)
        case .customHTTP:
            throw UploadError.invalidConfiguration(String(localized: "this kind of destination can’t delete files itself"))
        }
        Log.upload.notice("Delete from \(destination.kindName, privacy: .public) finished")
    }

    // MARK: Helpers shared by the backends

    func secret(_ field: String, of destination: UploadDestination) throws -> String {
        guard let value = secrets.secret(field, of: destination.id) else { throw UploadError.secretMissing(field: field) }
        return value
    }

    static func mimeType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// `a/b` from ` /a//b/ `: no empty segments, none at the ends.
    static func normalizedFolder(_ folder: String) -> String {
        folder.split(separator: "/").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "/")
    }

    /// `host` or `host:port`, as the Host header and a signature carry it.
    static func hostWithPort(of url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? ""
        let shown = host.contains(":") ? "[\(host)]" : host
        if let port = url.port, !(port == 80 && url.scheme == "http") && !(port == 443 && url.scheme == "https") {
            return "\(shown):\(port)"
        }
        return shown
    }

    /// What `<Code>` and `<Message>` say in an S3 error body.
    static func s3Error(in body: String) -> (code: String?, message: String?) {
        func value(_ tag: String) -> String? {
            guard let open = body.range(of: "<\(tag)>"), let close = body.range(of: "</\(tag)>", range: open.upperBound..<body.endIndex) else { return nil }
            return String(body[open.upperBound..<close.lowerBound])
        }
        return (value("Code"), value("Message"))
    }

    /// An HTTP error status as the sentence for it.
    static func failure(status: Int, message: String?) -> UploadError {
        switch status {
        case 401, 403: .authRejected(detail: message)
        case 404: .notFound(detail: message)
        case 413: .fileTooLarge(limit: nil)
        default: .server(status: status, message: message)
        }
    }
}

// MARK: Transport

/// One request on the upload's session, with progress and error mapping.
struct Transport: Sendable {
    let session: URLSession
    let progress: (@Sendable (Double) -> Void)?

    /// A cap on the answer kept: links and error messages are short, and the rest is not needed.
    private static let answerLimit = 256 * 1024

    func send(_ request: URLRequest, body fileURL: URL? = nil) async throws -> UploadResponse {
        let host = request.url.map { Uploader.hostWithPort(of: $0) } ?? ""
        let delegate = ProgressDelegate(report: progress)
        do {
            let (data, response): (Data, URLResponse)
            if let fileURL {
                (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request, delegate: delegate)
            }
            guard let http = response as? HTTPURLResponse else { throw UploadError.unreachable(host: host) }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            let text = String(decoding: data.prefix(Self.answerLimit), as: UTF8.self)
            return UploadResponse(status: http.statusCode, text: text, url: http.url, headers: headers)
        } catch {
            throw UploadError.from(error, host: host)
        }
    }
}

/// Turns the session's byte counts into fractions, a hundredth at a time so a large file does not wake the
/// main actor for every packet.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: (@Sendable (Double) -> Void)?
    private let last = Mutex<Double>(-1)

    init(report: (@Sendable (Double) -> Void)?) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let report, totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let due = last.withLock { last in
            guard fraction - last >= 0.01 || fraction >= 1 && last < 1 else { return false }
            last = fraction
            return true
        }
        if due { report(fraction) }
    }
}

// MARK: Names

/// Which name a file is uploaded under.
public enum UploadNaming {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func name(for fileURL: URL, originalName: String?, naming: FileNaming) -> String {
        let shown = sanitized(originalName ?? fileURL.lastPathComponent)
        switch naming {
        case .original:
            return shown.isEmpty ? randomName(extension: fileURL.pathExtension) : shown
        case .random:
            let ext = fileURL.pathExtension.isEmpty ? (shown as NSString).pathExtension : fileURL.pathExtension
            return randomName(extension: ext)
        }
    }

    /// Ten random lowercase letters and digits and the extension, lowercased.
    public static func randomName<G: RandomNumberGenerator>(extension ext: String, using generator: inout G) -> String {
        let stem = String((0..<10).map { _ in alphabet.randomElement(using: &generator)! })
        return ext.isEmpty ? stem : "\(stem).\(ext.lowercased())"
    }

    public static func randomName(extension ext: String) -> String {
        var generator = SystemRandomNumberGenerator()
        return randomName(extension: ext, using: &generator)
    }

    /// A name with no slashes or control characters, which no key or path should be made to hold.
    static func sanitized(_ name: String) -> String {
        name.unicodeScalars
            .map { $0 == "/" || $0 == "\\" || $0.properties.generalCategory == .control ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }
}
