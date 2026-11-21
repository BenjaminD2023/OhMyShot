import Foundation

/// A copied recording is a file reference. Timed history checks it on demand; only Never needs to notice
/// the clipboard changing while the app is idle.
@MainActor
public final class RecordingClipboardHold {
    private let changeCount: () -> Int
    private let released: (UUID) -> Void
    private var recording: (id: UUID, changeCount: Int)?
    private(set) var watch: Task<Void, Never>?

    public init(changeCount: @escaping () -> Int, released: @escaping (UUID) -> Void) {
        self.changeCount = changeCount
        self.released = released
    }

    public var heldID: UUID? {
        guard let recording, recording.changeCount == changeCount() else { return nil }
        return recording.id
    }

    public func copied(_ id: UUID, retention: HistoryRetention) {
        let former = recording?.id
        recording = (id, changeCount())
        updatePolling(for: retention)
        if let former, former != id { released(former) }
    }

    public func updatePolling(for retention: HistoryRetention) {
        guard retention == .never, recording != nil else {
            watch?.cancel()
            watch = nil
            return
        }
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                poll()
            }
        }
    }

    func poll() {
        guard watch != nil, let recording, heldID == nil else { return }
        self.recording = nil
        watch?.cancel()
        watch = nil
        released(recording.id)
    }
}
