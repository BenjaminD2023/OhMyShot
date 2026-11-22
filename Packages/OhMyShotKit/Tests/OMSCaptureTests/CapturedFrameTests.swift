import CoreFoundation
import CoreGraphics
import OMSCore
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

    private func halfFloatComponent(_ image: CGImage, x: Int, y: Int, component: Int) throws -> Float {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let componentOffset = y * image.bytesPerRow + x * image.bitsPerPixel / 8 + component * image.bitsPerComponent / 8
        let bits = UInt16(bytes[componentOffset]) | UInt16(bytes[componentOffset + 1]) << 8
        return Float(Float16(bitPattern: bits))
    }

    @Test func aPickedPixelIsReadAsTheDisplayShowedIt() throws {
        let frame = frame()
        // The block is at pixels 200..<240 across and 100..<140 down.
        #expect(frame.color(atPixel: 210, 110)?.hex == "#000000")
        #expect(frame.color(atPixel: 10, 10)?.hex == "#FFFFFF")
        #expect(frame.color(atPixel: 800, 10) == nil)
        // Display P3's own red, which sRGB cannot hold, stays itself.
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(try #require(CGColor(colorSpace: space, components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let red = try #require(CapturedFrame(image: image, hdrImage: nil, displayID: 7, frame: CGRect(x: 0, y: 0, width: 1, height: 1)).color(atPixel: 0, 0))
        #expect(!red.isInSRGB)
        #expect(red.displayP3 == "color(display-p3 1 0 0)")
        // An sRGB color kept in an 8-bit Display P3 frame comes back as itself, and within sRGB, though the
        // rounding leaves it a hair past the edge.
        context.setFillColor(CGColor(srgbRed: 0, green: 122.0 / 255, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let blueImage = try #require(context.makeImage())
        let blue = try #require(CapturedFrame(image: blueImage, hdrImage: nil, displayID: 7, frame: CGRect(x: 0, y: 0, width: 1, height: 1)).color(atPixel: 0, 0))
        #expect(blue.hex == "#007AFF")
        #expect(blue.isInSRGB)
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

    @Test func aWindowShadowImageCanBeCroppedUsingItsPictureFrame() throws {
        let full = frame()
        // Same 800 × 600 image mapped 10 pt left and 10 pt down from `full.frame` (as a shadowed window capture).
        let pictureFrame = CGRect(x: -410, y: 90, width: 400, height: 300)
        // The black block (pixels 200..<240, 100..<140) sits at global (-310, 320)..(-290, 340).
        let selection = CGRect(x: -320, y: 310, width: 40, height: 40)
        let crop = try #require(full.cropped(to: selection, mappedFrom: pictureFrame, pixelsPerPoint: 2))
        #expect(crop.image.width == 80 && crop.image.height == 80)
        #expect(crop.frame == selection)
        #expect(crop.displayID == 7)
        #expect(pixel(crop.image, x: 19, y: 30) == [255, 255, 255, 255])
        #expect(pixel(crop.image, x: 20, y: 30) == [0, 0, 0, 255])
        #expect(pixel(crop.image, x: 30, y: 19) == [255, 255, 255, 255])
        #expect(pixel(crop.image, x: 30, y: 20) == [0, 0, 0, 255])
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

    @Test func liveCaptureRestoresOnlyTransientWindowPixels() throws {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        let live = solid(1, 0, 0, frame: display, scale: 2, id: 1)
        let transient = solid(0, 0, 1, frame: display, scale: 2, id: 1)
        let snapshot = TransientCaptureSnapshot(frame: transient, regions: [CGRect(x: 20, y: 20, width: 30, height: 30)])
        let restored = try #require(live.restoringTransientContent(from: [snapshot]))
        #expect(pixel(restored.image, x: 50, y: 130) == [0, 0, 255, 255])
        #expect(pixel(restored.image, x: 10, y: 10) == [255, 0, 0, 255])
    }

    @Test func emptyTransientSnapshotsLeaveTheLiveCaptureAlone() throws {
        let live = solid(1, 0, 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, id: 1)
        let restored = try #require(live.restoringTransientContent(from: []))
        #expect(pixel(restored.image, x: 10, y: 10) == [255, 0, 0, 255])
    }

    @Test func transientPixelsRemainUnderTransparentCursorPixels() throws {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        let live = solid(1, 0, 0, frame: display, scale: 2, id: 1)
        let transient = solid(0, 0, 1, frame: display, scale: 2, id: 1)
        let snapshot = TransientCaptureSnapshot(frame: transient, regions: [CGRect(x: 20, y: 20, width: 30, height: 30)])
        let cursorContext = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        cursorContext.clear(CGRect(x: 0, y: 0, width: 4, height: 4))
        cursorContext.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        cursorContext.fill(CGRect(x: 0, y: 3, width: 1, height: 1))
        let cursor = cursorContext.makeImage()!
        let restored = try #require(live.restoringTransientContent(
            from: [snapshot], cursor: (cursor, CGRect(x: 30, y: 30, width: 2, height: 2))
        ))
        #expect(pixel(restored.image, x: 60, y: 136) == [0, 255, 0, 255])
        #expect(pixel(restored.image, x: 61, y: 136) == [0, 0, 255, 255])
        #expect(pixel(restored.image, x: 70, y: 136) == [0, 0, 255, 255])
        #expect(pixel(restored.image, x: 10, y: 10) == [255, 0, 0, 255])

        let hdrLive = CapturedFrame(image: live.image, hdrImage: live.image, displayID: live.displayID, frame: display)
        #expect(hdrLive.restoringTransientContent(from: [snapshot]) == nil)
    }

    @Test func fractionalMixedScaleEmptyCropDoesNotDiscardOtherDisplayRegions() throws {
        let area = CGRect(x: -0.5, y: 0, width: 10.5, height: 10)
        let live = solid(1, 0, 0, frame: area, scale: 2, id: 1)
        let left = solid(0, 0, 1, frame: CGRect(x: -100, y: 0, width: 100, height: 10), scale: 1, id: 2)
        let right = solid(0, 1, 0, frame: CGRect(x: 0, y: 0, width: 100, height: 10), scale: 2, id: 3)
        let snapshots = [
            TransientCaptureSnapshot(frame: left, regions: [left.frame]),
            TransientCaptureSnapshot(frame: right, regions: [right.frame]),
        ]

        let restored = try #require(live.restoringTransientContent(from: snapshots))
        #expect(pixel(restored.image, x: 0, y: 10) == [0, 0, 255, 255])
        #expect(pixel(restored.image, x: 1, y: 10) == [0, 255, 0, 255])
    }

    @Test func fractionalClipDoesNotRescalePatternedTransientPixels() throws {
        let targetFrame = CGRect(x: -110, y: 0, width: 100.5, height: 10)
        let live = solid(1, 0, 0, frame: targetFrame, scale: 2, id: 1)
        let sourceFrame = CGRect(x: -100, y: 0, width: 100, height: 10)
        let sourceContext = CGContext(
            data: nil, width: 100, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        for x in 0..<100 {
            sourceContext.setFillColor(x.isMultiple(of: 2) ? CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            sourceContext.fill(CGRect(x: x, y: 0, width: 1, height: 10))
        }
        let sourceImage = sourceContext.makeImage()!
        let croppedSource = try #require(sourceImage.cropping(to: CGRect(x: 0, y: 0, width: 91, height: 10)))
        let source = CapturedFrame(image: sourceImage, hdrImage: nil, displayID: 2, frame: sourceFrame)
        let restored = try #require(live.restoringTransientContent(
            from: [TransientCaptureSnapshot(frame: source, regions: [sourceFrame])]
        ))

        func composite(destinationWidth: CGFloat) -> CGImage {
            let context = CGContext(
                data: nil, width: live.image.width, height: live.image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            let bitmap = CGRect(x: 0, y: 0, width: live.image.width, height: live.image.height)
            context.draw(live.image, in: bitmap)
            context.saveGState()
            context.clip(to: CGRect(x: 20, y: 0, width: 181, height: 20))
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(croppedSource, in: CGRect(x: 20, y: 0, width: destinationWidth, height: 20))
            context.restoreGState()
            return context.makeImage()!
        }

        let expected = composite(destinationWidth: 182)
        let rescaled = composite(destinationWidth: 181)
        var distinguishesRescaling = false
        for x in 20..<201 {
            let expectedPixel = pixel(expected, x: x, y: 10)
            #expect(pixel(restored.image, x: x, y: 10) == expectedPixel)
            distinguishesRescaling = distinguishesRescaling || expectedPixel != pixel(rescaled, x: x, y: 10)
        }
        #expect(distinguishesRescaling)
    }

    @Test func transientRegionsComposeIntoSyntheticHDRBuffers() throws {
        let display = CGRect(x: 0, y: 0, width: 8, height: 8)
        let sdr = solid(0, 0, 0, frame: display, scale: 1, id: 1)
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let info = CGBitmapInfo.byteOrder16Little
            .union(.floatComponents)
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        func hdrImage(_ components: [CGFloat]) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                bitmapInfo: info.rawValue
            ))
            context.setFillColor(try #require(CGColor(colorSpace: space, components: components)))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try #require(context.makeImage())
        }

        let live = CapturedFrame(image: sdr.image, hdrImage: try hdrImage([0.25, 0.25, 0.25, 1]), displayID: 1, frame: display)
        let transient = CapturedFrame(image: sdr.image, hdrImage: try hdrImage([0, 1.5, 0, 1]), displayID: 1, frame: display)
        let restored = try #require(live.restoringTransientContent(
            from: [TransientCaptureSnapshot(frame: transient, regions: [CGRect(x: 2, y: 2, width: 3, height: 3)])]
        ))

        #expect(restored.hdrImage?.bitsPerComponent == 16)
        #expect(restored.hdrImage?.colorSpace?.name == CGColorSpace.extendedSRGB)
        let restoredHDR = try #require(restored.hdrImage)
        let transientHDR = try #require(transient.hdrImage)
        let restoredHighlight = try halfFloatComponent(restoredHDR, x: 3, y: 3, component: 1)
        let transientHighlight = try halfFloatComponent(transientHDR, x: 3, y: 3, component: 1)
        let background = try halfFloatComponent(restoredHDR, x: 0, y: 0, component: 1)
        #expect(abs(restoredHighlight - transientHighlight) < 0.01)
        #expect(restoredHighlight > 1.4)
        #expect(abs(background - 0.25) < 0.01)
    }

    @Test func croppedMixedScaleDisplaySnapshotsRestoreAcrossANegativeOriginArea() throws {
        let area = CGRect(x: -50, y: 20, width: 100, height: 50)
        let live = solid(1, 0, 0, frame: area, scale: 2, id: 1)
        let left = solid(0, 0, 1, frame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1, id: 2)
        let right = solid(0, 1, 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, id: 3)
        let snapshots = [
            TransientCaptureSnapshot(frame: left, regions: [CGRect(x: -45, y: 30, width: 20, height: 20)]),
            TransientCaptureSnapshot(frame: right, regions: [CGRect(x: 10, y: 30, width: 20, height: 20)]),
        ]

        let restored = try #require(live.restoringTransientContent(from: snapshots))
        #expect(pixel(restored.image, x: 30, y: 70) == [0, 0, 255, 255])
        #expect(pixel(restored.image, x: 130, y: 70) == [0, 255, 0, 255])
        #expect(pixel(restored.image, x: 80, y: 70) == [255, 0, 0, 255])
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

    /// The edges of what an area holds come back in global points, found on its part of the picture and a margin as they
    /// would be on the whole picture.
    @Test func theContentBoundsOfAnAreaAreFoundInItsPartAsInTheWhole() throws {
        let frame = frame()
        // The block is 20 points square at (-300, 330) in global space.
        let block = CGRect(x: -300, y: 330, width: 20, height: 20)
        #expect(frame.contentBounds(in: CGRect(x: -320, y: 300, width: 100, height: 80)) == block)
        let grid = try #require(PixelGrid(frame.image, pixelsPerPoint: 2))
        // Areas whose sides run close by the block's edges, where the detector looks past the area's side.
        for area in [CGRect(x: -302, y: 328, width: 30, height: 30), CGRect(x: -305, y: 325, width: 26, height: 26), CGRect(x: -400, y: 100, width: 400, height: 300)] {
            let pixels = CGRect(x: (area.minX + 400) * 2, y: (400 - area.maxY) * 2, width: area.width * 2, height: area.height * 2)
            let whole = grid.contentBounds(in: pixels).map {
                CGRect(x: -400 + $0.minX / 2, y: 400 - $0.maxY / 2, width: $0.width / 2, height: $0.height / 2)
            }
            #expect(frame.contentBounds(in: area) == whole, "\(area)")
        }
        // White alone has no edges, and an area off the picture has nothing in it.
        #expect(frame.contentBounds(in: CGRect(x: -100, y: 120, width: 60, height: 60)) == nil)
        #expect(frame.contentBounds(in: CGRect(x: 100, y: 100, width: 60, height: 60)) == nil)
    }
}
