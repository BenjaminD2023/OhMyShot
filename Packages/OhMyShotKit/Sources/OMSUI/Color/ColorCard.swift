import AppKit
import OMSCore

/// The card an Option-click with the color picker opens: the color in every notation, each a click from
/// the clipboard; its contrast against a second color picked from the screen (WCAG 2 and APCA); and Pin.
/// It floats by where the color was picked without taking focus, and goes away by itself when left
/// alone; hovering it holds it, and so does picking the second color.
public final class ColorCardHUD {
    /// Contrast… was pressed: the owner picks a second color off the screen for `showContrast(with:)`.
    public var onContrast: (() -> Void)?
    /// Pin was pressed; the card has gone.
    public var onPin: ((ScreenColor) -> Void)?

    private var panel: TextResultPanel?
    private var card: ColorCard?
    private var anchor: CGRect = .zero
    private var dismissal: Task<Void, Never>?
    private var hovering = false
    private var picking = false
    private var windowLease: ActiveResources.Lease?

    public init() {}

    public var isShowing: Bool { panel != nil }

    /// Shows `color` by `point`, in AppKit's global coordinates, replacing any card already up.
    public func show(_ color: ScreenColor, near point: CGPoint) {
        anchor = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
        picking = false
        let isNew = panel == nil
        let panel = self.panel ?? makePanel()
        card?.show(color)
        place(panel)
        if isNew {
            appear(panel)
            windowLease = windowLease ?? ActiveResources.shared.acquire(.window)
        }
        announce(String(localized: "Color \(color.hex)", bundle: .module))
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
        scheduleDismissal()
    }

    /// Shows the card's color against `other`, picked for it.
    public func showContrast(with other: ScreenColor) {
        picking = false
        guard let card, let panel else { return }
        card.showContrast(with: other)
        place(panel)
        announce(card.contrastSummary ?? "")
        scheduleDismissal()
    }

    public func dismiss() {
        dismissal?.cancel()
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

    private func makePanel() -> TextResultPanel {
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
            self?.scheduleDismissal()
        }
        card.onResize = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.place(panel)
        }
        let panel = TextResultPanel()
        panel.contentView = card
        self.panel = panel
        self.card = card
        return panel
    }

    /// Below the point, centered on it; above when there is no room below; kept on screen.
    private func place(_ panel: NSPanel) {
        guard let card else { return }
        let size = card.fittingSize()
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let margin = ColorCard.margin
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

    /// Gone after 15 s left alone, held while hovered or while a second color is picked; with VoiceOver,
    /// a minute, long enough to reach its buttons.
    private func scheduleDismissal() {
        dismissal?.cancel()
        guard !hovering, !picking, panel != nil else { return }
        let delay: Duration = NSWorkspace.shared.isVoiceOverEnabled ? .seconds(60) : .seconds(15)
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func announce(_ message: String) {
        guard let card, !message.isEmpty else { return }
        NSAccessibility.post(element: card, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// The card itself, in the text result card's materials: a swatch and the hex; a row for each notation
/// with its copy button; the contrast against a second color once there is one; Contrast… and Pin.
final class ColorCard: NSView {
    var onClose: (() -> Void)?
    var onContrast: (() -> Void)?
    var onPin: ((ScreenColor) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// The card changed height (the contrast came in); the panel takes its new size.
    var onResize: (() -> Void)?

    /// Room for the shadow to fade out completely: twice its blur plus its drop.
    static let margin: CGFloat = Theme.Shadow.radius * 2 + Theme.Shadow.drop
    /// Wide enough for the longest notation, Display P3's, to show whole: each row shows what it copies.
    static let width: CGFloat = 368
    private static let padding: CGFloat = 14
    private static let rowHeight: CGFloat = 26
    private static let labelWidth: CGFloat = 74

    private let background = CALayer()
    private let swatch = CALayer()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let closeButton = CardButton(style: .chipIcon, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private var rows: [(format: ColorFormat, label: NSTextField, value: NSTextField, copy: CardButton)] = []
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
    /// The second color; the card's own color is the text on it, until swapped.
    private var other: ScreenColor?
    private var swapped = false
    private var copyFeedback: [ColorFormat: Task<Void, Never>] = [:]

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
        subtitle.font = Theme.Typeface.label(size: 11, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        for format in ColorFormat.allCases {
            let label = NSTextField(labelWithString: format.title)
            label.font = Theme.Typeface.label(size: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "")
            value.font = Theme.Typeface.reading(size: 12, weight: .medium)
            value.textColor = .labelColor
            value.lineBreakMode = .byTruncatingMiddle
            value.isSelectable = true
            let copy = CardButton(style: .chipIcon, title: String(localized: "Copy \(format.title)", bundle: .module), symbolName: "doc.on.doc")
            copy.target = self
            copy.action = #selector(copyRow(_:))
            copy.tag = rows.count
            rows.append((format, label, value, copy))
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

    func show(_ color: ScreenColor) {
        self.color = color
        other = nil
        swapped = false
        title.stringValue = color.hex
        subtitle.stringValue = color.isInSRGB
            ? String(localized: "Within sRGB", bundle: .module)
            : String(localized: "Outside sRGB: HEX, RGB, and HSL are the nearest", bundle: .module)
        for row in rows {
            row.value.stringValue = color.string(in: row.format)
            row.copy.symbolName = "doc.on.doc"
        }
        contrastButton.title = String(localized: "Contrast…", bundle: .module)
        refreshContrast()
        applyAppearance()
        setAccessibilityLabel(String(localized: "Color \(color.hex)", bundle: .module))
        needsLayout = true
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
        background.shadowPath = CGPath(roundedRect: background.bounds, cornerWidth: Theme.Radius.card, cornerHeight: Theme.Radius.card, transform: nil)
        let left = card.minX + Self.padding
        let right = card.maxX - Self.padding
        var y = card.minY + Self.padding
        swatch.frame = CGRect(x: left, y: y + 3, width: 28, height: 28)
        CATransaction.commit()

        let textLeft = left + 28 + 10
        closeButton.frame = CGRect(x: right - 24, y: y, width: 24, height: 24)
        // Text fields inset their glyphs by 2 pt.
        title.frame = CGRect(x: textLeft - 2, y: y, width: closeButton.frame.minX - 8 - textLeft, height: 19)
        subtitle.frame = CGRect(x: textLeft - 2, y: y + 19, width: right - textLeft + 2, height: 15)
        y += 34 + 5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        firstDivider.frame = CGRect(x: left, y: y, width: right - left, height: 1 / (window?.backingScaleFactor ?? 2))
        CATransaction.commit()
        y += 5
        for row in rows {
            layoutRow(label: row.label, value: row.value, trailing: row.copy, y: y, left: left, right: right)
            y += Self.rowHeight
        }
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
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.96) : CGColor(gray: 1, alpha: 0.97)
        background.borderWidth = increaseContrast ? 1 : 0.5
        background.borderColor = switch (dark, increaseContrast) {
        case (true, true): CGColor(gray: 1, alpha: 0.5)
        case (true, false): CGColor(gray: 1, alpha: 0.12)
        case (false, true): CGColor(gray: 0, alpha: 0.35)
        case (false, false): CGColor(gray: 0, alpha: 0.08)
        }
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
    }

    // MARK: Pointer and actions

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Clicking the card must not bring this app in front of the one being worked in.
        NSApp.preventWindowOrdering()
    }

    @objc private func copyRow(_ sender: CardButton) {
        guard let color, rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag]
        let pasteboard = NSPasteboard.general
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
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: String(localized: "Copied \(color.string(in: row.format))", bundle: .module),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
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
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: summary,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }
}
