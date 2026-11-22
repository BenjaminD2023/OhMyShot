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

    @Test func windowsArePutTogetherWhereTheyAreNowBackToFront() {
        let notes = WindowTarget(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), ownerName: "Notes", title: nil)
        let mail = WindowTarget(id: 2, frame: CGRect(x: 200, y: 0, width: 100, height: 100), ownerName: "Mail", title: nil)
        let offScreen = WindowTarget(id: 3, frame: CGRect(x: 400, y: 0, width: 50, height: 50), ownerName: "Maps", title: nil)
        // Since they were chosen, Notes was moved and made larger, Mail came to the front, and Maps left the screen
        // (closed, minimized, or on another Space).
        let notesNow = WindowTarget(id: 1, frame: CGRect(x: 50, y: 60, width: 300, height: 200), ownerName: "Notes", title: nil)
        let other = WindowTarget(id: 9, frame: CGRect(x: 0, y: 0, width: 800, height: 600), ownerName: "Safari", title: nil)
        let placed = ScreenCapturer.backToFront([notes, mail, offScreen], in: [mail, other, notesNow])
        #expect(placed.map(\.id) == [3, 1, 2])
        #expect(placed.map(\.frame) == [offScreen.frame, notesNow.frame, mail.frame])
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

    @Test func windowsFromA2xAndA1xDisplayKeepTheirSizeTogether() throws {
        func solid(width: Int, height: Int) throws -> CGImage {
            let ctx = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(ctx.makeImage())
        }
        // Two windows of 100 × 50 points, one taken on a 2× display, the other on a 1× display, put together at 1×.
        let composited = try #require(ScreenCapturer.compositeWindows(
            [
                (image: try solid(width: 200, height: 100), windowFrame: CGRect(x: 0, y: 0, width: 100, height: 50), pixelsPerPoint: 2),
                (image: try solid(width: 100, height: 50), windowFrame: CGRect(x: 200, y: 0, width: 100, height: 50), pixelsPerPoint: 1),
            ],
            scale: 1,
            displayID: 9
        ))
        #expect(composited.frame == CGRect(x: 0, y: 0, width: 300, height: 50))
        #expect(composited.image.width == 300 && composited.image.height == 50)
    }

    @Test func aWindowFromALowerScaleDisplayKeepsItsSizeInPoints() throws {
        let red = try Self.solid(width: 200, height: 100, red: 1, blue: 0)
        // 50 by 50 points from a 1x display: 50 by 50 pixels, to fill 100 by 100 on the 2x canvas.
        let blue = try Self.solid(width: 50, height: 50, red: 0, blue: 1)
        let composited = try #require(ScreenCapturer.compositeWindows(
            [
                (image: red, windowFrame: CGRect(x: 100, y: 100, width: 100, height: 50), pixelsPerPoint: 2),
                (image: blue, windowFrame: CGRect(x: 180, y: 120, width: 50, height: 50), pixelsPerPoint: 1),
            ],
            scale: 2,
            displayID: 9
        ))
        #expect(composited.image.width == 260 && composited.image.height == 140)
        // The blue window's top-right corner, which it reaches only at its size in points.
        let corner = try Self.pixel(of: composited.image, x: 250, y: 10)
        #expect(corner.blue > 200 && corner.red < 50 && corner.alpha > 200)
    }

    @Test func liveWindowFrameUsesFreshSCWindowFrameFlippedToAppKitSpace() {
        let primary = Self.display(CGRect(x: 0, y: 0, width: 1440, height: 900))
        let layout = DisplayLayout(displays: [primary])
        let stale = CGRect(x: 100, y: 200, width: 400, height: 300)
        // Fresh SCWindow resized in CG coordinates (y down from primary top): top=100, height=400 -> AppKit y=400..800.
        let freshCG = CGRect(x: 120, y: 100, width: 600, height: 400)
        #expect(
            ScreenCapturer.liveWindowFrame(scWindowFrame: freshCG, fallback: stale, layout: layout)
                == CGRect(x: 120, y: 400, width: 600, height: 400)
        )
        #expect(ScreenCapturer.liveWindowFrame(scWindowFrame: .zero, fallback: stale, layout: layout) == stale)
    }

    private static func solid(width: Int, height: Int, red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The pixel at `x`, `y` from the image's top-left.
    private static func pixel(of image: CGImage, x: Int, y: Int) throws -> (red: UInt8, blue: UInt8, alpha: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: y + 1 - image.height, width: image.width, height: image.height))
        return (bytes[0], bytes[2], bytes[3])
    }
}
