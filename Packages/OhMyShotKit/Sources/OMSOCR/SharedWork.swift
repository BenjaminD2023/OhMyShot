import Synchronization

/// Work done once for everyone who asks for it while it runs. What it makes is kept; when it fails, it is
/// forgotten, so the next ask starts it again; and once everyone waiting for it has stopped waiting, it is
/// stopped and forgotten too, so nothing runs on for nobody.
final class SharedWork<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private enum Entry {
        /// Under way, for those waiting on it.
        case running(run: Int, task: Task<Void, Never>, waiting: [Int: CheckedContinuation<Value, Error>])
        case done(Value)
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var lastID = 0
    }

    private let state = Mutex(State())
    private let work: @Sendable (Key) async throws -> Value

    init(_ work: @escaping @Sendable (Key) async throws -> Value) {
        self.work = work
    }

    deinit {
        state.withLock { state in
            for case .running(_, let task, _) in state.entries.values { task.cancel() }
        }
    }

    /// What the work makes for `key`: kept from before, or from the run under way, or from a run started
    /// now. Throws what the run throws, or `CancellationError` once the caller is cancelled, which stops
    /// the run if nobody else is waiting for it.
    func value(for key: Key) async throws -> Value {
        let waiter = state.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait(continuation, as: waiter, for: key)
            }
        } onCancel: {
            stopWaiting(waiter, for: key)
        }
    }

    private enum Arrival: Sendable {
        case kept(Value)
        case cancelled
        case waiting
    }

    private func wait(_ continuation: CheckedContinuation<Value, Error>, as waiter: Int, for key: Key) {
        let arrival = state.withLock { state -> Arrival in
            if case .done(let value) = state.entries[key] { return .kept(value) }
            // Cancelled before it began to wait, its cancellation found nothing to stop.
            if Task.isCancelled { return .cancelled }
            if case .running(let run, let task, var waiting) = state.entries[key] {
                waiting[waiter] = continuation
                state.entries[key] = .running(run: run, task: task, waiting: waiting)
            } else {
                state.lastID += 1
                let run = state.lastID
                let task = Task { [weak self, work] in
                    let result: Result<Value, Error>
                    do {
                        result = .success(try await work(key))
                    } catch {
                        result = .failure(error)
                    }
                    self?.finish(run, for: key, with: result)
                }
                state.entries[key] = .running(run: run, task: task, waiting: [waiter: continuation])
            }
            return .waiting
        }
        switch arrival {
        case .kept(let value): continuation.resume(returning: value)
        case .cancelled: continuation.resume(throwing: CancellationError())
        case .waiting: break
        }
    }

    private func stopWaiting(_ waiter: Int, for key: Key) {
        let (continuation, stopped) = state.withLock { state -> (CheckedContinuation<Value, Error>?, Task<Void, Never>?) in
            guard case .running(let run, let task, var waiting) = state.entries[key],
                  let continuation = waiting.removeValue(forKey: waiter)
            else { return (nil, nil) }
            guard waiting.isEmpty else {
                state.entries[key] = .running(run: run, task: task, waiting: waiting)
                return (continuation, nil)
            }
            // Nobody waits for it any more.
            state.entries[key] = nil
            return (continuation, task)
        }
        stopped?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ run: Int, for key: Key, with result: Result<Value, Error>) {
        let waiting = state.withLock { state -> [CheckedContinuation<Value, Error>] in
            // A run stopped for want of waiters has nobody to tell, and its place may be a newer run's.
            guard case .running(let current, _, let waiting) = state.entries[key], current == run else { return [] }
            if case .success(let value) = result {
                state.entries[key] = .done(value)
            } else {
                state.entries[key] = nil
            }
            return Array(waiting.values)
        }
        for continuation in waiting { continuation.resume(with: result) }
    }
}
