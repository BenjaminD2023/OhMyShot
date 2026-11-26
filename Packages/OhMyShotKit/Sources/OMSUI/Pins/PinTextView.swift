import AppKit

/// A text card's scroll container: scrolls vertically when long text exceeds the pin window's height,
/// and forwards Option-scroll (opacity), Command-scroll (zoom), and non-overflowing scrolls to the pin.
final class PinTextScrollView: NSScrollView {
    var onForwardScroll: ((NSEvent) -> Void)?

    var canScrollVertically: Bool {
        guard let documentView else { return false }
        return documentView.frame.height > contentView.bounds.height + 0.5
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) || !canScrollVertically {
            onForwardScroll?(event)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// A text card's text, laid out once at 100 percent and drawn scaled with the pin, so it wraps where it
/// did at 100 percent at any zoom and stays sharp. Long text scrolls smoothly inside `PinTextScrollView`,
/// and `http`/`https` links open when clicked while preserving drag-to-move. It selects as text does:
/// a drag on it selects, a double click takes a word and a triple click a paragraph. The pin takes every
/// other press, and drags (`PinView.takesTextPress`), and it keeps the cursor. It is no element of its own:
/// VoiceOver reads the pin, which carries the text.
final class PinTextView: NSTextView {
    /// The whole text, past what the card lays out.
    let fullText: String
    /// Unscaled height required to display all laid-out lines at 100 percent zoom.
    let contentHeight: CGFloat
    /// Copies the selection's text, through the pin, which says "Copied".
    var onCopy: ((String) -> Void)?
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { scaleToZoom() } }
    }

    init(text: String) {
        fullText = text
        let size = PinText.textSize(for: text)
        let storage = NSTextStorage(attributedString: PinText.scrollableAttributed(text))
        // TextKit 1, as the card's size is measured, so the lines break where the measure said.
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // As wide as the text measured at 100 percent, with unbounded lines so long text scrolls smoothly.
        let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let measuredHeight = max(ceil(layout.usedRect(for: container).height), size.height)
        contentHeight = measuredHeight
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: size.width, height: measuredHeight)), textContainer: container)
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
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
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

    /// The `http`/`https` link URL at `point` (in the text view's own coordinates), or nil if none.
    func linkURL(at point: CGPoint) -> URL? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              layoutManager.glyphRange(for: textContainer).length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).contains(point) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        guard charIndex < storage.length,
              let url = storage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
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

    // The pin sets the cursor: an I-beam on text, pointing hand on links.
    override func resetCursorRects() {}
    override func cursorUpdate(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {
        enclosingScrollView?.superview?.mouseMoved(with: event) ?? superview?.mouseMoved(with: event)
    }
}
