import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMSCore

/// What a screenshot becomes where it leaves the app: format, 1×, sRGB, the border, alpha.
struct PictureExportTests {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A picture of one color (red, green, blue, alpha, in `space`), with `clear` pixel columns cleared at each
    /// side when asked, as a window's corners are.
    private func picture(
        _ width: Int, _ height: Int, color: [UInt8] = [255, 255, 255, 255], space: CGColorSpace = srgb, hasAlpha: Bool = true,
        clearCorner: Int = 0
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let corner = clearCorner > 0 && (x < clearCorner || x >= width - clearCorner) && (y < clearCorner || y >= height - clearCorner)
                let offset = (y * width + x) * 4
                if corner { continue }
                // Premultiplied.
                let alpha = Int(color[3])
                bytes[offset] = UInt8(Int(color[0]) * alpha / 255)
                bytes[offset + 1] = UInt8(Int(color[1]) * alpha / 255)
                bytes[offset + 2] = UInt8(Int(color[2]) * alpha / 255)
                bytes[offset + 3] = color[3]
            }
        }
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func decode(_ data: Data) throws -> (image: CGImage, properties: [CFString: Any], type: String?) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, properties, CGImageSourceGetType(source) as String?)
    }

    /// The pixel at (x, y) as the image stores it, in its own color space and not premultiplied.
    private func raw(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        // Redrawn into a bitmap of the image's own space, so no color conversion happens.
        let space = try #require(image.colorSpace)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        let alpha = Int(bytes[offset + 3])
        guard alpha > 0 else { return [0, 0, 0, 0] }
        return [0, 1, 2].map { min(255, Int(bytes[offset + $0]) * 255 / alpha) } + [alpha]
    }

    // MARK: Format

    @Test func eachFormatIsWrittenAsItself() throws {
        let image = try picture(40, 30, color: [200, 80, 40, 255])
        for (format, type) in [(ImageExporter.Format.png, UTType.png), (.jpeg, .jpeg), (.heic, .heic)] {
            let encoded = try PictureExport.encode(image, pixelsPerPoint: 2, output: ScreenshotOutput(format: format))
            #expect(encoded.format == format)
            let decoded = try decode(encoded.data)
            #expect(decoded.type == type.identifier)
            #expect(decoded.image.width == 40 && decoded.image.height == 30)
        }
    }

    @Test func aLowerQualityMakesASmallerFile() throws {
        // Noise, which a lossy format has to work at.
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 255, count: 120 * 120 * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 { bytes[index + channel] = UInt8.random(in: 0...255, using: &generator) }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let noise = try #require(CGImage(
            width: 120, height: 120, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 480, space: Self.srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        for format in [ImageExporter.Format.jpeg, .heic] {
            let low = try PictureExport.encode(noise, pixelsPerPoint: 1, output: ScreenshotOutput(format: format, quality: 0.5))
            let high = try PictureExport.encode(noise, pixelsPerPoint: 1, output: ScreenshotOutput(format: format, quality: 1))
            #expect(low.data.count < high.data.count)
        }
    }

    @Test func theQualityStaysWithinWhatSettingsOffer() {
        #expect(ScreenshotOutput(quality: 0.1).quality == 0.5)
        #expect(ScreenshotOutput(quality: 7).quality == 1)
    }

    @Test func formatsAreReadFromExtensions() {
        #expect(ImageExporter.Format(fileExtension: "JPG") == .jpeg)
        #expect(ImageExporter.Format(fileExtension: "jpeg") == .jpeg)
        #expect(ImageExporter.Format(fileExtension: "heic") == .heic)
        #expect(ImageExporter.Format(fileExtension: "png") == .png)
        #expect(ImageExporter.Format(fileExtension: "gif") == nil)
    }

    @Test func aPlainPNGIsLeftAlone() {
        #expect(ScreenshotOutput.standard.isUnchanged)
        #expect(!ScreenshotOutput(format: .jpeg).isUnchanged)
        #expect(!ScreenshotOutput(retinaAtOneX: true).isUnchanged)
        #expect(!ScreenshotOutput(convertsToSRGB: true).isUnchanged)
        #expect(!ScreenshotOutput(addsBorder: true).isUnchanged)
    }

    // MARK: 1×

    @Test func aRetinaPictureComesOutAtItsSizeInPoints() throws {
        let image = try picture(400, 300)
        let encoded = try PictureExport.encode(image, pixelsPerPoint: 2, output: ScreenshotOutput(retinaAtOneX: true))
        let decoded = try decode(encoded.data)
        #expect(decoded.image.width == 200 && decoded.image.height == 150)
        // 72 dpi: one pixel per point, which a file with no resolution also says.
        #expect((decoded.properties[kCGImagePropertyDPIWidth] as? Double ?? 72) < 72.5)
    }

    @Test func aPictureOfUnknownScaleOrAlready1xKeepsItsSize() throws {
        let image = try picture(400, 300)
        let output = ScreenshotOutput(retinaAtOneX: true)
        #expect(try decode(PictureExport.encode(image, pixelsPerPoint: nil, output: output).data).image.width == 400)
        #expect(try decode(PictureExport.encode(image, pixelsPerPoint: 1, output: output).data).image.width == 400)
        #expect(!PictureExport.prepare(image, pixelsPerPoint: 1, output: output).isChanged)
    }

    @Test func aThreeTimesPictureIsScaledToo() throws {
        let image = try picture(300, 150)
        let prepared = PictureExport.prepare(image, pixelsPerPoint: 3, output: ScreenshotOutput(retinaAtOneX: true))
        #expect(prepared.image.width == 100 && prepared.image.height == 50)
        #expect(prepared.pixelsPerPoint == 1)
    }

    @Test func aRetinaPictureWithoutScalingStatesItsResolution() throws {
        let image = try picture(400, 300)
        let encoded = try PictureExport.encode(image, pixelsPerPoint: 2, output: ScreenshotOutput(format: .jpeg))
        let decoded = try decode(encoded.data)
        #expect(decoded.image.width == 400)
        let dpi = try #require(decoded.properties[kCGImagePropertyDPIWidth] as? Double)
        #expect(abs(dpi - 144) < 1)
    }

    // MARK: sRGB

    @Test func aDisplayP3PictureIsConvertedToSRGB() throws {
        // A color P3 holds and sRGB does too, which the two write with different numbers.
        let p3 = try picture(8, 8, color: [204, 102, 51, 255], space: Self.displayP3)
        let converted = try PictureExport.encode(p3, pixelsPerPoint: nil, output: ScreenshotOutput(convertsToSRGB: true))
        let kept = try PictureExport.encode(p3, pixelsPerPoint: nil, output: ScreenshotOutput())
        let after = try decode(converted.data).image
        let before = try decode(kept.data).image
        #expect(after.colorSpace?.name == CGColorSpace.sRGB)
        #expect(before.colorSpace?.name == CGColorSpace.displayP3)
        // Expected: the same color in sRGB, as ColorSync gives it.
        let expected = try #require(CGColor(colorSpace: Self.displayP3, components: [0.8, 0.4, 0.2, 1])?.converted(to: Self.srgb, intent: .defaultIntent, options: nil)?.components)
        let pixel = try raw(after, 4, 4)
        for channel in 0..<3 {
            #expect(abs(Double(pixel[channel]) - Double(expected[channel]) * 255) <= 2)
        }
        // And it is not the P3 numbers, which would be the picture relabelled.
        #expect(abs(pixel[0] - 204) > 5)
    }

    @Test func aPictureAlreadyInSRGBIsNotRedrawn() throws {
        let image = try picture(20, 20)
        #expect(!PictureExport.prepare(image, pixelsPerPoint: nil, output: ScreenshotOutput(convertsToSRGB: true)).isChanged)
    }

    // MARK: Border

    @Test func theBorderIsOnePixelAllRound() throws {
        let image = try picture(20, 16)
        let prepared = PictureExport.prepare(image, pixelsPerPoint: nil, output: ScreenshotOutput(addsBorder: true))
        let out = prepared.image
        #expect(out.width == 20 && out.height == 16 && prepared.isChanged)
        let ink = Int((255 * (1 - PictureExport.borderOpacity)).rounded())
        for (x, y) in [(0, 0), (19, 0), (0, 15), (19, 15), (10, 0), (10, 15), (0, 8), (19, 8)] {
            let pixel = try raw(out, x, y)
            #expect(abs(pixel[0] - ink) <= 2, "pixel \(x),\(y)")
        }
        // Inside, nothing changed; each corner took the ink once.
        for (x, y) in [(1, 1), (10, 8), (18, 14), (1, 8), (10, 1)] {
            #expect(try raw(out, x, y)[0] == 255, "pixel \(x),\(y)")
        }
    }

    @Test func noBorderUnlessAsked() throws {
        let image = try picture(20, 16)
        #expect(!PictureExport.prepare(image, pixelsPerPoint: nil, output: ScreenshotOutput()).isChanged)
    }

    @Test func aPictureWithClearCornersGetsNoBorder() throws {
        let window = try picture(30, 20, clearCorner: 3)
        let prepared = PictureExport.prepare(window, pixelsPerPoint: nil, output: ScreenshotOutput(addsBorder: true))
        #expect(!prepared.isChanged)
        #expect(PictureExport.hasTransparentEdge(window))
    }

    @Test func aPictureWithAClearShadowAroundItGetsNoBorder() throws {
        // A one pixel clear ring.
        let inner = try picture(18, 8)
        let context = try #require(CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: Self.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(inner, in: CGRect(x: 1, y: 1, width: 18, height: 8))
        let shadowed = try #require(context.makeImage())
        #expect(PictureExport.hasTransparentEdge(shadowed))
        #expect(!PictureExport.prepare(shadowed, pixelsPerPoint: nil, output: ScreenshotOutput(addsBorder: true)).isChanged)
    }

    @Test func anOpaquePictureCountsAsOpaqueWhateverItsAlphaInfo() throws {
        #expect(!PictureExport.hasTransparentEdge(try picture(10, 10, hasAlpha: true)))
        #expect(!PictureExport.hasTransparentEdge(try picture(10, 10, hasAlpha: false)))
    }

    @Test func theBorderFollowsTheScaling() throws {
        // One pixel in the file that is written, not in the picture that was taken.
        let image = try picture(400, 300)
        let prepared = PictureExport.prepare(image, pixelsPerPoint: 2, output: ScreenshotOutput(retinaAtOneX: true, addsBorder: true))
        #expect(prepared.image.width == 200)
        #expect(try raw(prepared.image, 0, 100)[0] < 230)
        #expect(try raw(prepared.image, 1, 100)[0] > 250)
    }

    // MARK: Alpha

    @Test func aPNGKeepsItsTransparencyAndAJPEGIsFlattenedOnWhite() throws {
        let window = try picture(30, 20, color: [20, 40, 200, 255], clearCorner: 4)
        let png = try decode(PictureExport.encode(window, pixelsPerPoint: nil, output: ScreenshotOutput()).data).image
        #expect(try raw(png, 0, 0)[3] == 0)
        let jpeg = try decode(PictureExport.encode(window, pixelsPerPoint: nil, output: ScreenshotOutput(format: .jpeg)).data).image
        let corner = try raw(jpeg, 0, 0)
        #expect(corner[0] >= 245 && corner[1] >= 245 && corner[2] >= 245)
        // The window itself is still blue.
        let middle = try raw(jpeg, 15, 10)
        #expect(middle[2] > 150 && middle[0] < 80)
    }

    @Test func aHEICKeepsItsTransparency() throws {
        let window = try picture(32, 24, color: [20, 40, 200, 255], clearCorner: 5)
        let decoded = try decode(PictureExport.encode(window, pixelsPerPoint: nil, output: ScreenshotOutput(format: .heic, quality: 1)).data).image
        #expect(try raw(decoded, 0, 0)[3] < 40)
        #expect(try raw(decoded, 16, 12)[3] > 215)
    }

    // MARK: HDR

    /// An extended-sRGB, half-float picture with light brighter than SDR white, as a capture of an HDR display has.
    private func hdrPicture(_ width: Int, _ height: Int) throws -> CGImage {
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = Float16(Float(x) / Float(width) * 3)
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value * 0.5
                pixels[offset + 2] = 0.2
                pixels[offset + 3] = 1
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 2) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
            space: CGColorSpace(name: CGColorSpace.extendedSRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func hasGainMap(_ data: Data) throws -> Bool {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    }

    @Test func aHEICOfAnHDRCaptureCarriesAnISOGainMap() throws {
        let sdr = try picture(64, 64, color: [180, 90, 50, 255])
        let hdr = try hdrPicture(64, 64)
        let encoded = try PictureExport.encode(sdr, pixelsPerPoint: 2, hdr: hdr, output: ScreenshotOutput(format: .heic))
        #expect(encoded.format == .heic)
        #expect(try hasGainMap(encoded.data))
        // The base picture is what a viewer without HDR shows.
        #expect(try decode(encoded.data).image.width == 64)
    }

    @Test func theGainMapFollowsTheScaling() throws {
        let sdr = try picture(128, 64)
        let hdr = try hdrPicture(128, 64)
        let encoded = try PictureExport.encode(sdr, pixelsPerPoint: 2, hdr: hdr, output: ScreenshotOutput(format: .heic, retinaAtOneX: true, addsBorder: true))
        #expect(try hasGainMap(encoded.data))
        #expect(try decode(encoded.data).image.width == 64)
    }

    @Test func noGainMapForOtherFormatsOrWhenConvertingToSRGB() throws {
        let sdr = try picture(64, 64)
        let hdr = try hdrPicture(64, 64)
        let jpeg = try PictureExport.encode(sdr, pixelsPerPoint: 2, hdr: hdr, output: ScreenshotOutput(format: .jpeg))
        #expect(try !hasGainMap(jpeg.data))
        let converted = try PictureExport.encode(sdr, pixelsPerPoint: 2, hdr: hdr, output: ScreenshotOutput(format: .heic, convertsToSRGB: true))
        #expect(try !hasGainMap(converted.data))
        let without = try PictureExport.encode(sdr, pixelsPerPoint: 2, output: ScreenshotOutput(format: .heic))
        #expect(try !hasGainMap(without.data))
    }

    @Test func anHDRPictureOfAnotherSizeIsNotUsed() throws {
        let sdr = try picture(64, 64)
        let hdr = try hdrPicture(32, 32)
        let encoded = try PictureExport.encode(sdr, pixelsPerPoint: nil, hdr: hdr, output: ScreenshotOutput(format: .heic))
        #expect(try !hasGainMap(encoded.data))
    }

    // MARK: Files

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PictureExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aCaptureFileIsReadAndConverted() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Shot.png")
        try writePNG(try picture(200, 100, color: [30, 120, 60, 255]), to: file)
        let encoded = try PictureExport.encode(fileAt: file, pixelsPerPoint: 2, output: ScreenshotOutput(format: .jpeg, retinaAtOneX: true))
        let decoded = try decode(encoded.data)
        #expect(decoded.type == UTType.jpeg.identifier)
        #expect(decoded.image.width == 100)
    }

    @Test func aFileThatStatesItsResolutionNeedsNoScale() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Shot.png")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try picture(200, 100), [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let encoded = try PictureExport.encode(fileAt: file, pixelsPerPoint: nil, output: ScreenshotOutput(retinaAtOneX: true))
        #expect(try decode(encoded.data).image.width == 100)
    }

    @Test func theExportedCopyKeepsTheCapturesNameAndIsMadeOnce() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Exports", directoryHint: .isDirectory)
        let file = folder.appending(path: "OhMyShot 2026-10-08 at 00.25.10.png")
        try writePNG(try picture(60, 40), to: file)
        let output = ScreenshotOutput(format: .jpeg)
        let first = try ExportedFiles.file(for: file, pixelsPerPoint: 2, output: output, in: cache)
        #expect(first.lastPathComponent == "OhMyShot 2026-10-08 at 00.25.10.jpg")
        #expect(first.path(percentEncoded: false).hasPrefix(cache.path(percentEncoded: false)))
        let made = try #require(try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let second = try ExportedFiles.file(for: file, pixelsPerPoint: 2, output: output, in: cache)
        #expect(second == first)
        #expect(try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == made)
        // Another format is another copy.
        let heic = try ExportedFiles.file(for: file, pixelsPerPoint: 2, output: ScreenshotOutput(format: .heic), in: cache)
        #expect(heic.pathExtension == "heic" && heic != first)
    }

    @Test func aChangedCaptureIsExportedAgain() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Exports", directoryHint: .isDirectory)
        let file = folder.appending(path: "Shot.png")
        try writePNG(try picture(60, 40), to: file)
        let output = ScreenshotOutput(format: .jpeg)
        let first = try ExportedFiles.file(for: file, pixelsPerPoint: 1, output: output, in: cache)
        #expect(try decode(Data(contentsOf: first)).image.width == 60)
        // The editor keeps its marks: a larger picture in the same file, later.
        try writePNG(try picture(90, 40), to: file)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: file.path(percentEncoded: false))
        let second = try ExportedFiles.file(for: file, pixelsPerPoint: 1, output: output, in: cache)
        #expect(try decode(Data(contentsOf: second)).image.width == 90)
    }

    @Test func aCaptureLeftAsItIsAndARecordingAreHandedOverUnconverted() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Exports", directoryHint: .isDirectory)
        let file = folder.appending(path: "Shot.png")
        try writePNG(try picture(10, 10), to: file)
        #expect(try ExportedFiles.file(for: file, pixelsPerPoint: 2, output: .standard, in: cache) == file)
        let clip = folder.appending(path: "Clip.gif")
        try Data("GIF89a".utf8).write(to: clip)
        #expect(try ExportedFiles.file(for: clip, pixelsPerPoint: 2, output: ScreenshotOutput(format: .jpeg), in: cache) == clip)
        let movie = folder.appending(path: "Clip.mp4")
        try Data([0]).write(to: movie)
        #expect(try ExportedFiles.file(for: movie, pixelsPerPoint: 2, output: ScreenshotOutput(format: .heic), in: cache) == movie)
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
    }

    @Test func oldCopiesAreSweptAway() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Exports", directoryHint: .isDirectory)
        let file = folder.appending(path: "Shot.png")
        try writePNG(try picture(10, 10), to: file)
        let copy = try ExportedFiles.file(for: file, pixelsPerPoint: 1, output: ScreenshotOutput(format: .jpeg), in: cache)
        ExportedFiles.removeOld(in: cache)
        #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        ExportedFiles.removeOld(in: cache, now: .now.addingTimeInterval(ExportedFiles.lifetime + 60))
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    }

    @Test func theFoldersOldCopiesLeaveEmptyGoToo() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Exports", directoryHint: .isDirectory)
        let file = folder.appending(path: "Shot.png")
        try writePNG(try picture(10, 10), to: file)
        let old = try ExportedFiles.file(for: file, pixelsPerPoint: 1, output: ScreenshotOutput(format: .jpeg), in: cache)
        // A folder that was empty to begin with, and one only another empty folder is in.
        let empty = cache.appending(path: "gone/deeper", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        ExportedFiles.removeOld(in: cache, now: .now.addingTimeInterval(ExportedFiles.lifetime + 60))
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: empty.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
        // What is asked for next is made again, in folders made again.
        let again = try ExportedFiles.file(for: file, pixelsPerPoint: 1, output: ScreenshotOutput(format: .jpeg), in: cache)
        #expect(FileManager.default.fileExists(atPath: again.path(percentEncoded: false)))
    }

    @Test func theClipboardKeepsOnlyItsLastFewFilesAndLeavesUploadsAlone() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Exports", directoryHint: .isDirectory)
        let image = try picture(20, 10)
        let output = ScreenshotOutput(format: .jpeg)
        let upload = try ExportedFiles.file(forPicture: image, named: "Upload", pixelsPerPoint: 1, output: output, in: cache)
        var copies: [URL] = []
        for index in 0..<(ExportedFiles.clipboardFilesKept + 3) {
            let copy = try ExportedFiles.file(forClipboard: image, named: "Copy \(index)", pixelsPerPoint: 1, output: output, in: cache)
            // A directory's date moves with what is put in it, so the order is the order they were made in.
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(Double(index) - 100)], ofItemAtPath: copy.deletingLastPathComponent().path(percentEncoded: false)
            )
            copies.append(copy)
        }
        let kept = copies.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        #expect(kept.count == ExportedFiles.clipboardFilesKept)
        #expect(kept.last == copies.last)
        #expect(copies[0].pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: upload.path(percentEncoded: false)))
        #expect(try decode(Data(contentsOf: copies.last!)).image.width == 20)
    }
}
