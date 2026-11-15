import CoreGraphics
import CoreText
import Foundation

/// A line of text tiled across a picture, faint and turned up 30°, as a mark of who it is from or what it is for: on
/// one picture in the editor (the document's), or on every copy that leaves the app (Settings, through
/// `ScreenshotOutput`). Never on the capture the history keeps, which reading text and redaction suggestions read.
public struct Watermark: Codable, Sendable, Equatable, Hashable {
    /// Dark text, for light pictures, or light text, for dark ones.
    public enum Tone: String, Codable, Sendable, CaseIterable {
        case dark, light
    }

    public var text: String
    public var tone: Tone
    /// How much the text shows, from 0.05 to 0.6.
    public var opacity: Double
    /// The text's size as a share of the picture's shorter side, from 0.02 to 0.1.
    public var size: Double

    public static let opacityRange: ClosedRange<Double> = 0.05...0.6
    public static let sizeRange: ClosedRange<Double> = 0.02...0.1

    public init(text: String, tone: Tone = .dark, opacity: Double = 0.15, size: Double = 0.035) {
        self.text = text
        self.tone = tone
        self.opacity = min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }

    /// Nothing to draw: no text but spaces.
    public var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Draws a `Watermark`.
public enum WatermarkPainter {
    /// Tiles `watermark` across `rect` of `context`, whose user space is y down (as the editor's and exports' are),
    /// clipped to `rect`, rounded by `cornerRadius`: the text in rows turned up 30°, each row half a step along from
    /// the one before, at the size the watermark says of the rect's shorter side (10 pixels at least).
    public static func paint(_ watermark: Watermark, in rect: CGRect, cornerRadius: CGFloat = 0, context: CGContext) {
        let rect = rect.standardized
        guard !watermark.isBlank, rect.width >= 1, rect.height >= 1 else { return }
        let size = max(10, CGFloat(watermark.size) * min(rect.width, rect.height))
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let gray: CGFloat = watermark.tone == .dark ? 0 : 1
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: watermark.text.replacingOccurrences(of: "\n", with: " "), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: CGFloat(watermark.opacity)),
        ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width > 0 else { return }
        let stepX = width + max(size * 3, width * 0.6)
        let stepY = size * 4
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: min(cornerRadius, rect.width / 2), cornerHeight: min(cornerRadius, rect.height / 2), transform: nil))
        context.clip()
        context.translateBy(x: rect.midX, y: rect.midY)
        // Up 30° to the right: in a y-down space that turns against the clock.
        context.rotate(by: -.pi / 6)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Enough rows and columns to cover the rect at any turn: its diagonal across, from its middle.
        let reach = hypot(rect.width, rect.height) / 2 + stepX
        var row = 0
        var y = -reach
        while y <= reach {
            var x = -reach + (row % 2 == 0 ? 0 : stepX / 2)
            while x <= reach {
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, context)
                x += stepX
            }
            y += stepY
            row += 1
        }
    }
}
