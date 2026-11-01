import Foundation
import Testing
@testable import OMSCore

@MainActor
struct CommunityInviteTests {
    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    /// A calendar of its own, so the days don't move with the Mac's time zone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// Noon on 2 November 2026 and the days after it, in the test's calendar.
    private func day(_ offset: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 2 + offset, hour: hour))!
    }

    /// Keeps `count` captures on each of `days` days, from the first.
    private func keep(_ count: Int, onEachOf days: Int, in invite: CommunityInvite) {
        for offset in 0..<days {
            for minute in 0..<count {
                invite.captureKept(at: day(offset).addingTimeInterval(TimeInterval(minute * 60)), calendar: calendar)
            }
        }
    }

    @Test func aNewInstallIsNotInvited() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.launched()
        #expect(!invite.mayAppear(busy: false))
    }

    /// Captures enough over enough days, all in the first launch, still wait for a later one.
    @Test func neverAtTheFirstLaunch() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.launched()
        keep(10, onEachOf: 3, in: invite)
        #expect(!invite.mayAppear(busy: false))
        let next = CommunityInvite(defaults: defaults)
        next.launched()
        #expect(next.mayAppear(busy: false))
    }

    @Test func manyCapturesOnOneDayAreNotEnough() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.launched()
        invite.launched()
        keep(50, onEachOf: 1, in: invite)
        #expect(invite.captures == 50 && invite.days == 1)
        #expect(!invite.mayAppear(busy: false))
    }

    @Test func enoughDaysWithTooFewCapturesAreNotEnough() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.launched()
        invite.launched()
        keep(3, onEachOf: 3, in: invite)
        #expect(invite.captures == 9 && invite.days == 3)
        #expect(!invite.mayAppear(busy: false))
        invite.captureKept(at: day(2, hour: 18), calendar: calendar)
        #expect(invite.mayAppear(busy: false))
    }

    /// Days are calendar days: just before and just after midnight are two, a morning and an evening one.
    @Test func daysAreCalendarDays() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.captureKept(at: day(0, hour: 8), calendar: calendar)
        invite.captureKept(at: day(0, hour: 22), calendar: calendar)
        #expect(invite.days == 1)
        invite.captureKept(at: day(0, hour: 23).addingTimeInterval(59 * 60), calendar: calendar)
        invite.captureKept(at: day(1, hour: 0).addingTimeInterval(60), calendar: calendar)
        #expect(invite.days == 2)
        // A day back, as after the clock was set back, is a day of its own too.
        invite.captureKept(at: day(0, hour: 12), calendar: calendar)
        #expect(invite.days == 3)
    }

    @Test func nothingInProgressIsInterrupted() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.launched()
        invite.launched()
        keep(4, onEachOf: 3, in: invite)
        #expect(!invite.mayAppear(busy: true))
        #expect(invite.mayAppear(busy: false))
    }

    /// Shown once, closed any way, it never appears again, across launches too, and stops counting.
    @Test func onceShownNeverAgain() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.launched()
        invite.launched()
        keep(4, onEachOf: 3, in: invite)
        #expect(invite.mayAppear(busy: false))
        invite.shown()
        #expect(!invite.mayAppear(busy: false))
        let next = CommunityInvite(defaults: defaults)
        next.launched()
        keep(10, onEachOf: 5, in: next)
        #expect(next.wasShown && !next.mayAppear(busy: false))
        #expect(next.launches == 2 && next.captures == 12)
    }

    @Test func theCountsAreKeptAcrossLaunches() throws {
        let (defaults, cleanUp) = try makeDefaults()
        defer { cleanUp() }
        let invite = CommunityInvite(defaults: defaults)
        invite.launched()
        keep(2, onEachOf: 2, in: invite)
        let next = CommunityInvite(defaults: defaults)
        #expect(next.launches == 1 && next.captures == 4 && next.days == 2 && !next.wasShown)
        // The last capture's day is kept as well: another on it is not a new day.
        next.captureKept(at: day(1, hour: 20), calendar: calendar)
        #expect(next.days == 2)
    }
}
