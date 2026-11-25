import AppKit
import OMSCore
import OMSDesign

/// The card an Option-click with the color picker opens: the color in every notation, each a click from
/// the clipboard; its contrast against a second color picked from the screen (WCAG 2 and APCA); and Pin.
/// It floats by where the color was picked, a level above pins, without taking focus unless it was opened
/// from the keyboard or VoiceOver is on; then Escape closes it, ⌘C copies its lead notation, and Tab moves
/// through its buttons with Full Keyboard Access. It goes away by itself when left alone; hovering it
/// holds it, and so does picking the second color.
public final class ColorCardHUD {
    /// Contrast… was pressed: the owner picks a second color off the screen for `showContrast(with:)`.
    public var onContrast: (() -> Void)?
    /// Pin was pressed; the card has gone.
    public var onPin: ((ScreenColor) -> Void)?

    private var panel: ColorCardPanel?
    private var card: ColorCard?
    private var anchor: CGRect = .zero
    private var dismissal: Task<Void, Never>?
    private var hovering = false
    private var interacted = false
    private var dragging = false
    private var hasBeenMoved = false
    private var picking = false
    private var windowLease: ActiveResources.Lease?
    private lazy var escapeKey = EscapeHotKey { [weak self] in self?.dismiss() }

    public init() {}

    isolated deinit {
        escapeKey.disarm()
    }

    public var isShowing: Bool { panel != nil }

    /// Shows `color` by `point`, in AppKit's global coordinates, replacing any card already up. Its title is
    /// the color in `format`, the notation clicks copy (Display P3 when that is an sRGB notation the color is
    /// outside of). `fromKeyboard`: the card takes the keys, as it does whenever VoiceOver is on.
    public func show(_ color: ScreenColor, near point: CGPoint, format: ColorFormat, fromKeyboard: Bool = false) {
        anchor = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
        picking = false
        hovering = false
        interacted = false
        dragging = false
        hasBeenMoved = false
        let isNew = panel == nil
        let panel = self.panel ?? makePanel()
        card?.show(color, format: format)
        place(panel)
        if isNew {
            appear(panel)
            windowLease = windowLease ?? ActiveResources.shared.acquire(.window)
        }
        panel.takesKeys = fromKeyboard || NSWorkspace.shared.isVoiceOverEnabled
        if panel.takesKeys {
            panel.makeKey()
            panel.makeFirstResponder(card?.firstControl)
        }
        updateEscapeKey()
        announce(card?.accessibilityLabel() ?? "")
        scheduleDismissal()
    }

    #if DEBUG
    /// The card's window behind the desktop picture of the main display, for a scripted capture of how it
    /// draws: nothing shows. Dismiss it afterwards.
    public func debugHide() -> NSWindow? {
        guard let panel else { return nil }
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let visible = NSScreen.main?.visibleFrame { panel.setFrameOrigin(CGPoint(x: visible.minX + 40, y: visible.minY + 40)) }
        dismissal?.cancel()
        return panel
    }
    #endif

    /// Holds the card while a second color is picked, or lets it go on as before.
    public func setPickingContrast(_ picking: Bool) {
        self.picking = picking
        updateEscapeKey()
        scheduleDismissal()
    }

    /// Shows the card's color against `other`, picked for it.
    public func showContrast(with other: ScreenColor) {
        picking = false
        guard let card, let panel else { return }
        card.showContrast(with: other)
        place(panel)
        updateEscapeKey()
        announce(card.contrastSummary ?? "")
        scheduleDismissal()
    }

