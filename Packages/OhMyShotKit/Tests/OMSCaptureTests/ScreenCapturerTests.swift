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
        #expect(AreaFrame.local(rect, on: primary) == CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    @Test func regionOnADisplayLeftOfAndAboveTheOrigin() {
        let builtIn = Self.display(CGRect(x: -2056, y: 111, width: 2056, height: 1329))
        let rect = CGRect(x: -2000, y: 200, width: 300, height: 100)
        #expect(AreaFrame.local(rect, on: builtIn) == CGRect(x: 56, y: 1140, width: 300, height: 100))
    }

    @Test func wholeDisplayMapsToItsOwnBounds() {
        let builtIn = Self.display(CGRect(x: -2056, y: 111, width: 2056, height: 1329))
        #expect(AreaFrame.local(builtIn.frame, on: builtIn) == CGRect(x: 0, y: 0, width: 2056, height: 1329))
    }

    @Test func compositeWindowsCombinesMultipleWindowsInBoundingBox() throws {
        func solidWindow(width: Int, height: Int, color: CGColor) throws -> CGImage {
            let ctx = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(ctx.makeImage())
        }
        let imgA = try solidWindow(width: 200, height: 100, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let imgB = try solidWindow(width: 100, height: 100, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let composited = try #require(ScreenCapturer.compositeWindows(
            [
                (image: imgA, windowFrame: CGRect(x: 100, y: 100, width: 100, height: 50)),
                (image: imgB, windowFrame: CGRect(x: 180, y: 120, width: 50, height: 50)),
            ],
            scale: 2,
            displayID: 9
        ))
        #expect(composited.frame == CGRect(x: 100, y: 100, width: 130, height: 70))
        #expect(composited.image.width == 260 && composited.image.height == 140)
    }
}
