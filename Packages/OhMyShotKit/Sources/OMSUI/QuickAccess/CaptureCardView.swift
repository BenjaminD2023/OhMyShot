import AppKit
import Foundation
import OMSCore
import QuartzCore

/// The column of capture cards, newest at the bottom. Transparent; each card draws its own soft shadow,
/// so the view keeps a margin around the cards for it.
///
/// Not flipped: cards are placed from the bottom up, so they stay put on screen while the panel grows or
/// shrinks at the top.
final class CardStackView: NSView {
    var onCopy: ((QuickAccessItem) -> Void)?
    var onSave: ((QuickAccessItem) -> Void)?
    var onSaveAs: ((QuickAccessItem) -> Void)?
    var onOpen: ((QuickAccessItem) -> Void)?
    var onReveal: ((QuickAccessItem) -> Void)?
    var onMoveToTrash: ((QuickAccessItem) -> Void)?
    var onClose: ((QuickAccessItem) -> Void)?

    static let margin: CGFloat = 18
    static let gap: CGFloat = 12
    static let width = CaptureCardView.width + margin * 2

    private var cards: [UUID: CaptureCardView] = [:]
    private var generation = 0

    /// The height a stack of `items` needs, margins included.
    static func height(for items: [QuickAccessItem]) -> CGFloat {
        let heights = items.map(CaptureCardView.preferredHeight(for:))
        return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * gap + margin * 2
    }

    /// Shows `items`, oldest at the top. Cards that stay glide to their new places, `entering` slides in
    /// from the screen edge, and cards no longer listed slide out. `completion` runs once the motion has
    /// ended, unless a newer call has started its own, so a shrinking panel can wait for the cards.
    func show(_ items: [QuickAccessItem], entering: UUID?, completion: (() -> Void)? = nil) {
        generation += 1
        let generation = generation
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.slide
        let ids = Set(items.map(\.id))
        let leaving = cards.values.filter { !ids.contains($0.item.id) }
        leaving.forEach { cards[$0.item.id] = nil }

        // From the bottom up: the newest card is the last item.
        var frames: [UUID: CGRect] = [:]
        var y = Self.margin
        for item in items.reversed() {
            let height = CaptureCardView.preferredHeight(for: item)
            frames[item.id] = CGRect(x: Self.margin, y: y, width: CaptureCardView.width, height: height)
            y += height + Self.gap
        }

        var staying: [(CaptureCardView, CGRect)] = []
        for item in items {
            guard let frame = frames[item.id] else { continue }
            if let card = cards[item.id] {
                card.item = item
                if card.frame != frame { staying.append((card, frame)) }
            } else {
                let card = makeCard(for: item)
                card.frame = frame
                if item.id == entering { card.slideIn() }
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (card, frame) in staying {
                card.animator().frame = frame
            }
            for card in leaving {
                card.animator().alphaValue = 0
                card.animator().setFrameOrigin(CGPoint(x: card.frame.minX - 40, y: card.frame.minY))
            }
        }
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            leaving.forEach { $0.removeFromSuperview() }
            guard let self, generation == self.generation else { return }
            completion?()
        }
    }

    func showCopied(_ id: UUID) {
        cards[id]?.showCopied()
    }

    func previewHover(_ id: UUID) {
        cards[id]?.setHovering(true)
    }

    func markSaved(_ id: UUID, at url: URL) {
        cards[id]?.item.savedURL = url
        cards[id]?.showSaved()
    }

    private func makeCard(for item: QuickAccessItem) -> CaptureCardView {
        let card = CaptureCardView(item: item)
        card.onCopy = { [weak self, weak card] in
            guard let card else { return }
            self?.onCopy?(card.item)
            card.showCopied()
        }
        card.onSave = { [weak self, weak card] in
            guard let card else { return }
            if card.item.savedURL != nil { self?.onReveal?(card.item) } else { self?.onSave?(card.item) }
        }
        card.onSaveAs = { [weak self, weak card] in card.map { self?.onSaveAs?($0.item) } }
        card.onOpen = { [weak self, weak card] in card.map { self?.onOpen?($0.item) } }
        card.onReveal = { [weak self, weak card] in card.map { self?.onReveal?($0.item) } }
        card.onMoveToTrash = { [weak self, weak card] in card.map { self?.onMoveToTrash?($0.item) } }
        card.onClose = { [weak self, weak card] in card.map { self?.onClose?($0.item) } }
        addSubview(card)
        cards[item.id] = card
        return card
    }
}

/// One capture: the picture with rounded corners and a soft shadow; on hover, buttons to copy or save
/// it, close it, or reach the rest of its actions.
final class CaptureCardView: NSView, NSDraggingSource {
    static let width: CGFloat = 220

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onMoveToTrash: (() -> Void)?
    var onClose: (() -> Void)?

    var item: QuickAccessItem {
        didSet { updateAccessibility() }
    }

