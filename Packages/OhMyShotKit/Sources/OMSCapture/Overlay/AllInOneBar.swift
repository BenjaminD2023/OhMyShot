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
        /// All-In-One's other modes: what the next area is for.
        case text
        case scroll
        case record
        case cancel
    }

    var onSelect: ((Choice) -> Void)?
    var onMove: ((CGVector, CGPoint) -> Void)?
    var onHide: (() -> Void)?
    var isDragging: Bool { handle.isDragging }
    var dragHandleFrame: CGRect { handle.convert(handle.bounds, to: self) }

    private let container: NSView
    private let handle = CaptureBarHandle()
    private var hideButton: BarButton!
    private var hideHovered = false
    private let stack = NSStackView()
    /// Inside the glass, an opaque window-colored backing: the bar sits over arbitrary screen content,
    /// and even a slightly translucent fill let text behind it show through near the rounded ends, where
    /// the glass bends what is behind it. The glass still gives the capsule its rim.
    private let backing = NSView()
    private var buttons: [Choice: BarButton] = [:]
    private let modesDivider = NSBox()
    private var selected: Choice = .area
    /// All-In-One's purpose for the next area, shown as a second on-state beside the area or window.
    private var purpose: Choice?
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
        stack.addArrangedSubview(handle)
        handle.onMove = { [weak self] delta, point in self?.onMove?(delta, point) }
        for choice in [Choice.area, .window, .fullscreen] {
            stack.addArrangedSubview(makeButton(choice))
        }
        modesDivider.boxType = .separator
        modesDivider.translatesAutoresizingMaskIntoConstraints = false
        modesDivider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(modesDivider)
        stack.setCustomSpacing(8, after: buttons[.fullscreen]!)
        stack.setCustomSpacing(8, after: modesDivider)
        for choice in [Choice.text, .scroll, .record] {
            stack.addArrangedSubview(makeButton(choice))
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(8, after: buttons[.record]!)
        stack.setCustomSpacing(8, after: divider)
        stack.addArrangedSubview(makeButton(.cancel))
        hideButton = BarButton(
            title: "", image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage(),
            target: self, action: #selector(hideClicked)
        )
        hideButton.isBordered = false
        hideButton.imagePosition = .imageOnly
        hideButton.contentTintColor = .labelColor
        hideButton.wantsLayer = true
        hideButton.layer?.cornerRadius = Self.buttonHeight / 2
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        hideButton.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
        hideButton.widthAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
        hideButton.toolTip = String(localized: "Hide toolbar (H to show)", bundle: .module)
        hideButton.setAccessibilityLabel(String(localized: "Hide toolbar", bundle: .module))
        hideButton.setAccessibilityHelp(hideButton.toolTip)
        hideButton.onHover = { [weak self] inside in
            self?.hideHovered = inside
            self?.applyAppearance()
        }
        stack.addArrangedSubview(hideButton)
        showModes(false)

        if let glass = container as? NSGlassEffectView {
            backing.wantsLayer = true
            backing.addSubview(stack)
            glass.contentView = backing
        } else {
            container.addSubview(stack)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Capture modes", bundle: .module))
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var fittingSize: NSSize {
        stack.fittingSize
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
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

    /// Shows All-In-One's modes beside area, window, and screen; Capture Area's bar has only those three.
    func showModes(_ shows: Bool) {
        for choice in [Choice.text, .scroll, .record] { buttons[choice]?.isHidden = !shows }
        modesDivider.isHidden = !shows
    }

    /// Marks how the next capture is chosen: an area or a window (the screen is taken at once, never held).
    func select(_ choice: Choice) {
        guard choice == .area || choice == .window else { return }
        selected = choice
        restyle()
    }

    /// Marks what All-In-One's next area is for (text, scrolling, recording), apart from how it is chosen; nil for
    /// a plain capture.
    func markPurpose(_ choice: Choice?) {
        purpose = choice
        restyle()
    }

    /// The chips shown as on, for tests.
    var onChoices: Set<Choice> {
        Set(buttons.filter { $0.value.state == .on }.map(\.key))
    }

    private func restyle() {
        for (candidate, button) in buttons where candidate != .cancel {
            let isSelected = candidate == selected || candidate == purpose
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
            // The hairline keeps the capsule's edge on white pages, where the glass alone fades out; Increase Contrast
            // firms it up and doubles the chip fills, as the other capsule bars do.
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.borderWidth = contrast ? 1 : 0.5
            layer?.borderColor = contrast
                ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35))
                : NSColor.separatorColor.cgColor
            let boost: CGFloat = contrast ? 2 : 1
            let highlight = dark ? CGColor(gray: 1, alpha: 0.16 * boost) : CGColor(gray: 0, alpha: 0.08 * boost)
            let hover = dark ? CGColor(gray: 1, alpha: 0.09 * boost) : CGColor(gray: 0, alpha: 0.045 * boost)
            for (candidate, button) in buttons {
                button.layer?.backgroundColor = (candidate == selected || candidate == purpose) && candidate != .cancel ? highlight
                    : candidate == hovered ? hover
                    : .clear
            }
            hideButton?.layer?.backgroundColor = hideHovered ? hover : .clear
        }
    }

    private func makeButton(_ choice: Choice) -> NSButton {
        let (symbol, title, help): (String, String, String) = switch choice {
        case .area:
            ("rectangle.dashed", String(localized: "Area", bundle: .module), String(localized: "Drag to capture an area", bundle: .module))
        case .window:
            ("macwindow", String(localized: "Window", bundle: .module), String(localized: "Click a window to capture it (Space)", bundle: .module))
        case .fullscreen:
            ("display", String(localized: "Screen", bundle: .module), String(localized: "Capture this whole screen", bundle: .module))
        case .text:
            ("text.viewfinder", String(localized: "Text", bundle: .module), String(localized: "Drag over text to copy it (O)", bundle: .module))
        case .scroll:
            ("arrow.up.and.down.text.horizontal", String(localized: "Scrolling", bundle: .module), String(localized: "Drag over the part that scrolls to capture all of it (S)", bundle: .module))
        case .record:
            ("record.circle", String(localized: "Record", bundle: .module), String(localized: "Drag over an area to record it (R)", bundle: .module))
        case .cancel:
            ("xmark", String(localized: "Cancel", bundle: .module), String(localized: "Cancel (Esc)", bundle: .module))
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
        switch choice {
        case .cancel:
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        case .text, .scroll, .record:
            // As wide as their labels plus the chips' padding, so the gaps on both sides of the separator match.
            button.widthAnchor.constraint(equalToConstant: ceil(button.intrinsicContentSize.width) + 22).isActive = true
        case .area, .window, .fullscreen:
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        }
        buttons[choice] = button
        return button
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let choice = buttons.first(where: { $0.value === sender })?.key else { return }
        onSelect?(choice)
    }

    @objc private func hideClicked() { onHide?() }
}

/// A borderless bar button that reports the pointer entering and leaving it, for its hover highlight.
final class BarButton: NSButton {
    var onHover: ((Bool) -> Void)?

    /// Its frame is the chip: no bezel margins, which made a symbol-only chip as tall as its symbol's own
    /// alignment rect wanted rather than the chip's height.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
