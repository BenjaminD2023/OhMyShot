import CoreGraphics
import OMSCore
@testable import OMSUI
import Testing

/// The camera menu's Position and the bubble's VoiceOver actions put the bubble 24 points in from a corner.
@MainActor
struct CameraBubbleCornerTests {
    private let area = CGRect(x: 100, y: 50, width: 1000, height: 600)

    @Test func eachCornerIs24PointsIn() {
        #expect(CameraBubble.corner(.bottomLeft, of: area, side: 180) == CGRect(x: 124, y: 74, width: 180, height: 180))
        #expect(CameraBubble.corner(.bottomRight, of: area, side: 180) == CGRect(x: 896, y: 74, width: 180, height: 180))
        #expect(CameraBubble.corner(.topLeft, of: area, side: 180) == CGRect(x: 124, y: 446, width: 180, height: 180))
        #expect(CameraBubble.corner(.topRight, of: area, side: 180) == CGRect(x: 896, y: 446, width: 180, height: 180))
    }

    @Test func aSmallAreaKeepsTheBubbleCentredInIt() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 200)
        // Less room than 24 points each side: what room there is is split.
        #expect(CameraBubble.corner(.topRight, of: small, side: 180) == CGRect(x: 10, y: 10, width: 180, height: 180))
    }

    @Test func togglingFillRestoresChosenCornerInsteadOfBottomLeft() {
        for corner in CameraBubbleCommand.Corner.allCases {
            var placement = CameraBubble.Placement()
            placement.update(area: area, side: 180)
            placement.move(to: corner, side: 180)
            let expected = CameraBubble.corner(corner, of: area, side: 180)
            #expect(placement.bubble == expected)

            let enteredFill = placement.toggleFill(side: 180)
            #expect(enteredFill)
            #expect(placement.fills)
            let exitedFill = placement.toggleFill(side: 180)
            #expect(!exitedFill)
            #expect(!placement.fills)
            #expect(placement.bubble == expected)
            #expect(placement.wasMoved)
        }
    }

    @Test func togglingFillRestoresCustomDraggedFrame() {
        var placement = CameraBubble.Placement()
        placement.update(area: area, side: 180)
        let dragged = placement.drag(by: CGVector(dx: 240, dy: 160), in: area)
        #expect(dragged == CGRect(x: 364, y: 234, width: 180, height: 180))

        let enteredFill = placement.toggleFill(side: 180)
        #expect(enteredFill)
        let exitedFill = placement.toggleFill(side: 180)
        #expect(!exitedFill)
        #expect(placement.bubble == dragged)
        #expect(placement.wasMoved)
    }

    @Test func movingToCornerWhileFillingExitsFillAndSnaps() {
        var placement = CameraBubble.Placement()
        placement.update(area: area, side: 180)
        placement.toggleFill(side: 180)
        #expect(placement.fills)

        let exitedFill = placement.move(to: .bottomRight, side: 180)
        #expect(exitedFill)
        #expect(!placement.fills)
        #expect(placement.bubble == CameraBubble.corner(.bottomRight, of: area, side: 180))
    }
}
