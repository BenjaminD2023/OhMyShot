import Synchronization

/// Counts everything that costs power or memory while it is alive.
///
/// Idle has to mean idle: once nothing of ours is on screen, every count is zero. Code that starts a
/// capture stream, an event monitor, a timer, or holds a full-screen frame takes a lease and ends it
/// when done. Debug hooks and the power gate read `snapshot` to prove nothing was left running.
public final class ActiveResources: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case captureStream
        case eventMonitor
        case eventTap
        case timer
        case frameBuffer
        case window
        case activity
        /// A process of the app's own running beside it (the text reader).
        case helperProcess
    }

    public static let shared = ActiveResources()

    private let counts = Mutex<[Kind: Int]>([:])

    public init() {}

    /// Registers one live resource. It is released when the lease ends or is deallocated.
    public func acquire(_ kind: Kind) -> Lease {
        counts.withLock { $0[kind, default: 0] += 1 }
        return Lease(kind: kind, registry: self)
    }

    /// Live resources by kind. Kinds with nothing alive are omitted, so idle is an empty dictionary.
    public var snapshot: [Kind: Int] {
        counts.withLock { $0 }
    }

    public var isIdle: Bool { snapshot.isEmpty }

    fileprivate func release(_ kind: Kind) {
        counts.withLock { counts in
            let remaining = counts[kind, default: 0] - 1
            precondition(remaining >= 0, "ActiveResources: \(kind) released more often than acquired")
            counts[kind] = remaining == 0 ? nil : remaining
        }
    }

    /// A handle on one registered resource. Ending it more than once is harmless.
    public final class Lease: Sendable {
        public let kind: Kind
        private let registry: ActiveResources
        private let ended = Atomic<Bool>(false)

        fileprivate init(kind: Kind, registry: ActiveResources) {
            self.kind = kind
            self.registry = registry
        }

        public func end() {
            guard !ended.exchange(true, ordering: .acquiringAndReleasing) else { return }
            registry.release(kind)
        }

        deinit { end() }
    }
}
