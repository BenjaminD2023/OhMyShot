import AppKit
import OMSCore

/// A small capsule of chips over the screen, built as the All-In-One and recording bars are: glass because it
/// is small, an opaque window-colored backing inside so the screen never shows through its symbols, a solid
/// capsule with Reduce Transparency, chips concentric with the capsule that fill under the pointer, and a
/// hairline that Increase Contrast firms up.
class CapsuleBar: NSView {
    static let height: CGFloat = 42
    static let inset: CGFloat = 6
    static let chip: CGFloat = 30

    private let container: NSView
    private let backing = NSView()
    private let stack = NSStackView()
    private var chips: [BarButton] = []
    private var hovered: BarButton?
    /// Chips shown as on: the selected fill.
    private var on: Set<ObjectIdentifier> = []

    init() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            container = solid
        } else {
            container = NSGlassEffectView()
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(container)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        if let glass = container as? NSGlassEffectView {
            backing.wantsLayer = true
            backing.addSubview(stack)
            glass.contentView = backing
        } else {
            container.addSubview(stack)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var fittingSize: NSSize {
        stack.fittingSize
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        container.frame = bounds
        if let glass = container as? NSGlassEffectView {
            glass.cornerRadius = radius
            backing.frame = glass.bounds
            backing.layer?.cornerRadius = radius
            stack.frame = backing.bounds
        } else {
            container.layer?.cornerRadius = radius
            stack.frame = container.bounds
        }
        layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// A chip: a symbol, a title, or both (symbol leading), that calls `action` on `target`.
    func addChip(symbol: String?, title: String?, help: String, target: AnyObject?, action: Selector) -> BarButton {
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title == nil ? help : nil) }?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        let button = BarButton(title: "", image: image ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.chip / 2
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: Self.chip).isActive = true
        if let title {
            button.imagePosition = symbol == nil ? .noImage : .imageLeading
            button.imageHugsTitle = true
            setTitle(title, of: button)
            button.setAccessibilityLabel(title)
        } else {
            button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: Self.chip).isActive = true
        }
        button.toolTip = help
        button.setAccessibilityHelp(help)
        button.onHover = { [weak self, weak button] inside in
            guard let self, let button else { return }
            if inside {
                hovered = button
            } else if hovered === button {
                hovered = nil
            }
            applyAppearance()
        }
        if let last = stack.arrangedSubviews.last, !(last is NSBox) { stack.setCustomSpacing(2, after: last) }
        stack.addArrangedSubview(button)
        chips.append(button)
        applyAppearance()
        return button
    }

    /// A chip's title in the bar's type; `emphasized` for the one that goes ahead.
    func setTitle(_ title: String, of button: BarButton, emphasized: Bool = false) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.Typeface.label(size: 12, weight: emphasized ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        button.setAccessibilityLabel(title)
    }

    /// Any other control in the bar's row (All-In-One's size fields), 2 pt from what comes before it.
    func addView(_ view: NSView) {
        if let last = stack.arrangedSubviews.last, !(last is NSBox) { stack.setCustomSpacing(2, after: last) }
        stack.addArrangedSubview(view)
    }

    func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(6, after: last) }
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(6, after: divider)
    }

    /// Shows `button` as on or off, as a choice in hand is: the selected fill and an accent symbol.
    func setOn(_ isOn: Bool, _ button: BarButton) {
        if isOn { on.insert(ObjectIdentifier(button)) } else { on.remove(ObjectIdentifier(button)) }
        button.state = isOn ? .on : .off
        button.contentTintColor = isOn ? .controlAccentColor : .labelColor
        applyAppearance()
    }

    /// Layer colors are fixed values, resolved for this view's appearance and again when it changes;
    /// Increase Contrast doubles the chip fills and firms up the hairline.
    private func applyAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if container is NSGlassEffectView {
                backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            } else {
                container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.borderWidth = contrast ? 1 : 0.5
            layer?.borderColor = contrast
                ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35))
                : NSColor.separatorColor.cgColor
            let boost: CGFloat = contrast ? 2 : 1
            let selected = dark ? CGColor(gray: 1, alpha: 0.16 * boost) : CGColor(gray: 0, alpha: 0.08 * boost)
            let hover = dark ? CGColor(gray: 1, alpha: 0.09 * boost) : CGColor(gray: 0, alpha: 0.045 * boost)
            for chip in chips {
                chip.layer?.backgroundColor = on.contains(ObjectIdentifier(chip)) ? selected
                    : chip === hovered && chip.isEnabled ? hover : .clear
            }
        }
    }
}
