import CoreGraphics
import Testing
@testable import OMSCapture
@testable import OMSCore

struct ScreenCapturerTests {
    static func display(_ frame: CGRect) -> DisplayInfo {
        DisplayInfo(
            id: 9,
            name: "Test",
            frame: frame,
            pixelSize: CGSize(width: frame.width * 2, height: frame.height * 2),
            backingScale: 2,
            maximumPotentialEDR: 1
        )
    }

    @Test func regionOnThePrimaryDisplayIsMeasuredFromItsTopLeft() {
        let primary = Self.display(CGRect(x: 0, y: 0, width: 3440, height: 1440))
        let rect = CGRect(x: 100, y: 1340, width: 100, height: 50)
        #expect(ScreenCapturer.displayLocalRect(rect, on: primary) == CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    @Test func regionOnADisplayLeftOfAndAboveTheOrigin() {
        let builtIn = Self.display(CGRect(x: -2056, y: 111, width: 2056, height: 1329))
        let rect = CGRect(x: -2000, y: 200, width: 300, height: 100)
        #expect(ScreenCapturer.displayLocalRect(rect, on: builtIn) == CGRect(x: 56, y: 1140, width: 300, height: 100))
    }

    @Test func wholeDisplayMapsToItsOwnBounds() {
        let builtIn = Self.display(CGRect(x: -2056, y: 111, width: 2056, height: 1329))
        #expect(ScreenCapturer.displayLocalRect(builtIn.frame, on: builtIn) == CGRect(x: 0, y: 0, width: 2056, height: 1329))
    }
}
