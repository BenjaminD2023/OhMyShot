import Foundation

/// The captures shortcuts are still handing on. With Keep Captures at Never a capture lives only as long as something
/// holds it, and with Quick Access off nothing else may: the capture would go before the shortcut read its file. So a
/// shortcut holds its capture from the moment it is kept until its file is read, and lets go of it then, however the
/// shortcut ended, so nothing is kept after it.
@MainActor
public final class ShortcutCaptureHolds {
    public private(set) var heldIDs = Set<UUID>()
    /// Told a capture once no shortcut holds it, so it can go if nothing else does.
    private let released: (UUID) -> Void

    public init(released: @escaping (UUID) -> Void) {
        self.released = released
    }

    /// Runs a shortcut's `work`, which calls `hold` with its capture's ID as soon as the capture is kept. The capture is
    /// held until `work` ends: with the file read, with an error, or cancelled. A `hold` after that holds nothing. With
    /// `lettingGo` off the hold ends without a word, and the capture is left as one kept without a shortcut is: a pinned
    /// capture, which the pin's Save and drag still read.
    public func holding<Result>(
        lettingGo: Bool = true, _ work: (_ hold: @escaping (UUID) -> Void) async throws -> Result
    ) async rethrows -> Result {
        var held = Set<UUID>(), ended = false
        defer {
            ended = true
            for id in held {
                heldIDs.remove(id)
                if lettingGo { released(id) }
            }
        }
        return try await work { [weak self] id in
            guard !ended, let self else { return }
            held.insert(id)
            heldIDs.insert(id)
        }
    }
}
