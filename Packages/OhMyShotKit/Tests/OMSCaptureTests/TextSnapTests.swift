import CoreGraphics
import Testing
@testable import OMSCapture

struct TextSnapTests {
    /// A paragraph, y up: 400 wide, 80 tall, its bottom at 500.
    let paragraph = CGRect(x: 100, y: 500, width: 400, height: 80)
    let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    private func snap(_ blocks: [CGRect], _ rect: CGRect) -> (rect: CGRect, edges: TextSnap.Edges) {
        TextSnap(blocks: blocks).snapped(rect, within: bounds)
    }

    @Test func anEdgeSixPointsFromABlockSnapsToTheMarginOutsideIt() {
        let result = snap([paragraph], CGRect(x: 94, y: 490, width: 426, height: 110))
        #expect(result.rect.minX == 96)
        #expect(result.edges == .left)
        // The other sides were too far to snap, and stay.
        #expect(result.rect.maxX == 520 && result.rect.minY == 490 && result.rect.maxY == 600)
    }

    @Test func anEdgeTenPointsAwayStays() {
        let result = snap([paragraph], CGRect(x: 90, y: 480, width: 440, height: 130))
        #expect(result.rect == CGRect(x: 90, y: 480, width: 440, height: 130))
        #expect(result.edges.isEmpty)
    }

    @Test func aDragAroundAParagraphLandsOnItWithAMarginOnEverySide() {
        let result = snap([paragraph], CGRect(x: 95, y: 495, width: 410, height: 90))
        #expect(result.rect == CGRect(x: 96, y: 496, width: 408, height: 88))
        #expect(result.edges == [.left, .right, .top, .bottom])
    }

    @Test func anEdgeCuttingIntoABlocksFirstOrLastLineMovesOutToTakeItWhole() {
        // Left, right, and bottom edges a few points inside the block; the top a few points above.
        let result = snap([paragraph], CGRect(x: 103, y: 503, width: 394, height: 80))
        #expect(result.rect == CGRect(x: 96, y: 496, width: 408, height: 88))
    }

    @Test func aBlockOnlyCountsWhereTheSelectionReachesIt() {
        // Level with the paragraph's left edge, but entirely above it.
        let above = snap([paragraph], CGRect(x: 96, y: 700, width: 200, height: 100))
        #expect(above.rect == CGRect(x: 96, y: 700, width: 200, height: 100))
        #expect(above.edges.isEmpty)
        // Beside it, level with its top edge: it does not reach the paragraph along the other axis either.
        let beside = snap([paragraph], CGRect(x: 800, y: 575, width: 100, height: 100))
        #expect(beside.edges.isEmpty)
    }

    @Test func aMarginNeverRunsOverANeighbor() {
        // Six points apart: a full margin would stand inside the second block.
        let first = CGRect(x: 100, y: 500, width: 100, height: 40)
        let second = CGRect(x: 206, y: 500, width: 100, height: 40)
        let result = snap([first, second], CGRect(x: 90, y: 490, width: 113, height: 60))
        #expect(result.rect.maxX == 203)
        #expect(result.edges.contains(.right))
    }

    @Test func anEdgeDoesNotSnapToAPlaceThatCutsAnotherBlock() {
        // A wide heading over a narrow column: the column's left margin would run through the heading.
        let heading = CGRect(x: 50, y: 600, width: 550, height: 20)
        let column = CGRect(x: 200, y: 500, width: 100, height: 80)
        let result = snap([heading, column], CGRect(x: 195, y: 490, width: 120, height: 140))
        #expect(!result.edges.contains(.left))
        #expect(result.rect.minX == 195)
    }

    @Test func aMarginPastTheBoundsDoesNotSnap() {
        let block = CGRect(x: 2, y: 500, width: 200, height: 40)
        let result = snap([block], CGRect(x: 3, y: 490, width: 250, height: 60))
        #expect(result.rect.minX == 3)
        #expect(!result.edges.contains(.left))
    }

