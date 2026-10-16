import Foundation
import Observation

/// One upload as a card or a progress bar watches it: start it, read `state`, cancel it.
///
/// The job holds the task that awaits the upload, so cancelling the job cancels the transfer. Its `state`
/// is observable, and `fraction` moves at most about a hundred times over the whole upload.
@MainActor
@Observable
public final class UploadJob: Identifiable {
    public enum State: Equatable {
        case waiting
        case uploading(fraction: Double)
        case finished(UploadResult)
        case failed(UploadError)
        case cancelled

        public var isFinal: Bool {
            switch self {
            case .waiting, .uploading: false
            case .finished, .failed, .cancelled: true
            }
        }
    }

    public let id = UUID()
    public let fileURL: URL
    public let destination: UploadDestination
    public private(set) var state: State = .waiting

    @ObservationIgnored private let uploader: Uploader
    @ObservationIgnored private let originalName: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(fileURL: URL, destination: UploadDestination, originalName: String? = nil, uploader: Uploader) {
        self.fileURL = fileURL
        self.destination = destination
        self.originalName = originalName
        self.uploader = uploader
    }

    /// Begins the upload. Calling it again while one is running does nothing.
    public func start() {
        guard task == nil else { return }
        state = .uploading(fraction: 0)
        let uploader = uploader, fileURL = fileURL, destination = destination, originalName = originalName
        task = Task { [weak self] in
            let outcome: State
            do {
                let result = try await uploader.upload(fileAt: fileURL, to: destination, originalName: originalName) { fraction in
                    Task { @MainActor in self?.reportProgress(fraction) }
                }
                outcome = .finished(result)
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as UploadError {
                outcome = .failed(error)
            } catch {
                outcome = .failed(.invalidConfiguration(error.localizedDescription))
            }
            self?.state = outcome
        }
    }

    /// Stops the upload. The state becomes `.cancelled` once the transfer has stopped.
    public func cancel() {
        task?.cancel()
        if task == nil, !state.isFinal { state = .cancelled }
    }

    /// Waits for the upload to end and gives its final state.
    public func finish() async -> State {
        await task?.value
        return state
    }

    private func reportProgress(_ fraction: Double) {
        // A late report must not move a job that has already ended.
        if case .uploading = state { state = .uploading(fraction: fraction) }
    }
}
