import AppKit
import OMSCore

/// The tool rail: a slim glass capsule of tool chips standing at the canvas's left edge. The tool in
/// hand is marked as the All-In-One bar marks its mode: a light highlight and the symbol in the accent.
///
/// Glass because the rail is small; inside it an opaque window-colored backing, so the capture never
/// shows through. With Reduce Transparency it is a solid capsule.
final class ToolRail: NSView {
    var onSelect: ((AnnotationTool) -> Void)?

    static let width: CGFloat = 42
    private static let inset: CGFloat = 6
    private static let chip: CGFloat = 30
    /// Tools in groups, separated by hairlines: pointing, drawing, words and numbers, hiding and
    /// showing, the picture itself.
    static let groups: [[AnnotationTool]] = [
        [.select],
        [.arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .highlightBox],
        [.text, .counter],
        [.redact, .spotlight],
        [.crop, .background],
    ]
    /// The quick preview keeps the everyday marks at hand; Edit reveals the rest in the same session.
    static let previewGroups: [[AnnotationTool]] = [
        [.select],
        [.arrow, .rectangle, .pen, .highlighter],
        [.text],
        [.crop],
    ]
    private(set) var displayedGroups = ToolRail.groups
    var tools: [AnnotationTool] { displayedGroups.flatMap { $0 } }

    private var container = NSView()
    private let backing = NSView()
    private let stack = NSStackView()
    private var chips: [AnnotationTool: RailChip] = [:]
    private var selected: AnnotationTool = .arrow
    private var displayOptions: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        stack.orientation = .vertical
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        buildChips()
        backing.wantsLayer = true
        installContainer()
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Tools", bundle: .module))
        applyAppearance()
    }

    func showPreviewTools(_ preview: Bool) {
        let groups = preview ? Self.previewGroups : Self.groups
        guard displayedGroups != groups else { return }
        displayedGroups = groups
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.removeAll()
        buildChips()
        select(selected)
        needsLayout = true
    }

    private func buildChips() {
        for (index, group) in displayedGroups.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.widthAnchor.constraint(equalToConstant: 18).isActive = true
                stack.addArrangedSubview(divider)
                if let last = stack.arrangedSubviews.dropLast().last {
                    stack.setCustomSpacing(6, after: last)
                }
                stack.setCustomSpacing(6, after: divider)
            }
            for tool in group {
                stack.addArrangedSubview(makeChip(tool))
            }
        }
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

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var fittingSize: NSSize {
        CGSize(width: Self.width, height: stack.fittingSize.height)
    }

    override func layout() {
        super.layout()
        let radius = bounds.width / 2
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

    func select(_ tool: AnnotationTool) {
        selected = tool
        for (candidate, chip) in chips {
            chip.state = candidate == tool ? .on : .off
            chip.contentTintColor = candidate == tool ? .controlAccentColor : .labelColor
        }
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Layer colors are resolved for this view's appearance, and again when it or the accessibility
    /// display options change. Increase Contrast gives the capsule a firm edge and the chips firmer fills.
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
            for (tool, chip) in chips {
                chip.layer?.backgroundColor = tool == selected ? highlight : chip.isHovered ? hover : .clear
            }
        }
    }

    private func makeChip(_ tool: AnnotationTool) -> NSButton {
        let name = Self.name(of: tool)
        let image = NSImage(systemSymbolName: Self.symbol(for: tool), accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        let chip = RailChip(image: image ?? NSImage(), target: self, action: #selector(clicked(_:)))
        chip.onHover = { [weak self] _ in self?.applyAppearance() }
        chip.isBordered = false
        chip.imagePosition = .imageOnly
        chip.contentTintColor = .labelColor
        chip.wantsLayer = true
        chip.layer?.cornerRadius = Self.chip / 2
        chip.setButtonType(.onOff)
        chip.toolTip = Self.help(for: tool)
        chip.setAccessibilityLabel(name)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: Self.chip).isActive = true
        chip.heightAnchor.constraint(equalToConstant: Self.chip).isActive = true
        chips[tool] = chip
        return chip
    }

    /// Every tool with its key, which the rail's chips show only in their tooltips: there is no menu bar to list them.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (index, group) in Self.groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for tool in group {
                let item = NSMenuItem(title: Self.name(of: tool), action: #selector(chosenFromMenu(_:)), keyEquivalent: String(tool.key))
                item.keyEquivalentModifierMask = []
                item.image = NSImage(systemSymbolName: Self.symbol(for: tool), accessibilityDescription: nil)
                item.state = tool == selected ? .on : .off
                item.representedObject = tool.rawValue
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func chosenFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = AnnotationTool(rawValue: raw) else { return }
        select(tool)
        onSelect?(tool)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let tool = chips.first(where: { $0.value === sender })?.key else { return }
        // The chip toggles itself; the session decides what is selected.
        select(selected)
        onSelect?(tool)
    }

    static func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble.variable"
        case .highlighter: "highlighter"
        case .highlightBox: "rectangle.inset.filled"
        case .text: "textformat"
        case .counter: "1.circle"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "circle.dashed.inset.filled"
        case .crop: "crop"
        case .background: "photo.artframe"
        }
    }

    /// A tool's help tag: its name and key, and for the highlighter how it meets text.
    static func help(for tool: AnnotationTool) -> String {
        let title = "\(name(of: tool)) (\(String(tool.key).uppercased()))"
        guard tool == .highlighter else { return title }
        return title + "\n" + String(localized: "Snaps to text. Hold ⌘ to draw freely.", bundle: .module)
    }

    static func name(of tool: AnnotationTool) -> String {
        switch tool {
        case .select: String(localized: "Select", bundle: .module)
        case .arrow: String(localized: "Arrow", bundle: .module)
        case .line: String(localized: "Line", bundle: .module)
        case .rectangle: String(localized: "Rectangle", bundle: .module)
        case .ellipse: String(localized: "Ellipse", bundle: .module)
        case .pen: String(localized: "Pen", bundle: .module)
        case .highlighter: String(localized: "Highlighter", bundle: .module)
        case .highlightBox: String(localized: "Highlight Box", bundle: .module)
        case .text: String(localized: "Text", bundle: .module)
        case .counter: String(localized: "Counter", bundle: .module)
        case .redact: String(localized: "Redact", bundle: .module)
        case .spotlight: String(localized: "Spotlight", bundle: .module)
        case .crop: String(localized: "Crop", bundle: .module)
        case .background: String(localized: "Background", bundle: .module)
        }
    }
}

/// The fills of chips in the rail and the capsule: a light highlight for the selected chip and half of it
/// on hover, as in the All-In-One bar; about twice as strong with Increase Contrast.
enum ChipFill {
    static func selected(dark: Bool, contrast: Bool) -> CGColor {
        dark ? CGColor(gray: 1, alpha: contrast ? 0.28 : 0.16) : CGColor(gray: 0, alpha: contrast ? 0.16 : 0.08)
    }

    static func hover(dark: Bool, contrast: Bool) -> CGColor {
        dark ? CGColor(gray: 1, alpha: contrast ? 0.16 : 0.09) : CGColor(gray: 0, alpha: contrast ? 0.09 : 0.045)
    }
}

/// A borderless chip that knows when the pointer is over it, for its hover highlight.
final class RailChip: NSButton {
    var onHover: ((Bool) -> Void)?
    private(set) var isHovered = false

    /// No padding around the frame, as a button otherwise keeps for its bezel: the layer's fill covers
    /// the frame, and it must be the square the constraints give, for a round chip.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(false)
    }
}