    @Test func nothingSnapsWithoutBlocks() {
        let result = snap([], CGRect(x: 94, y: 490, width: 426, height: 110))
        #expect(result.rect == CGRect(x: 94, y: 490, width: 426, height: 110))
        #expect(result.edges.isEmpty)
    }

    @Test func theNearestPlaceWins() {
        // Two blocks' left edges 3 and 6 points from the selection's: it lands by the nearer margin.
        let near = CGRect(x: 104, y: 500, width: 100, height: 40)
        let far = CGRect(x: 107, y: 500, width: 100, height: 40)
        let result = snap([far, near], CGRect(x: 101, y: 490, width: 300, height: 60))
        #expect(result.rect.minX == 100)
        #expect(result.edges.contains(.left))
    }

    @Test func blocksFoundInPixelsAreFramedInGlobalPoints() {
        // A display left of the primary one and raised, at two pixels per point; y is up in points, down in pixels.
        let frame = CGRect(x: -2056, y: 111, width: 2056, height: 1329)
        let block = TextSnap.block(fromPixels: CGRect(x: 200, y: 100, width: 400, height: 60), in: frame, pixelsPerPoint: 2)
        #expect(block == CGRect(x: -1956, y: 1360, width: 200, height: 30))
        // The pixel row 0 is the display's top edge; the last row is its bottom.
        let top = TextSnap.block(fromPixels: CGRect(x: 0, y: 0, width: 20, height: 10), in: frame, pixelsPerPoint: 2)
        #expect(top.maxY == frame.maxY)
    }
}

struct SelectionSnappingTests {
    let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let snap = TextSnap(blocks: [CGRect(x: 100, y: 500, width: 400, height: 80)])

