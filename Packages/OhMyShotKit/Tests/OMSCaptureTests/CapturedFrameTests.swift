import CoreGraphics
import Testing
@testable import OMSCapture

struct CapturedFrameTests {
    /// A display 400 × 300 points at 2×, left of and above the origin, in Display P3: white, with a black
    /// block 20 points square at (100, 50) points from its top-left corner, which is (-300, 330) in
    /// global space.
    private func frame() -> CapturedFrame {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        // The context is y up: 50 points from the top of 300 is 460 pixels from the bottom, less the block.
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
        context.fill(CGRect(x: 200, y: 600 - 100 - 40, width: 40, height: 40))
        return CapturedFrame(image: context.makeImage()!, hdrImage: nil, displayID: 7, frame: CGRect(x: -400, y: 100, width: 400, height: 300))
    }

    /// The bytes of one pixel, counted from the top-left corner, read in the image's own color space.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: image.colorSpace!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return bytes
    }

    @Test func aSelectionComesOutAsItsOwnPixels() throws {
        let crop = try #require(frame().cropped(to: CGRect(x: -310, y: 320, width: 40, height: 40)))
        #expect(crop.image.width == 80 && crop.image.height == 80)
        #expect(crop.frame == CGRect(x: -310, y: 320, width: 40, height: 40))
        #expect(crop.displayID == 7 && crop.pixelsPerPoint == 2)
        // The block starts 10 points (20 pixels) in from the crop's left and top edges.
        #expect(pixel(crop.image, x: 30, y: 30) == [0, 0, 0, 255])
        #expect(pixel(crop.image, x: 5, y: 5) == [255, 255, 255, 255])
        #expect(pixel(crop.image, x: 19, y: 30) == [255, 255, 255, 255])
        #expect(pixel(crop.image, x: 20, y: 30) == [0, 0, 0, 255])
    }

    @Test func theColorSpaceIsKept() throws {
        let crop = try #require(frame().cropped(to: CGRect(x: -310, y: 320, width: 40, height: 40)))
        #expect(crop.image.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test func fractionalEdgesRoundToWholePixels() throws {
        let crop = try #require(frame().cropped(to: CGRect(x: -399.8, y: 100.3, width: 50.5, height: 20.2)))
        #expect(crop.image.width == 101 && crop.image.height == 40)
        #expect(crop.frame == CGRect(x: -400, y: 100.5, width: 50.5, height: 20))
    }

    @Test func aSelectionPastTheEdgeIsCutToTheDisplay() throws {
        let crop = try #require(frame().cropped(to: CGRect(x: -50, y: 350, width: 100, height: 100)))
        #expect(crop.image.width == 100 && crop.image.height == 100)
        #expect(crop.frame == CGRect(x: -50, y: 350, width: 50, height: 50))
    }

    @Test func aSelectionOffTheDisplayGivesNothing() {
        #expect(frame().cropped(to: CGRect(x: 10, y: 10, width: 50, height: 50)) == nil)
    }

    // MARK: Stitching

    /// A display's capture in one color: `frame` in global points at `scale` pixels per point.
    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, frame: CGRect, scale: CGFloat, space: CFString = CGColorSpace.sRGB, id: CGDirectDisplayID) -> CapturedFrame {
        let colorSpace = CGColorSpace(name: space)!
        let context = CGContext(
            data: nil, width: Int(frame.width * scale), height: Int(frame.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return CapturedFrame(image: context.makeImage()!, hdrImage: nil, displayID: id, frame: frame)
    }

    /// A red display on the right, and a blue one left of it whose top is level and whose bottom is
    /// 30 points higher; the area crosses their shared edge and reaches below the blue one.
    private let area = CGRect(x: -40, y: 10, width: 80, height: 60)

    @Test func partsGoWhereTheyLieAndNothingFillsWhereNoDisplayIs() throws {
        let right = solid(1, 0, 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, id: 1)
        let left = solid(0, 0, 1, frame: CGRect(x: -80, y: 30, width: 80, height: 70), scale: 2, id: 2)
        let parts = try [#require(right.cropped(to: area)), #require(left.cropped(to: area))]
        let stitched = try #require(CapturedFrame.stitched(parts, covering: area, pixelsPerPoint: 2))
        #expect(stitched.image.width == 160 && stitched.image.height == 120)
        #expect(stitched.frame == area)
        // The red part is the larger: 40 × 60 points against 40 × 40.
        #expect(stitched.displayID == 1)
        #expect(pixel(stitched.image, x: 10, y: 10) == [0, 0, 255, 255])
        #expect(pixel(stitched.image, x: 79, y: 30) == [0, 0, 255, 255])
        #expect(pixel(stitched.image, x: 80, y: 30) == [255, 0, 0, 255])
        #expect(pixel(stitched.image, x: 150, y: 60) == [255, 0, 0, 255])
        // Below the blue display: nothing.
        #expect(pixel(stitched.image, x: 10, y: 110) == [0, 0, 0, 0])
    }

    @Test func aLessSharpDisplayIsScaledUpToTheSharpestOne() throws {
        let right = solid(1, 0, 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, id: 1)
        let left = solid(0, 0, 1, frame: CGRect(x: -80, y: 30, width: 80, height: 70), scale: 1, id: 2)
        let parts = try [#require(right.cropped(to: area)), #require(left.cropped(to: area))]
        #expect(parts[1].image.width == 40)
        let stitched = try #require(CapturedFrame.stitched(parts, covering: area, pixelsPerPoint: 2))
        #expect(stitched.image.width == 160 && stitched.image.height == 120)
        #expect(pixel(stitched.image, x: 40, y: 40) == [0, 0, 255, 255])
    }

    @Test func partsInDifferentColorSpacesComeTogetherInDisplayP3() throws {
        let right = solid(1, 0, 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, space: CGColorSpace.displayP3, id: 1)
        let left = solid(0, 0, 1, frame: CGRect(x: -80, y: 30, width: 80, height: 70), scale: 2, id: 2)
        let leftPart = try #require(left.cropped(to: area))
        let mixedParts = try [#require(right.cropped(to: area)), leftPart]
        let mixed = try #require(CapturedFrame.stitched(mixedParts, covering: area, pixelsPerPoint: 2))
        #expect(mixed.image.colorSpace?.name == CGColorSpace.displayP3)
        let sameRight = solid(1, 0, 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, id: 1)
        let sameParts = try [#require(sameRight.cropped(to: area)), leftPart]
        let same = try #require(CapturedFrame.stitched(sameParts, covering: area, pixelsPerPoint: 2))
        #expect(same.image.colorSpace?.name == CGColorSpace.sRGB)
    }
}
