import CryptoKit
import Foundation
import OSLog
import Synchronization

/// Why a model pack didn't download.
public enum ModelPackError: Error, Equatable, Sendable, LocalizedError {
    /// The disk lacks room for what is left to download, with some to spare.
    case notEnoughSpace(needed: Int64, available: Int64)
    /// No mirror gave the file: the last one tried, and why.
    case unreachable(host: String, reason: String)
    /// A file came down twice with the wrong size or SHA-256.
    case damaged(file: String)
    /// The files couldn't be written or moved into place.
    case unwritable(String)
    /// The pack as listed can't be used (`ModelPack.problem`).
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            String(localized: "There isn’t enough space on this Mac: \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) is needed, \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free.", bundle: .module)
        case .unreachable(let host, let reason):
            String(localized: "Couldn’t download from \(host). \(reason)", bundle: .module)
        case .damaged(let file):
            String(localized: "“\(file)” came down damaged twice.", bundle: .module)
        case .unwritable(let reason):
            String(localized: "The files couldn’t be saved: \(reason)", bundle: .module)
        case .invalid(let problem):
            String(localized: "This model pack can’t be downloaded: \(problem)", bundle: .module)
        }
    }
}

/// Downloads a model pack's files into its download folder and installs the pack once every file checks out.
///
/// Each file is written to `<path>.partial` as it arrives, so a download cut off, paused, or interrupted by quitting
/// goes on from where it stopped: the next one asks for the rest with a `Range` request (Hugging Face's CDN
/// answers those, also across the redirect from a `resolve` address). The bytes are hashed as they come, the
/// ones already on disk first, and a file is kept only when its size and SHA-256 are the listed ones. A mirror
/// that fails is followed by the next; a file that comes down damaged is fetched once more from the start,
/// from the next mirror, and then the download fails.
///
/// Each download holds an `ActiveResources` lease and its own `URLSession`, invalidated when it ends, so nothing
/// is left running between downloads. Cancelling the task that awaits `download` stops it and keeps what came.
public final class ModelPackDownloader: Sendable {
    let store: ModelPackStore
    let resources: ActiveResources
    let makeConfiguration: @Sendable () -> URLSessionConfiguration
    let availableSpace: @Sendable (URL) -> Int64?
    /// Room left free on the disk beyond the download.
    static let spareSpace: Int64 = 200 * 1024 * 1024

    /// - Parameters:
    ///   - sessionConfiguration: Builds each download's session configuration; tests install a `URLProtocol` here.
    ///   - availableSpace: The free space for important use on the volume holding a folder; tests give their own.
    public init(
        store: ModelPackStore,
        resources: ActiveResources = .shared,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = ModelPackDownloader.defaultConfiguration,
        availableSpace: @escaping @Sendable (URL) -> Int64? = ModelPackDownloader.availableSpace(at:)
    ) {
        self.store = store
        self.resources = resources
        self.makeConfiguration = sessionConfiguration
        self.availableSpace = availableSpace
    }