    public func dismiss() {
        dismissal?.cancel()
        escapeKey.disarm()
        hovering = false
        interacted = false
        dragging = false
        hasBeenMoved = false
        guard let panel else { return }
        self.panel = nil
        card = nil
        picking = false
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            panel.orderOut(nil)
            if self?.panel == nil {
                self?.windowLease = nil
                MemoryRelief.returnFreedPages()
            }
        }
    }

    private func makePanel() -> ColorCardPanel {
        let card = ColorCard()
        card.onClose = { [weak self] in self?.dismiss() }
        card.onContrast = { [weak self] in
            self?.setPickingContrast(true)
            self?.onContrast?()
        }
        card.onPin = { [weak self] color in
            self?.dismiss()
            self?.onPin?(color)
        }
        card.onHover = { [weak self] inside in
            self?.hovering = inside
            if !inside { self?.interacted = false }
            self?.updateEscapeKey()
            self?.scheduleDismissal()
        }
        card.onDragStateChange = { [weak self] isDragging in
            self?.dragging = isDragging
            if isDragging {
                self?.hasBeenMoved = true
                self?.interacted = true
            }
            self?.updateEscapeKey()
            self?.scheduleDismissal()
        }
        card.onResize = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.place(panel)
        }
        let panel = ColorCardPanel()
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.onCopy = { [weak card] in card?.copyLead() }
        panel.onClick = { [weak self] in
            self?.interacted = true
            self?.updateEscapeKey()
            self?.scheduleDismissal()
        }
        panel.contentView = card
        self.panel = panel
        self.card = card
        return panel
    }

    /// Below the point, centered on it; above when there is no room below; kept on screen.
    /// If the user dragged the card elsewhere, keeps its top-left corner in place while resizing.
    private func place(_ panel: NSPanel) {
        guard let card else { return }
        let size = card.fittingSize()
        let margin = ColorCard.margin
        if hasBeenMoved {
            let current = panel.frame
            let screen = NSScreen.screens.first { $0.frame.intersects(current) } ?? NSScreen.main
            let visible = (screen?.visibleFrame ?? current).insetBy(dx: 8 - margin, dy: 8 - margin)
            var origin = CGPoint(x: current.minX, y: current.maxY - size.height)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            panel.setFrame(CGRect(origin: origin, size: size).integral, display: true)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? anchor).insetBy(dx: 8 - margin, dy: 8 - margin)
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 - size.height + margin)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 6 - margin
            if origin.y + size.height > visible.maxY { origin.y = max(visible.minY, visible.maxY - size.height) }
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        panel.setFrame(CGRect(origin: origin, size: size).integral, display: true)
    }

    /// A short fade and rise, or nothing with Reduce Motion, as the text result card appears.
    private func appear(_ panel: NSPanel) {
        panel.orderFrontRegardless()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            return
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.slide
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -6
        rise.toValue = 0
        rise.duration = Theme.Motion.slide
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        card?.layer?.add(rise, forKey: "rise")
    }

    /// Arms Escape without stealing focus whenever the card is hovered or clicked (and not already key).
    private func updateEscapeKey() {
        guard let panel, !picking else {
            escapeKey.disarm()
            return
        }
        if !panel.takesKeys, hovering || interacted {
            escapeKey.arm()
        } else {
            escapeKey.disarm()
        }
    }

    /// Gone after 15 s left alone, held while hovered, dragged, or while a second color is picked; with VoiceOver,
    /// a minute, long enough to reach its buttons.
    private func scheduleDismissal() {
        dismissal?.cancel()
        guard !hovering, !picking, !dragging, panel != nil else { return }
        let delay: Duration = NSWorkspace.shared.isVoiceOverEnabled ? .seconds(60) : .seconds(15)
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func announce(_ message: String) {
        guard let card, !message.isEmpty else { return }
        VoiceOver.announce(message, from: card)
    }
}

