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
}
