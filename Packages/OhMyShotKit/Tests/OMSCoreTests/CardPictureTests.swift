import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OMSCore

/// What a capture's card shows of a long picture, and its thumbnail made from that part.
struct CardPictureTests {
    private static let red: UInt32 = 0xFFFF_0000, blue: UInt32 = 0xFF00_00FF

    /// A picture `width` × `height`, red in its top `band` rows and blue below.
    private static func picture(width: Int, height: Int, band: Int) throws -> CGImage {
        var pixels = [UInt32](repeating: blue, count: width * height)
        for index in 0 ..< width * band { pixels[index] = red }
        let context = try #require(pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )?.makeImage()
        })
        return context
    }

    /// The color at the top left and the bottom left of `image`, as 0xAARRGGBB.
    private static func corners(of image: CGImage) throws -> (top: UInt32, bottom: UInt32) {
        var pixels = [UInt32](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (pixels[0], pixels[(image.height - 1) * image.width])
    }

    @Test func aLongPictureShowsItsTopInTheCardsShape() {
        #expect(CardPicture.shownRect(width: 3346, height: 50_000) == CGRect(x: 0, y: 0, width: 3346, height: 2616))
        #expect(CardPicture.shownRect(width: 9600, height: 960) == CGRect(x: 0, y: 0, width: 2112, height: 960))
        #expect(CardPicture.shownRect(width: 1600, height: 1000) == CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    @Test func aLongPicturesThumbnailIsItsTopAtFullSharpness() async throws {
        // 600 wide: the card's part is the top 469 rows; red down to row 400, blue below.
        let image = try Self.picture(width: 600, height: 9000, band: 400)
        let thumbnail = try #require(await HistoryStore.cardThumbnail(of: image, maxPixels: 300))
        #expect(thumbnail.width == 300 && thumbnail.height == 235)
        let corners = try Self.corners(of: thumbnail)
        #expect(corners.top == Self.red && corners.bottom == Self.blue)
    }

    @Test func aLongPicturesThumbnailFromItsFileIsTheSame() async throws {
        let image = try Self.picture(width: 600, height: 9000, band: 400)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let thumbnail = try #require(await HistoryStore.cardThumbnail(of: data as Data, maxPixels: 300))
        #expect(thumbnail.width == 300 && thumbnail.height == 235)
        let corners = try Self.corners(of: thumbnail)
        #expect(corners.top == Self.red && corners.bottom == Self.blue)
    }

    @Test func aPictureStoredTurnedIsShownUpright() async throws {
        // 600 × 300 with a quarter-turn orientation: shown 300 × 600, so 150 × 300 at 300 pixels.
        let image = try Self.picture(width: 600, height: 300, band: 100)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let thumbnail = try #require(await HistoryStore.cardThumbnail(of: data as Data, maxPixels: 300))
        #expect(thumbnail.width == 150 && thumbnail.height == 300)
    }

    @Test func anOrdinaryPictureIsShownWhole() async throws {
        let image = try Self.picture(width: 800, height: 500, band: 100)
        let thumbnail = try #require(await HistoryStore.cardThumbnail(of: image, maxPixels: 400))
        #expect(thumbnail.width == 400 && thumbnail.height == 250)
    }
}
