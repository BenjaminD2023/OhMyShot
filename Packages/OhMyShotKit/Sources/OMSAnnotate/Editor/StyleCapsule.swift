import AppKit
import OMSCore

/// The style capsule: a white capsule holding the controls for one kind of mark (color, size, and the
/// kind's own variants). It sits beside the selected mark, or at the foot of the tool rail for the next
/// mark when nothing is selected.
final class StyleCapsule: NSView {
    /// A settings change and its undo name.
    var onChange: ((String, (inout ToolSettings) -> Void) -> Void)?
    var onDelete: (() -> Void)?
    /// Redact All: covers every open redaction suggestion.
    var onRedactAll: (() -> Void)?
    /// Try Again: reads the capture again for the tool, after a reading that failed.
    var onRetry: (() -> Void)?
    var onCropReset: (() -> Void)?
    var onCropDone: (() -> Void)?
    /// A background fill was picked; nil takes the background away.
    var onBackdropFill: ((Backdrop.Fill?) -> Void)?
    /// Choose a picture for the background, from the chip.
    var onBackdropChoosePicture: (() -> Void)?
    /// Show the background's adjustments, beside the chip.
    var onBackdropAdjust: ((NSView) -> Void)?
    /// Show the background presets, from the chip.
    var onBackdropPresets: ((NSView) -> Void)?
    /// A shape was chosen for the crop frame.
    var onCropRatio: ((CropRatio) -> Void)?
    /// Toggles sampling a color directly from the canvas picture (shortcut I).
    var onPickCanvasColor: (() -> Void)?
    /// Whether the canvas color eyedropper is currently active.
    var isPickingCanvasColor = false
    /// The colors a person has kept; the chips beside the inks, and the one that keeps another.
    var savedColors = SavedColors.shared

    static let height: CGFloat = 38
    private static let inset: CGFloat = 4
    /// The room at each end, the same at both: a chip's fill 4 pt from the end crowded it.
    private static let endInset: CGFloat = 8

    private let stack = NSStackView()
    private var displayOptions: NSObjectProtocol?
    private var kind: AnnotationTool = .arrow
    private var settings = ToolSettings()
    private var hasSelection = false
    /// The redaction tool's open suggestions.
    private var suggestions = 0
    private var finding = false
    /// The last reading for the tool failed.
    private var failed = false
    /// Whether the size chips mean anything: not for highlights snapped to text.
    private var sized = true
    /// The shape the crop frame keeps, while the crop is in hand.
    private var cropRatio = CropRatio.free
    private var chips: [CapsuleChip] = []
    /// What the background controls show, when the background is in hand.
    private var background: BackgroundState?
    /// The chip that opens the background's adjustments, while it is shown.
    private(set) weak var adjustChip: NSView?

    struct BackgroundState: Equatable {
        var backdrop: Backdrop?
        /// The picture chosen last, offered again.
        var lastPicture: String?
        /// The blurred capture a blur background would show.
        var blur: CGImage?

