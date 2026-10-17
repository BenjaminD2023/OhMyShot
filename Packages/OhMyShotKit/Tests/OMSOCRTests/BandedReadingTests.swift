import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMSOCR

/// `VisionPipeline.recognize` over a picture tall enough to be read in bands, with Vision itself.
struct BandedReadingTests {
    /// Where each line's top is drawn, in a 4200-pixel-tall picture read in three bands (0–2048, 1792–3840,
    /// 3584–4200): the first well inside a band, two in the overlap of the first two, one across the first
    /// band's bottom edge (2048), and the others in the middle of the second band and in the third.
    private static let lines: [(text: String, top: CGFloat)] = [
        ("Granite bridge over harbor", 300),
        ("Violet lantern near market", 1830),
        ("Copper kettle beside river", 1960),
        ("Silver compass under willow", 2030),
        ("Amber window above garden", 3000),
        ("Marble statue behind station", 3900),
    ]

    /// Black Helvetica of `size` pixels on white: each line's left edge at `x` and its top at `top`.
    private func render(width: Int, height: Int, size: CGFloat, _ lines: [(text: String, x: CGFloat, top: CGFloat)]) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        for (text, x, top) in lines {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            // Core Graphics counts from the bottom; the baseline sits a little under the line's top.
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - top - size * 0.9)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return try #require(context.makeImage())
    }

    private func page() throws -> CGImage {
        try render(width: 1500, height: 4200, size: 44, Self.lines.map { ($0.text, 80, $0.top) })
    }

    @Test func aTallPictureIsReadInBandsEveryLineOnceInPlace() async throws {
        let image = try page()
        #expect(PictureText.pieces(width: image.width, height: image.height).count == 3)
        var options = VisionPipeline.Options()
        options.timeout = .seconds(60)
        let result = try await VisionPipeline(options: options).recognize(image)

        #expect(result.lines.count == Self.lines.count)
        for (expected, line) in zip(Self.lines, result.lines) {
            #expect(line.text.filter { !$0.isWhitespace } == expected.text.filter { !$0.isWhitespace })
            // The box is where the line was drawn, in the whole picture's pixels.
            #expect(line.box.minY > expected.top - 20 && line.box.maxY < expected.top + 80)
            #expect(line.box.minX > 60 && line.box.minX < 120)
        }
        #expect(result.text.split(separator: "\n").count == Self.lines.count)
    }

    /// The same picture as a PNG, read from the file a band at a time (`PictureText.Bands`): the same lines in the same
    /// places, with the same confidence, as from the picture decoded.
    @Test func aTallPNGIsReadFromItsFileAsFromItsPicture() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "banded-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try page(), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(PictureText.Bands(fileAt: url) != nil)

        var options = VisionPipeline.Options()
        options.timeout = .seconds(60)
        let pipeline = VisionPipeline(options: options)
        let fromFile = try await pipeline.recognize(fileAt: url)
        let decoded = try await pipeline.recognize(PictureText.image(at: url))
        #expect(fromFile.lines.count == Self.lines.count)
        #expect(fromFile.text == decoded.text)
        #expect(fromFile.lines.map(\.box) == decoded.lines.map(\.box))
        #expect(fromFile.lines.map(\.confidence) == decoded.lines.map(\.confidence))
    }

    /// A 4400 × 1500 picture is read in three columns (0–2048, 1792–3840, 3584–4400). A line from 1300 to past
    /// 2400 runs across the first overlap whole, so both columns read it cut.
    @Test func aLineAColumnCutWentThroughIsReadWhole() async throws {
        let text = "Granite bridge over harbor near the old market square"
        let image = try render(width: 4400, height: 1500, size: 44, [(text, 1500, 300)])
        let pieces = PictureText.pieces(width: image.width, height: image.height)
        #expect(pieces.count == 3 && pieces[0].width == 2048)

        var options = VisionPipeline.Options()
        options.timeout = .seconds(60)
        let result = try await VisionPipeline(options: options).recognize(image)
        #expect(result.lines.count == 1)
        #expect(result.text.filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
        // From where it starts to where it ends, not to a column's edge.
        let box = try #require(result.lines.first?.box)
        #expect(box.minX > 1450 && box.minX < 1560 && box.maxX > 2400)
    }

    /// A 5120 × 1440 screen of long, small lines, most of them across a cut: read whole, Vision loses over a third
    /// of the text of such a page; in columns, every line must come back once, whole.
    @Test func aDenseUltrawideScreenKeepsEveryLongLineWhole() async throws {
        let adjectives = ["quiet", "bright", "narrow", "heavy", "early", "hidden", "plain", "steady", "rough", "gentle"]
        let nouns = ["harbor", "lantern", "window", "kettle", "compass", "orchard", "bridge", "station", "garden", "market"]
        let drawn: [(text: String, x: CGFloat, top: CGFloat)] = (0..<30).map { number in
            let (a, b) = (number * 7 % 10, number * 3 % 10)
            let text = "\(number + 1). The \(adjectives[a]) \(nouns[b]) crosses the \(adjectives[(a + 3) % 10]) \(nouns[(b + 4) % 10]) near the old mill, "
                + "and nobody asks why the \(nouns[(b + 2) % 10]) keeps circling the \(adjectives[(a + 5) % 10]) \(nouns[(b + 6) % 10]) until the morning bell."
            return (text, CGFloat(60 + number * 397 % 2300), CGFloat(20 + number * 40))
        }
        let image = try render(width: 5120, height: 1440, size: 17, drawn)
        #expect(PictureText.pieces(width: image.width, height: image.height).count == 3)
        var options = VisionPipeline.Options()
        options.timeout = .seconds(60)
        let result = try await VisionPipeline(options: options).recognize(image)

        #expect(result.lines.count == drawn.count)
        let expected = drawn.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
        let read = result.text.filter { !$0.isWhitespace }.count
        #expect(abs(read - expected) * 100 <= expected)
        // None is cut at a column's edge (2048, 3840).
        #expect(!result.lines.contains { $0.box.maxX > 2040 && $0.box.maxX < 2056 || $0.box.maxX > 3832 && $0.box.maxX < 3848 })
    }
}
