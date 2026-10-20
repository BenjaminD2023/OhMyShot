import CoreGraphics
import OMSCore
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

    @Test func aBoxStartedOnContentPreservesAllDiscontinuities() {
        let grid = grid()
        // One corner on the button, three on the page: the page is the background.
        let bounds = grid.contentBounds(in: CGRect(x: 65, y: 25, width: 20, height: 25))
        #expect(bounds == CGRect(x: 65, y: 25, width: 11, height: 19))
    }

    @Test func gradientsAndShadowsFollowAdjacentPixelsInBothDirections() {
        let fixtures: [([Int], Int, ClosedRange<Int>)] = [
            ([0, 13, 26, 40, 53], 1, 0...2),
            (Array(stride(from: 80, through: 160, by: 10)), 4, 0...8),
            ([255, 250, 245, 240, 235, 230, 10, 10, 10], 3, 0...5),
            ([255, 250, 245, 240, 235, 230, 10, 10, 10], 7, 6...8),
        ]
        for (levels, pointer, expected) in fixtures {
            let pixels = levels.map { UInt32(0xFF00_0000) | UInt32($0) * 0x010101 }
            let row = PixelGrid(width: levels.count, height: 1, pixels: pixels)
            let column = PixelGrid(width: 1, height: levels.count, pixels: pixels)
            #expect(row.span(throughX: pointer, y: 0, horizontal: true) == expected)
            #expect(column.span(throughX: 0, y: pointer, horizontal: false) == expected)
        }
    }

    @Test func thresholdsAreInclusiveForEachColorChannel() {
        for tolerance in MeasureTolerance.allCases {
            for shift: UInt32 in [0, 8, 16] {
                let exact = Self.black | UInt32(tolerance.threshold) << shift
                let beyond = Self.black | UInt32(tolerance.threshold + 1) << shift
                #expect(PixelGrid.matches(Self.black, exact, tolerance: tolerance))
                #expect(!PixelGrid.matches(Self.black, beyond, tolerance: tolerance))
            }
        }
        // The grid's chosen screenshot semantics compare RGB, independent of an alpha byte.
        #expect(PixelGrid.matches(0x0012_3456, 0xFF12_3456, tolerance: .zero))
    }

    @Test func toleranceCanRecoverAFaintHairline() {
        var pixels = [UInt32](repeating: Self.white, count: 9 * 7)
        for y in 2...4 { pixels[y * 9 + 4] = 0xFFF5_F5F5 }
        let grid = PixelGrid(width: 9, height: 7, pixels: pixels)
        let selection = CGRect(x: 0, y: 0, width: 9, height: 7)
        #expect(grid.contentBounds(in: selection, tolerance: .medium) == nil)
        #expect(grid.contentBounds(in: selection, tolerance: .low) == CGRect(x: 4, y: 2, width: 1, height: 3))
        // Pointing directly at the line supplies evidence from three neighboring rows.
        #expect(grid.span(throughX: 4, y: 3, horizontal: true, tolerance: .medium) == 4...4)
        #expect(grid.span(throughX: 4, y: 3, horizontal: true, tolerance: .low) == 4...4)
    }

    @Test func unrelatedBottomRowsCannotWidenAClosedObject() {
        // The earlier literal scanner widened this object to (2,2,6,2) because of the final ramp.
        // The ramp's open transition is not part of the object's closed perimeter.
        var pixels = [UInt32](repeating: 0xFF64_6464, count: 8 * 8)
        for y in 2...3 { for x in 4...5 { pixels[y * 8 + x] = Self.black } }
        for x in 0..<8 { pixels[7 * 8 + x] = 0xFF00_0000 | UInt32(100 + x * 10) * 0x010101 }
        let grid = PixelGrid(width: 8, height: 8, pixels: pixels)
        #expect(grid.contentBounds(in: CGRect(x: 0, y: 0, width: 8, height: 8)) == CGRect(x: 4, y: 2, width: 2, height: 2))
    }

    @Test func antialiasedEdgesNeedSpatialSupportAndGradientsRemainOneSurface() {
        var levels = [Int](repeating: 255, count: 45)
        levels[10] = 245
        levels[11] = 235
        for x in 12..<30 { levels[x] = 225 }
        levels[30] = 235
        levels[31] = 245
        let row = levels.map { UInt32(0xFF00_0000) | UInt32($0) * 0x010101 }
        let grid = PixelGrid(width: 45, height: 9, pixels: Array(repeating: row, count: 9).flatMap { $0 })
        #expect(grid.span(throughX: 20, y: 4, horizontal: true) == 11...30)
        let ramp = (0..<20).map { UInt32(0xFF00_0000) | UInt32(40 + $0 * 8) * 0x010101 }
        let gradient = PixelGrid(width: 20, height: 9, pixels: Array(repeating: ramp, count: 9).flatMap { $0 })
        #expect(gradient.span(throughX: 10, y: 4, horizontal: true) == 0...19)
        #expect(gradient.contentBounds(in: CGRect(x: 0, y: 0, width: 20, height: 9)) == nil)
    }

    @Test func oppositeEdgesOfANarrowFaintBarDoNotCancelEachOther() {
        for scale in [1, 2, 3] {
            let width = 30 * scale, height = 40 * scale
            var pixels = [UInt32](repeating: Self.white, count: width * height)
            for y in (8 * scale)..<(32 * scale) {
                for x in (12 * scale)..<(14 * scale) { pixels[y * width + x] = 0xFFF5_F5F5 }
            }
            let grid = PixelGrid(width: width, height: height, pixels: pixels, pixelsPerPoint: CGFloat(scale))
            #expect(grid.contentBounds(in: CGRect(x: 0, y: 0, width: width, height: height)) == CGRect(x: 12 * scale, y: 8 * scale, width: 2 * scale, height: 24 * scale))
            #expect(grid.span(throughX: 12 * scale, y: 20 * scale, horizontal: true) == (12 * scale)...(14 * scale - 1))
        }
    }

    @Test func bandsCrossingBothSelectionEdgesStillSnapWithoutInventingASingleEdgeObject() {
        for horizontal in [true, false] {
            for color in [Self.black, UInt32(0xFFF5_F5F5)] {
                let pixels = (0..<30).flatMap { y in
                    (0..<30).map { x in ((horizontal ? y : x) >= 10 && (horizontal ? y : x) < 20) ? color : Self.white }
                }
                let grid = PixelGrid(width: 30, height: 30, pixels: pixels)
                let expected = horizontal ? CGRect(x: 5, y: 10, width: 20, height: 10) : CGRect(x: 10, y: 5, width: 10, height: 20)
                #expect(grid.contentBounds(in: CGRect(x: 5, y: 5, width: 20, height: 20)) == expected)
                // Only one boundary is inside this crop; the user's rectangle is the safe choice.
                #expect(grid.contentBounds(in: CGRect(x: 5, y: 5, width: 10, height: 10)) == nil)
            }
        }
    }

    @Test func sharpBordersAndSinglePixelDimensionsStayInBounds() {
        var pixels = [UInt32](repeating: Self.white, count: 9 * 7)
        for y in 1...5 { for x in 2...6 {
            if y == 1 || y == 5 || x == 2 || x == 6 { pixels[y * 9 + x] = Self.black }
        } }
        let grid = PixelGrid(width: 9, height: 7, pixels: pixels)
        #expect(grid.contentBounds(in: CGRect(x: -10, y: -10, width: 40, height: 40)) == CGRect(x: 2, y: 1, width: 5, height: 5))
        #expect(grid.contentBounds(in: CGRect(x: 20, y: 20, width: 1, height: 1)) == nil)
        let strip = PixelGrid(width: 3, height: 1, pixels: [Self.white, Self.black, Self.white])
        #expect(strip.contentBounds(in: CGRect(x: 0, y: 0, width: 3, height: 1)) == CGRect(x: 1, y: 0, width: 1, height: 1))
        let single = PixelGrid(width: 1, height: 1, pixels: [Self.black])
        #expect(single.span(throughX: 99, y: -99, horizontal: true) == 0...0)
        #expect(single.contentBounds(in: CGRect(x: 0, y: 0, width: 1, height: 1)) == nil)
    }

    @Test func aCancelledImageCopyDoesNotProduceAGrid() async throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return PixelGrid(image)
        }
        let result = await worker.value
        #expect(result == nil)
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