    /// No cookies, no cache, no background session: a download is a few requests and leaves nothing behind.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 3600
        return configuration
    }

    public static func availableSpace(at folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Downloads what is left of the pack's files and installs the pack.
    ///
    /// - Parameter progress: Called with the bytes on disk so far (counting what an earlier download left), at most
    ///   about a hundred times over the pack. It is called on a background queue.
    /// - Throws: `ModelPackError`, or `CancellationError` when the calling task is cancelled; what came is kept.
    @concurrent
    public func download(_ pack: ModelPack, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> ModelPackStore.Receipt {
        if let problem = pack.problem { throw ModelPackError.invalid(problem) }
        let lease = resources.acquire(.download)
        defer { lease.end() }

        let staging: URL
        do {
            staging = try store.prepareDownload(of: pack)
        } catch {
            throw ModelPackError.unwritable(error.localizedDescription)
        }
        let already = store.downloaded(pack)
        if let available = availableSpace(staging), available < pack.size - already + Self.spareSpace {
            throw ModelPackError.notEnoughSpace(needed: pack.size - already, available: available)
        }

        let session = URLSession(configuration: makeConfiguration())
        defer { session.invalidateAndCancel() }
        let meter = Meter(total: pack.size, done: already, report: progress)
        Log.modelPacks.notice("Downloading model pack \(pack.id, privacy: .public) \(pack.version, privacy: .public): \(pack.size - already, privacy: .public) of \(pack.size, privacy: .public) bytes left")
        do {
            for file in pack.files {
                try Task.checkCancellation()
                try await fetch(file, of: pack, into: staging, session: session, meter: meter)
            }
            let receipt: ModelPackStore.Receipt
            do {
                receipt = try store.install(pack)
            } catch {
                throw ModelPackError.unwritable(error.localizedDescription)
            }
            meter.finish()
            Log.modelPacks.notice("Installed model pack \(pack.id, privacy: .public) \(pack.version, privacy: .public)")
            return receipt
        } catch is CancellationError {
            Log.modelPacks.notice("Model pack \(pack.id, privacy: .public) download stopped, \(meter.done, privacy: .public) bytes kept")
            throw CancellationError()
        } catch {
            Log.modelPacks.error("Model pack \(pack.id, privacy: .public) download failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fetches only the pack's license file, to show before the download starts, and gives its text. The file is
    /// kept in the download's folder, so the download doesn't fetch it again.
    ///
    /// - Throws: `ModelPackError`, or `CancellationError` when the calling task is cancelled.
    @concurrent
    public func license(of pack: ModelPack) async throws -> String {
        if let problem = pack.problem { throw ModelPackError.invalid(problem) }
        guard let file = pack.files.first(where: { $0.path == pack.license.file }) else { throw ModelPackError.invalid("no license file") }
        let lease = resources.acquire(.download)
        defer { lease.end() }
        let staging: URL
        do {
            staging = try store.prepareDownload(of: pack)
        } catch {
            throw ModelPackError.unwritable(error.localizedDescription)
        }
        let session = URLSession(configuration: makeConfiguration())
        defer { session.invalidateAndCancel() }
        try await fetch(file, of: pack, into: staging, session: session, meter: Meter(total: file.size, done: 0, report: nil))
        let data: Data
        do {
            data = try Data(contentsOf: ModelPackStore.place(file.path, under: staging))
        } catch {
            throw ModelPackError.unwritable(error.localizedDescription)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: A file

    private func fetch(_ file: ModelPack.File, of pack: ModelPack, into staging: URL, session: URLSession, meter: Meter) async throws {
        let target = ModelPackStore.place(file.path, under: staging)
        guard ModelPackStore.contains(staging, target) else { throw ModelPackError.invalid("file path \(file.path) leaves the pack") }
        // Checked before it got its name.
        if ModelPackStore.size(of: target) == file.size { return }
        let partial = ModelPackStore.partial(of: target)

        var mirror = 0
        var attempts = 0
        var damaged = 0
        var lastReason = "", lastHost = pack.mirrors[0].host() ?? pack.host
        // Each mirror once; a damaged file once more, from the start, from the next mirror.
        while attempts < pack.mirrors.count + damaged {
            try Task.checkCancellation()
            let url = pack.url(of: file, at: pack.mirrors[mirror % pack.mirrors.count])
            attempts += 1
            do {
                let transfer = try Transfer(partial: partial, file: file, meter: meter)
                defer { transfer.close() }
                try await transfer.run(url, in: session)
                guard transfer.length == file.size, transfer.digest() == file.sha256 else {
                    // Not the file listed: start it over, once.
                    Log.modelPacks.error("Model pack file \(file.path, privacy: .public) from \(url.host() ?? "?", privacy: .public) came down damaged (\(transfer.length, privacy: .public) bytes)")
                    transfer.close()
                    meter.rewind(transfer.length)
                    try? FileManager.default.removeItem(at: partial)
                    damaged += 1
                    guard damaged < 2 else { throw ModelPackError.damaged(file: file.path) }
                    mirror += 1
                    continue
                }
                transfer.close()
                do {
                    try FileManager.default.moveItem(at: partial, to: target)
                } catch {
                    throw ModelPackError.unwritable(error.localizedDescription)
                }
                return
            } catch let error as ModelPackError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TransferError {
                lastReason = error.reason
                lastHost = url.host() ?? pack.host
                Log.modelPacks.error("Model pack file \(file.path, privacy: .public) from \(url.host() ?? "?", privacy: .public): \(error.reason, privacy: .public)")
                mirror += 1
            }
        }
        throw ModelPackError.unreachable(host: lastHost, reason: lastReason)
    }
}

/// What ended a request for a file, short of the file: it may come from another mirror.
struct TransferError: Error {
    let reason: String
}

/// Bytes on disk over the whole pack, reported at most about a hundred times.
final class Meter: Sendable {
    private struct Count {
        var done: Int64
        var reported: Int64
    }

    private let total: Int64
    private let step: Int64
    private let count: Mutex<Count>
    private let report: (@Sendable (Int64) -> Void)?

    init(total: Int64, done: Int64, report: (@Sendable (Int64) -> Void)?) {
        self.total = total
        self.step = max(total / 100, 1)
        self.count = Mutex(Count(done: done, reported: done))
        self.report = report
        report?(done)
    }

    var done: Int64 { count.withLock { $0.done } }

    func add(_ bytes: Int64) {
        let due: Int64? = count.withLock { count in
            count.done += bytes
            guard count.done - count.reported >= step else { return nil }
            count.reported = count.done
            return count.done
        }
        if let due { report?(due) }
    }

    /// Takes back bytes thrown away (a file started over).
    func rewind(_ bytes: Int64) {
        let now = count.withLock { count in
            count.done = max(count.done - bytes, 0)
            count.reported = count.done
            return count.done
        }
        report?(now)
    }

    func finish() {
        report?(count.withLock { $0.done })
    }
}

/// One request for one file: appends what comes to the partial file and hashes it.
///
/// Its state is touched on the session's delegate queue while the request runs, and before and after it by the
/// download, never at once.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let file: ModelPack.File
    private let meter: Meter
    private var handle: FileHandle?
    private var hasher = SHA256()
    /// Bytes in the partial file, and hashed.
    private(set) var length: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Opens the partial file, keeping what it holds when that can be the file's start, and hashes it.
    init(partial: URL, file: ModelPack.File, meter: Meter) throws {
        self.partial = partial
        self.file = file
        self.meter = meter
        super.init()
        let manager = FileManager.default
        if !manager.fileExists(atPath: partial.path(percentEncoded: false)) {
            guard manager.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
                throw ModelPackError.unwritable("couldn’t create \(partial.lastPathComponent)")
            }
        }
        do {
            let handle = try FileHandle(forUpdating: partial)
            self.handle = handle
            let size = try handle.seekToEnd()
            if size > UInt64(file.size) {
                // Longer than the file: none of it can be trusted.
                try handle.truncate(atOffset: 0)
                meter.rewind(min(Int64(size), file.size))
            } else if size > 0 {
                try handle.seek(toOffset: 0)
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
                length = Int64(size)
            }
        } catch let error as ModelPackError {
            throw error
        } catch {
            throw ModelPackError.unwritable(error.localizedDescription)
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    func digest() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Asks for the rest of the file, or checks nothing is left when the partial file is already whole.
    func run(_ url: URL, in session: URLSession) async throws {
        guard length < file.size else { return }
        var request = URLRequest(url: url)
        if length > 0 { request.setValue("bytes=\(length)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        task.delegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(disposition(for: response))
    }

    private func disposition(for response: URLResponse) -> URLSession.ResponseDisposition {
        guard let response = response as? HTTPURLResponse else {
            failure = TransferError(reason: String(localized: "It didn’t answer over HTTP.", bundle: .module))
            return .cancel
        }
        switch response.statusCode {
        case 206:
            // The rest of the file, from where the partial one ends, of a file the listed size.
            guard let range = response.value(forHTTPHeaderField: "Content-Range").flatMap(Self.parse),
                  range.start == length, range.total == nil || range.total == file.size
            else {
                failure = TransferError(reason: String(localized: "It sent another part of the file than the one asked for.", bundle: .module))
                return .cancel
            }
            return .allow
        case 200:
            // The whole file: the server ignored the range, so what was kept goes.
            if response.expectedContentLength > 0, response.expectedContentLength != file.size {
                failure = TransferError(reason: String(localized: "It has another file there, of \(response.expectedContentLength) bytes.", bundle: .module))
                return .cancel
            }
            if length > 0 {
                do {
                    try handle?.truncate(atOffset: 0)
                } catch {
                    failure = ModelPackError.unwritable(error.localizedDescription)
                    return .cancel
                }
                meter.rewind(length)
                hasher = SHA256()
                length = 0
            }
            return .allow
        case 416:
            // Nothing after the partial file: it is whole or wrong, and the check after says which.
            return .cancel
        default:
            failure = TransferError(reason: String(localized: "It answered HTTP \(response.statusCode).", bundle: .module))
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        if length + Int64(data.count) > file.size {
            failure = TransferError(reason: String(localized: "It sent more than the file.", bundle: .module))
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = ModelPackError.unwritable(error.localizedDescription)
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        length += Int64(data.count)
        meter.add(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error = error as? URLError, error.code == .cancelled, (task.response as? HTTPURLResponse)?.statusCode == 416 {
            continuation.resume()
        } else if let error = error as? URLError, error.code == .cancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: TransferError(reason: error.localizedDescription))
        } else {
            continuation.resume()
        }
    }

    /// "bytes 1000-1999/21159378" (the total may be "*").
    static func parse(_ header: String) -> (start: Int64, total: Int64?)? {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = text.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let start = Int64(parts[0][..<dash]) else { return nil }
        return (start, Int64(parts[1]))
    }
}
