import AppKit
import OMSCore

/// A short word on a card in the upload badge's materials, with a symbol before it: "Copied" over a card copied from
/// the keyboard, whose Copy capsule shows only under the pointer, and "Moved to Trash" over a card waiting to go.
/// It takes no clicks.
final class CardNoticeBadge: NSView {
    private let mark = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var symbolName: String?
    private var symbolColors: [NSColor]?

    private static let height: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        label.font = Theme.Typeface.reading(size: 10.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(mark)
        addSubview(label)
        setAccessibilityElement(false)
        isHidden = true
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Nothing under it takes a click from it: it only says what happened.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The most the badge may span; the card sets it.
    var widest: CGFloat = 152 {
        didSet {
            guard widest != oldValue else { return }
            needsLayout = true
        }
    }

    /// Shows `text` after `symbol` (in the badge's ink, or in `colors`); fades in unless Reduce Motion is on.
    func show(_ text: String, symbol: String, colors: [NSColor]? = nil) {
        label.stringValue = text
        symbolName = symbol
        symbolColors = colors
        applyAppearance()
        needsLayout = true
        superview?.needsLayout = true
        // A badge fading out comes back from where it is.
        if isHidden {
            isHidden = false
            alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again meanwhile, it stays.
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        }
    }

    private var labelSize: NSSize {
        let size = label.attributedStringValue.size()
        // A text field's cell wants a few points of its own around the text, or it shortens it.
        return NSSize(width: ceil(size.width) + 6, height: ceil(size.height))
    }

    override var fittingSize: NSSize {
        NSSize(width: min(8 + 13 + 5 + labelSize.width + 9, widest), height: Self.height)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = height / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        CATransaction.commit()
        mark.frame = CGRect(x: 8, y: (height - 13) / 2, width: 13, height: 13)
        let text = labelSize
        label.frame = CGRect(x: 26, y: ((height - text.height) / 2).rounded(), width: min(text.width, max(bounds.width - 26 - 9, 0)), height: text.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let ink = BadgeMaterial.apply(to: layer, in: self)
        label.textColor = ink
        mark.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: symbolColors ?? [ink])))
    }
}
