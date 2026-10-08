import AppKit
import CoreGraphics
import CoreText
import Foundation

/// A text mark laid out with Core Text, in pixels. The same layout draws it on screen and in exports,
/// and the editing field uses the same font and line height, so text does not move when editing ends.
nonisolated struct TextLayout {
    let font: CTFont
    let lines: [CTLine]
    /// Each line's advance, trailing spaces excluded.
    let lineWidths: [CGFloat]
    let lineHeight: CGFloat
    /// From the top of a line to its baseline.
    let baseline: CGFloat
    /// The text's own area.
    let textSize: CGSize
    /// Room around the text: the label's padding, or half the outline.
    let inset: CGSize
    let look: TextBlock.Look

    /// The whole mark: text plus label or outline.
    var size: CGSize {
        CGSize(width: textSize.width + inset.width * 2, height: textSize.height + inset.height * 2)
    }

    var cornerRadius: CGFloat { look == .label ? CTFontGetSize(font) * 0.32 : 0 }

    /// The width of the edge around outlined text.
    var outlineWidth: CGFloat { max(CTFontGetSize(font) * 0.16, 2) }

    /// Line height as a multiple of the type size, shared with the editing field.
    static let lineSpacing: CGFloat = 1.25

    /// The face of text marks: the system font, semibold.
    static func font(pointSize: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: .semibold)
    }

    init(_ block: TextBlock, scale: CGFloat) {
        let size = max(block.fontSize * scale, 1)
        let font = Self.font(pointSize: size) as CTFont
        self.font = font
        look = block.look
        lineHeight = (size * Self.lineSpacing).rounded()
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        baseline = ((lineHeight - ascent - descent) / 2 + ascent).rounded()

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let wrapWidth = block.width.map { max($0 - (block.look == .label ? size * 0.8 : 0), size) }
        var lines: [CTLine] = []
        for paragraph in block.string.components(separatedBy: "\n") {
            let attributed = NSAttributedString(string: paragraph, attributes: attributes)
            guard let wrapWidth, attributed.length > 0 else {
                lines.append(CTLineCreateWithAttributedString(attributed))
                continue
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            while start < attributed.length {
                let count = max(CTTypesetterSuggestLineBreak(typesetter, start, Double(wrapWidth)), 1)
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                start += count
            }
        }
        self.lines = lines
        lineWidths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0)) }
        let width = wrapWidth ?? lineWidths.max() ?? 0
        textSize = CGSize(width: ceil(max(width, 1)), height: lineHeight * CGFloat(max(lines.count, 1)))
        inset = switch block.look {
        case .plain: .zero
        case .outlined: CGSize(width: ceil(max(size * 0.16, 2) / 2), height: ceil(max(size * 0.16, 2) / 2))
        case .label: CGSize(width: (size * 0.4).rounded(), height: (size * 0.16).rounded())
        }
    }

    /// Where each line's baseline starts, for the mark's top left at `origin`, in y-down coordinates.
    func baselineOrigins(at origin: CGPoint) -> [CGPoint] {
        lines.indices.map { index in
            CGPoint(x: origin.x + inset.width, y: origin.y + inset.height + lineHeight * CGFloat(index) + baseline)
        }
    }

    /// Draws the lines in the context's fill color. The context's user space is y-down.
    func drawLines(in context: CGContext, at origin: CGPoint) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (line, start) in zip(lines, baselineOrigins(at: origin)) {
            context.textPosition = start
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    /// The glyphs' outlines, for the edge of outlined text. Color glyphs (emoji) have none.
    func glyphPath(at origin: CGPoint) -> CGPath {
        let path = CGMutablePath()
        for (line, start) in zip(lines, baselineOrigins(at: origin)) {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                for (glyph, position) in zip(glyphs, positions) {
                    guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                    // Glyphs are drawn y-up; flip them onto the baseline in y-down space.
                    let transform = CGAffineTransform(translationX: start.x + position.x, y: start.y - position.y).scaledBy(x: 1, y: -1)
                    path.addPath(glyphPath, transform: transform)
                }
            }
        }
        return path
    }
}

/// A counter's disc and label, in pixels.
nonisolated struct CounterLayout {
    let diameter: CGFloat
    let line: CTLine
    let labelBounds: CGRect

    init(_ counter: Counter, lineWidth: CGFloat, scale: CGFloat) {
        diameter = ((16 + lineWidth * 3) * scale).rounded()
        let label = counter.label
        var size = diameter * 0.5
        var line = Self.line(label, size: size)
        var bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        // Long labels (VIII, AB) shrink to fit the disc.
        if bounds.width > diameter * 0.72 {
            size *= diameter * 0.72 / bounds.width
            line = Self.line(label, size: size)
            bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        }
        self.line = line
        labelBounds = bounds
    }

    private static func line(_ label: String, size: CGFloat) -> CTLine {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font as CTFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
    }

    func rect(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    /// Draws the label centered on `center` in the context's fill color; y-down user space.
    func drawLabel(in context: CGContext, at center: CGPoint) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Center the ink, not the type's box, so digits sit in the middle of the disc.
        context.textPosition = CGPoint(x: center.x - labelBounds.midX, y: center.y + labelBounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
