import AppKit
import OMSCore

/// One result's lifetime. Pure timestamps keep hover/reuse/expiry behavior testable without waiting.
struct TextResultLifetime {
    private(set) var generation: UInt = 0
    private var countdown: CardCountdown?

    mutating func start(at now: TimeInterval, hovered: Bool, voiceOver: Bool, closeAfter: Int = 1) {
        generation &+= 1
        guard closeAfter > 0 else {
            countdown = nil
            return
        }
        let interval = TimeInterval(voiceOver ? max(20, closeAfter) : closeAfter)
        countdown = CardCountdown(interval: interval, at: now)
        if hovered { countdown?.hold(.pointer, at: now) }
    }

    mutating func setHovered(_ hovered: Bool, at now: TimeInterval) {
        guard var countdown, hovered != countdown.isHeld else { return }
        if hovered {
            countdown.hold(.pointer, at: now)
        } else {
            // A full interval after leaving, including the longer accessibility interval.
            countdown = CardCountdown(interval: countdown.interval, at: now)
        }
        self.countdown = countdown
    }

    mutating func stop() {
        generation &+= 1
        countdown = nil
    }

    func timeLeft(at now: TimeInterval) -> TimeInterval? { countdown?.timeLeft(at: now) }

    func isDue(at now: TimeInterval, generation: UInt) -> Bool {
        self.generation == generation && countdown?.isDue(at: now) == true
    }
}

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
        /// The text was read but left off the clipboard, which changed meanwhile; the card's Copy puts it there.
        case notCopied(text: String)
    }

    /// The line-break switch was pressed.
    public var onToggleJoin: (() -> Void)?
    /// Copy was pressed on a card whose text wasn't copied.
    public var onCopy: (() -> Void)?

    private var panel: TextResultPanel?
    private var card: TextResultCard?
    private var anchor: CGRect = .zero
    private var position: TextResultPosition = .belowSelection
    private var state: State?
    private var note: String?
    private var dismissal: Task<Void, Never>?
    private var lifetime = TextResultLifetime()
    private var windowLease: ActiveResources.Lease?

    public init() {}

    deinit { dismissal?.cancel() }

    /// Shows `state` by `selection`, in AppKit's global coordinates. `note` is a line under the text, such as who read
    /// it ("Read by Claude"), or why this Mac's reading was copied instead of the cloud model's.
    public func show(_ state: State, near selection: CGRect, position: TextResultPosition = .belowSelection, closeAfter: Int = 1, note: String? = nil) {
        anchor = selection
        self.position = position
        let isNew = panel == nil
        let panel = self.panel ?? makePanel()
        card?.show(state, note: note)
        place(panel)
        if isNew {
            appear(panel)
            if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }
        }
        if state != self.state || note != self.note { announce(state, note: note) }
        self.state = state
        self.note = note
        // A stationary pointer can already cover a newly shown/moved/resized card without an enter event.
        lifetime.start(at: Self.now, hovered: panel.frame.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin).contains(NSEvent.mouseLocation),
                       voiceOver: NSWorkspace.shared.isVoiceOverEnabled, closeAfter: closeAfter)
        scheduleDismissal()
    }

    public func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        lifetime.stop()
        guard let panel else { return }
        self.panel = nil
        card = nil
        state = nil
        note = nil
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
        // A fading old panel must never act on the next result's card.
        card.onToggleJoin = { [weak self, weak card] in
            guard let self, let card, self.card === card else { return }
            onToggleJoin?()
        }
        card.onCopy = { [weak self, weak card] in
            guard let self, let card, self.card === card else { return }
            onCopy?()
        }
        card.onClose = { [weak self, weak card] in
            guard let self, let card, self.card === card else { return }
            dismiss()
        }
        card.onHover = { [weak self, weak card] inside in
            guard let self, let card, self.card === card else { return }
            lifetime.setHovered(inside, at: Self.now)
            scheduleDismissal()
        }
        let panel = TextResultPanel()
        panel.contentView = card
        self.panel = panel
        self.card = card
        return panel
    }

    /// The selection's display, including point anchors from file/URL captures on a secondary display.
    static func displayIndex(for selection: CGRect, frames: [CGRect]) -> Int? {
        if selection.width == 0 || selection.height == 0 {
            return frames.firstIndex { $0.contains(CGPoint(x: selection.midX, y: selection.midY)) }
        }
        return frames.indices.filter { frames[$0].intersects(selection) }.max {
            let a = frames[$0].intersection(selection), b = frames[$1].intersection(selection)
            return a.width * a.height < b.width * b.height
        }
    }

    /// Frame includes the shadow margin. The card itself keeps the existing screen/selection gaps.
    static func frame(size: CGSize, near anchor: CGRect, position: TextResultPosition, visibleFrame: CGRect) -> CGRect {
        let margin = TextResultCard.margin
        let visible = visibleFrame.insetBy(dx: 8 - margin, dy: 8 - margin)
        var origin: CGPoint
        switch position {
        case .bottomLeft:
            origin = CGPoint(x: visibleFrame.minX + QuickAccessPlacement.edge - margin,
                             y: visibleFrame.minY + QuickAccessPlacement.edge - margin)
        case .belowSelection:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 10 - size.height + margin)
            if origin.y < visible.minY {
                origin.y = anchor.maxY + 10 - margin
                if origin.y + size.height > visible.maxY { origin.y = anchor.minY + 10 - margin }
            }
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(origin: origin, size: size).integral
    }

    private func place(_ panel: NSPanel) {
        guard let card else { return }
        let screens = NSScreen.screens
        let screen = Self.displayIndex(for: anchor, frames: screens.map(\.frame)).map { screens[$0] } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let width = min(max(anchor.width, 300), 420, max(1, visible.width - 16))
        let size = card.fittingSize(width: width)
        panel.setFrame(Self.frame(size: size, near: anchor, position: position, visibleFrame: visible), display: true)
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

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// One sleeping task, none while hovered. Every result starts fresh; an old task cannot close a new one.
    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = nil
        guard let delay = lifetime.timeLeft(at: Self.now) else { return }
        let generation = lifetime.generation
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, lifetime.generation == generation else { return }
            if lifetime.isDue(at: Self.now, generation: generation) {
                dismiss()
            } else {
                // Uptime pauses during system sleep; an early wake must keep the remaining interval scheduled.
                scheduleDismissal()
            }
        }
    }

    private func announce(_ state: State, note: String?) {
        let said = switch state {
        case .copied(let text, _, _): TextResultCard.copiedCount(text)
        case .empty: String(localized: "No text found", bundle: .module)
        case .copiedFormula: String(localized: "Copied the formula as LaTeX", bundle: .module)
        case .noFormula: String(localized: "No formula found", bundle: .module)
        case .notCopied: String(localized: "Not copied", bundle: .module)
        }
        let message = [said, note].compactMap { $0 }.joined(separator: ". ")
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
    var onCopy: (() -> Void)?
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
    /// Who read the text, or why this Mac's reading was copied instead: two lines at most.
    private let note = NSTextField(wrappingLabelWithString: "")
    private let joinButton = CardButton(style: .chip, title: "", symbolName: "arrow.right.to.line")
    private let closeButton = CardButton(style: .chipIcon, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private var state: TextResultHUD.State = .empty
    private var noteText: String?

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
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        // Wrapped by words and cut at its second line: a truncating break would measure, and show, one line.
        note.lineBreakMode = .byWordWrapping
        note.usesSingleLineMode = false
        note.cell?.wraps = true
        note.cell?.isScrollable = false
        note.cell?.truncatesLastVisibleLine = true
        joinButton.target = self
        joinButton.action = #selector(toggleJoin)
        closeButton.target = self
        closeButton.action = #selector(close)
        for view in [symbol, title, count, preview, detail, note, joinButton, closeButton] as [NSView] {
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

    func show(_ state: TextResultHUD.State, note: String? = nil) {
        self.state = state
        self.noteText = note
        self.note.stringValue = note ?? ""
        self.note.isHidden = note == nil
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
        case .notCopied(let text):
            symbolName = "doc.on.clipboard"
            title.stringValue = String(localized: "Not copied", bundle: .module)
            count.stringValue = String(localized: "\(text.count) characters", bundle: .module)
            preview.stringValue = text
            preview.font = .systemFont(ofSize: 12)
            preview.lineBreakMode = .byTruncatingTail
            // The chip copies instead of switching line breaks.
            joinButton.title = String(localized: "Copy", bundle: .module)
            joinButton.symbolName = "doc.on.doc"
            joinButton.isHidden = false
        }
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold).applying(.init(paletteColors: Self.symbolColors(for: state))))
        preview.isHidden = !Self.isCopied(state)
        joinButton.isHidden = joinButton.isHidden || !Self.isCopied(state)
        detail.isHidden = state != .empty && state != .noFormula
        setAccessibilityLabel([title.stringValue, count.stringValue, noteText ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
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
        if !note.isHidden { height += 4 + noteHeight(width: inner) }
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
        if !note.isHidden {
            y += 4
            let height = noteHeight(width: right - column)
            note.frame = CGRect(x: column - 2, y: y, width: right - column + 2, height: height)
            y += height
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
        show(state, note: noteText)
    }

    /// Whether the card shows the text read.
    private static func isCopied(_ state: TextResultHUD.State) -> Bool {
        switch state {
        case .copied, .copiedFormula, .notCopied: true
        case .empty, .noFormula: false
        }
    }

    /// A white check in a green disc, as on a saved Quick Access card; otherwise one quiet color.
    private static func symbolColors(for state: TextResultHUD.State) -> [NSColor] {
        switch state {
        case .copied, .copiedFormula: [.white, .systemGreen]
        case .empty, .noFormula, .notCopied: [.secondaryLabelColor]
        }
    }

    /// At most two lines of note (the field's own limit), with the room its cell draws them in.
    private func noteHeight(width: CGFloat) -> CGFloat {
        let full = note.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = NSLayoutManager().defaultLineHeight(for: note.font ?? .systemFont(ofSize: 11))
        return ceil(min(full, lineHeight * 2 + 4))
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
        let card = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        guard !card.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: card, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Clicking the card must not bring this app in front of the one being worked in.
        NSApp.preventWindowOrdering()
    }

    @objc private func toggleJoin() {
        if case .notCopied = state { onCopy?() } else { onToggleJoin?() }
    }
    @objc private func close() { onClose?() }
}
