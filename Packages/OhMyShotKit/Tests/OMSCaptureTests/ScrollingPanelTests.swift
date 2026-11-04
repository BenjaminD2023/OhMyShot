import CoreGraphics
import Testing
@testable import OMSCapture

struct ScrollingPanelTests {
    let area = CGRect(x: 100, y: 100, width: 400, height: 500)

    @Test func theWindowHasRoomForTheShadowsAllRound() {
        // Far from the area: the room on every side.
        let frame = CGRect(x: 700, y: 300, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(frame, clear: area) == frame.insetBy(dx: -24, dy: -24))
    }

    @Test func theRoomStopsAtTheAreaItStandsBeside() {
        // 12 pt right of the area: the room on its left ends at the area's edge.
        let right = CGRect(x: 512, y: 300, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(right, clear: area) == CGRect(x: 500, y: 276, width: 236, height: 348))
        let left = CGRect(x: -112, y: 300, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(left, clear: area) == CGRect(x: -136, y: 276, width: 236, height: 348))
        let below = CGRect(x: 100, y: -212, width: 300, height: 300)
        #expect(ScrollingPanel.withShadowRoom(below, clear: area) == CGRect(x: 76, y: -236, width: 348, height: 336))
        let above = CGRect(x: 100, y: 612, width: 300, height: 200)
        #expect(ScrollingPanel.withShadowRoom(above, clear: area) == CGRect(x: 76, y: 600, width: 348, height: 236))
    }

    @Test func insideTheAreaTheRoomIsAllRound() {
        let inside = CGRect(x: 288, y: 288, width: 200, height: 300)
        #expect(ScrollingPanel.withShadowRoom(inside, clear: area) == inside.insetBy(dx: -24, dy: -24))
    }
}
