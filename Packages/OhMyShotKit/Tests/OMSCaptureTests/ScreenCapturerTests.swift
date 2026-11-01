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
                (image: imgA, windowFrame: CGRect(x: 100, y: 100, width: 100, height: 50), pixelsPerPoint: 2),
                (image: imgB, windowFrame: CGRect(x: 180, y: 120, width: 50, height: 50), pixelsPerPoint: 2),
            ],
            scale: 2,
            displayID: 9
        ))
        #expect(composited.frame == CGRect(x: 100, y: 100, width: 130, height: 70))
        #expect(composited.image.width == 260 && composited.image.height == 140)
    }
    @Test func compositeWindowsPreservesMixedDisplayScalesAndShadows() throws {
        func solid(_ width: Int, _ height: Int, _ color: CGColor) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        // The 2× window has a 5 pt shadow margin; the 1× window has none.
        let retina = try solid(220, 120, CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let standard = try solid(50, 50, CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let result = try #require(ScreenCapturer.compositeWindows([
            (image: retina, windowFrame: CGRect(x: 100, y: 100, width: 100, height: 50), pixelsPerPoint: 2),
            (image: standard, windowFrame: CGRect(x: 220, y: 100, width: 50, height: 50), pixelsPerPoint: 1),
        ], scale: 2, displayID: 9))
        #expect(result.frame == CGRect(x: 100, y: 100, width: 170, height: 50))
        #expect(result.image.width == 350 && result.image.height == 120)
        // Sample an interior portion that only the correctly scaled 1× image can fill.
        let pixel = try #require(result.image.cropping(to: CGRect(x: 330, y: 30, width: 1, height: 1)))
        let sample = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(sample.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[2] == 255 && bytes[3] == 255)
    }

}
