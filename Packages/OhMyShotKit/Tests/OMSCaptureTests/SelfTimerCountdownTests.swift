import CoreGraphics
import Testing
@testable import OMSCapture

struct SelfTimerCountdownTests {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func theDiscSitsCenteredUnderTheArea() {
        let frame = SelfTimerCountdown.discFrame(for: CGRect(x: 100, y: 300, width: 200, height: 100), diameter: 64, displays: [display])
        #expect(frame == CGRect(x: 168, y: 224, width: 64, height: 64))
    }

    @Test func withNoRoomBelowItGoesAbove() {
        let frame = SelfTimerCountdown.discFrame(for: CGRect(x: 100, y: 20, width: 200, height: 100), diameter: 64, displays: [display])
        #expect(frame == CGRect(x: 168, y: 132, width: 64, height: 64))
    }

    @Test func withNoRoomEitherWayItGoesInsideTheBottomEdge() {
        let frame = SelfTimerCountdown.discFrame(for: CGRect(x: 100, y: 20, width: 200, height: 750), diameter: 64, displays: [display])
        #expect(frame == CGRect(x: 168, y: 32, width: 64, height: 64))
        // The whole screen: inside its bottom edge.
        #expect(SelfTimerCountdown.discFrame(for: display, diameter: 64, displays: [display]) == CGRect(x: 468, y: 12, width: 64, height: 64))
    }

    @Test func belowWhereNoDisplayIsItGoesAbove() {
        // A shorter display left of this one; the area crosses onto it, its bottom middle over the gap.
        let left = CGRect(x: -1000, y: 200, width: 1000, height: 600)
        let frame = SelfTimerCountdown.discFrame(for: CGRect(x: -300, y: 250, width: 400, height: 200), diameter: 64, displays: [display, left])
        #expect(frame == CGRect(x: -132, y: 462, width: 64, height: 64))
    }

    @Test func itStaysOnTheDisplay() {
        // At the right edge neither below nor above fits: inside, pulled back onto the display.
        let frame = SelfTimerCountdown.discFrame(for: CGRect(x: 950, y: 400, width: 40, height: 40), diameter: 64, displays: [display])
        #expect(frame == CGRect(x: 928, y: 412, width: 64, height: 64))
    }
}
