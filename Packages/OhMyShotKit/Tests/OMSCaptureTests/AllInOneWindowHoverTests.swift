import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// All-In-One before anything is chosen: the window under the pointer is highlighted, cut to the display it is on, and a
/// click on it frames it, while a drag still chooses an area.
@MainActor
struct AllInOneWindowHoverTests {
    /// Two 2× displays side by side, 800 × 600 points each.
    private static let left = DisplayInfo(
        id: 1, name: "Left", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    private static let right = DisplayInfo(
        id: 2, name: "Right", frame: CGRect(x: 800, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    /// Front to back, as the window list has them.
    private static let front = WindowTarget(id: 10, frame: CGRect(x: 100, y: 100, width: 300, height: 200), ownerName: "Notes", title: nil)
    private static let back = WindowTarget(id: 20, frame: CGRect(x: 50, y: 50, width: 600, height: 400), ownerName: "Safari", title: nil)
    private static let across = WindowTarget(id: 30, frame: CGRect(x: 700, y: 480, width: 300, height: 100), ownerName: "Terminal", title: nil)
    private static let windows = [front, back, across]

    @Test func theFrontmostWindowUnderThePointerIsHighlighted() {
        let onFront = OverlayController.hoveredWindow(at: CGPoint(x: 150, y: 150), in: Self.windows, on: Self.left)
        #expect(onFront?.window == Self.front && onFront?.area == Self.front.frame && onFront?.display == Self.left)
        let onBack = OverlayController.hoveredWindow(at: CGPoint(x: 600, y: 400), in: Self.windows, on: Self.left)
        #expect(onBack?.window == Self.back && onBack?.area == Self.back.frame)
        #expect(OverlayController.hoveredWindow(at: CGPoint(x: 20, y: 20), in: Self.windows, on: Self.left) == nil)
        #expect(OverlayController.hoveredWindow(at: CGPoint(x: 150, y: 150), in: [], on: Self.left) == nil)
    }

    /// A window across two displays is highlighted, and framed, only as far as the display the pointer is on.
    @Test func aWindowAcrossDisplaysIsCutToTheOneUnderThePointer() {
        let onLeft = OverlayController.hoveredWindow(at: CGPoint(x: 750, y: 500), in: Self.windows, on: Self.left)
        #expect(onLeft?.window == Self.across && onLeft?.area == CGRect(x: 700, y: 480, width: 100, height: 100))
        let onRight = OverlayController.hoveredWindow(at: CGPoint(x: 900, y: 500), in: Self.windows, on: Self.right)
        #expect(onRight?.window == Self.across && onRight?.area == CGRect(x: 800, y: 480, width: 200, height: 100))
        // The pointer is on the other display.
        #expect(OverlayController.hoveredWindow(at: CGPoint(x: 900, y: 500), in: Self.windows, on: Self.left) == nil)
    }

    /// Too little of a window on the display to frame as an area is not highlighted.
    @Test func aSliverOnTheDisplayIsNotHighlighted() {
        let edge = WindowTarget(id: 40, frame: CGRect(x: 790, y: 100, width: 400, height: 300), ownerName: "Mail", title: nil)
        #expect(OverlayController.hoveredWindow(at: CGPoint(x: 795, y: 200), in: [edge], on: Self.left) == nil)
        let onRight = OverlayController.hoveredWindow(at: CGPoint(x: 900, y: 200), in: [edge], on: Self.right)
        #expect(onRight?.area == CGRect(x: 800, y: 100, width: 390, height: 300))
    }

    /// A press keeps the window under it while it stays within the drag threshold (under 4 pixels either way), and lets
    /// it go for good once it is a drag, even when the drag comes back to where it began.
    @Test func aPressIsAClickUntilItIsDragged() throws {
        let pressed = try #require(OverlayController.hoveredWindow(at: CGPoint(x: 150, y: 150), in: Self.windows, on: Self.left))
        var selection = SelectionModel(bounds: Self.left.frame, pixelsPerPoint: Self.left.pixelsPerPoint)
        selection.begin(at: CGPoint(x: 150, y: 150))
        var kept: OverlayController.HoveredWindow? = OverlayController.pressedWindow(pressed, after: selection)
        #expect(kept == pressed)
        // A pixel's jitter is still a click.
        selection.drag(to: CGPoint(x: 151, y: 149))
        kept = OverlayController.pressedWindow(kept, after: selection)
        #expect(kept == pressed)
        // Wide but not tall is no drag either, as Capture Area counts it.
        selection.drag(to: CGPoint(x: 250, y: 149.5))
        kept = OverlayController.pressedWindow(kept, after: selection)
        #expect(kept == pressed)
        selection.drag(to: CGPoint(x: 250, y: 100))
        kept = OverlayController.pressedWindow(kept, after: selection)
        #expect(kept == nil)
        selection.drag(to: CGPoint(x: 150, y: 150))
        #expect(selection.isTooSmall)
        kept = OverlayController.pressedWindow(kept, after: selection)
        #expect(kept == nil)
    }

    /// The highlight is drawn as window mode draws its window, named with the size a click frames, until a drag makes a
    /// selection.
    @Test func theHighlightStandsForTheSelectionUntilADrag() throws {
        let view = OverlayView(display: Self.left)
        view.reset(pointer: CGPoint(x: 150, y: 150), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot, allInOne: true)
        let hovered = try #require(OverlayController.hoveredWindow(at: CGPoint(x: 600, y: 400), in: Self.windows, on: Self.left))
        view.highlight(hovered)
        #expect(view.debugSizeReading == "Safari  ·  1200 × 800")
        #expect(view.accessibilityValue() as? String == "Safari  ·  1200 × 800")

        var selection = SelectionModel(bounds: Self.left.frame, pixelsPerPoint: Self.left.pixelsPerPoint)
        selection.begin(at: CGPoint(x: 600, y: 400))
        selection.drag(to: CGPoint(x: 601, y: 399))
        view.show(selection: selection, showsReading: true, isDragging: true)
        #expect(view.debugSizeReading == "Safari  ·  1200 × 800")

        selection.drag(to: CGPoint(x: 700, y: 350))
        view.highlight(nil)
        view.show(selection: selection, showsReading: true, isDragging: true)
        #expect(view.debugSizeReading == "200 × 100")
    }
}
