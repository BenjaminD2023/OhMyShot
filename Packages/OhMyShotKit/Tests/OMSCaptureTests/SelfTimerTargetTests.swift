import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// What Self-Timer captures at zero is what the same choice captures without it: Shift-clicked windows stay windows,
/// each captured on its own, and only the countdown's outline is the frame around them.
struct SelfTimerTargetTests {
    /// A 2× display 800 × 600 points with its bottom-left corner at the origin.
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    /// Two windows with desktop between them.
    private static let left = WindowTarget(id: 10, frame: CGRect(x: 20, y: 40, width: 200, height: 150), ownerName: "Notes", title: "Today")
    private static let right = WindowTarget(id: 11, frame: CGRect(x: 500, y: 300, width: 250, height: 200), ownerName: "Mail", title: "Inbox")

    @Test func shiftClickedWindowsStayWindowsAndOnlyTheOutlineIsTheirUnion() throws {
        let target = try #require(SelfTimerTarget(.windows([Self.left, Self.right], modifiers: [.shift])))
        #expect(target == .windows([Self.left, Self.right], [.shift]))
        #expect(target.outline == CGRect(x: 20, y: 40, width: 730, height: 460))
    }

    @Test func oneWindowStaysAWindowWithTheKeysHeld() throws {
        let target = try #require(SelfTimerTarget(.window(Self.left, modifiers: [.shift])))
        #expect(target == .window(Self.left, [.shift]))
        #expect(target.outline == Self.left.frame)
    }

    @Test func anAreaIsCapturedAsAnArea() throws {
        let area = CGRect(x: 100, y: 200, width: 300, height: 150)
        let target = try #require(SelfTimerTarget(.region(area, display: Self.display, modifiers: [], frozen: nil)))
        #expect(target == .area(area))
        #expect(target.outline == area)
    }

    @Test func noWindowsOrNoCaptureCountsNothingDown() {
        #expect(SelfTimerTarget(.windows([], modifiers: [])) == nil)
        #expect(SelfTimerTarget(.cancelled) == nil)
        #expect(SelfTimerTarget(.annotated) == nil)
        #expect(SelfTimerTarget(.scroll(Self.left.frame, display: Self.display, autoScrolls: false)) == nil)
    }
}
