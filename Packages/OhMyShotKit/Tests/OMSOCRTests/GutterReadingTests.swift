import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OMSOCR

/// A code screenshot beside a narrow gutter (Xcode's, at 2x), read with Vision itself: `LineNumbers` takes the numbers
/// out, and `rereadCodeWithLatinModel` reads the code again right of them, the comment in Chinese with its `//`.
struct GutterReadingTests {
    private static let code = [
        "import { useState } from 'react';",
        "export function Counter({ initial = 0 }: Props) {",
        "  const [count, setCount] = useState(initial);",
        "  // 点击后加一",
        "  return (",
        "    <button onClick={() => setCount(count + 1)}>",
        "      Count: {count}",
        "    </button>",
        "  );",
        "}",
    ]

    /// Menlo of 24 pixels, a line every 32: the numbers gray and right-aligned at 56, the code black from 80.
    private func screenshot() throws -> CGImage {
        let (width, height) = (1400, 32 * Self.code.count + 60)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 24, nil)
        let line = { (text: String, gray: CGFloat) in
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
            ]))
        }
        for (index, text) in Self.code.enumerated() {
            let baseline = CGFloat(height) - 30 - CGFloat(index + 1) * 32 + 8
            let number = line("\(index + 1)", 0.55)
            context.textPosition = CGPoint(x: 56 - CTLineGetTypographicBounds(number, nil, nil, nil), y: baseline)
            CTLineDraw(number, context)
            context.textPosition = CGPoint(x: 80, y: baseline)
            CTLineDraw(line(text, 0.1), context)
        }
        return try #require(context.makeImage())
    }

    @Test func theCodeIsReadWithoutItsNumbersAndKeepsItsCommentMark() async throws {
        var options = VisionPipeline.Options()
        options.timeout = .seconds(60)
        let result = try await VisionPipeline(options: options).recognize(try screenshot())
        // Every line as drawn: no numbers, the indentation, the comment's `//`, and the code itself.
        #expect(result.text.split(separator: "\n").map(String.init) == Self.code)
    }
}
