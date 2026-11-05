import Testing
@testable import OMSCore

/// When Settings warns that a capture won't be kept anywhere but History.
struct AfterCaptureKeepsNothingTests {
    private let none = AfterCapture(copies: false, showsQuickAccess: false, saves: false, uploads: false)

    @Test func nothingChosenKeepsNothing() {
        #expect(none.keepsNothing(hasDestination: false))
        #expect(none.keepsNothing(hasDestination: true))
    }

    @Test func anyOfCopyQuickAccessAndSaveKeepsIt() {
        var copies = none
        copies.copies = true
        var card = none
        card.showsQuickAccess = true
        var saves = none
        saves.saves = true
        for choice in [copies, card, saves] {
            #expect(!choice.keepsNothing(hasDestination: false))
        }
    }

    /// Upload keeps it only with a destination to upload to: without one, the choice isn't shown, and does nothing.
    @Test func uploadKeepsItOnlyWithADestination() {
        var uploads = none
        uploads.uploads = true
        #expect(!uploads.keepsNothing(hasDestination: true))
        #expect(uploads.keepsNothing(hasDestination: false))
    }
}
