import AppKit
import OMSCore

/// Buttons for the app's floating panels, drawn by hand. AppKit draws its own controls dimmed in windows
/// that are not key, and the floating panels (Quick Access, the text result) never become key, so
/// standard buttons would always look disabled there.
final class CardButton: NSControl {
    enum Style {
        /// A white capsule with a symbol and a label, over a picture.
        case pill
        /// A small dark circle with a symbol, over a picture's corner.
        case round
        /// A tinted capsule with a symbol and a label, on a card.
        case chip
        /// A tinted circle with a symbol, on a card.
        case chipIcon
    }

    var title: String {
        didSet {
            setAccessibilityLabel(title)
            if style == .chipIcon || style == .round { toolTip = title }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var symbolName: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// What the button stands on, filled under it: over text, so the letters it covers don't show through.
    var backdrop: NSColor? {
        didSet { needsDisplay = true }
    }

    private let style: Style
    private var pressed = false {
        didSet { needsDisplay = true }
    }
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    init(style: Style, title: String, symbolName: String) {
        self.style = style
        self.title = title
        self.symbolName = symbolName
        super.init(frame: .zero)
        setFrameSize(intrinsicContentSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        if style == .round || style == .chipIcon { toolTip = title }
        if style == .pill {
            // A soft lift, so the capsule holds its edge on bright pictures.
            wantsLayer = true
            layer?.shadowColor = .black
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        if style == .pill {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        }
    }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .pill:
            NSSize(width: 112, height: 30)
        case .round, .chipIcon:
            NSSize(width: 24, height: 24)
        case .chip:
            NSSize(width: ceil((symbol(ink: .labelColor)?.size.width ?? 0) + 5 + label(ink: .labelColor).size().width + 22), height: 26)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let radius = bounds.height / 2
        if let backdrop {
            backdrop.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let ink: NSColor
        switch style {
        case .pill:
            // Opaque, so text in the capture never shows through the label.
            NSColor(white: pressed ? 0.84 : hovering ? 1 : 0.97, alpha: 1).setFill()
            ink = NSColor(white: 0.1, alpha: 1)
        case .round:
            NSColor(white: 0, alpha: pressed ? 0.72 : hovering ? 0.62 : 0.5).setFill()
            ink = .white
        case .chip, .chipIcon:
            let strength: CGFloat = pressed ? 2.6 : hovering ? 1.7 : 1
            NSColor(white: dark ? 1 : 0, alpha: (dark ? 0.1 : 0.06) * strength).setFill()
            ink = .labelColor
        }
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if increaseContrast {
            let edge: NSColor = switch style {
            case .pill: NSColor(white: 0, alpha: 0.5)
            case .round: NSColor(white: 1, alpha: 0.7)
            case .chip, .chipIcon: dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.35)
            }
            edge.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            outline.stroke()
        }

        let image = symbol(ink: ink)
        let symbolSize = image?.size ?? .zero
        switch style {
        case .round, .chipIcon:
            image?.draw(in: CGRect(x: bounds.midX - symbolSize.width / 2, y: bounds.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height))
        case .pill, .chip:
            let text = label(ink: ink)
            let textSize = text.size()
            let spacing: CGFloat = style == .pill ? 6 : 5
            var x = bounds.midX - (symbolSize.width + spacing + textSize.width) / 2
            image?.draw(in: CGRect(x: x, y: bounds.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height))
            x += symbolSize.width + spacing
            text.draw(at: CGPoint(x: x, y: bounds.midY - textSize.height / 2))
        }
    }

    private func symbol(ink: NSColor) -> NSImage? {
        let size: CGFloat = switch style {
        case .pill: 12
        case .round: 10.5
        case .chip: 11
        case .chipIcon: 9.5
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: style == .chip ? .semibold : .bold).applying(.init(paletteColors: [ink])))
    }

    private func label(ink: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: style == .pill ? Theme.Typeface.label(size: 13, weight: .semibold) : Theme.Typeface.label(size: 12, weight: .medium),
            .foregroundColor: ink,
        ])
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
        pressed = false
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        pressed = true
        // Tracks the press like a standard button: it fires only if released inside.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { sendAction(action, to: target) }
                return
            }
            pressed = inside
        }
        pressed = false
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}
