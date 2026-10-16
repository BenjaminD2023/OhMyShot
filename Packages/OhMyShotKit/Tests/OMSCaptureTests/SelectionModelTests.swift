import CoreGraphics
import Testing
@testable import OMSCapture

struct SelectionModelTests {
    /// The built-in display as the author runs it: left of the primary, raised, 2 pixels per point.
    let bounds = CGRect(x: -2056, y: 111, width: 2056, height: 1329)

    @Test func draggingUpAndLeftStillMakesAPositiveRect() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 800))
        model.drag(to: CGPoint(x: -1100, y: 700))
        #expect(model.rect == CGRect(x: -1100, y: 700, width: 100, height: 100))
    }

    @Test func aHundredPointSelectionIsTwoHundredPixels() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -900, y: 600))
        #expect(model.pixelSize == (200, 200))
    }

    @Test func edgesSnapToWholePixels() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000.3, y: 500.2))
        model.drag(to: CGPoint(x: -899.8, y: 600.74))
        #expect(model.rect == CGRect(x: -1000.5, y: 500, width: 100.5, height: 100.5))
        #expect(model.pixelSize == (201, 201))
    }

    @Test func selectionStaysOnItsDisplay() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -100, y: 1400))
        model.drag(to: CGPoint(x: 300, y: 1600))
        #expect(model.rect == CGRect(x: -100, y: 1400, width: 100, height: 40))
    }

    @Test func shiftKeepsItSquare() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -950, y: 380), modifiers: .square)
        #expect(model.rect == CGRect(x: -1000, y: 380, width: 120, height: 120))
    }

    @Test func optionGrowsFromTheCenter() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -960, y: 530), modifiers: .fromCenter)
        #expect(model.rect == CGRect(x: -1040, y: 470, width: 80, height: 60))
    }

    @Test func spaceMovesTheSelectionAndStopsAtTheEdge() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -300, y: 500))
        model.drag(to: CGPoint(x: -200, y: 600))
        model.move(by: CGVector(dx: 500, dy: 0))
        #expect(model.rect == CGRect(x: -100, y: 500, width: 100, height: 100))
    }

    /// Shift keeps another shape when one is set; the longer side leads, as for a square.
    @Test func shiftKeepsTheShapeSet() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.shape = 16.0 / 9
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -840, y: 510), modifiers: .square)
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 160, height: 90))
        // Pulled mostly down: the height leads and the width follows.
        model.drag(to: CGPoint(x: -990, y: 590), modifiers: .square)
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 160, height: 90))
        model.drag(to: CGPoint(x: -990, y: 680), modifiers: .square)
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 320, height: 180))
    }

    /// At the display's edge the shape shrinks to fit rather than being cut to another one.
    @Test func aShapeKeptHoldsAtTheEdge() {
        var square = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        square.begin(at: CGPoint(x: -100, y: 500))
        square.drag(to: CGPoint(x: -40, y: 800), modifiers: .square)
        #expect(square.rect == CGRect(x: -100, y: 500, width: 100, height: 100))
        var wide = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        wide.shape = 2
        wide.begin(at: CGPoint(x: -100, y: 500))
        wide.drag(to: CGPoint(x: -40, y: 800), modifiers: .square)
        #expect(wide.rect == CGRect(x: -100, y: 500, width: 100, height: 50))
        // From the center, the nearer edge limits both ways.
        var centered = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        centered.begin(at: CGPoint(x: -100, y: 500))
        centered.drag(to: CGPoint(x: -20, y: 700), modifiers: [.square, .fromCenter])
        #expect(centered.rect == CGRect(x: -200, y: 400, width: 200, height: 200))
    }

    /// The arrow keys move the dragged corner while the pointer stays: on a 2× display half a point is a pixel.
    @Test func nudgingMovesTheCornerAPixelWithoutThePointer() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -900, y: 600))
        #expect(model.isNudged == false && model.corner == CGPoint(x: -900, y: 600))
        model.nudge(by: CGVector(dx: 0.5, dy: 0))
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 100.5, height: 100))
        #expect(model.pixelSize == (201, 200))
        #expect(model.pointer == CGPoint(x: -900, y: 600) && model.corner == CGPoint(x: -899.5, y: 600) && model.isNudged)
        // Up is positive in global points: five points up raise the dragged (top right) corner.
        model.nudge(by: CGVector(dx: 0, dy: 5))
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 100.5, height: 105))
        model.nudge(by: CGVector(dx: -0.5, dy: -5))
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 100, height: 100) && !model.isNudged)
    }

    /// A nudge is not thrown away by the pointer's next move: the corner stays that far from it for the drag.
    @Test func aNudgeHoldsThroughTheDrag() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -900, y: 600))
        model.nudge(by: CGVector(dx: 0.5, dy: 0))
        model.drag(to: CGPoint(x: -800, y: 650))
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 200.5, height: 150))
        #expect(model.pixelSize == (401, 300))
        // A new selection starts clean.
        model.begin(at: CGPoint(x: -500, y: 500))
        model.drag(to: CGPoint(x: -400, y: 600))
        #expect(model.rect == CGRect(x: -500, y: 500, width: 100, height: 100) && !model.isNudged)
    }

    @Test func nudgingStopsAtTheBoundsAndComesBackFromThem() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -100, y: 1400))
        model.drag(to: CGPoint(x: -50, y: 1420))
        model.nudge(by: CGVector(dx: 1000, dy: 1000))
        #expect(model.rect == CGRect(x: -100, y: 1400, width: 100, height: 40))
        #expect(model.corner == CGPoint(x: 0, y: 1440))
        // Held at the edge, the first arrow back moves the corner at once: no hidden distance to work off.
        model.nudge(by: CGVector(dx: -10, dy: 0))
        #expect(model.rect == CGRect(x: -100, y: 1400, width: 90, height: 40))
    }

    @Test func nudgingKeepsShiftAndOptionInForce() {
        var square = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        square.begin(at: CGPoint(x: -1000, y: 500))
        square.drag(to: CGPoint(x: -950, y: 470), modifiers: .square)
        #expect(square.rect == CGRect(x: -1000, y: 450, width: 50, height: 50))
        square.nudge(by: CGVector(dx: 10, dy: 0), modifiers: .square)
        #expect(square.rect == CGRect(x: -1000, y: 440, width: 60, height: 60))
        var centered = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        centered.begin(at: CGPoint(x: -1000, y: 500))
        centered.drag(to: CGPoint(x: -960, y: 530), modifiers: .fromCenter)
        centered.nudge(by: CGVector(dx: 10, dy: 0), modifiers: .fromCenter)
        #expect(centered.rect == CGRect(x: -1050, y: 470, width: 100, height: 60))
    }

    /// Before a press there is no corner to nudge.
    @Test func nothingIsNudgedBeforeAPress() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.nudge(by: CGVector(dx: 5, dy: 5))
        #expect(model.rect == nil && model.corner == nil && !model.isNudged)
    }

    /// A pointer past the bounds (a drag held to one display, the pointer on the next) leaves the corner at the edge,
    /// and the arrow keys move it from there at once, not after working off the distance the pointer is out.
    @Test func nudgingWorksFromAPointerBeyondTheBounds() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -300, y: 500))
        model.drag(to: CGPoint(x: 200, y: 600))
        #expect(model.rect == CGRect(x: -300, y: 500, width: 300, height: 100))
        model.nudge(by: CGVector(dx: -0.5, dy: 0))
        #expect(model.rect == CGRect(x: -300, y: 500, width: 299.5, height: 100))
        #expect(model.corner == CGPoint(x: -0.5, y: 600))
        // Further out changes nothing; brought back inside, the pointer carries on from the corner it left.
        model.drag(to: CGPoint(x: 400, y: 600))
        #expect(model.rect == CGRect(x: -300, y: 500, width: 299.5, height: 100))
        model.drag(to: CGPoint(x: -100, y: 600))
        #expect(model.rect == CGRect(x: -300, y: 500, width: 199.5, height: 100))
    }

    /// Shift keeps a shape, so a nudge along the side that follows moves nothing: it is not remembered, and letting
    /// go of Shift brings back the free selection, with no distance built up behind the shape.
    @Test func aNudgeTheShapeHeldAcrossIsNotKept() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -700, y: 600))
        model.drag(to: CGPoint(x: -700, y: 600), modifiers: .square)
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 300, height: 300))
        // Shift and Down, five times: ten pixels each, toward the anchor along the shorter side.
        for _ in 0..<5 { model.nudge(by: CGVector(dx: 0, dy: -5), modifiers: .square) }
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 300, height: 300) && !model.isNudged)
        model.drag(to: CGPoint(x: -700, y: 600))
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 300, height: 100))
        // Along the side that leads, the shape follows the key.
        model.drag(to: CGPoint(x: -700, y: 600), modifiers: .square)
        model.nudge(by: CGVector(dx: -5, dy: 0), modifiers: .square)
        #expect(model.rect == CGRect(x: -1000, y: 500, width: 295, height: 295) && model.isNudged)
    }

    /// A nudge the display's edge stops is not remembered either.
    @Test func aNudgeTheEdgeStopsIsNotKept() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 1400))
        model.drag(to: CGPoint(x: -700, y: 1430), modifiers: .square)
        // A square, held to the 40 points of room above (1440 - 1400).
        #expect(model.rect == CGRect(x: -1000, y: 1400, width: 40, height: 40))
        for _ in 0..<30 { model.nudge(by: CGVector(dx: 5, dy: 0), modifiers: .square) }
        #expect(model.rect == CGRect(x: -1000, y: 1400, width: 40, height: 40) && !model.isNudged)
        model.drag(to: CGPoint(x: -700, y: 1430))
        #expect(model.rect == CGRect(x: -1000, y: 1400, width: 300, height: 30))
    }

    /// A side not dragged at all grows toward the room there is, so a drag along an edge still makes a square.
    @Test func shiftAlongAnEdgeGrowsTowardTheRoom() {
        // The top edge: nothing above, so the square grows down.
        var top = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        top.begin(at: CGPoint(x: -1000, y: 1440))
        top.drag(to: CGPoint(x: -700, y: 1440), modifiers: .square)
        #expect(top.rect == CGRect(x: -1000, y: 1140, width: 300, height: 300))
        // The right edge, dragged straight down: nothing to the right, so it grows left.
        var right = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        right.begin(at: CGPoint(x: 0, y: 500))
        right.drag(to: CGPoint(x: 0, y: 700), modifiers: .square)
        #expect(right.rect == CGRect(x: -200, y: 500, width: 200, height: 200))
        // With room on the side it grows toward, it still takes that side.
        var inside = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        inside.begin(at: CGPoint(x: -1000, y: 500))
        inside.drag(to: CGPoint(x: -700, y: 500), modifiers: .square)
        #expect(inside.rect == CGRect(x: -1000, y: 500, width: 300, height: 300))
    }

    @Test func aClickIsNotASelection() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -999, y: 501))
        #expect(model.isTooSmall)
    }

    /// Both of the author's displays: the built-in one left of the ultrawide, their tops level.
    let bothDisplays = CGRect(x: -2056, y: 111, width: 2056, height: 1329).union(CGRect(x: 0, y: 0, width: 3440, height: 1440))

    @Test func aDragCarriesTheSelectionOntoTheNextDisplay() {
        var model = SelectionModel(bounds: bothDisplays, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: 500, y: 1300))
        model.drag(to: CGPoint(x: -400, y: 900))
        #expect(model.rect == CGRect(x: -400, y: 900, width: 900, height: 400))
        #expect(model.pixelSize == (1800, 800))
    }

    @Test func acrossDisplaysEdgesStillSnapToWholePixels() {
        var model = SelectionModel(bounds: bothDisplays, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: 100.3, y: 1000.2))
        model.drag(to: CGPoint(x: -100.8, y: 1200.74))
        #expect(model.rect == CGRect(x: -101, y: 1000, width: 201.5, height: 200.5))
    }

    @Test func movingAcrossDisplaysStopsAtTheOuterEdges() {
        var model = SelectionModel(bounds: bothDisplays, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -100, y: 1000))
        model.drag(to: CGPoint(x: 100, y: 1200))
        model.move(by: CGVector(dx: -5000, dy: 1000))
        #expect(model.rect == CGRect(x: -2056, y: 1240, width: 200, height: 200))
    }
}
