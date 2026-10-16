import Foundation
import Testing
@testable import OMSCore

/// Which cards close by themselves, and when: the holds and countdowns of the whole stack. Every call says what
/// time it is, so none of this waits.
struct CardCloseScheduleTests {
    private let first = UUID()
    private let second = UUID()

    @Test func cardsStartTheirTimeAndCloseWhenItIsUp() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first], interval: 10, at: 100)
        #expect(schedule.isCounting(first))
        #expect(schedule.timeUntilNextClose(at: 104) == 6)
        #expect(schedule.takeDue(at: 109).isEmpty)
        #expect(schedule.takeDue(at: 110) == [first])
        // A card that was taken is not due again.
        #expect(!schedule.isCounting(first))
        #expect(schedule.takeDue(at: 500).isEmpty)
    }

    @Test func nothingCountsDownWhileClosingByItselfIsOff() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first, second], interval: nil, at: 0)
        #expect(!schedule.isCounting(first) && !schedule.isCounting(second))
        #expect(schedule.timeUntilNextClose(at: 0) == nil)
        #expect(schedule.takeDue(at: 1_000).isEmpty)
    }

    @Test func turningItOffStopsTheCardsAlreadyCounting() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first], interval: 10, at: 0)
        schedule.sync(cards: [first], interval: nil, at: 5)
        #expect(!schedule.isCounting(first))
        #expect(schedule.timeUntilNextClose(at: 5) == nil)
    }

    @Test func aCardAlreadyCountingKeepsItsOwnTime() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first], interval: 10, at: 0)
        // The interval was changed in Settings; a card that came later has the new one.
        schedule.sync(cards: [first, second], interval: 60, at: 4)
        #expect(schedule.timeUntilNextClose(at: 4) == 6)
        #expect(schedule.takeDue(at: 10) == [first])
        #expect(schedule.takeDue(at: 63).isEmpty)
        #expect(schedule.takeDue(at: 64) == [second])
    }

    @Test func aHeldCardWaitsAndThenHasTheGraceLeft() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first], interval: 10, at: 0)
        schedule.hold(.pointer, for: first, if: true, at: 8)
        #expect(schedule.holds(on: first) == [.pointer])
        #expect(schedule.timeUntilNextClose(at: 9) == nil)
        #expect(schedule.takeDue(at: 1_000).isEmpty)
        schedule.hold(.pointer, for: first, if: false, at: 50)
        #expect(schedule.holds(on: first).isEmpty)
        // Two seconds were left; a card the pointer just left has the grace.
        #expect(schedule.timeUntilNextClose(at: 50) == CardCountdown.grace)
        #expect(schedule.takeDue(at: 53.9).isEmpty)
        #expect(schedule.takeDue(at: 54) == [first])
    }

    @Test func aCardWaitsUntilEveryHoldIsGone() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first], interval: 5, at: 0)
        schedule.hold(.pointer, for: first, if: true, at: 1)
        schedule.hold(.menu, for: first, if: true, at: 2)
        schedule.hold(.pointer, for: first, if: false, at: 3)
        #expect(schedule.holds(on: first) == [.menu])
        #expect(schedule.timeUntilNextClose(at: 3) == nil)
        schedule.hold(.menu, for: first, if: false, at: 20)
        #expect(schedule.timeUntilNextClose(at: 20) == 4)
    }

    @Test func aHoldTakenBeforeCountingBeganIsThereWhenItDoes() {
        var schedule = CardCloseSchedule()
        // Closing by itself was off while the pointer came onto the card; then Settings turned it on.
        schedule.hold(.pointer, for: first, if: true, at: 0)
        #expect(!schedule.isCounting(first))
        schedule.sync(cards: [first], interval: 10, at: 30)
        #expect(schedule.isCounting(first))
        #expect(schedule.timeUntilNextClose(at: 31) == nil)
        schedule.hold(.pointer, for: first, if: false, at: 40)
        #expect(schedule.timeUntilNextClose(at: 40) == 10)
    }

    @Test func theNextCloseIsTheSoonestCardThatIsNotHeld() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first], interval: 5, at: 0)
        schedule.sync(cards: [first, second], interval: 30, at: 0)
        #expect(schedule.timeUntilNextClose(at: 1) == 4)
        schedule.hold(.keyboard, for: first, if: true, at: 1)
        #expect(schedule.timeUntilNextClose(at: 1) == 29)
        schedule.hold(.upload, for: second, if: true, at: 1)
        #expect(schedule.timeUntilNextClose(at: 1) == nil)
    }

    @Test func aCardBroughtBackStartsItsTimeAgain() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first], interval: 10, at: 0)
        schedule.restart(first)
        #expect(!schedule.isCounting(first))
        schedule.sync(cards: [first], interval: 10, at: 8)
        #expect(schedule.timeUntilNextClose(at: 9) == 9)
    }

    @Test func aCardWhoseCopyCouldNotBeSavedStaysAndIsNotStartedAgain() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first, second], interval: 10, at: 0)
        // Both are due; the first could not be saved, and the second was closed.
        let due = schedule.takeDue(at: 10)
        #expect(Set(due) == [first, second])
        schedule.keepOpen(first)
        schedule.forget(second)
        #expect(schedule.isKept(first))
        // Each later sync (a card closed, a card added) leaves it alone: no retry, no new time.
        schedule.sync(cards: [first], interval: 10, at: 11)
        schedule.sync(cards: [first], interval: 10, at: 500)
        #expect(!schedule.isCounting(first))
        #expect(schedule.timeUntilNextClose(at: 500) == nil)
        // The person closes it, and nothing of it is left.
        schedule.forget(first)
        #expect(!schedule.isKept(first))
    }

    @Test func aCardThatIsGoneLeavesNothingToWakeFor() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first, second], interval: 10, at: 0)
        schedule.hold(.pointer, for: first, if: true, at: 1)
        schedule.hold(.keyboard, for: second, if: true, at: 1)
        // One was trashed, the other deleted from History: neither may count, hold, or stay.
        schedule.forget(first)
        schedule.forget(second)
        #expect(!schedule.isCounting(first) && !schedule.isCounting(second))
        #expect(schedule.holds(on: first).isEmpty && schedule.holds(on: second).isEmpty)
        #expect(schedule.timeUntilNextClose(at: 2) == nil)
        // A card with the same identity brought back is a new card.
        schedule.sync(cards: [first], interval: 10, at: 20)
        #expect(schedule.timeUntilNextClose(at: 20) == 10)
    }

    @Test func aGoneCardsKeptMarkIsGoneToo() {
        var schedule = CardCloseSchedule()
        schedule.keepOpen(first)
        schedule.forget(first)
        schedule.sync(cards: [first], interval: 10, at: 0)
        #expect(schedule.isCounting(first))
    }

    @Test func removingAllLeavesNothing() {
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [first, second], interval: 10, at: 0)
        schedule.hold(.drag, for: first, if: true, at: 1)
        schedule.keepOpen(second)
        schedule.removeAll()
        #expect(!schedule.isCounting(first) && !schedule.isCounting(second))
        #expect(schedule.holds(on: first).isEmpty)
        #expect(!schedule.isKept(second))
        #expect(schedule.timeUntilNextClose(at: 2) == nil)
    }
}
