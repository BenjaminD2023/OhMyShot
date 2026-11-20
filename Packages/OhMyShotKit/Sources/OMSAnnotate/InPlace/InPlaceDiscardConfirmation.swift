struct InPlaceDiscardConfirmation {
    private(set) var deadline: ContinuousClock.Instant?

    mutating func mayDiscard(hasMarks: Bool, now: ContinuousClock.Instant = .now) -> Bool {
        if !hasMarks || deadline.map({ now < $0 }) == true {
            deadline = nil
            return true
        }
        deadline = now.advanced(by: .seconds(4))
        return false
    }
}
