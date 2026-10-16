import Foundation
import Observation
import OSLog

/// What a card or a list shows of an upload.
public enum UploadStatus: Equatable, Sendable {
    case uploading(fraction: Double)
    case finished(link: URL)
    case failed(message: String)
}

/// The uploads in flight and the last result of each, keyed by the capture they carry.
///
/// An upload belongs to the capture, not to its card: closing the card, or the History window, leaves it
/// running, and whoever shows the capture next finds its state here. Nothing in here runs between uploads.
/// Each upload is one `UploadJob` (which holds the `ActiveResources` lease while it transfers) and one
/// observer task that ends the moment the job does.
///
/// The center touches no interface: where a link goes when an upload ends is the closure given with the
/// upload, and the interface listens to `onChange`.
@MainActor
@Observable
public final class UploadCenter {
    /// What is needed to run an upload again after it failed.
    private struct Request {
        let fileURL: URL
        let originalName: String?
        let destinationID: UUID
        let finished: @MainActor (UploadResult, UploadDestination) -> Void
    }

    private struct Entry {
        let job: UploadJob
        let request: Request
        var observer: Task<Void, Never>?
    }

    @ObservationIgnored private let store: UploadDestinationStore
    @ObservationIgnored private let uploader: Uploader
    private var entries: [UUID: Entry] = [:]

    /// Told when a capture's upload begins, moves, ends, or is dropped (nil), with the destination's name.
    @ObservationIgnored public var onChange: ((_ captureID: UUID, _ status: UploadStatus?, _ destinationName: String) -> Void)?

    public init(store: UploadDestinationStore, uploader: Uploader) {
        self.store = store
        self.uploader = uploader
    }

    /// Uploads a capture's file.
    ///
    /// - Parameters:
    ///   - originalName: The name the person knows the capture by; history files are stored under others.
    ///   - destinationID: nil for the default destination.
    ///   - finished: Runs once, on the main actor, when the file is up, with its result and destination. It
    ///     is where a link is copied and announced; a retry runs it too.
    /// - Returns: false when there is no such destination, or the capture is already uploading.
    @discardableResult
    public func start(
        captureID: UUID,
        fileURL: URL,
        originalName: String?,
        destinationID: UUID? = nil,
        finished: @escaping @MainActor (UploadResult, UploadDestination) -> Void
    ) -> Bool {
        guard let destination = destinationID.flatMap(store.destination(id:)) ?? (destinationID == nil ? store.defaultDestination : nil) else {
            return false
        }
        return begin(captureID, Request(fileURL: fileURL, originalName: originalName, destinationID: destination.id, finished: finished), destination)
    }

    /// Runs a failed upload again, to the same destination, as a new job.
    @discardableResult
    public func retry(captureID: UUID) -> Bool {
        guard
            let entry = entries[captureID], case .failed = entry.job.state,
            let destination = store.destination(id: entry.request.destinationID)
        else { return false }
        return begin(captureID, entry.request, destination)
    }

    private func begin(_ captureID: UUID, _ request: Request, _ destination: UploadDestination) -> Bool {
        if let running = entries[captureID], !running.job.state.isFinal { return false }
        let job = UploadJob(fileURL: request.fileURL, destination: destination, originalName: request.originalName, uploader: uploader)
        entries[captureID] = Entry(job: job, request: request, observer: nil)
        job.start()
        entries[captureID]?.observer = Task { [weak self] in
            // Ends with the job: the observation finishes once the state is final.
            let progress = Observations.untilFinished { () -> Observations<UploadStatus, Never>.Iteration in
                switch job.state {
                case .waiting: .next(.uploading(fraction: 0))
                case .uploading(let fraction): .next(.uploading(fraction: fraction))
                case .finished, .failed, .cancelled: .finish
                }
            }
            for await status in progress {
                self?.report(captureID, job, status)
            }
            self?.settle(captureID, job)
        }
        onChange?(captureID, .uploading(fraction: 0), destination.name)
        return true
    }

    private func report(_ captureID: UUID, _ job: UploadJob, _ status: UploadStatus) {
        guard entries[captureID]?.job === job else { return }
        onChange?(captureID, status, job.destination.name)
    }

    private func settle(_ captureID: UUID, _ job: UploadJob) {
        guard let entry = entries[captureID], entry.job === job else { return }
        switch job.state {
        case .finished(let result):
            Log.upload.notice("Upload finished")
            onChange?(captureID, .finished(link: result.link), job.destination.name)
            entry.request.finished(result, job.destination)
        case .failed(let error):
            // What the server said is the person's to read on the card, not for the log.
            Log.upload.error("Upload failed")
            onChange?(captureID, .failed(message: error.localizedDescription), job.destination.name)
        case .cancelled, .waiting, .uploading:
            Log.upload.notice("Upload cancelled")
            entries[captureID] = nil
            onChange?(captureID, nil, job.destination.name)
        }
    }

    // MARK: Asking

    public func status(for captureID: UUID) -> UploadStatus? {
        guard let entry = entries[captureID] else { return nil }
        switch entry.job.state {
        case .waiting: return .uploading(fraction: 0)
        case .uploading(let fraction): return .uploading(fraction: fraction)
        case .finished(let result): return .finished(link: result.link)
        case .failed(let error): return .failed(message: error.localizedDescription)
        case .cancelled: return nil
        }
    }

    public func isUploading(_ captureID: UUID) -> Bool {
        entries[captureID].map { !$0.job.state.isFinal } ?? false
    }

    /// The captures being uploaded now: their files must stay where they are.
    public var uploadingIDs: Set<UUID> {
        Set(entries.filter { !$0.value.job.state.isFinal }.keys)
    }

    public var isIdle: Bool { uploadingIDs.isEmpty }

    /// The link of a capture's last finished upload, while the center remembers it.
    public func link(for captureID: UUID) -> URL? {
        if case .finished(let link)? = status(for: captureID) { return link }
        return nil
    }

    // MARK: Ending

    /// Stops a capture's upload.
    public func cancel(captureID: UUID) {
        entries[captureID]?.job.cancel()
    }

    /// Stops every upload and waits until the transfers have, so their temporary files are gone.
    public func cancelAll() async {
        let jobs = entries.values.map(\.job)
        jobs.forEach { $0.cancel() }
        for job in jobs { _ = await job.finish() }
    }

    /// Drops what is remembered of a capture's last upload (its link, or its failure), unless one is running.
    public func forget(captureID: UUID) {
        guard let entry = entries[captureID], entry.job.state.isFinal else { return }
        entries[captureID] = nil
    }
}
