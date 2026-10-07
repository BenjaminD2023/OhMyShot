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

    @Test func aClickIsNotASelection() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: -1000, y: 500))
        model.drag(to: CGPoint(x: -999, y: 501))
        #expect(model.isTooSmall)
    }
}
