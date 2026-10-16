import Foundation

/// When one Quick Access card closes by itself. It counts down from the card's appearance, and stops while
/// anything holds the card: the pointer over it, its menu open, a drag out of it, Quick Look showing it,
/// the keyboard on it, an upload going, or the editor having its capture open. When the last hold ends the card gets at least `grace` more
/// seconds, so a card the pointer just left, or an upload that just finished, never vanishes under the eye.
///
/// Pure: every call says what time it is, so the timing is tested without waiting.
public struct CardCountdown: Equatable, Sendable {
    /// Why a card is kept.
    public enum Hold: Hashable, Sendable {
        case pointer
        case menu
        case drag
        case preview
        case keyboard
        /// An upload is going, or failed and waits for Retry.
        case upload
        /// The annotation editor has the capture open, and keeps its marks over the card's picture when it closes.
        case editor
    }

    /// The least a held card has left when its last hold ends, in seconds (or its whole time, when that is shorter).
    public static let grace: TimeInterval = 4

    public let interval: TimeInterval
    public private(set) var holds: Set<Hold> = []
    /// When the card is due while nothing holds it.
    private var deadline: TimeInterval
    /// What was left when the first hold began.
    private var left: TimeInterval

    public init(interval: TimeInterval, at now: TimeInterval) {
        self.interval = interval
        deadline = now + interval
        left = interval
    }

    /// Whether anything keeps the card from closing.
    public var isHeld: Bool { !holds.isEmpty }

    public mutating func hold(_ hold: Hold, at now: TimeInterval) {
        if holds.isEmpty { left = max(deadline - now, 0) }
        holds.insert(hold)
    }

    public mutating func release(_ hold: Hold, at now: TimeInterval) {
        guard holds.remove(hold) != nil, holds.isEmpty else { return }
        deadline = now + max(left, min(Self.grace, interval))
    }

    /// Seconds before the card closes; nil while it is held.
    public func timeLeft(at now: TimeInterval) -> TimeInterval? {
        isHeld ? nil : max(deadline - now, 0)
    }

    /// Whether the card's time is up.
    public func isDue(at now: TimeInterval) -> Bool {
        timeLeft(at: now) == 0
    }
}
