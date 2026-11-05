import AppKit

/// A text card's text, laid out once at 100 percent and drawn scaled with the pin, so it wraps where it
/// did at 100 percent at any zoom and stays sharp. It selects as text does: a drag on it selects, a double
/// click takes a word and a triple click a paragraph. The pin takes every other press, and drags
/// (`PinView.takesTextPress`), and it keeps the cursor. It is no element of its own: VoiceOver reads the
/// pin, which carries the text.
final class PinTextView: NSTextView {
    /// The whole text, past what the card lays out.
    let fullText: String
    /// Copies the selection's text, through the pin, which says "Copied".
    var onCopy: ((String) -> Void)?
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { scaleToZoom() } }
    }

    init(text: String) {
        fullText = text
        let size = PinText.textSize(for: text)
        let storage = NSTextStorage(attributedString: PinText.attributed(text))
        // TextKit 1, as the card's size is measured, so the lines break where the measure said.
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // As wide as the text measured at 100 percent, and as many lines as the card holds, the last one
        // cut with an ellipsis when there is more.
        let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = PinText.maxLines
        container.lineBreakMode = .byTruncatingTail
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: .zero, size: size), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scaleToZoom()
    }

    /// The text at 100 percent in the view's own coordinates, drawn at the zoom.
    private func scaleToZoom() {
        setBoundsSize(CGSize(width: frame.width / zoom, height: frame.height / zoom))
        needsDisplay = true
    }

    /// Whether `point`, in the view's own coordinates, is on the text: on a line, from its first glyph to a
    /// little past its last.
    func isOnText(_ point: CGPoint) -> Bool {
        guard let layoutManager, let textContainer, layoutManager.glyphRange(for: textContainer).length > 0 else { return false }
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        return layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).insetBy(dx: -4, dy: 0).contains(point)
    }

    /// What copying the selection takes (`PinText.copied`); nil with nothing selected.
    var selectionToCopy: String? {
        PinText.copied(selecting: selectedRange(), in: string, of: fullText)
    }

    /// Copy in the text's own menu goes as ⌘C does, through the pin.
    override func copy(_ sender: Any?) {
        guard let text = selectionToCopy else { return }
        onCopy?(text)
    }

    func clearSelection() {
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    // The pin sets the cursor: an I-beam only where a press selects.
    override func resetCursorRects() {}
    override func cursorUpdate(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {
        superview?.mouseMoved(with: event)
    }
}
