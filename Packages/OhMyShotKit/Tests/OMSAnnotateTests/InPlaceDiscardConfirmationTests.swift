import Testing
@testable import OMSAnnotate

struct InPlaceDiscardConfirmationTests {
    @Test func onlyTwoSeparateRequestsCanDiscardMarks() {
        var confirmation = InPlaceDiscardConfirmation()
        let now = ContinuousClock.now
        let empty = confirmation.mayDiscard(hasMarks: false, now: now)
        let first = confirmation.mayDiscard(hasMarks: true, now: now)
        let second = confirmation.mayDiscard(hasMarks: true, now: now.advanced(by: .seconds(1)))
        let next = confirmation.mayDiscard(hasMarks: true, now: now.advanced(by: .seconds(2)))
        #expect(empty)
        #expect(!first)
        #expect(second)
        #expect(!next)
    }

    @Test func anExpiredRequestCannotDiscardMarks() throws {
        var confirmation = InPlaceDiscardConfirmation()
        let first = confirmation.mayDiscard(hasMarks: true)
        let expired = try #require(confirmation.deadline)
        let late = confirmation.mayDiscard(hasMarks: true, now: expired)
        let second = confirmation.mayDiscard(hasMarks: true, now: expired.advanced(by: .seconds(1)))
        #expect(!first)
        #expect(!late)
        #expect(second)
    }
}
