import Foundation

/// The invitation to MMFoundation's Discord, the community of the organization that makes OhMyShot: once ever, and
/// only to someone who has been using the app for a while.
///
/// It may appear at a launch once captures have been kept on several days, never at the first launch. Kept captures
/// are counted as they are kept and launches as they happen, a few numbers in the defaults: nothing runs in between,
/// so waiting for it costs nothing. It is never shown over work in progress, and once shown it is spent, however it
/// was closed. Settings › About and the menu bar keep their Join Discord links.
@MainActor
public final class CommunityInvite {
    /// The organization's Discord. The website answers it with a redirect to the server's current invite, so a new
    /// invite never needs a new version of the app.
    public static let discord = URL(string: "https://mmfoundation.dev/discord")!

    /// Captures kept, screenshots and recordings alike, before the invitation may appear.
    public static let capturesNeeded = 10
    /// The different days those captures have to be spread over, so a first busy afternoon is not enough.
    public static let daysNeeded = 3

    private let defaults: UserDefaults

    /// Launches since the invitation began counting, this one included once `launched()` is called.
    public private(set) var launches: Int
    /// Captures kept since it began counting.
    public private(set) var captures: Int
    /// The different days, in the calendar of the moment, a capture was kept on.
    public private(set) var days: Int
    /// When the last capture was kept, to tell whether the next is on a new day.
    private var lastCapture: Date?
    /// Whether it has been shown: then it never appears again.
    public private(set) var wasShown: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launches = defaults.integer(forKey: Key.launches)
        captures = defaults.integer(forKey: Key.captures)
        days = defaults.integer(forKey: Key.days)
        lastCapture = defaults.object(forKey: Key.lastCapture) as? Date
        wasShown = defaults.bool(forKey: Key.shown)
    }

    /// The app has launched.
    public func launched() {
        guard !wasShown else { return }
        launches += 1
        defaults.set(launches, forKey: Key.launches)
    }

    /// A capture was kept in the history at `date`.
    public func captureKept(at date: Date = .now, calendar: Calendar = .current) {
        guard !wasShown else { return }
        captures += 1
        defaults.set(captures, forKey: Key.captures)
        if lastCapture.map({ !calendar.isDate($0, inSameDayAs: date) }) ?? true {
            days += 1
            defaults.set(days, forKey: Key.days)
        }
        lastCapture = date
        defaults.set(date, forKey: Key.lastCapture)
    }

    /// Whether the invitation may appear now: not shown before, not the first launch, enough captures over enough
    /// days, and nothing in progress (`busy`: a capture, a recording, an editor, another window asking for an answer).
    public func mayAppear(busy: Bool) -> Bool {
        !wasShown && !busy && launches >= 2 && captures >= Self.capturesNeeded && days >= Self.daysNeeded
    }

    /// It appeared: spent for good, whether it was answered, closed, or left open as the app quit.
    public func shown() {
        wasShown = true
        defaults.set(true, forKey: Key.shown)
    }

    private enum Key {
        static let launches = "communityInviteLaunches"
        static let captures = "communityInviteCaptures"
        static let days = "communityInviteDays"
        static let lastCapture = "communityInviteLastCapture"
        static let shown = "communityInviteShown"
    }
}