/// The card's panel: the text result card's floating manners, a level above pins (as Quick Access is), and
/// able to take the keys when the card asks: Escape closes the card and ⌘C copies its lead notation.
final class ColorCardPanel: NSPanel {
    var takesKeys = false
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        autorecalculatesKeyViewLoop = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { takesKeys }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onClick?()
        }
        if event.type == .keyDown, event.keyCode == 53 {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopy?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A static label that passes mouse events through to its parent card (for header dragging and
/// whole-row click-to-copy) while remaining readable to VoiceOver.
private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The card itself, in the text result card's materials: a swatch and the hex; a row for each notation
/// with its copy button; the contrast against a second color once there is one; Contrast… and Pin.
final class ColorCard: NSView {
    var onClose: (() -> Void)?
    var onContrast: (() -> Void)?
    var onPin: ((ScreenColor) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// The card's header started or finished being dragged.
    var onDragStateChange: ((Bool) -> Void)?
    /// The card changed height (the contrast came in); the panel takes its new size.
    var onResize: (() -> Void)?
    /// Destination pasteboard for copies; tests override to avoid mutating the general clipboard.
    var pasteboard: NSPasteboard = .general

    /// Room for the shadow to fade out completely: twice its blur plus its drop.
    static let margin: CGFloat = Theme.Shadow.radius * 2 + Theme.Shadow.drop
    /// Wide enough for the longest notation, Display P3's, to show whole: each row shows what it copies.
    static let width: CGFloat = 368
    private static let padding: CGFloat = 14
    private static let rowHeight: CGFloat = 26
    private static let labelWidth: CGFloat = 74

    private let background = CALayer()
    private let swatch = CALayer()
    private let title = PassThroughLabel(labelWithString: "")
    private let subtitle = PassThroughLabel(labelWithString: "")
    private let closeButton = CardButton(style: .chipIcon, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private(set) var rows: [(format: ColorFormat, label: NSTextField, value: NSTextField, copy: CardButton, highlight: CALayer)] = []
    private let firstDivider = CALayer()
    private let secondDivider = CALayer()
    // Contrast.
    private let otherLabel = NSTextField(labelWithString: String(localized: "Against", bundle: .module))
    private let otherSwatch = CALayer()
    private let otherValue = NSTextField(labelWithString: "")
    private let swapButton = CardButton(style: .chipIcon, title: String(localized: "Swap Text and Background", bundle: .module), symbolName: "arrow.left.arrow.right")
    private let wcagLabel = NSTextField(labelWithString: "WCAG 2")
    private let wcagValue = NSTextField(labelWithString: "")
    private let wcagVerdict = NSTextField(labelWithString: "")
    private let apcaLabel = NSTextField(labelWithString: "APCA")
    private let apcaValue = NSTextField(labelWithString: "")
    private let apcaVerdict = NSTextField(labelWithString: "")
    private let contrastButton = CardButton(style: .chip, title: String(localized: "Contrast…", bundle: .module), symbolName: "circle.lefthalf.filled")
    private let pinButton = CardButton(style: .chip, title: String(localized: "Pin", bundle: .module), symbolName: "pin")

    private var color: ScreenColor?
    /// The notation the title shows and ⌘C copies.
    private var lead: ColorFormat = .hex
    /// The second color; the card's own color is the text on it, until swapped.
    private var other: ScreenColor?
    private var swapped = false
    private var copyFeedback: [ColorFormat: Task<Void, Never>] = [:]
    private(set) var headerDragRect: CGRect = .zero
    private var hoveredRowIndex: Int?
    private var pressedRowIndex: Int?
    private var isDraggingHeader = false
    private var dragStartScreen: CGPoint?
    private var dragStartWindowOrigin: CGPoint?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        background.cornerRadius = Theme.Radius.card
        background.cornerCurve = .continuous
        background.shadowColor = .black
        background.shadowOpacity = Theme.Shadow.opacity
        background.shadowRadius = Theme.Shadow.radius
        background.shadowOffset = CGSize(width: 0, height: Theme.Shadow.drop)
        layer?.addSublayer(background)
        for well in [swatch, otherSwatch] {
            well.cornerCurve = .continuous
            well.borderWidth = 0.5
            layer?.addSublayer(well)
        }
        swatch.cornerRadius = 7
        otherSwatch.cornerRadius = 4
        for divider in [firstDivider, secondDivider] { layer?.addSublayer(divider) }

        title.font = Theme.Typeface.reading(size: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = Theme.Typeface.label(size: 11, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        for format in ColorFormat.allCases {
            let highlight = CALayer()
            highlight.cornerRadius = 6
            highlight.cornerCurve = .continuous
            layer?.addSublayer(highlight)
            let label = PassThroughLabel(labelWithString: format.title)
            label.font = Theme.Typeface.label(size: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            let value = PassThroughLabel(labelWithString: "")
            value.font = Theme.Typeface.reading(size: 12, weight: .medium)
            value.textColor = .labelColor
            value.lineBreakMode = .byTruncatingMiddle
            let copy = CardButton(style: .chipIcon, title: String(localized: "Copy \(format.title)", bundle: .module), symbolName: "doc.on.doc")
            copy.target = self
            copy.action = #selector(copyRow(_:))
            copy.tag = rows.count
            rows.append((format, label, value, copy, highlight))
            for view in [label, value, copy] as [NSView] { addSubview(view) }
        }
        for label in [otherLabel, wcagLabel, apcaLabel] {
            label.font = Theme.Typeface.label(size: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        otherValue.font = Theme.Typeface.reading(size: 12, weight: .medium)
        otherValue.textColor = .labelColor
        for value in [wcagValue, apcaValue] {
            value.font = Theme.Typeface.reading(size: 13, weight: .semibold)
            value.textColor = .labelColor
        }
        for verdict in [wcagVerdict, apcaVerdict] {
            verdict.font = Theme.Typeface.label(size: 11, weight: .medium)
            verdict.textColor = .secondaryLabelColor
            verdict.lineBreakMode = .byTruncatingTail
        }
        closeButton.target = self
        closeButton.action = #selector(close)
        swapButton.target = self
        swapButton.action = #selector(swap)
        contrastButton.target = self
        contrastButton.action = #selector(pickContrast)
        pinButton.target = self
        pinButton.action = #selector(pin)
        for view in [title, subtitle, closeButton, otherLabel, otherValue, swapButton, wcagLabel, wcagValue, wcagVerdict,
                     apcaLabel, apcaValue, apcaVerdict, contrastButton, pinButton] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func displayOptionsChanged() {
        applyAppearance()
        for view in subviews { view.needsDisplay = true }
    }

    // MARK: Content

    func show(_ color: ScreenColor, format: ColorFormat) {
        self.color = color
        other = nil
        swapped = false
        // The notation clicks copy leads, unless it is an sRGB one the color is outside of.
        let sRGBNotation = format == .hex || format == .rgb || format == .hsl
        lead = sRGBNotation && !color.isInSRGB ? .displayP3 : format
        title.stringValue = color.string(in: lead)
        // A long notation steps the title down a size rather than cutting it.
        title.font = Theme.Typeface.reading(size: title.stringValue.count > 12 ? 13 : 15, weight: .semibold)
        // Said only when it matters: the common case says nothing.
        subtitle.stringValue = color.isInSRGB ? "" : String(localized: "Outside sRGB: HEX, RGB, and HSL are the closest", bundle: .module)
        subtitle.isHidden = color.isInSRGB
        for row in rows {
            row.value.stringValue = color.string(in: row.format)
            row.copy.symbolName = "doc.on.doc"
        }
        contrastButton.title = String(localized: "Contrast…", bundle: .module)
        refreshContrast()
        applyAppearance()
        setAccessibilityLabel(String(localized: "Color \(title.stringValue)", bundle: .module))
        needsLayout = true
    }

    /// The first button the keys go to: the lead notation's copy button.
    var firstControl: NSView? {
        rows.first { $0.format == lead }?.copy
    }

    /// Copies the lead notation, as ⌘C does, with the row's button saying so.
    func copyLead() {
        guard let row = rows.first(where: { $0.format == lead }) else { return }
        copyRow(row.copy)
    }

    func showContrast(with other: ScreenColor) {
        self.other = other
        swapped = false
        contrastButton.title = String(localized: "Pick Another…", bundle: .module)
        refreshContrast()
        needsLayout = true
        onResize?()
    }

    /// What VoiceOver hears when the contrast comes in.
    var contrastSummary: String? {
        guard !wcagValue.isHidden else { return nil }
        return [wcagLabel.stringValue, wcagValue.stringValue, wcagVerdict.stringValue, apcaLabel.stringValue, apcaValue.stringValue, apcaVerdict.stringValue]
            .joined(separator: ", ")
    }

    private var showsContrast: Bool { other != nil }

    private func refreshContrast() {
        let contrastViews: [NSView] = [otherLabel, otherValue, swapButton, wcagLabel, wcagValue, wcagVerdict, apcaLabel, apcaValue, apcaVerdict]
        guard let color, let other else {
            contrastViews.forEach { $0.isHidden = true }
            secondDivider.isHidden = true
            otherSwatch.isHidden = true
            return
        }
        contrastViews.forEach { $0.isHidden = false }
        secondDivider.isHidden = false
        otherSwatch.isHidden = false
        let (text, background) = swapped ? (other, color) : (color, other)
        otherLabel.stringValue = swapped ? String(localized: "Text", bundle: .module) : String(localized: "Background", bundle: .module)
        otherValue.stringValue = other.hex
        otherSwatch.backgroundColor = other.cgColor
        let ratio = text.wcagContrast(with: background)
        wcagValue.stringValue = ScreenColor.ratioText(ratio)
        wcagVerdict.stringValue = Self.wcagVerdict(ratio)
        let lightness = ScreenColor.apcaContrast(text: text, background: background)
        apcaValue.stringValue = "Lc \(Int(lightness.rounded()))".replacingOccurrences(of: "-", with: "−")
        apcaVerdict.stringValue = Self.apcaVerdict(abs(lightness))
        swapButton.title = swapped
            ? String(localized: "Make \(color.hex) the Text", bundle: .module)
            : String(localized: "Make \(color.hex) the Background", bundle: .module)
    }

    /// Which of WCAG 2's levels the ratio meets.
    static func wcagVerdict(_ ratio: Double) -> String {
        if ratio >= 7 { return String(localized: "AAA", bundle: .module) }
        if ratio >= 4.5 { return String(localized: "AA, AAA for large text", bundle: .module) }
        if ratio >= 3 { return String(localized: "AA for large text only", bundle: .module) }
        return String(localized: "Fails AA", bundle: .module)
    }

    /// What APCA's guidance allows at that lightness contrast.
    static func apcaVerdict(_ lightness: Double) -> String {
        if lightness >= 90 { return String(localized: "Any text", bundle: .module) }
        if lightness >= 75 { return String(localized: "Body text", bundle: .module) }
        if lightness >= 60 { return String(localized: "Large or bold text", bundle: .module) }
        if lightness >= 45 { return String(localized: "Headlines", bundle: .module) }
        if lightness >= 30 { return String(localized: "Placeholder and disabled text", bundle: .module) }
        return String(localized: "Too low for text", bundle: .module)
    }

    // MARK: Layout

    func fittingSize() -> CGSize {
        CGSize(width: Self.width + Self.margin * 2, height: contentHeight() + Self.margin * 2)
    }

    private func contentHeight() -> CGFloat {
        var height = Self.padding * 2
        height += 34 + 10                                   // header, then the first divider's space
        height += CGFloat(rows.count) * Self.rowHeight
        if showsContrast { height += 10 + 3 * Self.rowHeight }
        height += 12 + 26                                   // the buttons
        return ceil(height)
    }

    override func layout() {
        super.layout()
        // Before the panel has its size, the card would be a null rectangle, whose infinite edges make NaN
        // frames for the layers, which Core Animation refuses.
        guard bounds.width > Self.margin * 2, bounds.height > Self.margin * 2 else { return }
        let card = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = card
        background.shadowPath = .continuousRoundedRect(background.bounds, radius: Theme.Radius.card)
        let left = card.minX + Self.padding
        let right = card.maxX - Self.padding
        var y = card.minY + Self.padding
        swatch.frame = CGRect(x: left, y: y + 3, width: 28, height: 28)
        CATransaction.commit()

        let textLeft = left + 28 + 10
        closeButton.frame = CGRect(x: right - 24, y: y, width: 24, height: 24)
        // Text fields inset their glyphs by 2 pt. Without a subtitle the title centers on the swatch.
        let titleY = subtitle.isHidden ? y + 3 + (28 - 19) / 2 : y
        title.frame = CGRect(x: textLeft - 2, y: titleY, width: closeButton.frame.minX - 8 - textLeft, height: 19)
        subtitle.frame = CGRect(x: textLeft - 2, y: y + 19, width: right - textLeft + 2, height: 15)
        y += 34 + 5
        headerDragRect = CGRect(x: card.minX, y: card.minY, width: card.width, height: y - card.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        firstDivider.frame = CGRect(x: left, y: y, width: right - left, height: 1 / (window?.backingScaleFactor ?? 2))
        CATransaction.commit()
        y += 5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in rows {
            row.highlight.frame = CGRect(x: card.minX + 8, y: y, width: card.width - 16, height: Self.rowHeight)
            layoutRow(label: row.label, value: row.value, trailing: row.copy, y: y, left: left, right: right)
            y += Self.rowHeight
        }
        CATransaction.commit()
        if showsContrast {
            y += 5
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            secondDivider.frame = CGRect(x: left, y: y, width: right - left, height: 1 / (window?.backingScaleFactor ?? 2))
            otherSwatch.frame = CGRect(x: left + Self.labelWidth, y: y + 5 + (Self.rowHeight - 16) / 2, width: 16, height: 16)
            CATransaction.commit()
            y += 5
            otherLabel.frame = CGRect(x: left - 2, y: y + 5, width: Self.labelWidth, height: 16)
            otherValue.frame = CGRect(x: left + Self.labelWidth + 16 + 6 - 2, y: y + 4, width: right - 24 - 8 - (left + Self.labelWidth + 22), height: 17)
            swapButton.frame = CGRect(x: right - 24, y: y + 1, width: 24, height: 24)
            y += Self.rowHeight
            for (label, value, verdict) in [(wcagLabel, wcagValue, wcagVerdict), (apcaLabel, apcaValue, apcaVerdict)] {
                label.frame = CGRect(x: left - 2, y: y + 5, width: Self.labelWidth, height: 16)
                let valueWidth = ceil(value.intrinsicContentSize.width)
                value.frame = CGRect(x: left + Self.labelWidth - 2, y: y + 3, width: valueWidth, height: 19)
                let verdictLeft = value.frame.maxX + 8
                verdict.frame = CGRect(x: verdictLeft, y: y + 5, width: max(0, right - verdictLeft), height: 16)
                y += Self.rowHeight
            }
        }
        y += 12
        let contrastSize = contrastButton.intrinsicContentSize
        contrastButton.frame = CGRect(x: left, y: y, width: contrastSize.width, height: contrastSize.height)
        let pinSize = pinButton.intrinsicContentSize
        pinButton.frame = CGRect(x: contrastButton.frame.maxX + 8, y: y, width: pinSize.width, height: pinSize.height)
    }

    private func layoutRow(label: NSTextField, value: NSTextField, trailing: NSView, y: CGFloat, left: CGFloat, right: CGFloat) {
        label.frame = CGRect(x: left - 2, y: y + 5, width: Self.labelWidth, height: 16)
        trailing.frame = CGRect(x: right - 24, y: y + 1, width: 24, height: 24)
        value.frame = CGRect(x: left + Self.labelWidth - 2, y: y + 4, width: trailing.frame.minX - 8 - (left + Self.labelWidth - 2), height: 17)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// The text result card's materials, resolved for this view's appearance.
    private func applyAppearance() {
        let dark = effectiveAppearance.isDark
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.backgroundColor = Theme.Material.cardFill(dark: dark)
        background.borderWidth = Theme.Material.edgeWidth(contrast: increaseContrast)
        background.borderColor = Theme.Material.edge(dark: dark, contrast: increaseContrast)
        // The capsule swatch edge, so a white or a near-black color still reads as a swatch.
        let edge = dark ? CGColor(gray: 1, alpha: increaseContrast ? 0.6 : 0.38) : CGColor(gray: 0, alpha: increaseContrast ? 0.4 : 0.18)
        for well in [swatch, otherSwatch] {
            well.borderColor = edge
            well.borderWidth = increaseContrast ? 1 : 0.5
        }
        swatch.backgroundColor = color?.cgColor
        let divider = Theme.cgColor(.separatorColor, for: effectiveAppearance)
        firstDivider.backgroundColor = divider
        secondDivider.backgroundColor = divider
        CATransaction.commit()
        updateRowHighlights()
    }

    private func updateRowHighlights() {
        let dark = effectiveAppearance.isDark
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, row) in rows.enumerated() {
            if pressedRowIndex == index && hoveredRowIndex == index {
                row.highlight.backgroundColor = Theme.ChipFill.selectedColor(dark: dark, contrast: increaseContrast)
            } else if hoveredRowIndex == index {
                row.highlight.backgroundColor = Theme.ChipFill.hoverColor(dark: dark, contrast: increaseContrast)
            } else {
                row.highlight.backgroundColor = nil
            }
        }
        CATransaction.commit()
    }

    // MARK: Pointer and actions

    func rowIndex(at point: CGPoint) -> Int? {
        rows.indices.first { rows[$0].highlight.frame.contains(point) }
    }

    func isInHeaderDragArea(_ point: CGPoint) -> Bool {
        headerDragRect.contains(point) && !closeButton.frame.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredRowIndex = rowIndex(at: point)
        updateRowHighlights()
        onHover?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = rowIndex(at: point)
        if index != hoveredRowIndex {
            hoveredRowIndex = index
            updateRowHighlights()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredRowIndex != nil {
            hoveredRowIndex = nil
            updateRowHighlights()
        }
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Clicking or dragging the card must not bring this app in front of the one being worked in.
        NSApp.preventWindowOrdering()
        let point = convert(event.locationInWindow, from: nil)
        if let index = rowIndex(at: point) {
            pressedRowIndex = index
            hoveredRowIndex = index
            updateRowHighlights()
            return
        }
        if isInHeaderDragArea(point), let origin = window?.frame.origin {
            isDraggingHeader = true
            dragStartScreen = NSEvent.mouseLocation
            dragStartWindowOrigin = origin
            onDragStateChange?(true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isDraggingHeader, let startScreen = dragStartScreen, let startOrigin = dragStartWindowOrigin {
            let current = NSEvent.mouseLocation
            window?.setFrameOrigin(CGPoint(
                x: startOrigin.x + (current.x - startScreen.x),
                y: startOrigin.y + (current.y - startScreen.y)
            ))
            return
        }
        if pressedRowIndex != nil {
            let point = convert(event.locationInWindow, from: nil)
            hoveredRowIndex = rowIndex(at: point)
            updateRowHighlights()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingHeader {
            isDraggingHeader = false
            dragStartScreen = nil
            dragStartWindowOrigin = nil
            onDragStateChange?(false)
            return
        }
        if let pressed = pressedRowIndex {
            pressedRowIndex = nil
            let point = convert(event.locationInWindow, from: nil)
            let released = rowIndex(at: point)
            hoveredRowIndex = released
            updateRowHighlights()
            if released == pressed {
                copyRow(at: pressed)
            }
        }
    }

    func copyRow(at index: Int) {
        guard let color, rows.indices.contains(index) else { return }
        let row = rows[index]
        pasteboard.clearContents()
        pasteboard.setString(color.string(in: row.format), forType: .string)
        // The button says it is done for a moment, as the translation lens's copy button does.
        row.copy.symbolName = "checkmark"
        copyFeedback[row.format]?.cancel()
        copyFeedback[row.format] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            self.rows.first { $0.format == row.format }?.copy.symbolName = "doc.on.doc"
        }
        VoiceOver.announce(String(localized: "Copied \(color.string(in: row.format))", bundle: .module), from: self)
    }

    @objc private func copyRow(_ sender: CardButton) {
        copyRow(at: sender.tag)
    }

    @objc private func close() { onClose?() }
    @objc private func pickContrast() { onContrast?() }

    @objc private func pin() {
        if let color { onPin?(color) }
    }

    @objc private func swap() {
        swapped.toggle()
        refreshContrast()
        needsLayout = true
        if let summary = contrastSummary {
            VoiceOver.announce(summary, from: self, priority: .medium)
        }
    }
}