    @Test func aDragSnapsItsEdgesAndSaysWhich() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 1)
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 600, y: 540), snapping: snap)
        // The anchor's edges are the selection's top and left; the pointer's right edge was too far.
        #expect(model.rect == CGRect(x: 96, y: 540, width: 504, height: 44))
        #expect(model.snappedEdges == [.left, .top])
        #expect(model.anchor == CGPoint(x: 95, y: 585))
    }

    @Test func draggingBackFromABlockReleasesTheEdge() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 1)
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 505, y: 495), snapping: snap)
        #expect(model.snappedEdges == [.left, .right, .top, .bottom])
        model.drag(to: CGPoint(x: 700, y: 300), snapping: snap)
        #expect(model.rect == CGRect(x: 96, y: 300, width: 604, height: 284))
        #expect(model.snappedEdges == [.left, .top])
    }

    /// A corner set to the pixel with the arrow keys stays there: the pointer's next move does not snap it back.
    @Test func aNudgePlacesEdgesFreelyForTheRestOfTheDrag() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 1)
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 505, y: 495), snapping: snap)
        #expect(!model.snappedEdges.isEmpty)
        model.nudge(by: CGVector(dx: 1, dy: 0))
        model.drag(to: CGPoint(x: 505, y: 495), snapping: snap)
        #expect(model.rect == CGRect(x: 95, y: 495, width: 411, height: 90))
        #expect(model.snappedEdges.isEmpty)
    }

    @Test func commandPlacesEdgesFreelyForTheRestOfTheDrag() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 1)
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 505, y: 495), snapping: snap)
        model.drag(to: CGPoint(x: 505, y: 495), modifiers: .unsnapped, snapping: snap)
        #expect(model.rect == CGRect(x: 95, y: 495, width: 410, height: 90))
        #expect(model.snappedEdges.isEmpty)
        // Letting go of Command mid-drag does not throw the edges to the text: the drag stays free.
        model.drag(to: CGPoint(x: 505, y: 495), snapping: snap)
        model.drag(to: CGPoint(x: 506, y: 494), snapping: snap)
        #expect(model.rect == CGRect(x: 95, y: 494, width: 411, height: 91))
        #expect(model.snappedEdges.isEmpty)
        // The next drag snaps again.
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 505, y: 495), snapping: snap)
        #expect(model.snappedEdges == [.left, .right, .top, .bottom])
    }

    @Test func aClickWithAHairOfJitterStaysAClick() {
        // Pressed a few points inside a block's top-left corner, at two pixels per point.
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: 103, y: 577))
        model.drag(to: CGPoint(x: 103, y: 577), snapping: snap)
        #expect(model.isTooSmall)
        #expect(model.snappedEdges.isEmpty)
        model.drag(to: CGPoint(x: 103.5, y: 576.5), snapping: snap)
        #expect(model.isTooSmall)
        #expect(model.snappedEdges.isEmpty)
        // Dragged a few pixels further, it is a selection and snaps.
        model.drag(to: CGPoint(x: 110, y: 570), snapping: snap)
        #expect(!model.isTooSmall)
        #expect(model.snappedEdges.contains(.left))
        // And dragged back to a click, it is one again.
        model.drag(to: CGPoint(x: 103.5, y: 576.5), snapping: snap)
        #expect(model.isTooSmall)
    }

    @Test func aDragLongInOneDirectionOnlyIsStillTooThinToSnap() {
        // A line drawn along the top of a block: wide enough, but no height to speak of.
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        model.begin(at: CGPoint(x: 103, y: 577))
        model.drag(to: CGPoint(x: 300, y: 576.5), snapping: snap)
        #expect(model.isTooSmall)
        #expect(model.snappedEdges.isEmpty)
    }

    @Test func aSquareOrCenteredSelectionKeepsItsShape() {
        for modifiers in [SelectionModel.Modifiers.square, .fromCenter] {
            var model = SelectionModel(bounds: bounds, pixelsPerPoint: 1)
            model.begin(at: CGPoint(x: 95, y: 585))
            model.drag(to: CGPoint(x: 505, y: 495), modifiers: modifiers, snapping: snap)
            #expect(model.snappedEdges.isEmpty)
        }
    }

    @Test func snappedEdgesFallOnThePixelGrid() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 2)
        let block = TextSnap(blocks: [CGRect(x: 100.3, y: 500, width: 400, height: 80)])
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 505, y: 495), snapping: block)
        // 96.3 is between two device pixels; the edge takes the nearer one.
        #expect(model.rect?.minX == 96.5)
        #expect(model.rect?.maxX == 504.5 && model.pixelSize.width == 816)
    }

    @Test func movingASelectionLetsGoOfItsSnappedEdges() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 1)
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 505, y: 495), snapping: snap)
        model.move(by: CGVector(dx: 30, dy: 0))
        #expect(model.snappedEdges.isEmpty)
    }

    @Test func aDragWithoutSnappingIsUnchanged() {
        var model = SelectionModel(bounds: bounds, pixelsPerPoint: 1)
        model.begin(at: CGPoint(x: 95, y: 585))
        model.drag(to: CGPoint(x: 505, y: 495))
        #expect(model.rect == CGRect(x: 95, y: 495, width: 410, height: 90))
        #expect(model.snappedEdges.isEmpty)
    }
}

@MainActor
struct DragSnapChoiceTests {
    let snap = TextSnap(blocks: [CGRect(x: 100, y: 500, width: 400, height: 80)])

    @Test func anAreaThatWillBeRecordedOrScrolledSnapsToNothing() {
        #expect(OverlayController.snap(snap, whileChoosing: .record) == nil)
        #expect(OverlayController.snap(snap, whileChoosing: .scroll) == nil)
    }

    @Test func everyOtherDragSnaps() {
        #expect(OverlayController.snap(snap, whileChoosing: nil) == snap)
        #expect(OverlayController.snap(snap, whileChoosing: .text) == snap)
        #expect(OverlayController.snap(snap, whileChoosing: .screenshot(nil)) == snap)
        #expect(OverlayController.snap(nil, whileChoosing: nil) == nil)
    }
}
