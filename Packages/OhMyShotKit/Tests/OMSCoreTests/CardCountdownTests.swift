import Testing
@testable import OMSCore

/// When a Quick Access card closes by itself: its time runs out, stops while anything holds the card, and starts
/// again with a few seconds in hand. Every call says what time it is, so none of this waits.
struct CardCountdownTests {
    @Test func aCardIsDueWhenItsIntervalIsUp() {
        let countdown = CardCountdown(interval: 5, at: 100)
        #expect(!countdown.isDue(at: 100))
        #expect(!countdown.isDue(at: 104.9))
        #expect(countdown.isDue(at: 105))
        #expect(countdown.isDue(at: 500))
        #expect(countdown.timeLeft(at: 102) == 3)
    }

    @Test func aHeldCardIsNeverDue() {
        var countdown = CardCountdown(interval: 5, at: 0)
        countdown.hold(.pointer, at: 2)
        #expect(countdown.isHeld)
        #expect(countdown.timeLeft(at: 3) == nil)
        #expect(!countdown.isDue(at: 1_000))
    }

    @Test func aCardThePointerLeavesHasAtLeastTheGraceLeft() {
        var countdown = CardCountdown(interval: 10, at: 0)
        // Held with 1 second left; let go much later.
        countdown.hold(.pointer, at: 9)
        countdown.release(.pointer, at: 60)
        #expect(countdown.timeLeft(at: 60) == CardCountdown.grace)
        #expect(!countdown.isDue(at: 63.9))
        #expect(countdown.isDue(at: 64))
    }

    @Test(arguments: [CardCountdown.Hold.pointer, .preview])
    func aThreeSecondCardPausesForInteractionAndHasThreeSecondsAfterward(_ hold: CardCountdown.Hold) {
        var countdown = CardCountdown(interval: 3, at: 100)
        #expect(!countdown.isDue(at: 102.9))
        countdown.hold(hold, at: 102.9)
        #expect(countdown.timeLeft(at: 1_000) == nil)
        #expect(!countdown.isDue(at: 1_000))
        countdown.release(hold, at: 1_000)
        #expect(countdown.timeLeft(at: 1_000) == 3)
        #expect(!countdown.isDue(at: 1_002.9))
        #expect(countdown.isDue(at: 1_003))
    }

    @Test func aCardKeepsWhatItHadWhenThatIsMoreThanTheGrace() {
        var countdown = CardCountdown(interval: 60, at: 0)
        countdown.hold(.menu, at: 10)
        countdown.release(.menu, at: 100)
        // 50 seconds were left when it was held.
        #expect(countdown.timeLeft(at: 100) == 50)
        #expect(countdown.isDue(at: 150))
    }

    @Test func theGraceIsNeverLongerThanTheInterval() {
        var countdown = CardCountdown(interval: 2, at: 0)
        countdown.hold(.pointer, at: 1.5)
        countdown.release(.pointer, at: 10)
        #expect(countdown.timeLeft(at: 10) == 2)
    }

    @Test func aCardStaysHeldUntilEveryHoldIsLetGo() {
        var countdown = CardCountdown(interval: 5, at: 0)
        countdown.hold(.pointer, at: 1)
        countdown.hold(.upload, at: 2)
        countdown.release(.pointer, at: 3)
        #expect(countdown.isHeld)
        #expect(!countdown.isDue(at: 1_000))
        countdown.release(.upload, at: 20)
        #expect(!countdown.isHeld)
        #expect(countdown.timeLeft(at: 20) == CardCountdown.grace)
    }

    @Test func holdingTwiceForTheSameReasonIsOneHold() {
        var countdown = CardCountdown(interval: 5, at: 0)
        countdown.hold(.keyboard, at: 1)
        countdown.hold(.keyboard, at: 2)
        countdown.release(.keyboard, at: 3)
        #expect(!countdown.isHeld)
    }

    @Test func lettingGoOfWhatWasNotHeldChangesNothing() {
        var countdown = CardCountdown(interval: 5, at: 0)
        countdown.release(.drag, at: 4)
        #expect(countdown.timeLeft(at: 4) == 1)
        countdown.hold(.preview, at: 4)
        countdown.release(.menu, at: 30)
        #expect(countdown.isHeld)
    }
}
