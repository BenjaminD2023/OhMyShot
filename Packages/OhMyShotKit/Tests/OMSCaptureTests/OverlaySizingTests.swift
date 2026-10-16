import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

/// What Tab opens the size control on: the drag in hand, in the shape Shift kept, or an area around the crosshair.
@MainActor
struct OverlaySizingTests {
    private let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), pixelSize: CGSize(width: 2400, height: 1600),
        backingScale: 2, maximumPotentialEDR: 1
    )
    private let dragged = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let widescreen = AspectRatio(width: 16, height: 9)

    /// A drag made without Shift opens free, whatever shape Settings keep: the control is for typing a size.
    @Test func aFreeDragOpensFree() {
        for kept in [nil, widescreen] {
            let start = OverlayController.sizingStart(dragged: dragged, on: display, around: .zero, shapeLocked: false, kept: kept)
            #expect(start.area == dragged && start.ratio == nil)
        }
    }

    /// A drag made with Shift was kept to a shape, a square unless Settings keep another, and opens in it.
    @Test func aShapeLockedDragOpensInItsShape() {
        let square = OverlayController.sizingStart(dragged: dragged, on: display, around: .zero, shapeLocked: true, kept: nil)
        #expect(square.ratio == .square && square.area.width == square.area.height)
        let wide = OverlayController.sizingStart(dragged: dragged, on: display, around: .zero, shapeLocked: true, kept: widescreen)
        #expect(wide.ratio == widescreen && abs(wide.area.width / wide.area.height - 16.0 / 9) < 0.01 && display.frame.contains(wide.area))
    }

    /// With no drag in hand an area is framed around the crosshair, free, even if Shift is down or a shape is kept.
    @Test func noDragFramesAnAreaAroundTheCrosshair() {
        let point = CGPoint(x: 600, y: 400)
        for locked in [false, true] {
            let start = OverlayController.sizingStart(dragged: nil, on: display, around: point, shapeLocked: locked, kept: widescreen)
            #expect(start.ratio == nil && start.area == AreaFrame.starting(around: point, on: display, keeping: nil))
            #expect(abs(start.area.midX - 600) <= 0.5 && abs(start.area.midY - 400) <= 0.5)
        }
    }
}
