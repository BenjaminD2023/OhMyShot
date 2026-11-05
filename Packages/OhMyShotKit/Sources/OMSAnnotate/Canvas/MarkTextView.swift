import AppKit

/// The field a text mark is edited in: plain text, no automatic substitutions, transparent.
final class MarkTextView: NSTextView {
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
        if let outlineColor, !string.isEmpty, let context = NSGraphicsContext.current?.cgContext {
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
        super.draw(dirtyRect)
    }
}
