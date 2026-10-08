import AppKit
import CoreGraphics
import CoreText
import Foundation

/// A bitmap drawn like a Retina screenshot: laid out in points with a top-left origin, rendered at 2×.
final class Canvas {
    let size: CGSize
    let scale: CGFloat
    private let context: CGContext

    init(width: CGFloat, height: CGFloat, background: CGColor, scale: CGFloat = 2) {
        size = CGSize(width: width, height: height)
        self.scale = scale
        context = CGContext(
            data: nil,
            width: Int(width * scale),
            height: Int(height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
        // A top-left origin from here on.
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
    }

    /// Draws one line of text whose top edge is at `top`. Returns the line's width and height.
    @discardableResult
    func draw(_ text: NSAttributedString, x: CGFloat, top: CGFloat) -> CGSize {
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        context.saveGState()
        context.translateBy(x: x, y: top + ascent)
        // Core Text draws with y pointing up.
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return CGSize(width: width, height: ascent + descent)
    }

    /// The width and height a line of text takes.
    static func measure(_ text: NSAttributedString) -> CGSize {
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGSize(width: width, height: ascent + descent)
    }

    /// Draws vertical text in columns from right to left inside `rect`; each "\n" starts a new column.
    func drawVertical(_ text: NSAttributedString, in rect: CGRect) {
        context.saveGState()
        // Core Text frames are laid out with y pointing up: undo the flip for this drawing.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let frameRect = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let attributes = [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), attributes)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Draws an SF Symbol in `color`, fitted into `rect`, as an app draws an icon beside a label.
    func drawSymbol(_ name: String, in rect: CGRect, color: CGColor) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.height, weight: .regular)) else { return }
        var proposed = CGRect(origin: .zero, size: symbol.size)
        guard let mask = symbol.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        let aspect = symbol.size.width / max(symbol.size.height, 1)
        let size = aspect >= 1 ? CGSize(width: rect.width, height: rect.width / aspect) : CGSize(width: rect.height * aspect, height: rect.height)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        // Images draw with y up: flip back around the target.
        context.translateBy(x: 0, y: target.maxY + target.minY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: target, mask: mask)
        context.setFillColor(color)
        context.fill(target)
        context.restoreGState()
    }

    func fill(_ rect: CGRect, radius: CGFloat = 0, color: CGColor) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    func stroke(from start: CGPoint, to end: CGPoint, color: CGColor, width: CGFloat = 1) {
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    func image() -> CGImage {
        context.makeImage()!
    }
}

/// Fonts as macOS draws them in apps, with the cascade it uses for each language.
enum Fonts {
    /// The system UI face; CJK falls back to PingFang SC/TC, Hiragino Sans, or Apple SD Gothic Neo by
    /// `language`, as it does in a localized app.
    static func ui(_ size: CGFloat, language: String, bold: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, language as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard bold else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    }

    /// SF Mono, as code editors and terminals draw it.
    static func mono(_ size: CGFloat) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    }
}

extension NSAttributedString {
    /// Text in one font and color, with Core Text's own attribute keys.
    convenience init(_ string: String, font: CTFont, color: CGColor, vertical: Bool = false) {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if vertical {
            attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true
        }
        self.init(string: string, attributes: attributes)
    }
}

extension CGColor {
    /// An sRGB color from a hex value such as 0x1F1F24.
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}