    private let picture = CALayer()
    private let hoverShade = CALayer()
    private let actions = NSStackView()
    private let copyButton = CardButton(style: .pill, title: String(localized: "Copy", bundle: .module), symbolName: "doc.on.doc")
    private let saveButton = CardButton(style: .pill, title: String(localized: "Save", bundle: .module), symbolName: "square.and.arrow.down")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private let moreButton = CardButton(style: .round, title: String(localized: "More", bundle: .module), symbolName: "ellipsis")
    private let savedBadge = NSImageView()
    private var mouseDownPoint: CGPoint?
    private var swipeDistance: CGFloat = 0
    private var copiedReset: Task<Void, Never>?
    private var hoverGeneration = 0

    init(item: QuickAccessItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = .black
        layer.shadowOpacity = Theme.Shadow.opacity
        layer.shadowRadius = Theme.Shadow.radius
        // The view is flipped, so a positive offset falls downward.
        layer.shadowOffset = CGSize(width: 0, height: Theme.Shadow.drop)

        picture.contents = item.thumbnail
        picture.contentsGravity = .resizeAspect
        picture.cornerRadius = Theme.Radius.card
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.borderWidth = 0.5
        hoverShade.backgroundColor = CGColor(gray: 0, alpha: 0.22)
        hoverShade.cornerRadius = Theme.Radius.card
        hoverShade.cornerCurve = .continuous
        hoverShade.opacity = 0
        layer.addSublayer(picture)
        layer.addSublayer(hoverShade)

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        actions.orientation = .vertical
        actions.spacing = 8
        actions.addArrangedSubview(copyButton)
        actions.addArrangedSubview(saveButton)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        moreButton.target = self
        moreButton.action = #selector(moreClicked(_:))
        for view in hoverControls {
            view.isHidden = true
            view.alphaValue = 0
            addSubview(view)
        }
        savedBadge.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: String(localized: "Saved", bundle: .module))?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [.white, .systemGreen])))
        savedBadge.isHidden = item.savedURL == nil
        addSubview(savedBadge)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Copy", bundle: .module)) { [weak self] in self?.onCopy?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Save", bundle: .module)) { [weak self] in self?.onSave?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Open", bundle: .module)) { [weak self] in self?.onOpen?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Move to Trash", bundle: .module)) { [weak self] in self?.onMoveToTrash?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Close", bundle: .module)) { [weak self] in self?.onClose?(); return true },
        ])
        updateAccessibility()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// The picture keeps its proportions within sensible bounds; extreme shapes are letterboxed.
    static func preferredHeight(for item: QuickAccessItem) -> CGFloat {
        let aspect = CGFloat(item.pixelHeight) / CGFloat(max(item.pixelWidth, 1))
        return min(max(width * aspect, 100), 172)
    }

    private var hoverControls: [NSView] { [actions, closeButton, moreButton] }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        hoverShade.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.card, cornerHeight: Theme.Radius.card, transform: nil)
        CATransaction.commit()
        let actionsSize = actions.fittingSize
        actions.frame = CGRect(x: (bounds.width - actionsSize.width) / 2, y: (bounds.height - actionsSize.height) / 2, width: actionsSize.width, height: actionsSize.height)
        closeButton.frame = CGRect(x: 8, y: 8, width: 24, height: 24)
        moreButton.frame = CGRect(x: bounds.width - 32, y: 8, width: 24, height: 24)
        savedBadge.frame = CGRect(x: bounds.width - 26, y: bounds.height - 26, width: 18, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        picture.borderColor = dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.10)
        picture.backgroundColor = Theme.cgColor(.controlBackgroundColor, for: effectiveAppearance)
    }

    private func updateAccessibility() {
        setAccessibilityLabel(item.kind == .recording
            ? String(localized: "Recording, \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
            : String(localized: "Screenshot, \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module))
        setAccessibilityValue(item.savedURL == nil ? nil : String(localized: "Saved", bundle: .module))
    }

    /// The card slides in from the screen edge with a short ease-out, or simply appears with Reduce
    /// Motion on.
    func slideIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = -36
        slide.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Theme.Motion.slide
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "slideIn")
    }

    func showCopied() {
        copyButton.title = String(localized: "Copied", bundle: .module)
        copyButton.symbolName = "checkmark"
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            copyButton.title = String(localized: "Copy", bundle: .module)
            copyButton.symbolName = "doc.on.doc"
        }
    }

    func showSaved() {
        saveButton.title = String(localized: "Saved", bundle: .module)
        saveButton.symbolName = "checkmark"
        saveButton.toolTip = String(localized: "Show in Finder", bundle: .module)
        savedBadge.isHidden = false
        updateAccessibility()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    /// The shade and the buttons fade in over a moment, or simply appear with Reduce Motion on.
    func setHovering(_ hovering: Bool) {
        hoverGeneration += 1
        let generation = hoverGeneration
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        if hovering {
            hoverControls.forEach { $0.isHidden = false }
            savedBadge.isHidden = true
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(duration == 0)
        hoverShade.opacity = hovering ? 1 : 0
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverControls.forEach { $0.animator().alphaValue = hovering ? 1 : 0 }
        }
        guard !hovering else { return }
        // Hidden once faded, so invisible buttons never take clicks.
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard let self, generation == hoverGeneration else { return }
            hoverControls.forEach { $0.isHidden = true }
            savedBadge.isHidden = item.savedURL == nil
        }
    }

    // MARK: Click, drag, swipe, menu

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Clicking a card must not pull this app in front of the one being worked in.
        NSApp.preventWindowOrdering()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { onOpen?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        let draggingItem = NSDraggingItem(pasteboardWriter: item.fileURL as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: NSImage(cgImage: item.thumbnail, size: bounds.size))
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    override func scrollWheel(with event: NSEvent) {
        switch event.phase {
        case .began:
            swipeDistance = 0
        case .changed:
            swipeDistance += event.scrollingDeltaX
        case .ended:
            if abs(swipeDistance) > 60 { onClose?() }
            swipeDistance = 0
        default:
            break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: Selector) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menuItem.target = self
            menu.addItem(menuItem)
        }
        add(String(localized: "Copy", bundle: .module), "doc.on.doc", #selector(copyClicked))
        add(String(localized: "Save", bundle: .module), "square.and.arrow.down", #selector(saveClicked))
        add(String(localized: "Save As…", bundle: .module), "square.and.arrow.down.on.square", #selector(saveAsClicked))
        menu.addItem(.separator())
        add(String(localized: "Open", bundle: .module), "arrow.up.forward.app", #selector(openClicked))
        add(String(localized: "Show in Finder", bundle: .module), "folder", #selector(revealClicked))
        menu.addItem(.separator())
        add(String(localized: "Move to Trash", bundle: .module), "trash", #selector(trashClicked))
        add(String(localized: "Close", bundle: .module), "xmark", #selector(closeClicked))
        return menu
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func saveAsClicked() { onSaveAs?() }
    @objc private func openClicked() { onOpen?() }
    @objc private func revealClicked() { onReveal?() }
    @objc private func trashClicked() { onMoveToTrash?() }
    @objc private func closeClicked() { onClose?() }

    @objc private func moreClicked(_ sender: NSView) {
        makeMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}

/// The buttons over a hovered card, drawn by hand. AppKit draws its own controls dimmed in windows that
/// are not key, and the Quick Access panel never becomes key, so standard buttons would always look
/// disabled there.
final class CardButton: NSControl {
    enum Style {
        /// A white capsule with a symbol and a label, for the main actions.
        case pill
        /// A small dark circle with a symbol, for the corners.
        case round
    }

    var title: String {
        didSet {
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }

    var symbolName: String {
        didSet { needsDisplay = true }
    }

    private let style: Style
    private var pressed = false {
        didSet { needsDisplay = true }
    }
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    init(style: Style, title: String, symbolName: String) {
        self.style = style
        self.title = title
        self.symbolName = symbolName
        super.init(frame: CGRect(origin: .zero, size: style == .pill ? CGSize(width: 112, height: 30) : CGSize(width: 24, height: 24)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        if style == .round { toolTip = title }
        if style == .pill {
            // A soft lift, so the capsule holds its edge on bright pictures.
            wantsLayer = true
            layer?.shadowColor = .black
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    override func layout() {
        super.layout()
        if style == .pill {
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        style == .pill ? NSSize(width: 112, height: 30) : NSSize(width: 24, height: 24)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let ink: NSColor
        switch style {
        case .pill:
            // Opaque, so text in the capture never shows through the label.
            NSColor(white: pressed ? 0.84 : hovering ? 1 : 0.97, alpha: 1).setFill()
            ink = NSColor(white: 0.1, alpha: 1)
        case .round:
            NSColor(white: 0, alpha: pressed ? 0.72 : hovering ? 0.62 : 0.5).setFill()
            ink = .white
        }
        shape.fill()
        if increaseContrast {
            (style == .pill ? NSColor(white: 0, alpha: 0.5) : NSColor(white: 1, alpha: 0.7)).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2 - 0.5, yRadius: bounds.height / 2 - 0.5)
            outline.lineWidth = 1
            outline.stroke()
        }

        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: style == .pill ? 12 : 10.5, weight: .bold).applying(.init(paletteColors: [ink])))
        let symbolSize = symbol?.size ?? .zero
        switch style {
        case .round:
            symbol?.draw(in: CGRect(x: bounds.midX - symbolSize.width / 2, y: bounds.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height))
        case .pill:
            let label = NSAttributedString(string: title, attributes: [
                .font: Theme.Typeface.label(size: 13, weight: .semibold),
                .foregroundColor: ink,
            ])
            let labelSize = label.size()
            let spacing: CGFloat = 6
            var x = bounds.midX - (symbolSize.width + spacing + labelSize.width) / 2
            symbol?.draw(in: CGRect(x: x, y: bounds.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height))
            x += symbolSize.width + spacing
            label.draw(at: CGPoint(x: x, y: bounds.midY - labelSize.height / 2))
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
        pressed = false
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        pressed = true
        // Tracks the press like a standard button: it fires only if released inside.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { sendAction(action, to: target) }
                return
            }
            pressed = inside
        }
        pressed = false
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}
