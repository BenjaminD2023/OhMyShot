import CoreGraphics
import CoreText
import Foundation
import Testing
import Vision
@testable import OMSOCR

/// The lines Vision turns over (`VisionPipeline.isTurnedOver`), with Vision itself.
struct TurnedOverLineTests {
    @Test func onlyALineReadUpsideDownWithTheLeastConfidenceIsTurnedOver() {
        // Corners as Vision gives them, counted up from the bottom: an upright line's top left is left of its top right
        // and above its bottom left.
        let isTurnedOver = { (text: String, left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, confidence: Float) in
            VisionPipeline.isTurnedOver(
                text, topLeft: NormalizedPoint(x: left, y: top), topRight: NormalizedPoint(x: right, y: top),
                bottomLeft: NormalizedPoint(x: left, y: bottom), confidence: confidence
            )
        }
        // Line 26 of the dense wide screen (`BandedReadingTests`), as the Latin model returned it.
        let garble = "Tan caon a n ae n en cao"
        #expect(isTurnedOver(garble, 0.947, 0.382, 0.277, 0.290, 0.3))
        // The right way up, however unsure.
        #expect(!isTurnedOver(garble, 0.382, 0.947, 0.290, 0.277, 0.3))
        // Read upside down and sure of it: the text is upside down in the picture.
        #expect(!isTurnedOver("This label hangs upside down", 0.947, 0.382, 0.277, 0.290, 0.5))
        #expect(!isTurnedOver("This label hangs upside down", 0.947, 0.382, 0.277, 0.290, 1))
        // Right to left but the right way up is not turned over.
        #expect(!isTurnedOver(garble, 0.947, 0.382, 0.290, 0.277, 0.3))
        // A mark reads the same either way up.
        #expect(!isTurnedOver("--", 0.947, 0.900, 0.277, 0.290, 0.3))
        #expect(!isTurnedOver("o - o", 0.947, 0.900, 0.277, 0.290, 0.3))
    }

    @Test func aLineUpsideDownInThePictureIsStillRead() async throws {
        let (width, height) = (1200, 400)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let draw = { (text: String) in
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])), context)
        }
        let upright = [
            "The quiet harbor crosses the bright station near the old mill.",
            "Nobody asks why the kettle keeps circling the market.",
            "The narrow garden waits until the morning bell.",
        ]
        for (index, text) in upright.enumerated() {
            context.textPosition = CGPoint(x: 40, y: 340 - CGFloat(index) * 60)
            draw(text)
        }
        let turned = "This label hangs upside down on the wall of the station."
        context.translateBy(x: 1100, y: 120)
        context.rotate(by: .pi)
        context.textPosition = .zero
        draw(turned)

        var options = VisionPipeline.Options()
        options.timeout = .seconds(60)
        let result = try await VisionPipeline(options: options).recognize(try #require(context.makeImage()))
        #expect(result.lines.map(\.text) == upright + [turned])
    }
}