        static func == (lhs: BackgroundState, rhs: BackgroundState) -> Bool {
            lhs.backdrop?.fill == rhs.backdrop?.fill && (lhs.backdrop == nil) == (rhs.backdrop == nil)
                && lhs.lastPicture == rhs.lastPicture && lhs.blur === rhs.blur
        }
    }

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.endInset, bottom: Self.inset, right: Self.endInset)
        addSubview(stack)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var fittingSize: NSSize {
        CGSize(width: stack.fittingSize.width, height: Self.height)
    }

    override func layout() {
        super.layout()
        stack.frame = bounds
        let radius = bounds.height / 2
        layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        releaseColorPanel()
    }

    /// Lets go of the shared color panel, which does not retain its target: a panel left pointing at a
    /// freed capsule would send its next color there.
    func releaseColorPanel() {
        guard Self.colorPanelOwner === self, NSColorPanel.sharedColorPanelExists else { return }
        Self.colorPanelOwner = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
    }

    /// The capsule the shared color panel reports to; it cannot be asked for its target.
    private static weak var colorPanelOwner: StyleCapsule?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        guard window != nil else { return }
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    /// The reading capsule's materials, at control size.
    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = dark ? CGColor(gray: 0.17, alpha: 0.96) : CGColor(gray: 1, alpha: 0.97)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.borderWidth = contrast ? 1 : 0.5
        layer?.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
        chips.forEach {
            $0.applyAppearance()
            // Swatches draw their edge for the appearance and contrast in effect.
            $0.needsDisplay = true
        }
    }

    /// Shows the controls for `kind` with `settings`; `hasSelection` adds Delete.
    /// - Parameters:
    ///   - suggestions: redaction suggestions not yet covered, for Redact All.
    ///   - finding: the capture is being read for the tool: for redaction suggestions, or the lines of text
    ///     the highlighter snaps to.
    ///   - failed: the last reading for the tool failed, offered again with Try Again.
    ///   - sized: false leaves out the sizes, for highlights snapped to text.
    ///   - cropRatio: the shape the crop frame keeps, shown while the crop is in hand.
    func show(kind: AnnotationTool, settings: ToolSettings, hasSelection: Bool, suggestions: Int = 0, finding: Bool = false, failed: Bool = false, sized: Bool = true, cropRatio: CropRatio = .free) {
        self.cropRatio = cropRatio
        self.kind = kind
        self.settings = settings
        self.hasSelection = hasSelection
        self.suggestions = suggestions
        self.finding = finding
        self.failed = failed
        self.sized = sized
        background = nil
        rebuild()
    }

    /// Shows the background's fills, its adjustments, and its presets. Rebuilt only when what the chips
    /// show changes, so the adjustments' popover keeps its chip while a slider moves.
    func showBackground(_ state: BackgroundState) {
        guard kind != .background || background != state else { return }
        kind = .background
        hasSelection = false
        background = state
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.removeAll()
        setAccessibilityLabel(String(localized: "\(ToolRail.name(of: kind)) Style", bundle: .module))

        // The crop's text chips are capsules concentric with this one, 4 pt in at both ends.
        if kind == .crop {
            stack.edgeInsets.left = Self.inset
            stack.edgeInsets.right = Self.inset
            add(ratioChip())
            addDivider()
            add(textChip(String(localized: "Reset", bundle: .module)) { [weak self] in self?.onCropReset?() })
            add(textChip(String(localized: "Done", bundle: .module), prominent: true) { [weak self] in self?.onCropDone?() })
            return
        }
        stack.edgeInsets.left = Self.endInset
        stack.edgeInsets.right = Self.endInset
        if kind == .background, let background {
            buildBackground(background)
            return
        }

        var sections: [[NSView]] = []
        if usesColor {
            var colorChips = inks.map(colorChip) + savedColors.colors.map(savedColorChip) + [customColorChip()] + saveColorChip()
            if onPickCanvasColor != nil {
                let label = String(localized: "Pick Color from Canvas (I)", bundle: .module)
                let eyedropper = symbolChip("eyedropper", name: label, selected: isPickingCanvasColor) { [weak self] in
                    self?.onPickCanvasColor?()
                }
                colorChips.append(eyedropper)
            }
            sections.append(colorChips)
        }
        let sizes = sizeChips()
        if !sizes.isEmpty { sections.append(sizes) }
        let variants = variantChips()
        if !variants.isEmpty { sections.append(variants) }
        if castsShadow {
            let name = String(localized: "Shadow", bundle: .module)
            let chip = CapsuleChip(image: Self.shadowIcon()) { [weak self] in
                self?.change(name) { $0.shadow.toggle() }
            }
            chip.isSelected = settings.shadow
            chip.setAccessibilityLabel(name)
            chip.setAccessibilityValue(settings.shadow ? String(localized: "On", bundle: .module) : String(localized: "Off", bundle: .module))
            chip.toolTip = name
            sections.append([chip])
        }
        if hasSelection {
            sections.append([symbolChip("trash", name: String(localized: "Delete", bundle: .module), selected: false) { [weak self] in self?.onDelete?() }])
        }
        // Kept beside Delete too: a redaction drawn by hand is selected, and the rest still wait.
        if kind == .redact || kind == .highlighter, finding {
            sections.append([CapsuleStatus(String(localized: "Finding text…", bundle: .module))])
        } else if kind == .redact || kind == .highlighter, failed {
            sections.append([
                CapsuleStatus(String(localized: "Couldn’t read text", bundle: .module), busy: false),
                textChip(String(localized: "Try Again", bundle: .module)) { [weak self] in self?.onRetry?() },
            ])
        } else if kind == .redact, suggestions > 0 {
            sections.append([textChip(String(localized: "Redact All (\(suggestions))", bundle: .module)) { [weak self] in self?.onRedactAll?() }])
        }
        for (index, section) in sections.enumerated() {
            if index > 0 { addDivider() }
            section.forEach(add)
        }
    }

    private var usesColor: Bool {
        switch kind {
        case .spotlight, .crop, .select, .background: false
        case .redact: settings.redaction == .solid
        default: true
        }
    }

    private var castsShadow: Bool {
        switch kind {
        case .arrow, .line, .rectangle, .ellipse, .pen, .text, .counter: true
        // Selected marks show the select kind only when they belong to no tool: combined images.
        case .select: hasSelection
        default: false
        }
    }

    /// The room from each end of the capsule to what its first and last controls show, for checking that
    /// the two ends match: a status's own padding at an end counts as room.
    var endRoom: (leading: CGFloat, trailing: CGFloat) {
        layoutSubtreeIfNeeded()
        guard let first = stack.arrangedSubviews.first, let last = stack.arrangedSubviews.last else { return (0, 0) }
        let leading = first.frame.minX + ((first as? NSStackView)?.edgeInsets.left ?? 0)
        let trailing = stack.bounds.maxX - last.frame.maxX + ((last as? NSStackView)?.edgeInsets.right ?? 0)
        return (leading, trailing)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        if let chip = view as? CapsuleChip { chips.append(chip) }
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

    private func change(_ name: String, _ body: @escaping (inout ToolSettings) -> Void) {
        onChange?(name, body)
    }

    // MARK: Chips

    private func colorChip(_ color: RGBA) -> NSView {
        let selected = settings.color.withAlpha(1) == color
        let chip = CapsuleChip(swatch: Self.dot(color, selected: selected)) { [weak self] in
            self?.change(String(localized: "Color", bundle: .module)) { $0.color = color }
        }
        chip.isSelected = selected
        chip.setAccessibilityLabel(Self.colorName(color))
        chip.toolTip = Self.colorName(color)
        return chip
    }

    /// A color the person kept, among the inks: chosen again in one click, removed from its menu.
    private func savedColorChip(_ color: RGBA) -> NSView {
        let selected = SavedColors.stored(settings.color) == color
        let name = String(localized: "Saved Color", bundle: .module)
        let chip = CapsuleChip(swatch: Self.dot(color, selected: selected)) { [weak self] in
            self?.change(String(localized: "Color", bundle: .module)) { $0.color = color }
        }
        chip.isSelected = selected
        chip.setAccessibilityLabel(name)
        chip.toolTip = name
        let remove = String(localized: "Remove Saved Color", bundle: .module)
        let menu = NSMenu()
        let item = NSMenuItem(title: remove, action: #selector(removeSavedColor(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = color
        menu.addItem(item)
        chip.menu = menu
        chip.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: remove) { [weak self] in
            self?.savedColors.remove(color)
            return true
        }])
        return chip
    }

    @objc private func removeSavedColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? RGBA else { return }
        savedColors.remove(color)
    }

    /// The inks offered: the eight, led for the tools that start in it by the marker yellow, so it can be chosen again,
    /// in place of the other yellow, which a highlight needs no second of (and the capsule no wider).
    private var inks: [RGBA] {
        kind == .highlighter || kind == .highlightBox ? [.marker] + Self.palette.filter { $0 != .yellow } : Self.palette
    }

    /// Whether the color in use is none of the inks nor a kept one: it has the Other Color chip, and can be kept.
    private var usesUnsavedColor: Bool {
        !inks.contains(settings.color.withAlpha(1)) && !savedColors.contains(settings.color)
    }

    /// Keeps the color in use, when it is one of the person's own that is not kept yet. With the colors full,
    /// the chip is there but dimmed, and says why.
    private func saveColorChip() -> [NSView] {
        // The marker yellow the highlighter and the highlight box start in is theirs, not a color chosen.
        guard usesUnsavedColor, settings.color.withAlpha(1) != .marker else { return [] }
        let name = String(localized: "Save Color", bundle: .module)
        let color = settings.color
        let chip = CapsuleChip(swatch: Self.saveDot()) { [weak self] in
            self?.savedColors.add(color)
        }
        chip.setAccessibilityLabel(name)
        chip.toolTip = name
        if savedColors.isFull {
            chip.isEnabled = false
            chip.toolTip = String(localized: "Remove a saved color to make room.", bundle: .module)
        }
        return [chip]
    }

    private func customColorChip() -> NSView {
        let isCustom = usesUnsavedColor
        let image = isCustom ? Self.dot(settings.color, selected: true) : Self.wheel()
        let chip = CapsuleChip(swatch: image) { [weak self] in self?.pickColor() }
        // Showing the color in use, it is the selected one, and says so.
        chip.isSelected = isCustom
        chip.setAccessibilityLabel(String(localized: "Other Color…", bundle: .module))
        chip.setAccessibilityValue(isCustom ? Self.colorName(settings.color.withAlpha(1)) : nil)
        chip.toolTip = String(localized: "Other Color…", bundle: .module)
        return chip
    }

    private func pickColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.color = NSColor(cgColor: settings.color.cgColor) ?? .systemRed
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        Self.colorPanelOwner = self
        panel.orderFront(nil)
    }

    @objc private func colorPicked(_ sender: NSColorPanel) {
        guard let color = RGBA(sender.color.cgColor) else { return }
        change(String(localized: "Color", bundle: .module)) { $0.color = color.withAlpha(1) }
    }

    private func sizeChips() -> [NSView] {
        guard sized else { return [] }
        switch kind {
        case .text:
            let sizes: [CGFloat] = [14, 20, 28, 40]
            // A size set some other way shows as the nearest step.
            let nearest = Self.nearest(settings.fontSize, in: sizes)
            return sizes.enumerated().map { index, size in
                let selected = size == nearest
                let chip = CapsuleChip(image: Self.letter(size: 9 + CGFloat(index) * 3)) { [weak self] in
                    self?.change(String(localized: "Text Size", bundle: .module)) { $0.fontSize = size }
                }
                chip.isSelected = selected
                chip.setAccessibilityLabel(String(localized: "\(Int(size)) points", bundle: .module))
                return chip
            }
        case .redact, .spotlight, .highlightBox, .crop, .select, .background:
            return []
        default:
            let widths: [CGFloat] = switch kind {
            case .highlighter: [10, 18, 28]
            case .counter: [2, 4, 7]
            default: [2, 4, 6, 10]
            }
            let nearest = Self.nearest(settings.lineWidth, in: widths)
            return widths.enumerated().map { index, width in
                let selected = width == nearest
                let chip = CapsuleChip(image: Self.sizeDot(diameter: 4 + CGFloat(index) * 3)) { [weak self] in
                    self?.change(String(localized: "Size", bundle: .module)) { $0.lineWidth = width }
                }
                chip.isSelected = selected
                chip.setAccessibilityLabel(String(localized: "\(Int(width)) points", bundle: .module))
                // A highlight snapped to text is as tall as its letters: the size is for one drawn freely.
                chip.toolTip = kind == .highlighter
                    ? String(localized: "\(Int(width)) pt, for strokes drawn freely (hold Command). Over text, a highlight is as tall as the letters.", bundle: .module)
                    : String(localized: "\(Int(width)) pt", bundle: .module)
                if kind == .highlighter { chip.setAccessibilityHelp(chip.toolTip) }
                return chip
            }
        }
    }

    private func variantChips() -> [NSView] {
        switch kind {
        case .arrow:
            return Arrow.Head.allCases.map { head in
                let chip = CapsuleChip(image: Self.arrowIcon(head)) { [weak self] in
                    self?.change(String(localized: "Arrow Style", bundle: .module)) { $0.arrowHead = head }
                }
                chip.isSelected = settings.arrowHead == head
                chip.setAccessibilityLabel(Self.name(of: head))
                chip.toolTip = Self.name(of: head)
                return chip
            }
        case .line:
            return [false, true].map { dashed in
                let chip = CapsuleChip(image: Self.lineIcon(dashed: dashed)) { [weak self] in
                    self?.change(String(localized: "Line Style", bundle: .module)) { $0.dashed = dashed }
                }
                chip.isSelected = settings.dashed == dashed
                let name = dashed ? String(localized: "Dashed", bundle: .module) : String(localized: "Solid", bundle: .module)
                chip.setAccessibilityLabel(name)
                chip.toolTip = name
                return chip
            }
        case .rectangle, .ellipse:
            let outline = kind == .rectangle ? "rectangle" : "circle"
            return [false, true].map { filled in
                symbolChip(filled ? outline + ".fill" : outline, name: filled ? String(localized: "Filled", bundle: .module) : String(localized: "Outline", bundle: .module), selected: settings.filled == filled) { [weak self] in
                    self?.change(String(localized: "Fill", bundle: .module)) { $0.filled = filled }
                }
            }
        case .text:
            return TextBlock.Look.allCases.map { look in
                let chip = CapsuleChip(image: Self.lookIcon(look)) { [weak self] in
                    self?.change(String(localized: "Text Style", bundle: .module)) { $0.textLook = look }
                }
                chip.isSelected = settings.textLook == look
                chip.setAccessibilityLabel(Self.name(of: look))
                chip.toolTip = Self.name(of: look)
                return chip
            }
        case .counter:
            return Counter.Numbering.allCases.map { numbering in
                let label = Counter(center: .zero, value: 1, numbering: numbering).label
                let chip = CapsuleChip(image: Self.glyph(label)) { [weak self] in
                    self?.change(String(localized: "Numbering", bundle: .module)) { $0.numbering = numbering }
                }
                chip.isSelected = settings.numbering == numbering
                chip.setAccessibilityLabel(Self.name(of: numbering))
                chip.toolTip = Self.name(of: numbering)
                return chip
            }
        case .redact:
            return Redaction.Method.allCases.map { method in
                let symbol = switch method {
                case .solid: "rectangle.fill"
                case .blur: "aqi.medium"
                case .pixelate: "checkerboard.rectangle"
                }
                return symbolChip(symbol, name: Self.name(of: method), selected: settings.redaction == method) { [weak self] in
                    self?.change(String(localized: "Redaction", bundle: .module)) { $0.redaction = method }
                }
            }
        case .spotlight:
            return [false, true].map { oval in
                symbolChip(oval ? "oval" : "rectangle", name: oval ? String(localized: "Oval", bundle: .module) : String(localized: "Rectangle", bundle: .module), selected: settings.oval == oval) { [weak self] in
                    self?.change(String(localized: "Spotlight Shape", bundle: .module)) { $0.oval = oval }
                }
            }
        default:
            return []
        }
    }

    // MARK: Crop

    /// The shape of the crop frame: its name, and a menu of the shapes on a click.
    private func ratioChip() -> CapsuleChip {
        let name = Self.name(of: cropRatio)
        let chip = textChip(name + " ▾") {}
        chip.setAccessibilityLabel(String(localized: "Crop Ratio, \(name)", bundle: .module))
        chip.toolTip = String(localized: "Crop Ratio", bundle: .module)
        chip.handlerOverride = { [weak self, weak chip] in
            guard let chip else { return }
            self?.showRatios(from: chip)
        }
        return chip
    }

    private func showRatios(from chip: NSView) {
        let menu = NSMenu()
        for ratio in CropRatio.presets {
            let item = NSMenuItem(title: Self.name(of: ratio), action: #selector(ratioChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ratio
            item.state = ratio == cropRatio ? .on : .off
            menu.addItem(item)
            // Free and the picture's own shape, then the fixed ones.
            if ratio == .original { menu.addItem(.separator()) }
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: chip.isFlipped ? chip.bounds.maxY + 4 : -4), in: chip)
    }

    @objc private func ratioChosen(_ sender: NSMenuItem) {
        guard let ratio = sender.representedObject as? CropRatio else { return }
        onCropRatio?(ratio)
    }

    static func name(of ratio: CropRatio) -> String {
        switch ratio {
        case .free: String(localized: "Free", bundle: .module)
        case .original: String(localized: "Original", bundle: .module)
        case .fixed(let width, let height): "\(width):\(height)"
        }
    }

    // MARK: Background

    private func buildBackground(_ state: BackgroundState) {
        setAccessibilityLabel(String(localized: "Background", bundle: .module))
        let fill = state.backdrop?.fill
        var fills: [NSView] = []
        fills.append(fillChip(Self.noneDot(), name: String(localized: "No Background", bundle: .module), selected: state.backdrop == nil) { [weak self] in
            self?.onBackdropFill?(nil)
        })
        fills.append(fillChip(Self.clearDot(), name: String(localized: "Transparent", bundle: .module), selected: fill == .clear) { [weak self] in
            self?.onBackdropFill?(.clear)
        })
        for gradient in BackdropGradient.allCases {
            fills.append(fillChip(Self.gradientDot(gradient), name: Self.name(of: gradient), selected: fill == .gradient(gradient)) { [weak self] in
                self?.onBackdropFill?(.gradient(gradient))
            })
        }
        // Always in its place, so the chips after it never shift; a plain disc until the blur exists.
        fills.append(fillChip(state.blur.map(Self.imageDot) ?? Self.dotImage(RGBA(red: 0.85, green: 0.85, blue: 0.85)), name: String(localized: "Blurred Capture", bundle: .module), selected: fill == .blur) { [weak self] in
            self?.onBackdropFill?(.blur)
        })
        // A color of one's own: the color ringed while in use, else a hue wheel that opens the panel.
        if case .color(let color) = fill {
            fills.append(fillChip(Self.dotImage(color), name: String(localized: "Background Color…", bundle: .module), selected: true) { [weak self] in
                self?.pickBackdropColor(color)
            })
        } else {
            fills.append(fillChip(Self.wheel(), name: String(localized: "Background Color…", bundle: .module), selected: false) { [weak self] in
                self?.pickBackdropColor(nil)
            })
        }
        // A picture: the one in use (choosing again opens the panel), the last one used, or a new one.
        if case .picture(let name) = fill {
            let image = PictureStore.shared.image(named: name, fitting: 64, limit: PictureStore.backgroundLimit)
            fills.append(fillChip(image.map(Self.imageDot) ?? Self.pictureSymbol(), name: String(localized: "Choose Another Picture…", bundle: .module), selected: true) { [weak self] in
                self?.onBackdropChoosePicture?()
            })
        } else if let last = state.lastPicture, let image = PictureStore.shared.image(named: last, fitting: 64, limit: PictureStore.backgroundLimit) {
            fills.append(fillChip(Self.imageDot(image), name: String(localized: "Picture", bundle: .module), selected: false) { [weak self] in
                self?.onBackdropFill?(.picture(last))
            })
        } else {
            fills.append(fillChip(Self.pictureSymbol(), name: String(localized: "Choose Picture…", bundle: .module), selected: false) { [weak self] in
                self?.onBackdropChoosePicture?()
            })
        }
        fills.forEach(add)
        addDivider()
        let adjust = symbolChip("slider.horizontal.3", name: String(localized: "Adjust Background", bundle: .module), selected: false) {}
        adjust.handlerOverride = { [weak self, weak adjust] in
            guard let adjust else { return }
            self?.onBackdropAdjust?(adjust)
        }
        add(adjust)
        adjustChip = adjust
        let presets = symbolChip("square.stack", name: String(localized: "Background Presets", bundle: .module), selected: false) {}
        presets.handlerOverride = { [weak self, weak presets] in
            guard let presets else { return }
            self?.onBackdropPresets?(presets)
        }
        add(presets)
    }

    private func fillChip(_ image: NSImage, name: String, selected: Bool, action: @escaping () -> Void) -> CapsuleChip {
        let chip = CapsuleChip(swatch: Self.ringed(image, selected: selected), action: action)
        chip.isSelected = selected
        chip.setAccessibilityLabel(name)
        chip.toolTip = name
        return chip
    }

    private func pickBackdropColor(_ current: RGBA?) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.color = current.flatMap { NSColor(cgColor: $0.cgColor) } ?? .white
        panel.setTarget(self)
        panel.setAction(#selector(backdropColorPicked(_:)))
        Self.colorPanelOwner = self
        panel.orderFront(nil)
    }

    @objc private func backdropColorPicked(_ sender: NSColorPanel) {
        guard let color = RGBA(sender.color.cgColor) else { return }
        onBackdropFill?(.color(color.withAlpha(1)))
    }

    static func name(of gradient: BackdropGradient) -> String {
        gradient.title
    }

    /// A fill chip's swatch, drawn as an ink's dot: a 16 pt disc in a 24 pt image, room left for the ring.
    /// `blends` says, for the capsule in dark or light, whether the swatch would vanish into it without an edge.
    private static func swatchImage(blends: @escaping (_ dark: Bool) -> Bool = { _ in false }, _ draw: @escaping (CGContext, CGRect) -> Void) -> NSImage {
        let image = NSImage(size: CGSize(width: inkChip, height: inkChip), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let disc = rect.insetBy(dx: inkInset, dy: inkInset)
            context.saveGState()
            context.addEllipse(in: disc)
            context.clip()
            draw(context, disc)
            context.restoreGState()
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if blends(dark) { strokeInkEdge(context, around: disc, dark: dark) }
            return true
        }
        // Drawn each time, so the edge follows the appearance and Increase Contrast.
        image.cacheMode = .never
        return image
    }

    /// The edge of an ink or swatch the capsule would swallow: 1 pt, black 0.22 in light, white 0.45 in dark,
    /// stronger under Increase Contrast.
    private static func strokeInkEdge(_ context: CGContext, around disc: CGRect, dark: Bool) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        context.setStrokeColor(dark ? CGColor(gray: 1, alpha: contrast ? 0.6 : 0.45) : CGColor(gray: 0, alpha: contrast ? 0.4 : 0.22))
        context.setLineWidth(1)
        context.strokeEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))
    }

    /// `image` with the ring of a chosen swatch around it: an ink's ring, in the label ink.
    private static func ringed(_ image: NSImage, selected: Bool) -> NSImage {
        guard selected else { return image }
        let ringed = NSImage(size: CGSize(width: inkChip, height: inkChip), flipped: true) { rect in
            image.draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        ringed.cacheMode = .never
        return ringed
    }

    /// White with a red stroke across: no background, as "None" swatches read in design apps.
    private static func noneDot() -> NSImage {
        swatchImage(blends: { !$0 }) { context, rect in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.setStrokeColor(RGBA.red.cgColor)
            context.setLineWidth(1.5)
            context.strokeLineSegments(between: [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)])
        }
    }

    /// A checkerboard: transparent room.
    private static func clearDot() -> NSImage {
        swatchImage(blends: { !$0 }) { context, rect in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.setFillColor(CGColor(gray: 0.78, alpha: 1))
            let cell = rect.width / 4
            for row in 0..<4 {
                for column in 0..<4 where (row + column).isMultiple(of: 2) {
                    context.fill(CGRect(x: rect.minX + CGFloat(column) * cell, y: rect.minY + CGFloat(row) * cell, width: cell, height: cell))
                }
            }
        }
    }

    /// Edged as an ink would be, by the blend's two ends: Paper on the light capsule, Graphite on the dark.
    private static func gradientDot(_ gradient: BackdropGradient) -> NSImage {
        let recipe = gradient.recipe
        return swatchImage(blends: { dark in blendsIntoCapsule(recipe.from, dark: dark) || blendsIntoCapsule(recipe.to, dark: dark) }) { context, rect in
            recipe.draw(in: rect, context: context)
        }
    }

    private static func dotImage(_ color: RGBA) -> NSImage {
        swatchImage(blends: { blendsIntoCapsule(color, dark: $0) }) { context, rect in
            context.setFillColor(color.withAlpha(1).cgColor)
            context.fill(rect)
        }
    }

    private static func imageDot(_ image: CGImage) -> NSImage {
        swatchImage { context, rect in
            context.interpolationQuality = .high
            AnnotationRenderer.drawImage(image, in: BackdropPainter.aspectFill(CGSize(width: image.width, height: image.height), in: rect), context: context)
        }
    }

    private static func pictureSymbol() -> NSImage {
        let image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func symbolChip(_ symbol: String, name: String, selected: Bool, action: @escaping () -> Void) -> CapsuleChip {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
        let chip = CapsuleChip(image: image, action: action)
        chip.isSelected = selected
        chip.setAccessibilityLabel(name)
        chip.toolTip = name
        return chip
    }

    private func textChip(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> CapsuleChip {
        let chip = CapsuleChip(title: title, prominent: prominent, action: action)
        chip.setAccessibilityLabel(title)
        return chip
    }

    private static func nearest(_ value: CGFloat, in steps: [CGFloat]) -> CGFloat {
        steps.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    // MARK: Icons

    /// An ink's chip: a 16 pt disc filling its 24 pt chip but for room for the ring of the chosen one.
    private static let inkChip: CGFloat = 24
    private static let inkInset: CGFloat = 4

    private static func dot(_ color: RGBA, selected: Bool) -> NSImage {
        let image = NSImage(size: CGSize(width: inkChip, height: inkChip), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let disc = rect.insetBy(dx: inkInset, dy: inkInset)
            context.setFillColor(color.withAlpha(1).cgColor)
            context.fillEllipse(in: disc)
            // An edge only on an ink the capsule would swallow (white on the light capsule, black on the dark):
            // a hairline around every ink read as a thin gray outline.
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if blendsIntoCapsule(color, dark: dark) { strokeInkEdge(context, around: disc, dark: dark) }
            // The chosen ink's ring is in the label ink, not the accent, which can be a hue beside the ink it rings
            // (a pink accent around red); 2 pt of the capsule show between the ring and the disc.
            if selected {
                context.setStrokeColor(NSColor.labelColor.cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            }
            return true
        }
        image.cacheMode = .never
        return image
    }

    /// Keep this color: a plus in an empty disc the size of an ink's, a swatch among the swatches.
    private static func saveDot() -> NSImage {
        let image = NSImage(size: CGSize(width: inkChip, height: inkChip), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let disc = rect.insetBy(dx: inkInset, dy: inkInset)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [2, 1.6])
            context.strokeEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(1.5)
            let arm: CGFloat = 3.5
            context.strokeLineSegments(between: [
                CGPoint(x: disc.midX - arm, y: disc.midY), CGPoint(x: disc.midX + arm, y: disc.midY),
                CGPoint(x: disc.midX, y: disc.midY - arm), CGPoint(x: disc.midX, y: disc.midY + arm),
            ])
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Whether an ink is too close to the capsule behind it to hold without an edge: nearly its luminance (a pale
    /// yellow on white), or a gray not far from it (black on the dark capsule). Yellow on white, saturated, holds.
    private static func blendsIntoCapsule(_ color: RGBA, dark: Bool) -> Bool {
        let capsule = dark ? RGBA(red: 0.17, green: 0.17, blue: 0.17).luminance : 1
        let ink = color.withAlpha(1).luminance
        let ratio = (max(ink, capsule) + 0.05) / (min(ink, capsule) + 0.05)
        let chroma = max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        return ratio < 1.25 || (chroma < 0.15 && ratio < 2)
    }

    /// The hue wheel that opens the color panel, an ink's size.
    private static func wheel(size: CGFloat = inkChip, inset: CGFloat = inkInset) -> NSImage {
        NSImage(size: CGSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let disc = rect.insetBy(dx: inset, dy: inset)
            let center = CGPoint(x: disc.midX, y: disc.midY)
            let steps = 36
            for step in 0..<steps {
                let start = CGFloat(step) / CGFloat(steps) * 2 * .pi
                let end = CGFloat(step + 1) / CGFloat(steps) * 2 * .pi + 0.02
                context.move(to: center)
                context.addArc(center: center, radius: disc.width / 2, startAngle: start, endAngle: end, clockwise: false)
                context.closePath()
                context.setFillColor(NSColor(hue: CGFloat(step) / CGFloat(steps), saturation: 0.85, brightness: 1, alpha: 1).cgColor)
                context.fillPath()
            }
            return true
        }
    }

    private static func sizeDot(diameter: CGFloat) -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func letter(size: CGFloat) -> NSImage {
        glyph("A", size: size)
    }

    private static func glyph(_ text: String, size: CGFloat = 12) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.black]
        let measured = (text as NSString).size(withAttributes: attributes)
        let image = NSImage(size: CGSize(width: max(measured.width, 16), height: 18), flipped: false) { rect in
            (text as NSString).draw(at: CGPoint(x: (rect.width - measured.width) / 2, y: (rect.height - measured.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func arrowIcon(_ head: Arrow.Head) -> NSImage {
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let arrow = Arrow(start: CGPoint(x: 3.5, y: 16.5), end: CGPoint(x: 16.5, y: 3.5), head: head)
            guard let path = ArrowPath.outline(arrow, width: head == .tapered ? 2.6 : 1.6, scale: 0.5) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(path)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A rounded square with a soft shadow below it: the mark shadow on or off.
    private static func shadowIcon() -> NSImage {
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let square = CGRect(x: 3.5, y: 3, width: 11, height: 11)
            context.setFillColor(CGColor(gray: 0, alpha: 0.32))
            context.addPath(CGPath(roundedRect: square.offsetBy(dx: 2.5, dy: 3), cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            context.setBlendMode(.clear)
            context.addPath(CGPath(roundedRect: square, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            context.setBlendMode(.normal)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1.5)
            context.addPath(CGPath(roundedRect: square, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func lineIcon(dashed: Bool) -> NSImage {
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let mark = Annotation(shape: .line(Line(start: CGPoint(x: 3, y: 17), end: CGPoint(x: 17, y: 3), dashed: dashed)), style: Style(lineWidth: 1.6, shadow: false))
            guard let path = MarkPaths.outline(of: mark, scale: 1) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(path)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func lookIcon(_ look: TextBlock.Look) -> NSImage {
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let image = NSImage(size: CGSize(width: 22, height: 20), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let size = ("A" as NSString).size(withAttributes: attributes)
            let point = CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
            switch look {
            case .plain:
                ("A" as NSString).draw(at: point, withAttributes: attributes)
            case .outlined:
                let stroked: [NSAttributedString.Key: Any] = [.font: font, .strokeColor: NSColor.black, .strokeWidth: 3.5]
                ("A" as NSString).draw(at: point, withAttributes: stroked)
            case .label:
                // A letter in a box, outlined: a solid block would read as a fill in the accent when
                // the chip is selected.
                let box = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2.5), xRadius: 4, yRadius: 4)
                box.lineWidth = 1.4
                NSColor.black.setStroke()
                box.stroke()
                let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.black]
                let size = ("A" as NSString).size(withAttributes: small)
                ("A" as NSString).draw(at: CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: small)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Names

    static func colorName(_ color: RGBA) -> String {
        switch color {
        case .red: String(localized: "Red", bundle: .module)
        case .orange: String(localized: "Orange", bundle: .module)
        case .yellow: String(localized: "Yellow", bundle: .module)
        case .green: String(localized: "Green", bundle: .module)
        case .blue: String(localized: "Blue", bundle: .module)
        case .purple: String(localized: "Purple", bundle: .module)
        case .black: String(localized: "Black", bundle: .module)
        case .white: String(localized: "White", bundle: .module)
        case .marker: String(localized: "Marker Yellow", bundle: .module)
        default: String(localized: "Custom Color", bundle: .module)
        }
    }

    static func name(of head: Arrow.Head) -> String {
        switch head {
        case .classic: String(localized: "Classic Arrow", bundle: .module)
        case .tapered: String(localized: "Tapered Arrow", bundle: .module)
        case .open: String(localized: "Open Arrow", bundle: .module)
        case .double: String(localized: "Double Arrow", bundle: .module)
        }
    }

    static func name(of look: TextBlock.Look) -> String {
        switch look {
        case .plain: String(localized: "Plain Text", bundle: .module)
        case .outlined: String(localized: "Outlined Text", bundle: .module)
        case .label: String(localized: "Label", bundle: .module)
        }
    }

    static func name(of numbering: Counter.Numbering) -> String {
        switch numbering {
        case .numbers: String(localized: "Numbers", bundle: .module)
        case .letters: String(localized: "Letters", bundle: .module)
        case .roman: String(localized: "Roman Numerals", bundle: .module)
        }
    }

    static func name(of method: Redaction.Method) -> String {
        switch method {
        case .solid: String(localized: "Solid", bundle: .module)
        case .blur: String(localized: "Blur", bundle: .module)
        case .pixelate: String(localized: "Pixelate", bundle: .module)
        }
    }
}

/// A quiet status in the capsule where a chip will come: a small spinner and a few words, as the text
/// panel shows its reading; without the spinner once there is nothing to wait for.
final class CapsuleStatus: NSStackView {
    init(_ text: String, busy: Bool = true) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        orientation = .horizontal
        spacing = 6
        // Busy, it ends the capsule, whose own end room is all there is past its words; done, Try Again follows it.
        edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: busy ? 0 : 4)
        if busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            addArrangedSubview(spinner)
        }
        addArrangedSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A chip in the style capsule: a borderless button with the capsule's own selected and hover fills; a symbol or
/// swatch names itself in a hover tag.
final class CapsuleChip: HoverTagButton {
    var isSelected = false {
        didSet { applyAppearance() }
    }
    /// Replaces the action given at creation, for chips that hand themselves to it.
    var handlerOverride: (() -> Void)?
    private let handler: () -> Void
    private var isHovered = false
    private let prominent: Bool
    /// A color swatch draws its own ring, and never a fill.
    private let isSwatch: Bool

    /// Every chip with a fill is this size, so its selected and hover fills match its neighbors'.
    static let side: CGFloat = 30
    /// A color swatch's chip, narrower: it has no fill to match.
    static let swatchWidth: CGFloat = 24

    /// No padding around the frame, as a button otherwise keeps for its bezel: the layer's fill covers the frame,
    /// and it must be the size the constraints give, or a symbol's chip fills the capsule's height as an oval.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    init(image: NSImage, action: @escaping () -> Void) {
        handler = action
        prominent = false
        isSwatch = false
        super.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        configure(width: Self.side)
    }

    init(swatch: NSImage, action: @escaping () -> Void) {
        handler = action
        prominent = false
        isSwatch = true
        super.init(frame: .zero)
        image = swatch
        imagePosition = .imageOnly
        configure(width: Self.swatchWidth)
    }

    init(title: String, prominent: Bool, action: @escaping () -> Void) {
        handler = action
        self.prominent = prominent
        isSwatch = false
        super.init(frame: .zero)
        self.title = title
        imagePosition = .noImage
        font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let width = (title as NSString).size(withAttributes: [.font: font!]).width + 28
        configure(width: width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(width: CGFloat) {
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
        // A swatch is as tall as it is wide; every other chip is the capsule's 30 tall.
        let height = min(width, Self.side)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        applyAppearance()
    }

    @objc private func clicked() {
        if let handlerOverride { handlerOverride() } else { handler() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if imagePosition == .noImage {
                attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            }
            // A prominent chip (Done) carries the selected fill: the accent is never a fill behind text.
            let selected = (isSelected || prominent) && !isSwatch
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let fill: CGColor = isSwatch ? .clear
                : selected ? ChipFill.selected(dark: dark, contrast: contrast)
                : isHovered ? ChipFill.hover(dark: dark, contrast: contrast)
                : .clear
            layer?.backgroundColor = fill
            contentTintColor = selected && !prominent ? .controlAccentColor : .labelColor
        }
        setAccessibilityValue(isSelected ? String(localized: "Selected", bundle: .module) : nil)
    }
}
