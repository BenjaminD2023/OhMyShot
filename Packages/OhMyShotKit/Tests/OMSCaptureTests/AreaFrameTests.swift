import CoreGraphics
import OMSCore
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

    /// A drag moves the frame whole inside the bounds, resizes it with the pointer held to them, or chooses a new area.
    @Test func aDragMovesResizesOrChoosesAnew() {
        let moved = AreaFrame.adjusted(.moving(start: CGPoint(x: 200, y: 200), original: rect), to: CGPoint(x: 900, y: 250), in: bounds)
        #expect(moved == CGRect(x: 600, y: 150, width: 400, height: 300))
        let resized = AreaFrame.adjusted(.resizing(.bottomRight, original: rect), to: CGPoint(x: 1200, y: 500), in: bounds)
        #expect(resized == CGRect(x: 100, y: 100, width: 900, height: 400))
        let chosen = AreaFrame.adjusted(.selecting(start: CGPoint(x: 300, y: 300)), to: CGPoint(x: 100, y: -50), in: bounds)
        #expect(chosen == CGRect(x: 100, y: 0, width: 200, height: 300))
        // Kept to a shape, a new area grows from where it began.
        let square = AreaFrame.adjusted(.selecting(start: CGPoint(x: 300, y: 300)), to: CGPoint(x: 500, y: 350), in: bounds, keeping: 1)
        #expect(square == CGRect(x: 300, y: 300, width: 200, height: 200))
    }

    /// What is left of an area on the bounds, unless that is smaller than the smallest area.
    @Test func anAreaIsFittedToTheBoundsOrNotAtAll() {
        #expect(AreaFrame.fitted(CGRect(x: -50, y: 700, width: 200, height: 200), in: bounds) == CGRect(x: 0, y: 700, width: 150, height: 100))
        #expect(AreaFrame.fitted(CGRect(x: 990, y: 100, width: 200, height: 200), in: bounds) == nil)
        #expect(AreaFrame.fitted(CGRect(x: 2000, y: 100, width: 200, height: 200), in: bounds) == nil)
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

    /// Every shape the menu offers reads back from its label; a label that is no shape reads as none.
    @Test func ratiosReadBackFromTheirLabel() {
        for preset in AspectRatio.presets {
            #expect(AspectRatio(label: preset.label) == preset, "\(preset.label)")
        }
        #expect(AspectRatio(label: "1.85:1") == AspectRatio(width: 1.85, height: 1))
        for label in ["", "16", "16:", ":9", "0:9", "16:0", "-4:3", "a:b", "16:9:1", "inf:1", "nan:1"] {
            #expect(AspectRatio(label: label) == nil, "\(label)")
        }
    }

    /// A side far outside what an area could be is no shape, and no label of any shape traps.
    @Test func absurdShapesAreNoShapeAndTheirLabelsAreSafe() {
        for label in ["1e300:1", "1:1e300", "1e-9:1", "1:1e-9", "101:1", "0.001:1", "9223372036854775808:1"] {
            #expect(AspectRatio(label: label) == nil, "\(label)")
        }
        #expect(AspectRatio(label: "100:0.01") != nil && AspectRatio(label: "0.01:100") != nil)
        for width in [1e300, 1e19, Double.infinity, Double.nan, 0.5] {
            #expect(!AspectRatio(width: width, height: 1).label.isEmpty)
        }
    }

    private let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), pixelSize: CGSize(width: 2400, height: 1600),
        backingScale: 2, maximumPotentialEDR: 1
    )
    /// A raised display to the left of the primary one, as the author's built-in one is.
    private let raised = DisplayInfo(
        id: 2, name: "Raised", frame: CGRect(x: -2056, y: 111, width: 2056, height: 1329), pixelSize: CGSize(width: 4112, height: 2658),
        backingScale: 2, maximumPotentialEDR: 1
    )

    /// With no drag, a size is typed for a third of the display across, around the crosshair.
    @Test func anAreaToTypeASizeForStartsAroundTheCrosshair() {
        let area = AreaFrame.starting(around: CGPoint(x: 600, y: 400), on: display, keeping: nil)
        #expect(area.width == 400 && area.height == 267)
        #expect(abs(area.midX - 600) <= 0.5 && abs(area.midY - 400) <= 0.5)
        // Near a corner it is moved back inside, whole.
        let cornered = AreaFrame.starting(around: CGPoint(x: -10, y: 120), on: raised, keeping: nil)
        #expect(raised.frame.contains(cornered) && cornered.width == 685 && cornered.height == 443)
        let far = AreaFrame.starting(around: CGPoint(x: 1195, y: 795), on: display, keeping: nil)
        #expect(display.frame.contains(far) && far.maxX == 1200 && far.maxY == 800)
    }

    @Test func aShapeKeptShapesTheStartingAreaAndStaysInside() {
        let wide = AreaFrame.starting(around: CGPoint(x: 600, y: 400), on: display, keeping: AspectRatio(width: 16, height: 9))
        #expect(abs(wide.width / wide.height - 16.0 / 9) < 0.01 && display.frame.contains(wide))
        let tall = AreaFrame.starting(around: CGPoint(x: 600, y: 400), on: display, keeping: AspectRatio(width: 9, height: 16))
        #expect(abs(tall.width / tall.height - 9.0 / 16) < 0.01 && display.frame.contains(tall))
    }

    /// A dragged area opens the control as it is, or reshaped to the shape kept around its middle.
    @Test func aDraggedAreaIsFramedAsItIsOrInTheShapeKept() {
        let dragged = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(AreaFrame.framed(dragged, on: display, keeping: nil) == dragged)
        let square = AreaFrame.framed(dragged, on: display, keeping: AspectRatio(width: 1, height: 1))
        #expect(square.width == 400 && square.height == 400)
        #expect(abs(square.midX - dragged.midX) <= 0.5 && abs(square.midY - dragged.midY) <= 0.5)
        // Kept on its pixels, and never off the display.
        let ragged = AreaFrame.framed(CGRect(x: 100.3, y: 100.3, width: 400.4, height: 300.2), on: display, keeping: nil)
        #expect(ragged.minX * 2 == (ragged.minX * 2).rounded() && ragged.width * 2 == (ragged.width * 2).rounded())
        let edge = AreaFrame.framed(CGRect(x: 1000, y: 600, width: 400, height: 300), on: display, keeping: nil)
        #expect(display.frame.contains(edge))
    }
}
