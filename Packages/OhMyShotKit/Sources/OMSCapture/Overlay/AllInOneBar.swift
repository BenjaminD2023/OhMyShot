import AppKit
import OMSCore

/// The All-In-One bar: a small glass capsule at the bottom of the overlay for switching between capturing
/// an area, a window, or the whole screen. Its buttons are capsules concentric with the bar.
///
/// Glass is used here because the bar is small; the full-screen overlay itself never carries glass. With
/// Reduce Transparency on, the capsule is a solid window-colored panel instead.
final class AllInOneBar: NSView {
    enum Choice: CaseIterable {
        case area
        case window
        case fullscreen
        case cancel
    }

    var onSelect: ((Choice) -> Void)?

    private let container: NSView
    private let stack = NSStackView()
    /// Inside the glass, an opaque window-colored backing: the bar sits over arbitrary screen content,
    /// and even a slightly translucent fill let text behind it show through near the rounded ends, where
    /// the glass bends what is behind it. The glass still gives the capsule its rim.
    private let backing = NSView()
    private var buttons: [Choice: BarButton] = [:]
    private var selected: Choice = .area
    private var hovered: Choice?
    private static let inset: CGFloat = 6
    private static let buttonHeight: CGFloat = 30

    init() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            solid.layer?.borderWidth = 0.5
            container = solid
        } else {
            let glass = NSGlassEffectView()
            container = glass
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
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        for choice in [Choice.area, .window, .fullscreen] {
            stack.addArrangedSubview(makeButton(choice))
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(8, after: buttons[.fullscreen]!)
        stack.setCustomSpacing(8, after: divider)
        stack.addArrangedSubview(makeButton(.cancel))

        if let glass = container as? NSGlassEffectView {
            backing.wantsLayer = true
            backing.addSubview(stack)
            glass.contentView = backing
        } else {
            container.addSubview(stack)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Capture modes"))
        applyAppearance()
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
        // A full capsule; the buttons inside are capsules too, so the corners stay concentric.
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

    /// Marks the current mode.
    func select(_ choice: Choice) {
        selected = choice
        for (candidate, button) in buttons where candidate != .cancel {
            let isSelected = candidate == choice
            button.state = isSelected ? .on : .off
            // The symbol carries the accent; the label stays in the label color so it reads on any tint.
            button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: Theme.Typeface.label(size: 12, weight: isSelected ? .semibold : .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Layer colors are fixed values, so they are resolved for this view's appearance and again whenever
    /// it changes.
    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if container is NSGlassEffectView {
                backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            } else {
                container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            // The hairline keeps the capsule's edge on white pages, where the glass alone fades out.
            layer?.borderColor = NSColor.separatorColor.cgColor
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let highlight = dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.08)
            let hover = dark ? CGColor(gray: 1, alpha: 0.09) : CGColor(gray: 0, alpha: 0.045)
            for (candidate, button) in buttons {
                button.layer?.backgroundColor = candidate == selected && candidate != .cancel ? highlight
                    : candidate == hovered ? hover
                    : .clear
            }
        }
    }

    private func makeButton(_ choice: Choice) -> NSButton {
        let (symbol, title, help): (String, String, String) = switch choice {
        case .area:
            ("rectangle.dashed", String(localized: "Area"), String(localized: "Drag to capture an area"))
        case .window:
            ("macwindow", String(localized: "Window"), String(localized: "Click a window to capture it (Space)"))
        case .fullscreen:
            ("display", String(localized: "Screen"), String(localized: "Capture this whole screen"))
        case .cancel:
            ("xmark", String(localized: "Cancel"), String(localized: "Cancel (Esc)"))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        let button = BarButton(title: title, image: image ?? NSImage(), target: self, action: #selector(clicked(_:)))
        button.onHover = { [weak self] inside in
            guard let self else { return }
            if inside {
                hovered = choice
            } else if hovered == choice {
                hovered = nil
            }
            applyAppearance()
        }
        button.isBordered = false
        button.imagePosition = choice == .cancel ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.font = Theme.Typeface.label(size: 12)
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.buttonHeight / 2
        button.setButtonType(choice == .cancel ? .momentaryPushIn : .onOff)
        button.toolTip = help
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: choice == .cancel ? 30 : 84).isActive = true
        buttons[choice] = button
        return button
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let choice = buttons.first(where: { $0.value === sender })?.key else { return }
        onSelect?(choice)
    }
}

/// A borderless bar button that reports the pointer entering and leaving it, for its hover highlight.
final class BarButton: NSButton {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
