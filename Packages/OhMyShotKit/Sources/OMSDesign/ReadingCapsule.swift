import AppKit
import QuartzCore

/// The reading capsule: a rounded capsule with a soft shadow, sized to its text, optionally led by a
/// color swatch. Every number shown on screen over other content uses it: the capture overlay's
/// readings and a pin's zoom and opacity.
@MainActor
public final class ReadingCapsule {
    public let layer = CALayer()
    private let textLayer = CATextLayer()
    private let swatchLayer = CALayer()
    private let showsSwatch: Bool
    private let font = Theme.Typeface.reading()

    public init(showsSwatch: Bool = false) {
        self.showsSwatch = showsSwatch
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.alignmentMode = .left
        layer.addSublayer(textLayer)
        swatchLayer.cornerRadius = 5
        swatchLayer.borderWidth = 1
        swatchLayer.isHidden = true
        layer.addSublayer(swatchLayer)
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.borderWidth = 0.5
        layer.isHidden = true
        // Readings change with the pointer, so nothing in them animates on its own: no number trails the
        // pointer, with Reduce Motion or without. A surface that fades the capsule animates its opacity.
        let still: [String: any CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "cornerRadius": NSNull(), "shadowPath": NSNull(),
            "contents": NSNull(), "string": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
            "foregroundColor": NSNull(),
        ]
        for part in [layer, textLayer, swatchLayer] {
            part.actions = still
        }
    }

    public func setScale(_ scale: CGFloat) {
        layer.contentsScale = scale
        textLayer.contentsScale = scale
    }

    /// The reading capsule's materials; under Increase Contrast its hairline is the 1 pt contrast one.
    public func applyAppearance(dark: Bool, contrast: Bool = false) {
        layer.backgroundColor = Theme.Material.capsuleFill(dark: dark)
        layer.borderWidth = Theme.Material.edgeWidth(contrast: contrast)
        layer.borderColor = Theme.Material.edge(dark: dark, contrast: contrast)
        textLayer.foregroundColor = dark ? CGColor(gray: 1, alpha: 0.92) : CGColor(gray: 0, alpha: 0.85)
        // Strong enough that a white or near-white sample still reads as a swatch on the white capsule.
        swatchLayer.borderColor = dark ? CGColor(gray: 1, alpha: 0.38) : CGColor(gray: 0, alpha: 0.3)
    }

    public var swatch: CGColor? {
        didSet {
            swatchLayer.backgroundColor = swatch
            swatchLayer.isHidden = swatch == nil
            relayout()
        }
    }

    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            textLayer.string = text
            relayout()
        }
    }

    /// How wide the text may run before it wraps onto another line. A reading is one line and never reaches it; a list
    /// (lines apart by newlines, such as the overlay's keys) is held to the display with it.
    public var maximumTextWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if maximumTextWidth != oldValue { relayout() } }
    }

    private func relayout() {
        let lineHeight = ceil(font.ascender - font.descender)
        var textHeight = lineHeight
        var textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        // More than a line: as tall as its lines, as wide as the longest, with a one-line capsule's corners.
        let isOneLine = !text.contains("\n") && textWidth <= maximumTextWidth
        if !isOneLine {
            let lines = (text as NSString).boundingRect(
                with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: font]
            )
            textWidth = ceil(lines.width)
            textHeight = ceil(lines.height)
        }
        textLayer.isWrapped = !isOneLine
        let height = textHeight + 9
        let corner = (lineHeight + 9) / 2
        let swatchWidth: CGFloat = showsSwatch && swatch != nil ? 16 : 0
        layer.bounds = CGRect(x: 0, y: 0, width: textWidth + 22 + swatchWidth, height: height)
        layer.cornerRadius = corner
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
        swatchLayer.frame = CGRect(x: 10, y: (height - 10) / 2, width: 10, height: 10)
        textLayer.frame = CGRect(x: 11 + swatchWidth, y: (height - textHeight) / 2 - 0.5, width: textWidth + 2, height: textHeight)
    }
}
