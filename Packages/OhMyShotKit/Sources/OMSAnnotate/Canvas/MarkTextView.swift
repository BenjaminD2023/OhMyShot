import AppKit

/// The field a text mark is edited in: plain text, no automatic substitutions, transparent. Its text is
/// set in the capture's pixels and its bounds are scaled to the zoom, so it measures and wraps as the
/// mark does; the label's fill and the outline are drawn here, in the same pixels.
final class MarkTextView: NSTextView {
    /// The fill of a label, behind the whole field; nil for the other looks.
    var labelFill: CGColor?
    var labelCornerRadius: CGFloat = 0
    var outlineColor: CGColor?
    var outlineFontSize: CGFloat = 20
    var outlineWrapWidth: CGFloat?

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        drawsBackground = false
        // A selected line break is washed to the end of its line, which without a wrap width has none.
        clipsToBounds = true
        focusRingType = .none
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext {
            if let labelFill {
                let radius = min(labelCornerRadius, bounds.width / 2, bounds.height / 2)
                context.setFillColor(labelFill)
                context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
            if let outlineColor, !string.isEmpty {
                let block = TextBlock(origin: .zero, string: string, fontSize: outlineFontSize, look: .outlined, width: outlineWrapWidth)
                let layout = TextLayout(block, scale: 1)
                context.saveGState()
                context.setStrokeColor(outlineColor)
                context.setLineWidth(layout.outlineWidth)
                context.setLineJoin(.round)
                context.addPath(layout.glyphPath(at: .zero))
                context.strokePath()
                context.restoreGState()
            }
        }
        super.draw(dirtyRect)
    }
}
