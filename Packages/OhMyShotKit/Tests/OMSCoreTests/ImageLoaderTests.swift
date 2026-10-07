import CoreGraphics
import Foundation
import ImageIO
@testable import OMSCore
import Testing
import UniformTypeIdentifiers

struct ImageLoaderTests {
    private func encoded(width: Int, height: Int, type: UTType, properties: [CFString: Any]) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func retinaScreenshotKeepsItsScale() throws {
        let data = try encoded(width: 300, height: 200, type: .png, properties: [
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
        ])
        let loaded = try #require(ImageLoader.load(data: data))
        #expect(loaded.image.width == 300 && loaded.image.height == 200)
        #expect(loaded.scale == 2)
    }

    @Test func unknownResolutionUsesTheFallback() throws {
        let data = try encoded(width: 300, height: 200, type: .png, properties: [:])
        #expect(try #require(ImageLoader.load(data: data)).scale == 1)
        #expect(try #require(ImageLoader.load(data: data, fallbackScale: 2)).scale == 2)
    }

    @Test func photoIsTurnedUpright() throws {
        // Orientation 6: the camera was turned; the stored pixels are landscape, the photo is portrait.
        let data = try encoded(width: 400, height: 300, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let loaded = try #require(ImageLoader.load(data: data))
        #expect(loaded.image.width == 300 && loaded.image.height == 400)
    }

    @Test func recognizesImageFilesByType() {
        #expect(ImageLoader.canLoad(URL(filePath: "/tmp/a.png")))
        #expect(ImageLoader.canLoad(URL(filePath: "/tmp/b.HEIC")))
        #expect(!ImageLoader.canLoad(URL(filePath: "/tmp/c.pdf")))
        #expect(!ImageLoader.canLoad(URL(string: "https://example.com/d.png")!))
    }
}
