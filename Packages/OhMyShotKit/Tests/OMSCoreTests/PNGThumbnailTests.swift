import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import OMSPixels
@testable import OMSCore

/// A card's thumbnail read straight from a PNG's rows.
struct PNGThumbnailTests {
    /// A picture `width` × `height` of a diagonal ramp in red and green, with `alpha`, drawn in `space`.
    private static func picture(width: Int, height: Int, alpha: UInt8 = 255, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let r = UInt32((x * 255) / max(width - 1, 1)) * UInt32(alpha) / 255, g = UInt32((y * 255) / max(height - 1, 1)) * UInt32(alpha) / 255
                pixels[y * width + x] = UInt32(alpha) << 24 | r << 16 | g << 8 | (x / 7 % 2 == 0 ? UInt32(alpha) / 3 : 0)
            }
        }
        return try #require(pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )?.makeImage()
        })
    }

    /// The thumbnail as the history makes it: the card's part of the picture.
    private static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        PNGThumbnail.make(from: data, maxPixels: maxPixels, part: CardPicture.shownRect)
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `image` drawn into a bitmap of its size, as RGBA bytes in sRGB.
    private static func bytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The mean difference per channel between two pictures of the same size, out of 255.
    private static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let first = bytes(a), second = bytes(b)
        var total = 0
        for i in 0 ..< first.count { total += abs(Int(first[i]) - Int(second[i])) }
        return Double(total) / Double(first.count)
    }

    @Test func aPictureIsReadAndMatchesWhatTheSystemMakesOfIt() async throws {
        let data = try Self.png(try Self.picture(width: 900, height: 600))
        let thumbnail = try #require(Self.thumbnail(data, maxPixels: 300))
        #expect(thumbnail.width == 300 && thumbnail.height == 200)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 300,
        ] as CFDictionary))
        #expect(reference.width == 300 && reference.height == 200)
        #expect(Self.difference(thumbnail, reference) < 2)
    }

    @Test func aPictureNotMadeSmallerKeepsEveryPixel() throws {
        let image = try Self.picture(width: 120, height: 80)
        let thumbnail = try #require(Self.thumbnail(try Self.png(image), maxPixels: 400))
        #expect(thumbnail.width == 120 && thumbnail.height == 80)
        #expect(Self.difference(thumbnail, image) < 0.01)
    }

    @Test func transparencyIsKept() throws {
        let image = try Self.picture(width: 200, height: 100, alpha: 128)
        let thumbnail = try #require(Self.thumbnail(try Self.png(image), maxPixels: 100))
        #expect(thumbnail.width == 100 && thumbnail.height == 50)
        let pixels = Self.bytes(thumbnail)
        #expect(pixels.indices.filter { $0 % 4 == 3 }.allSatisfy { abs(Int(pixels[$0]) - 128) <= 1 })
    }

    @Test func aLongPicturesTopIsReadWithoutTheRest() async throws {
        // 600 × 9000: the card shows the top 469 rows; the thumbnail is what drawing that part smaller makes.
        let image = try Self.picture(width: 600, height: 9000)
        let thumbnail = try #require(Self.thumbnail(try Self.png(image), maxPixels: 300))
        #expect(thumbnail.width == 300 && thumbnail.height == 235)
        let expected = try #require(await HistoryStore.cardThumbnail(of: image, maxPixels: 300))
        #expect(expected.width == 300 && expected.height == 235)
        #expect(Self.difference(thumbnail, expected) < 2)
    }

    @Test func aColorProfileIsKept() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let data = try Self.png(try Self.picture(width: 300, height: 200, space: p3))
        let thumbnail = try #require(Self.thumbnail(data, maxPixels: 150))
        #expect(thumbnail.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    }

    @Test func otherFormatsAreLeftToTheCaller() throws {
        let image = try Self.picture(width: 100, height: 100)
        let jpeg = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(Self.thumbnail(jpeg as Data, maxPixels: 50) == nil)
        #expect(Self.thumbnail(Data([1, 2, 3]), maxPixels: 50) == nil)
    }
}
