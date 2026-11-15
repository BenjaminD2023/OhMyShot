import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

/// The watermark on what leaves the app, and how it is drawn.
struct WatermarkTests {
    private func white(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// How many pixels of `image` are darker than white.
    private func marked(_ image: CGImage) throws -> Int {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).filter { data[$0 * 4] < 250 }.count
    }

    @Test func aWatermarkChangesWhatLeavesTheApp() throws {
        let plain = ScreenshotOutput()
        let marked = ScreenshotOutput(watermark: Watermark(text: "Confidential"))
        #expect(plain.isUnchanged && !plain.changesPicture)
        #expect(!marked.isUnchanged && marked.changesPicture)
        // Another text is another converted copy.
        #expect(marked.cacheKey != ScreenshotOutput(watermark: Watermark(text: "Draft")).cacheKey)
        // A blank one is none at all.
        #expect(ScreenshotOutput(watermark: Watermark(text: "  ")).watermark == nil)

        let picture = try white(400, 300)
        let prepared = PictureExport.prepare(picture, pixelsPerPoint: 2, output: marked)
        #expect(prepared.isChanged && prepared.image.width == 400)
        #expect(try self.marked(prepared.image) > 500)
        #expect(try self.marked(PictureExport.prepare(picture, pixelsPerPoint: 2, output: plain).image) == 0)
    }

    /// Tiled across the rect asked for, and nowhere outside it.
    @Test func theWatermarkStaysInItsRect() throws {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 400 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.translateBy(x: 0, y: 300)
        context.scaleBy(x: 1, y: -1)
        WatermarkPainter.paint(Watermark(text: "OhMyShot", opacity: 0.5), in: CGRect(x: 100, y: 50, width: 200, height: 150), context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Rows from the top in memory: y down, as drawn.
        var inside = 0, outside = 0
        for y in 0..<300 {
            for x in 0..<400 where data[(y * 400 + x) * 4] < 250 {
                if x >= 100, x < 300, y >= 50, y < 200 { inside += 1 } else { outside += 1 }
            }
        }
        #expect(inside > 300 && outside == 0)
    }
}
