import CoreGraphics
import Testing
@testable import OMSCapture

struct ScrollingPanelTests {
    let area = CGRect(x: 100, y: 100, width: 400, height: 500)

    @Test func theWindowHasRoomForTheShadowsAllRound() {
        // Far from the area: the room on every side, twice the card shadow's blur and its drop.
        let frame = CGRect(x: 700, y: 300, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(frame, clear: area) == frame.insetBy(dx: -34, dy: -34))
    }

    @Test func theRoomStopsAtTheAreaItStandsBeside() {
        // 12 pt right of the area: the room on its left ends at the area's edge.
        let right = CGRect(x: 512, y: 300, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(right, clear: area) == CGRect(x: 500, y: 266, width: 246, height: 368))
        let left = CGRect(x: -112, y: 300, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(left, clear: area) == CGRect(x: -146, y: 266, width: 246, height: 368))
        let below = CGRect(x: 100, y: -212, width: 300, height: 300)
        #expect(ScrollingPanel.withShadowRoom(below, clear: area) == CGRect(x: 66, y: -246, width: 368, height: 346))
        let above = CGRect(x: 100, y: 612, width: 300, height: 200)
        #expect(ScrollingPanel.withShadowRoom(above, clear: area) == CGRect(x: 66, y: 600, width: 368, height: 246))
    }

    @Test func insideTheAreaTheRoomIsAllRound() {
        let inside = CGRect(x: 288, y: 288, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(inside, clear: area) == inside.insetBy(dx: -34, dy: -34))
    }
}
