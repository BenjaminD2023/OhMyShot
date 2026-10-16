import CoreGraphics
import Testing
@testable import OMSCapture

/// The frame's arithmetic, in flipped points (y down) as the overlay's views use.
struct AreaFrameTests {
    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func aCornerKeepsTheRatioFromTheOppositeCorner() {
        // Dragging the bottom-right corner out mostly sideways: the width leads, the height follows at 16:9.
        let wide = AreaFrame.resized(rect, dragging: .bottomRight, to: CGPoint(x: 900, y: 450), keeping: 16.0 / 9)
        #expect(wide.origin == rect.origin)
        #expect(wide.width == 800 && abs(wide.height - 450) < 0.001)
        // The top-left corner: the bottom-right one stays where it was.
        let square = AreaFrame.resized(rect, dragging: .topLeft, to: CGPoint(x: 300, y: 0), keeping: 1)
        #expect(square.maxX == rect.maxX && square.maxY == rect.maxY)
        #expect(square.width == square.height && square.height == 400)
    }

    @Test func anEdgeKeepsTheRatioCentered() {
        let wider = AreaFrame.resized(rect, dragging: .right, to: CGPoint(x: 700, y: 999), keeping: 2)
        #expect(wider.minX == rect.minX && wider.width == 600 && wider.height == 300)
        #expect(wider.midY == rect.midY)
        let taller = AreaFrame.resized(rect, dragging: .bottom, to: CGPoint(x: 0, y: 500), keeping: 1)
        #expect(taller.minY == rect.minY && taller.height == 400 && taller.width == 400)
        #expect(taller.midX == rect.midX)
    }

    @Test func reshapingKeepsTheCenterAndTheBounds() {
        let square = AreaFrame.shaped(rect, to: 1, in: bounds)
        #expect(square.width == 400 && square.height == 400)
        #expect(square.midX == rect.midX && square.midY == rect.midY)
        // Too tall for the bounds at 9:16 from a 400-wide area: shrunk to fit, still 9:16, inside.
        let portrait = AreaFrame.shaped(rect, to: 9.0 / 16, in: bounds)
        #expect(abs(portrait.width / portrait.height - 9.0 / 16) < 0.001)
        #expect(bounds.contains(portrait))
    }

    @Test func aTypedSizeKeepsTheTopLeftAndStaysInside() {
        let sized = AreaFrame.sized(rect, to: CGSize(width: 640, height: 360), in: bounds)
        #expect(sized == CGRect(x: 100, y: 100, width: 640, height: 360))
        // Past the right edge: moved back; larger than the bounds: cut to them.
        let pushed = AreaFrame.sized(rect, to: CGSize(width: 950, height: 200), in: bounds)
        #expect(pushed == CGRect(x: 50, y: 100, width: 950, height: 200))
        let cut = AreaFrame.sized(rect, to: CGSize(width: 2000, height: 2000), in: bounds)
        #expect(cut == bounds)
    }

    @Test func ratiosReadAsTheirShape() {
        #expect(AspectRatio(width: 16, height: 9).label == "16:9")
        #expect(AspectRatio(width: 1.85, height: 1).label == "1.85:1")
    }
}
