import AppKit
import Foundation
import Testing
@testable import OMSCore

/// What a screenshot puts on the clipboard, on a pasteboard of the test's own.
@MainActor
struct PasteboardWriterTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OMSCoreTests-\(UUID().uuidString)"))
    }

    private func picture() throws -> (image: CGImage, png: Data) {
        let context = try #require(CGContext(
            data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (image, data as Data)
    }

    @Test func thePictureAloneIsThePictureAndNothingElse() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (image, png) = try picture()
        PasteboardWriter.write(png: png, image: image, to: pasteboard)
        let types = try #require(pasteboard.types)
        #expect(types.contains(.png) && !types.contains(.fileURL))
        #expect(pasteboard.data(forType: .png) == png)
    }

    @Test func theFileIsOfferedBesideThePicture() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (image, png) = try picture()
        let file = URL(filePath: "/tmp/OhMyShot Test.jpg")
        PasteboardWriter.write(png: png, image: image, fileURL: file, to: pasteboard)
        let types = try #require(pasteboard.types)
        #expect(types.contains(.png) && types.contains(.fileURL))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.first?.lastPathComponent == "OhMyShot Test.jpg")
    }

    @Test func theTIFFAskedForIsCompressedAndThePicture() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let (image, png) = try picture()
        PasteboardWriter.write(png: png, image: image, to: pasteboard)
        let tiff = try #require(pasteboard.data(forType: .tiff))
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let fields = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(fields[kCGImagePropertyTIFFCompression] as? Int == 5)
        let read = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(read.width == image.width && read.height == image.height)
        // The same color as the picture's, drawn the same way.
        #expect(try color(of: read) == color(of: image))
    }

    private func color(of image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }

    @Test func aFileAloneGoesOnAsFinderCopiesIt() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        PasteboardWriter.write(fileURL: URL(filePath: "/tmp/Clip.mp4"), to: pasteboard)
        #expect(pasteboard.types?.contains(.fileURL) == true)
        #expect(pasteboard.types?.contains(.png) != true)
    }
}
