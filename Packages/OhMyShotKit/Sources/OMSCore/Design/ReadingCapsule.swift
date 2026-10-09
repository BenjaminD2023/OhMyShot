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
        layer.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96)
        layer.borderWidth = contrast ? 1 : 0.5
        layer.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
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

    private func relayout() {
        let textHeight = ceil(font.ascender - font.descender)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let height = textHeight + 9
        let swatchWidth: CGFloat = showsSwatch && swatch != nil ? 16 : 0
        layer.bounds = CGRect(x: 0, y: 0, width: textWidth + 22 + swatchWidth, height: height)
        layer.cornerRadius = height / 2
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        swatchLayer.frame = CGRect(x: 10, y: (height - 10) / 2, width: 10, height: 10)
        textLayer.frame = CGRect(x: 11 + swatchWidth, y: (height - textHeight) / 2 - 0.5, width: textWidth + 2, height: textHeight)
    }
}
