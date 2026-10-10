import AppKit
import OMSCore

/// The recording bar: after choosing what to record, a small glass capsule under it holding what the
/// recording takes along (the Mac's sound, the microphone, clicks) and Record.
///
/// Built as the All-In-One bar is: glass because it is small, an opaque window-colored backing inside so
/// the screen never shows through its symbols, a solid capsule with Reduce Transparency, chips concentric
/// with the capsule. A choice that is on takes the selected fill and an accent symbol, as a tool in hand
/// does on the in-place toolbar.
final class RecordingBar: NSView {
    enum Toggle: CaseIterable {
        case systemAudio
        case microphone
        case clicks
    }

    var onToggle: ((Toggle) -> Void)?
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?

    static let height: CGFloat = 42
    private static let inset: CGFloat = 6
    private static let chip: CGFloat = 30

    private let container: NSView
    private let backing = NSView()
    private let stack = NSStackView()
    private var toggles: [Toggle: BarButton] = [:]
    private let recordButton: BarButton
    private let cancelButton: BarButton
    private var states: [Toggle: Bool] = [:]
    private var hovered: NSButton?

    init(choices: RecordingChoices) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            container = solid
        } else {
            container = NSGlassEffectView()
        }
        recordButton = BarButton(title: String(localized: "Record"), image: NSImage(), target: nil, action: nil)
        cancelButton = BarButton(title: String(localized: "Cancel"), image: NSImage(), target: nil, action: nil)
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
        for toggle in Toggle.allCases {
            stack.addArrangedSubview(makeToggle(toggle))
        }
        addDivider()
        configureRecordButton()
        stack.addArrangedSubview(recordButton)
        configureCancelButton()
        stack.addArrangedSubview(cancelButton)
        stack.setCustomSpacing(4, after: recordButton)

        if let glass = container as? NSGlassEffectView {
            backing.wantsLayer = true
            backing.addSubview(stack)
            glass.contentView = backing
        } else {
            container.addSubview(stack)
        }
        update(choices)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Recording"))
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

    /// Shows the choices as they are now.
    func update(_ choices: RecordingChoices) {
        states = [.systemAudio: choices.systemAudio, .microphone: choices.microphone, .clicks: choices.showsClicks]
        for (toggle, button) in toggles {
            let on = states[toggle] ?? false
            button.state = on ? .on : .off
            button.contentTintColor = on ? .controlAccentColor : .labelColor
            button.setAccessibilityValue(on ? String(localized: "On") : String(localized: "Off"))
        }
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
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
            for (toggle, button) in toggles {
                button.layer?.backgroundColor = states[toggle] == true ? selected : button === hovered ? hover : .clear
            }
            for button in [recordButton, cancelButton] {
                button.layer?.backgroundColor = button === hovered ? hover : .clear
            }
        }
    }

    private func makeToggle(_ toggle: Toggle) -> BarButton {
        let (symbol, title, help): (String, String, String) = switch toggle {
        case .systemAudio:
            ("speaker.wave.2", String(localized: "Computer Audio"), String(localized: "Record what the Mac plays"))
        case .microphone:
            ("mic", String(localized: "Microphone"), String(localized: "Record the microphone"))
        case .clicks:
            ("cursorarrow.click.2", String(localized: "Show Clicks"), String(localized: "Show clicks in the recording"))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        let button = BarButton(title: "", image: image ?? NSImage(), target: self, action: #selector(toggled(_:)))
        configureChip(button)
        button.setButtonType(.onOff)
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.setAccessibilityRole(.checkBox)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        button.widthAnchor.constraint(equalToConstant: Self.chip).isActive = true
        toggles[toggle] = button
        return button
    }

    private func configureRecordButton() {
        // The one red in the app: what records, as everywhere on the Mac.
        let dot = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium).applying(.init(paletteColors: [.white, .systemRed])))
        recordButton.image = dot
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        configureChip(recordButton)
        recordButton.imagePosition = .imageLeading
        recordButton.imageHugsTitle = true
        recordButton.attributedTitle = NSAttributedString(string: String(localized: "Record"), attributes: [
            .font: Theme.Typeface.label(size: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        recordButton.toolTip = String(localized: "Start recording (Return)")
        recordButton.setAccessibilityLabel(String(localized: "Record"))
        recordButton.setAccessibilityHelp(String(localized: "Start recording (Return)"))
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
    }

    private func configureCancelButton() {
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Cancel"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        configureChip(cancelButton)
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = .labelColor
        cancelButton.toolTip = String(localized: "Cancel (Esc)")
        cancelButton.setAccessibilityLabel(String(localized: "Cancel"))
        cancelButton.widthAnchor.constraint(equalToConstant: Self.chip).isActive = true
    }

    private func configureChip(_ button: BarButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.chip / 2
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: Self.chip).isActive = true
        button.onHover = { [weak self, weak button] inside in
            guard let self, let button else { return }
            if inside {
                hovered = button
            } else if hovered === button {
                hovered = nil
            }
            applyAppearance()
        }
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(6, after: last) }
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(6, after: divider)
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let toggle = toggles.first(where: { $0.value === sender })?.key else { return }
        onToggle?(toggle)
    }

    @objc private func recordClicked() {
        onRecord?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
