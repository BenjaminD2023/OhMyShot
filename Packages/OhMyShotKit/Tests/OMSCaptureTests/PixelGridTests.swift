import CoreGraphics
import Testing
@testable import OMSCapture

struct PixelGridTests {
    private static let white: UInt32 = 0xFFFF_FFFF
    private static let blue: UInt32 = 0xFF00_7AFF
    private static let black: UInt32 = 0xFF00_0000

    /// 100 × 60 white, with a blue button 40 × 20 at (30, 10) and a black icon 6 × 4 at (70, 40).
    private func grid() -> PixelGrid {
        var pixels = [UInt32](repeating: Self.white, count: 100 * 60)
        for y in 10..<30 { for x in 30..<70 { pixels[y * 100 + x] = Self.blue } }
        for y in 40..<44 { for x in 70..<76 { pixels[y * 100 + x] = Self.black } }
        return PixelGrid(width: 100, height: 60, pixels: pixels)
    }

    @Test func aRunEndsWhereTheColorChanges() {
        let grid = grid()
        // Inside the button: its own width and height.
        #expect(grid.span(throughX: 45, y: 20, horizontal: true) == 30...69)
        #expect(grid.span(throughX: 45, y: 20, horizontal: false) == 10...29)
        // Between the button and the frame's left edge: the gap, out to the edge.
        #expect(grid.span(throughX: 10, y: 20, horizontal: true) == 0...29)
        // Points outside the frame are taken at its edge.
        #expect(grid.span(throughX: -5, y: 20, horizontal: true) == 0...29)
    }

    @Test func colorsWithinTheToleranceAreOneRun() {
        // A soft shadow's dithering: off by a few levels, still one surface.
        let nearlyWhite: UInt32 = 0xFFFA_FBFC
        var pixels = [UInt32](repeating: Self.white, count: 20)
        pixels[12] = nearlyWhite
        let grid = PixelGrid(width: 20, height: 1, pixels: pixels)
        #expect(grid.span(throughX: 5, y: 0, horizontal: true) == 0...19)
        #expect(!PixelGrid.matches(Self.white, 0xFFE5_E5E5))
    }

    @Test func aBoxShrinksToWhatItHolds() {
        let grid = grid()
        // Drawn loosely around the icon.
        #expect(grid.contentBounds(in: CGRect(x: 62, y: 33, width: 25, height: 20)) == CGRect(x: 70, y: 40, width: 6, height: 4))
        // Around the button and part of the page: the button.
        #expect(grid.contentBounds(in: CGRect(x: 20, y: 2, width: 60, height: 35)) == CGRect(x: 30, y: 10, width: 40, height: 20))
        // Only page: nothing to snap to.
        #expect(grid.contentBounds(in: CGRect(x: 2, y: 40, width: 20, height: 15)) == nil)
    }

    @Test func aBoxStartedOnContentKeepsTheBackgroundMostCornersShare() {
        let grid = grid()
        // One corner on the button, three on the page: the page is the background.
        let bounds = grid.contentBounds(in: CGRect(x: 65, y: 25, width: 20, height: 25))
        #expect(bounds == CGRect(x: 65, y: 25, width: 11, height: 19))
    }

    @Test func aFrameBecomesAGrid() throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // The top row in the image: y up in the context.
        context.fill(CGRect(x: 2, y: 3, width: 3, height: 1))
        let image = try #require(context.makeImage())
        let grid = try #require(PixelGrid(image))
        #expect(grid.width == 8 && grid.height == 4)
        #expect(grid.span(throughX: 3, y: 0, horizontal: true) == 2...4)
        #expect(grid.span(throughX: 3, y: 2, horizontal: true) == 0...7)
    }
}
