import AppKit
import OMSCore

/// The optional card after Capture Text and Capture Formula (off by default; the selection's highlight is
/// the usual feedback): what went to the clipboard, how many characters, and for text a switch between
/// keeping and joining line breaks. It floats by the selection without taking focus and goes away by
/// itself; hovering it holds it.
public final class TextResultHUD {
    public enum State: Equatable {
        /// The text is on the clipboard. `joined` says whether wrapped lines were joined, `canJoin`
        /// whether joining changes anything.
        case copied(text: String, joined: Bool, canJoin: Bool)
        /// Nothing readable in the selection.
        case empty
        /// The LaTeX of the formula in the selection is on the clipboard.
        case copiedFormula(latex: String)
        /// The formula pack read no whole formula in the selection.
        case noFormula
    }

    /// The line-break switch was pressed.
    public var onToggleJoin: (() -> Void)?

    private var panel: TextResultPanel?
    private var card: TextResultCard?
    private var anchor: CGRect = .zero
    private var state: State?
    private var dismissal: Task<Void, Never>?
    private var hovering = false
    private var windowLease: ActiveResources.Lease?

    public init() {}

    /// Shows `state` by `selection`, in AppKit's global coordinates.
    public func show(_ state: State, near selection: CGRect) {
        anchor = selection
        let isNew = panel == nil
        let panel = self.panel ?? makePanel()
        card?.show(state)
        place(panel)
        if isNew {
            appear(panel)
            if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }
        }
        if state != self.state { announce(state) }
        self.state = state
        scheduleDismissal()
    }

    public func dismiss() {
        dismissal?.cancel()
        guard let panel else { return }
        self.panel = nil
        card = nil
        state = nil
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
        let card = TextResultCard()
        card.onToggleJoin = { [weak self] in self?.onToggleJoin?() }
        card.onClose = { [weak self] in self?.dismiss() }
        card.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.scheduleDismissal()
        }
        let panel = TextResultPanel()
        panel.contentView = card
        self.panel = panel
        self.card = card
        return panel
    }

    /// Below the selection, centered on it; above when there is no room below; kept on screen.
    private func place(_ panel: NSPanel) {
        guard let card else { return }
        let width = min(max(anchor.width, 300), 420)
        let size = card.fittingSize(width: width)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        // The panel is larger than the card by the shadow's margin; the card itself keeps 10 pt from the
        // selection and 8 pt from the screen's edges.
        let margin = TextResultCard.margin
        let visible = (screen?.visibleFrame ?? anchor).insetBy(dx: 8 - margin, dy: 8 - margin)
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 10 - size.height + margin)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 10 - margin
            if origin.y + size.height > visible.maxY { origin.y = max(visible.minY, anchor.minY + 10 - margin) }
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        panel.setFrame(CGRect(origin: origin, size: size).integral, display: true)
    }

    /// A short fade and rise, or nothing with Reduce Motion. The rise moves the card's layer, never the
    /// window: the card can change size mid-animation (switching line breaks), and a window frame
    /// animation would pull the new size back to the old one.
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

    /// Gone after a few seconds, longer when there is text to read; held while hovered. One timer at a
    /// time, and none while the card is held.
    private func scheduleDismissal() {
        dismissal?.cancel()
        guard !hovering, let state else { return }
        // With VoiceOver, the card stays long enough to reach its buttons by moving to it.
        let delay: Duration = if NSWorkspace.shared.isVoiceOverEnabled {
            .seconds(20)
        } else {
            switch state {
            case .copied, .copiedFormula: .seconds(4)
            case .empty, .noFormula: .seconds(2.5)
            }
        }
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func announce(_ state: State) {
        let message = switch state {
        case .copied(let text, _, _): TextResultCard.copiedCount(text)
        case .empty: String(localized: "No text found", bundle: .module)
        case .copiedFormula: String(localized: "Copied the formula as LaTeX", bundle: .module)
        case .noFormula: String(localized: "No formula found", bundle: .module)
        }
        guard let element = card else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// A transparent floating panel that never takes focus; the card draws its own shadow.
final class TextResultPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The card itself: a header with a symbol, a title, and the character count; up to three lines of
/// what was copied; and the line-break switch.
final class TextResultCard: NSView {
    var onToggleJoin: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    /// Room for the shadow to fade out completely: twice its blur plus its drop.
    static let margin: CGFloat = Theme.Shadow.radius * 2 + Theme.Shadow.drop
    private static let padding: CGFloat = 14

    private let background = CALayer()
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let joinButton = CardButton(style: .chip, title: "", symbolName: "arrow.right.to.line")
    private let closeButton = CardButton(style: .chipIcon, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private var state: TextResultHUD.State = .empty

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        background.cornerRadius = Theme.Radius.card
        background.cornerCurve = .continuous
        // The floating card's soft lift, as on Quick Access cards; the view is flipped, so a positive
        // offset falls downward.
        background.shadowColor = .black
        background.shadowOpacity = Theme.Shadow.opacity
        background.shadowRadius = Theme.Shadow.radius
        background.shadowOffset = CGSize(width: 0, height: Theme.Shadow.drop)
        layer?.addSublayer(background)

        title.font = Theme.Typeface.label(size: 13, weight: .semibold)
        title.textColor = .labelColor
        count.font = Theme.Typeface.reading(size: 12, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .labelColor
        preview.maximumNumberOfLines = 3
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.truncatesLastVisibleLine = true
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        joinButton.target = self
        joinButton.action = #selector(toggleJoin)
        closeButton.target = self
        closeButton.action = #selector(close)
        for view in [symbol, title, count, preview, detail, joinButton, closeButton] as [NSView] {
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

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func displayOptionsChanged() {
        applyAppearance()
        joinButton.needsDisplay = true
        closeButton.needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Every character a paste will contain, spaces and line breaks included.
    static func copiedCount(_ text: String) -> String {
        String(localized: "Copied \(text.count) characters", bundle: .module)
    }

    func show(_ state: TextResultHUD.State) {
        self.state = state
        let symbolName: String
        switch state {
        case .copied(let text, let joined, let canJoin):
            symbolName = "checkmark.circle.fill"
            title.stringValue = String(localized: "Copied", bundle: .module)
            count.stringValue = String(localized: "\(text.count) characters", bundle: .module)
            preview.stringValue = text
            joinButton.title = joined
                ? String(localized: "Keep Line Breaks", bundle: .module)
                : String(localized: "Join Lines", bundle: .module)
            joinButton.symbolName = joined ? "text.alignleft" : "arrow.right.to.line"
            joinButton.isHidden = !canJoin
            preview.font = .systemFont(ofSize: 12)
            preview.lineBreakMode = .byTruncatingTail
        case .empty:
            symbolName = "text.magnifyingglass"
            title.stringValue = String(localized: "No text found", bundle: .module)
            count.stringValue = ""
            detail.stringValue = String(localized: "Try a larger area, or text with more contrast.", bundle: .module)
        case .copiedFormula(let latex):
            symbolName = "checkmark.circle.fill"
            title.stringValue = String(localized: "Copied LaTeX", bundle: .module)
            count.stringValue = String(localized: "\(latex.count) characters", bundle: .module)
            preview.stringValue = latex
            // LaTeX is code: fixed-width, as it would be pasted into an editor, and broken anywhere, since it has few
            // spaces to break at (by words, a formula was one line cut short).
            preview.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            preview.lineBreakMode = .byCharWrapping
            joinButton.isHidden = true
        case .noFormula:
            symbolName = "x.squareroot"
            title.stringValue = String(localized: "No formula found", bundle: .module)
            count.stringValue = ""
            detail.stringValue = String(localized: "Select just the formula, with a little room around it.", bundle: .module)
        }
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold).applying(.init(paletteColors: Self.symbolColors(for: state))))
        preview.isHidden = !Self.isCopied(state)
        joinButton.isHidden = joinButton.isHidden || !Self.isCopied(state)
        detail.isHidden = state != .empty && state != .noFormula
        setAccessibilityLabel([title.stringValue, count.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }

    /// The card's size at `width`, with the margin its shadow needs.
    func fittingSize(width: CGFloat) -> CGSize {
        CGSize(width: width + Self.margin * 2, height: contentHeight(width: width) + Self.margin * 2)
    }

    /// Where the title, the preview, the detail, and the chip start: the symbol hangs to their left.
    private static let column: CGFloat = padding + 18 + 7

    private func contentHeight(width: CGFloat) -> CGFloat {
        let inner = width - Self.column - Self.padding
        var height = Self.padding * 2 + 24
        if !preview.isHidden {
            height += 4 + previewHeight(width: inner)
        }
        if !detail.isHidden { height += 4 + 16 }
        if !joinButton.isHidden { height += 10 + 26 }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        let card = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = card
        background.shadowPath = CGPath(roundedRect: background.bounds, cornerWidth: Theme.Radius.card, cornerHeight: Theme.Radius.card, transform: nil)
        CATransaction.commit()

        let left = card.minX + Self.padding
        let right = card.maxX - Self.padding
        // Text fields inset their glyphs by 2 pt; frames sit 2 pt left so glyphs and chips share the column.
        let column = card.minX + Self.column
        var y = card.minY + Self.padding
        closeButton.frame = CGRect(x: right - 24, y: y, width: 24, height: 24)
        symbol.frame = CGRect(x: left, y: y + 3, width: 18, height: 18)
        let countWidth = ceil(count.intrinsicContentSize.width)
        count.frame = CGRect(x: closeButton.frame.minX - 10 - countWidth, y: y + 4, width: countWidth, height: 17)
        title.frame = CGRect(x: column - 2, y: y + 3, width: max(0, count.frame.minX - 8 - column), height: 18)
        y += 24
        if !preview.isHidden {
            y += 4
            let height = previewHeight(width: right - column)
            preview.frame = CGRect(x: column - 2, y: y, width: right - column + 2, height: height)
            y += height
        }
        if !detail.isHidden {
            y += 4
            detail.frame = CGRect(x: column - 2, y: y, width: right - column + 2, height: 16)
            y += 16
        }
        if !joinButton.isHidden {
            y += 10
            let size = joinButton.intrinsicContentSize
            joinButton.frame = CGRect(x: column, y: y, width: size.width, height: size.height)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// The reading capsule's materials, resolved for this view's appearance.
    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        background.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.96) : CGColor(gray: 1, alpha: 0.97)
        background.borderWidth = increaseContrast ? 1 : 0.5
        background.borderColor = switch (dark, increaseContrast) {
        case (true, true): CGColor(gray: 1, alpha: 0.5)
        case (true, false): CGColor(gray: 1, alpha: 0.12)
        case (false, true): CGColor(gray: 0, alpha: 0.35)
        case (false, false): CGColor(gray: 0, alpha: 0.08)
        }
        show(state)
    }

    private static func isCopied(_ state: TextResultHUD.State) -> Bool {
        switch state {
        case .copied, .copiedFormula: true
        case .empty, .noFormula: false
        }
    }

    /// A white check in a green disc, as on a saved Quick Access card; otherwise one quiet color.
    private static func symbolColors(for state: TextResultHUD.State) -> [NSColor] {
        switch state {
        case .copied, .copiedFormula: [.white, .systemGreen]
        case .empty, .noFormula: [.secondaryLabelColor]
        }
    }

    /// At most three lines of preview; the field truncates what does not fit.
    private func previewHeight(width: CGFloat) -> CGFloat {
        let full = preview.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = NSLayoutManager().defaultLineHeight(for: preview.font ?? .systemFont(ofSize: 12))
        return ceil(min(full, lineHeight * 3))
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

    @objc private func toggleJoin() { onToggleJoin?() }
    @objc private func close() { onClose?() }
}
