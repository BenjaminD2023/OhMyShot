import Testing
@testable import OMSCapture

/// Whether the screenshot frames the overlay captures carry the pointer.
@MainActor
struct OverlayPointerTests {
    private static let purposes: [OverlayController.Purpose] = [.screenshot, .text, .annotate, .color, .measure, .record, .scroll]

    /// Only what a screenshot keeps: the frozen screen of Capture Area and Annotate Area. A color is read off the
    /// frame's pixels, the ruler measures them, text is read from them, and a recording or a scrolling capture is live.
    @Test func onlyAScreenshotsFrozenFramesCarryThePointer() {
        for purpose in Self.purposes {
            let keepsFrame = purpose == .screenshot || purpose == .annotate
            #expect(OverlayController.framesShowPointer(true, purpose: purpose, holdsStill: true) == keepsFrame, "\(purpose)")
        }
    }

    @Test func withoutTheSettingOrAFrozenScreenNoFrameCarriesIt() {
        for purpose in Self.purposes {
            #expect(!OverlayController.framesShowPointer(false, purpose: purpose, holdsStill: true), "\(purpose)")
            // A live screen is captured when the drag ends, by whoever began; the frames are only for the magnifier.
            #expect(!OverlayController.framesShowPointer(true, purpose: purpose, holdsStill: false), "\(purpose)")
        }
    }

    /// All-In-One may read its area's text from the frozen frame, and a Self-Timer's area is captured again once the
    /// overlay has gone: neither keeps the frame, so neither shows the pointer in it.
    @Test func allInOneAndTheSelfTimerFramesCarryNone() {
        for purpose in Self.purposes {
            #expect(!OverlayController.framesShowPointer(true, purpose: purpose, holdsStill: true, allInOne: true), "\(purpose)")
            #expect(!OverlayController.framesShowPointer(true, purpose: purpose, holdsStill: true, recaptured: true), "\(purpose)")
        }
    }
}
