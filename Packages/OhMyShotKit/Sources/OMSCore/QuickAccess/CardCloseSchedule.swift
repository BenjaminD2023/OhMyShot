import Foundation

/// Which Quick Access cards close by themselves, and when: what holds each card, each card's countdown, and the
/// cards that stay because their copy could not be saved when their time was up. The stack asks it when to wake
/// and whom to close; it keeps no timer of its own.
///
/// Pure: every call says what time it is, so none of this waits.
public struct CardCloseSchedule: Sendable {
    /// What holds each card now, whether or not closing by itself is on, so turning it on finds the pointer where it is.
    private var holds: [UUID: Set<CardCountdown.Hold>] = [:]
    /// When each card closes, while closing by itself is on.
    private var countdowns: [UUID: CardCountdown] = [:]
    /// Cards whose copy could not be saved when their time was up: they stay until closed.
    private var kept: Set<UUID> = []

    public init() {}

    /// What holds card `id` now.
    public func holds(on id: UUID) -> Set<CardCountdown.Hold> {
        holds[id] ?? []
    }

    /// Whether card `id` has a countdown.
    public func isCounting(_ id: UUID) -> Bool {
        countdowns[id] != nil
    }

    /// Whether card `id` stays until closed, its copy having failed to save.
    public func isKept(_ id: UUID) -> Bool {
        kept.contains(id)
    }

    /// Holds card `id` for `hold`, or lets that hold go (`on` false). A card's time stops with its first hold and,
    /// when the last ends, runs at least `CardCountdown.grace` more.
    public mutating func hold(_ hold: CardCountdown.Hold, for id: UUID, if on: Bool, at now: TimeInterval) {
        if on { holds[id, default: []].insert(hold) } else { holds[id]?.remove(hold) }
        guard var countdown = countdowns[id] else { return }
        if on { countdown.hold(hold, at: now) } else { countdown.release(hold, at: now) }
        countdowns[id] = countdown
    }

    /// Gives card `id` its time again, as when it is brought back.
    public mutating func restart(_ id: UUID) {
        countdowns[id] = nil
    }

    /// Starts the time of every card in `ids` that has none, when closing by itself is on (`interval` is the time
    /// each has), and stops all of it when it is off. A card already counting keeps its own time, whatever the
    /// interval was, and a kept card is not started again.
    public mutating func sync(cards ids: [UUID], interval: TimeInterval?, at now: TimeInterval) {
        guard let interval else {
            countdowns = [:]
            return
        }
        for id in ids where countdowns[id] == nil && !kept.contains(id) {
            var countdown = CardCountdown(interval: interval, at: now)
            for hold in holds[id] ?? [] { countdown.hold(hold, at: now) }
            countdowns[id] = countdown
        }
    }

    /// Seconds until the first card is due; nil while every card is held or none counts down.
    public func timeUntilNextClose(at now: TimeInterval) -> TimeInterval? {
        countdowns.values.compactMap { $0.timeLeft(at: now) }.min()
    }

    /// The active countdown state (remaining time and total interval) for card `id`, or nil when it is held or not counting.
    public func countdownState(for id: UUID, at now: TimeInterval) -> (remaining: TimeInterval, interval: TimeInterval)? {
        guard let countdown = countdowns[id], let left = countdown.timeLeft(at: now), left > 0 else { return nil }
        return (left, countdown.interval)
    }

    /// The cards whose time is up. Their countdowns end: a card that stays (`keepOpen`) is not counted again.
    public mutating func takeDue(at now: TimeInterval) -> [UUID] {
        let due = countdowns.filter { $0.value.isDue(at: now) }.map(\.key)
        for id in due { countdowns[id] = nil }
        return due
    }

    /// Card `id` stays until closed: its copy could not be saved, and it is not tried again.
    public mutating func keepOpen(_ id: UUID) {
        kept.insert(id)
    }

    /// Drops everything about card `id`, which is gone: nothing of it may wake the timer.
    public mutating func forget(_ id: UUID) {
        holds[id] = nil
        countdowns[id] = nil
        kept.remove(id)
    }

    /// Drops everything, for a stack that is gone.
    public mutating func removeAll() {
        self = CardCloseSchedule()
    }
}
