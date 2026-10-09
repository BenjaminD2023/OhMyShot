import AppKit
import OMSCore

/// The toolbar of in-place annotation: a small glass capsule beside the selection, in the manner of the
/// All-In-One bar, holding the drawing tools, Undo and Redo, and what to do with the marked selection.
///
/// Glass because it is small, with an opaque window-colored backing inside so the frozen screen never
/// shows through its symbols; a solid capsule with Reduce Transparency.
final class InPlaceToolbar: NSView {
    enum Action: CaseIterable {
        case undo
        case redo
        case openInEditor
        case save
        case cancel
        case copy
    }

    var onTool: ((AnnotationTool) -> Void)?
    var onAction: ((Action) -> Void)?

    /// Pointing and drawing, words and numbers, hiding and showing; as the editor's rail groups them.
    static let toolGroups: [[AnnotationTool]] = [
        [.arrow, .line, .rectangle, .ellipse, .pen, .highlighter],
        [.text, .counter],
        [.redact, .spotlight],
    ]

    static let height: CGFloat = 42
    private static let inset: CGFloat = 6
    private static let chip: CGFloat = 30

    private var container = NSView()
    private let backing = NSView()
    private let stack = NSStackView()
    private var toolChips: [AnnotationTool: RailChip] = [:]
    private var actionChips: [Action: RailChip] = [:]
    private var selected: AnnotationTool?
    private var displayOptions: NSObjectProtocol?

    var canUndo = false {
        didSet { if canUndo != oldValue { applyAppearance() } }
    }
    var canRedo = false {
        didSet { if canRedo != oldValue { applyAppearance() } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        for group in Self.toolGroups {
            if !stack.arrangedSubviews.isEmpty { addDivider() }
            for tool in group { stack.addArrangedSubview(makeToolChip(tool)) }
        }
        addDivider()
        for action in [Action.undo, .redo] { stack.addArrangedSubview(makeActionChip(action)) }
        addDivider()
        for action in [Action.openInEditor, .save, .cancel, .copy] { stack.addArrangedSubview(makeActionChip(action)) }
        backing.wantsLayer = true
        installContainer()
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Mark Up", bundle: .module))
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
    }

    override var fittingSize: NSSize {
        CGSize(width: stack.fittingSize.width, height: Self.height)
    }

    /// Glass, or a solid capsule with Reduce Transparency; swapped when the setting changes.
    private func installContainer() {
        let wantsSolid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let isSolid = !(container is NSGlassEffectView) && container.superview != nil
        guard container.superview == nil || wantsSolid != isSolid else { return }
        container.removeFromSuperview()
        stack.removeFromSuperview()
        backing.removeFromSuperview()
        if wantsSolid {
            let solid = NSView()
            solid.wantsLayer = true
            solid.addSubview(stack)
            container = solid
        } else {
            let glass = NSGlassEffectView()
            backing.addSubview(stack)
            glass.contentView = backing
            container = glass
        }
        addSubview(container, positioned: .below, relativeTo: nil)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        guard window != nil else { return }
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installContainer()
                self?.applyAppearance()
            }
        }
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

    /// Marks the tool in hand; nil while none is (the selection itself is adjusted then).
    func select(_ tool: AnnotationTool?) {
        selected = tool
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Resolved for this view's appearance, and again when it or the accessibility display options
    /// change. Increase Contrast gives the capsule a firm edge and the chips firmer fills.
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
            layer?.borderColor = contrast ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35)) : NSColor.separatorColor.cgColor
            let highlight = ChipFill.selected(dark: dark, contrast: contrast)
            let hover = ChipFill.hover(dark: dark, contrast: contrast)
            for (tool, chip) in toolChips {
                let isSelected = tool == selected
                chip.state = isSelected ? .on : .off
                chip.contentTintColor = isSelected ? .controlAccentColor : .labelColor
                chip.layer?.backgroundColor = isSelected ? highlight : chip.isHovered ? hover : .clear
            }
            for (action, chip) in actionChips {
                let enabled = switch action {
                case .undo: canUndo
                case .redo: canRedo
                default: true
                }
                chip.isEnabled = enabled
                // Copy is what finishing means here: its check carries the accent.
                chip.contentTintColor = !enabled ? .tertiaryLabelColor : action == .copy ? .controlAccentColor : .labelColor
                chip.layer?.backgroundColor = enabled && chip.isHovered ? hover : .clear
            }
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

    private func makeToolChip(_ tool: AnnotationTool) -> RailChip {
        let name = ToolRail.name(of: tool)
        let chip = makeChip(symbol: ToolRail.symbol(for: tool), name: name, help: ToolRail.help(for: tool))
        chip.setButtonType(.onOff)
        toolChips[tool] = chip
        return chip
    }

    private func makeActionChip(_ action: Action) -> RailChip {
        let (symbol, name, help): (String, String, String) = switch action {
        case .undo: ("arrow.uturn.backward", String(localized: "Undo", bundle: .module), String(localized: "Undo (⌘Z)", bundle: .module))
        case .redo: ("arrow.uturn.forward", String(localized: "Redo", bundle: .module), String(localized: "Redo (⇧⌘Z)", bundle: .module))
        case .openInEditor: ("arrow.up.forward.square", String(localized: "Open in Editor", bundle: .module), String(localized: "Open in the editor, to zoom, crop, or set a background", bundle: .module))
        case .save: ("square.and.arrow.down", String(localized: "Save", bundle: .module), String(localized: "Save to the export folder (⌘S)", bundle: .module))
        case .cancel: ("xmark", String(localized: "Cancel", bundle: .module), String(localized: "Cancel (Esc)", bundle: .module))
        case .copy: ("checkmark", String(localized: "Copy", bundle: .module), String(localized: "Copy and finish (Return)", bundle: .module))
        }
        let chip = makeChip(symbol: symbol, name: name, help: help)
        chip.setButtonType(.momentaryChange)
        actionChips[action] = chip
        return chip
    }

    private func makeChip(symbol: String, name: String, help: String) -> RailChip {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        let chip = RailChip(image: image ?? NSImage(), target: self, action: #selector(clicked(_:)))
        chip.onHover = { [weak self] _ in self?.applyAppearance() }
        chip.isBordered = false
        chip.imagePosition = .imageOnly
        chip.contentTintColor = .labelColor
        chip.wantsLayer = true
        chip.layer?.cornerRadius = Self.chip / 2
        chip.toolTip = help
        chip.setAccessibilityLabel(name)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: Self.chip).isActive = true
        chip.heightAnchor.constraint(equalToConstant: Self.chip).isActive = true
        return chip
    }

    @objc private func clicked(_ sender: NSButton) {
        if let tool = toolChips.first(where: { $0.value === sender })?.key {
            // The chip toggles itself; the session decides what is in hand.
            applyAppearance()
            onTool?(tool)
        } else if let action = actionChips.first(where: { $0.value === sender })?.key {
            onAction?(action)
        }
    }

    #if DEBUG
    /// Presses a chip as a click would, for scripted checks.
    func press(_ action: Action) {
        onAction?(action)
    }
    #endif
}
