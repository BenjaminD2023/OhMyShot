import CoreGraphics
import Testing
@testable import OMSUI

@MainActor
struct CopiedHUDTests {
    @Test func defaultDurationScalesWithMessageLength() {
        #expect(CopiedHUD.defaultDuration(for: "#112233") == .milliseconds(900))
        #expect(CopiedHUD.defaultDuration(for: String(repeating: "a", count: 20)) == .milliseconds(900))
        #expect(CopiedHUD.defaultDuration(for: String(repeating: "a", count: 35)) == .milliseconds(2500))
        #expect(CopiedHUD.defaultDuration(for: String(repeating: "a", count: 55)) == .milliseconds(3200))
    }

    @Test func originFlipsAndClampsLongMessagesInsideVisibleBounds() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let longSize = CGSize(width: 600, height: 24)
        // Near the right edge where flipping left would normally go negative; must clamp to x == 6.
        let clampedLeft = CopiedHUD.origin(for: longSize, near: CGPoint(x: 500, y: 400), in: visible)
        #expect(clampedLeft.x == 6)
        // Near the bottom edge: flips above and clamps inside [6, maxY - height - 6].
        let clampedBottom = CopiedHUD.origin(for: CGSize(width: 120, height: 24), near: CGPoint(x: 200, y: 10), in: visible)
        #expect(clampedBottom.y >= 6 && clampedBottom.y + 24 <= visible.maxY - 6)
    }
}
