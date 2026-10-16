import Foundation

/// Work that runs once for a key however many ask for it while it goes: a second request for a key whose work is
/// still running waits for it and has its answer, instead of starting the work again. Quick Access saves a capture
/// this way, so a double ⌘S, Save All over a Save, and a card closing by itself under a Save in progress make one
/// file and take one number.
///
/// The work is tracked on the main actor, where a request is also taken: the check for work already under way and
/// its start are one step, with nothing between them for another request to slip into.
@MainActor
public final class SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var running: [Key: Task<Value, Never>] = [:]

    public init() {}

    /// Whether work for `key` is running now.
    public func isRunning(_ key: Key) -> Bool {
        running[key] != nil
    }

    /// The work's answer: from `work` if nothing for `key` is running, else from the work that is, with `work` left unrun.
    public func run(_ key: Key, _ work: @escaping @MainActor () async -> Value) async -> Value {
        if let task = running[key] { return await task.value }
        let task = Task {
            let value = await work()
            // Done in the same step as the work, so a request after it starts new work and never joins finished work.
            running[key] = nil
            return value
        }
        running[key] = task
        return await task.value
    }
}
