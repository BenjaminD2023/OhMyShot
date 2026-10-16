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
    var onAnnotate: ((QuickAccessItem) -> Void)?
    var onReveal: ((QuickAccessItem) -> Void)?
    var onRecognizeText: ((QuickAccessItem) -> Void)?
    var onPin: ((QuickAccessItem) -> Void)?
    var onPrint: ((QuickAccessItem) -> Void)?
    var onMoveToTrash: ((QuickAccessItem) -> Void)?
    var onClose: ((QuickAccessItem) -> Void)?
    /// The file to hand to another app for a capture, dragged out or shared.
    var fileToHandOver: ((QuickAccessItem) -> URL)?
    /// What the menu offers for uploading, read each time a menu opens (see `UploadMenu`).
    var uploadMenu: () -> UploadMenu = { .hidden }
    var onUpload: ((QuickAccessItem, UUID?) -> Void)?
    var onCancelUpload: ((QuickAccessItem) -> Void)?
    var onRetryUpload: ((QuickAccessItem) -> Void)?
    var onCopyLink: ((QuickAccessItem) -> Void)?
    var hasLink: ((QuickAccessItem) -> Bool)?
    var canDeleteFromStorage: ((QuickAccessItem) -> Bool)?
    var onDeleteFromStorage: ((QuickAccessItem) -> Void)?
    /// The upload a capture has now, for a card made after it began (restored from Recently Closed).
    var currentUpload: ((QuickAccessItem) -> CardUpload?)?

    /// Room for each card's shadow to fade out completely: twice its blur plus its drop.
    static let margin: CGFloat = Theme.Shadow.radius * 2 + Theme.Shadow.drop
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

    #if DEBUG
    func debugShare(of id: UUID) { cards[id]?.debugShare() }

    func debugShowMenu(of id: UUID, whileOpen: @escaping @MainActor ([String]) async -> Void) {
        cards[id]?.debugShowMenu(whileOpen: whileOpen)
    }
    #endif

    func setUpload(_ upload: CardUpload?, for id: UUID) {
        cards[id]?.upload = upload
    }

    /// Where a card is on screen, for what is shown beside it.
    func screenFrame(ofCard id: UUID) -> CGRect? {
        guard let card = cards[id], let window else { return nil }
        return window.convertToScreen(card.convert(card.bounds, to: nil))
    }

    /// Shows a capture's new picture on its card.
    func replace(_ item: QuickAccessItem) {
        cards[item.id]?.item = item
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
        card.onAnnotate = { [weak self, weak card] in card.map { self?.onAnnotate?($0.item) } }
        card.onReveal = { [weak self, weak card] in card.map { self?.onReveal?($0.item) } }
        card.onRecognizeText = { [weak self, weak card] in card.map { self?.onRecognizeText?($0.item) } }
        card.onPin = { [weak self, weak card] in card.map { self?.onPin?($0.item) } }
        card.onPrint = { [weak self, weak card] in card.map { self?.onPrint?($0.item) } }
        card.onMoveToTrash = { [weak self, weak card] in card.map { self?.onMoveToTrash?($0.item) } }
        card.onClose = { [weak self, weak card] in card.map { self?.onClose?($0.item) } }
        card.fileToHandOver = { [weak self, weak card] in card.map { self?.fileToHandOver?($0.item) ?? $0.item.fileURL } }
        card.uploadMenu = { [weak self] in self?.uploadMenu() ?? .hidden }
        card.onUpload = { [weak self, weak card] destination in card.map { self?.onUpload?($0.item, destination) } }
        card.onCancelUpload = { [weak self, weak card] in card.map { self?.onCancelUpload?($0.item) } }
        card.onRetryUpload = { [weak self, weak card] in card.map { self?.onRetryUpload?($0.item) } }
        card.onCopyLink = { [weak self, weak card] in card.map { self?.onCopyLink?($0.item) } }
        card.hasLink = { [weak self, weak card] in card.flatMap { self?.hasLink?($0.item) } ?? false }
        card.canDeleteFromStorage = { [weak self, weak card] in card.flatMap { self?.canDeleteFromStorage?($0.item) } ?? false }
        card.onDeleteFromStorage = { [weak self, weak card] in card.map { self?.onDeleteFromStorage?($0.item) } }
        card.upload = currentUpload?(item)
        addSubview(card)
        cards[item.id] = card
        return card
    }
}

/// One capture: the picture with rounded corners and a soft shadow; on hover, buttons to copy or save
/// it, close it, or reach the rest of its actions.
final class CaptureCardView: NSView, NSDraggingSource {
    static let width = CardPicture.width

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onOpen: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRecognizeText: (() -> Void)?
    var onPin: (() -> Void)?
    var onPrint: (() -> Void)?
    var onMoveToTrash: (() -> Void)?
    var onClose: (() -> Void)?
    var fileToHandOver: (() -> URL?)?
    var uploadMenu: () -> UploadMenu = { .hidden }
    var onUpload: ((UUID?) -> Void)?
    var onCancelUpload: (() -> Void)?
    var onRetryUpload: (() -> Void)?
    var onCopyLink: (() -> Void)?
    var hasLink: () -> Bool = { false }
    var canDeleteFromStorage: () -> Bool = { false }
    var onDeleteFromStorage: (() -> Void)?

    /// The capture's upload, shown in the capsule at the top. A finished one goes again after a moment; the
    /// menu keeps Copy Link.
    var upload: CardUpload? {
        didSet {
            guard upload != oldValue else { return }
            uploadBadge.show(upload)
            updateAccessibility()
            finishedReset?.cancel()
            guard case .finished? = upload else { return }
            finishedReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, case .finished? = upload else { return }
                uploadBadge.show(nil)
            }
        }
    }

    var item: QuickAccessItem {
        didSet {
            if item.thumbnail !== oldValue.thumbnail {
                picture.contents = Self.shownPart(of: item.thumbnail)
            }
            updateDuration()
            updateAccessibility()
        }
    }

    private let picture = CALayer()
    private let hoverShade = CALayer()
    private let actions = NSStackView()
    private let copyButton = CardButton(style: .pill, title: String(localized: "Copy", bundle: .module), symbolName: "doc.on.doc")
    private let saveButton = CardButton(style: .pill, title: String(localized: "Save", bundle: .module), symbolName: "square.and.arrow.down")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private let moreButton = CardButton(style: .round, title: String(localized: "More", bundle: .module), symbolName: "ellipsis")
    private let savedBadge = NSImageView()
    /// A recording's length and a play mark, in a small capsule in the corner.
    private let durationBadge = DurationBadge()
    private let uploadBadge = CardUploadBadge()
    private var finishedReset: Task<Void, Never>?
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

        picture.contents = Self.shownPart(of: item.thumbnail)
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
        addSubview(durationBadge)
        addSubview(uploadBadge)
        uploadBadge.onAction = { [weak self] in
            guard let self else { return }
            if case .failed? = upload { onRetryUpload?() } else { onCancelUpload?() }
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateDuration()
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
        return min(max(width * aspect, 100), CardPicture.tallest)
    }

    /// The part of a capture the card shows (`CardPicture`). Thumbnails made for cards are that part already.
    static func shownPart(of image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        return CardPicture.shownPart(of: image)
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
        let badge = durationBadge.fittingSize
        durationBadge.frame = CGRect(x: 8, y: bounds.height - 8 - badge.height, width: badge.width, height: badge.height)
        // Between the corner buttons, level with them.
        let upload = uploadBadge.fittingSize
        uploadBadge.frame = CGRect(x: ((bounds.width - upload.width) / 2).rounded(), y: 8, width: upload.width, height: upload.height)
    }

    /// A recording shows its length in the bottom-left corner, after a play mark, or "GIF" for a GIF.
    private func updateDuration() {
        guard item.kind == .recording, let duration = item.duration else {
            durationBadge.isHidden = true
            return
        }
        durationBadge.isGIF = isGIF
        durationBadge.text = isGIF ? "GIF \(Self.format(duration))" : Self.format(duration)
        durationBadge.isHidden = false
        needsLayout = true
    }

    private var isGIF: Bool {
        item.fileURL.pathExtension.lowercased() == "gif"
    }

    /// A recording's length as cards show it: 0:42, 12:05, 1:02:09.
    static func format(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
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
            ? isGIF
                ? String(localized: "GIF, \(item.duration.map(Self.format) ?? ""), \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
                : String(localized: "Recording, \(item.duration.map(Self.format) ?? ""), \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
            : String(localized: "Screenshot, \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module))
        let state: String? = switch upload {
        case .uploading(let fraction)?: String(localized: "Uploading, \(min(Int((fraction * 100).rounded()), 99)) percent", bundle: .module)
        case .finished(let copied)?: copied ? String(localized: "Link copied", bundle: .module) : String(localized: "Uploaded", bundle: .module)
        case .failed(let message)?: String(localized: "Upload failed. \(message)", bundle: .module)
        case nil: nil
        }
        let value = [item.savedURL == nil ? nil : String(localized: "Saved", bundle: .module), state].compactMap(\.self)
        setAccessibilityValue(value.isEmpty ? nil : value.joined(separator: ", "))
    }

    /// The card's actions for VoiceOver, made when asked: what uploading offers depends on the destinations
    /// at that moment, and with none it offers nothing.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        func action(_ title: String, _ run: @escaping () -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: title) { run(); return true }
        }
        // A recording is played, saved, or sent on; marking up, reading text, and pinning are for pictures.
        let isPicture = item.kind == .screenshot
        var actions = [
            action(String(localized: "Copy", bundle: .module)) { [weak self] in self?.onCopy?() },
            action(String(localized: "Save", bundle: .module)) { [weak self] in self?.onSave?() },
        ]
        if isPicture { actions.append(action(String(localized: "Annotate", bundle: .module)) { [weak self] in self?.onAnnotate?() }) }
        actions.append(action(String(localized: "Open", bundle: .module)) { [weak self] in self?.onOpen?() })
        if isPicture {
            actions.append(action(String(localized: "Recognize Text", bundle: .module)) { [weak self] in self?.onRecognizeText?() })
            actions.append(action(String(localized: "Pin to Screen", bundle: .module)) { [weak self] in self?.onPin?() })
        }
        actions.append(action(String(localized: "Share", bundle: .module)) { [weak self] in self?.shareClicked() })
        switch upload {
        case .uploading?:
            actions.append(action(String(localized: "Cancel Upload", bundle: .module)) { [weak self] in self?.onCancelUpload?() })
        case .failed?:
            if !uploadMenu().isHidden {
                actions.append(action(String(localized: "Retry Upload", bundle: .module)) { [weak self] in self?.onRetryUpload?() })
            }
            actions.append(action(String(localized: "Copy Error", bundle: .module)) { [weak self] in self?.copyErrorClicked() })
        default:
            switch uploadMenu() {
            case .hidden: break
            case .upload: actions.append(action(String(localized: "Upload", bundle: .module)) { [weak self] in self?.onUpload?(nil) })
            case .uploadWithChoice(let targets):
                let name = targets.first(where: \.isDefault)?.name ?? targets[0].name
                actions.append(action(String(localized: "Upload to \(name)", bundle: .module)) { [weak self] in self?.onUpload?(nil) })
                for target in targets {
                    actions.append(action(String(localized: "Upload to \(target.name)", bundle: .module)) { [weak self] in self?.onUpload?(target.id) })
                }
            }
        }
        if hasLink() { actions.append(action(String(localized: "Copy Link", bundle: .module)) { [weak self] in self?.onCopyLink?() }) }
        if canDeleteFromStorage() {
            actions.append(action(String(localized: "Delete from Storage", bundle: .module)) { [weak self] in self?.onDeleteFromStorage?() })
        }
        actions.append(action(String(localized: "Move to Trash", bundle: .module)) { [weak self] in self?.onMoveToTrash?() })
        actions.append(action(String(localized: "Close", bundle: .module)) { [weak self] in self?.onClose?() })
        return actions
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
        // A picture opens in the editor; a recording in the recording window.
        if event.clickCount == 2 { onAnnotate?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        // The file in the format Settings choose, made now when it is not the capture itself.
        let draggingItem = NSDraggingItem(pasteboardWriter: (fileToHandOver?() ?? item.fileURL) as NSURL)
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
        if item.kind == .recording {
            // A movie is trimmed and made smaller there; a GIF only plays.
            if item.fileURL.pathExtension.lowercased() == "gif" {
                add(String(localized: "Play", bundle: .module), "play", #selector(annotateClicked))
            } else {
                add(String(localized: "Edit…", bundle: .module), "timeline.selection", #selector(annotateClicked))
            }
            add(String(localized: "Open", bundle: .module), "arrow.up.forward.app", #selector(openClicked))
        } else {
            add(String(localized: "Annotate…", bundle: .module), "pencil.tip.crop.circle", #selector(annotateClicked))
            add(String(localized: "Open", bundle: .module), "arrow.up.forward.app", #selector(openClicked))
            add(String(localized: "Recognize Text…", bundle: .module), "text.viewfinder", #selector(recognizeTextClicked))
            add(String(localized: "Pin to Screen", bundle: .module), "pin", #selector(pinClicked))
            add(String(localized: "Print…", bundle: .module), "printer", #selector(printClicked))
        }
        add(String(localized: "Show in Finder", bundle: .module), "folder", #selector(revealClicked))
        menu.addItem(.separator())
        addSharingItems(to: menu, add: add)
        add(String(localized: "Move to Trash", bundle: .module), "trash", #selector(trashClicked))
        add(String(localized: "Close", bundle: .module), "xmark", #selector(closeClicked))
        return menu
    }

    /// Share, always; then the upload entries, which exist only for a person who set up a destination.
    private func addSharingItems(to menu: NSMenu, add: (String, String, Selector) -> Void) {
        // Not the system's own Share item, which draws an icon the rest of this menu does not have.
        add(String(localized: "Share…", bundle: .module), "square.and.arrow.up", #selector(shareClicked))
        switch upload {
        case .uploading?:
            add(String(localized: "Cancel Upload", bundle: .module), "xmark.circle", #selector(cancelUploadClicked))
        case .failed?:
            // Retrying is uploading again: not offered once the last destination has been removed.
            if !uploadMenu().isHidden {
                add(String(localized: "Retry Upload", bundle: .module), "arrow.clockwise", #selector(retryUploadClicked))
            }
            add(String(localized: "Copy Error", bundle: .module), "doc.on.clipboard", #selector(copyErrorClicked))
        default:
            switch uploadMenu() {
            case .hidden:
                break
            case .upload:
                add(String(localized: "Upload", bundle: .module), "icloud.and.arrow.up", #selector(uploadClicked))
            case .uploadWithChoice(let targets):
                // With several destinations the plain Upload says which one it goes to.
                let name = targets.first(where: \.isDefault)?.name ?? targets[0].name
                add(String(localized: "Upload to \(name)", bundle: .module), "icloud.and.arrow.up", #selector(uploadClicked))
                let choice = NSMenuItem(title: String(localized: "Upload To", bundle: .module), action: nil, keyEquivalent: "")
                choice.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
                let submenu = NSMenu()
                for target in targets {
                    let entry = NSMenuItem(title: target.name, action: #selector(uploadToClicked(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = target.id
                    entry.state = target.isDefault ? .on : .off
                    submenu.addItem(entry)
                }
                choice.submenu = submenu
                menu.addItem(choice)
            }
        }
        if hasLink() {
            add(String(localized: "Copy Link", bundle: .module), "link", #selector(copyLinkClicked))
        }
        if canDeleteFromStorage() {
            add(String(localized: "Delete from Storage…", bundle: .module), "icloud.slash", #selector(deleteFromStorageClicked))
        }
        menu.addItem(.separator())
    }

    @objc private func uploadClicked() { onUpload?(nil) }
    @objc private func uploadToClicked(_ sender: NSMenuItem) { onUpload?(sender.representedObject as? UUID) }
    @objc private func cancelUploadClicked() { onCancelUpload?() }
    @objc private func retryUploadClicked() { onRetryUpload?() }
    @objc private func copyLinkClicked() { onCopyLink?() }
    @objc private func deleteFromStorageClicked() { onDeleteFromStorage?() }
    /// Puts the failure's sentence on the clipboard, for a bug report or a server's owner.
    @objc private func copyErrorClicked() {
        guard case .failed(let message)? = upload else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
    #if DEBUG
    func debugShare() { shareClicked() }
    #endif

    @objc private func shareClicked() {
        NSSharingServicePicker(items: [fileToHandOver?() ?? item.fileURL]).show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func saveAsClicked() { onSaveAs?() }
    @objc private func openClicked() { onOpen?() }
    @objc private func annotateClicked() { onAnnotate?() }
    @objc private func revealClicked() { onReveal?() }
    @objc private func recognizeTextClicked() { onRecognizeText?() }
    @objc private func pinClicked() { onPin?() }
    @objc private func printClicked() { onPrint?() }
    @objc private func trashClicked() { onMoveToTrash?() }
    @objc private func closeClicked() { onClose?() }

    #if DEBUG
    func debugShowMenu(whileOpen: @escaping @MainActor ([String]) async -> Void) {
        let menu = makeMenu()
        func titles(_ menu: NSMenu, _ indent: String = "") -> [String] {
            menu.items.flatMap { item -> [String] in
                item.isSeparatorItem ? [indent + "-"] : [indent + item.title] + (item.submenu.map { titles($0, indent + "  ") } ?? [])
            }
        }
        let shown = titles(menu)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            let look = Task { await whileOpen(shown) }
            try? await Task.sleep(for: .milliseconds(2200))
            look.cancel()
            menu.cancelTracking()
        }
        menu.popUp(beside: moreButton, outside: self)
    }
    #endif

    @objc private func moreClicked(_ sender: NSView) {
        makeMenu().popUp(beside: sender, outside: self)
    }
}

/// A recording's length on its card: a play mark (or the word GIF, set in the text) and the time in the
/// reading face, small, in a capsule of the reading capsule's materials.
private final class DurationBadge: NSView {
    private let mark = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    /// A GIF plays on its own: no play mark.
    var isGIF = false {
        didSet {
            mark.isHidden = isGIF
            needsLayout = true
        }
    }

    /// Where the label begins: after the mark, or at the capsule's padding.
    private var labelX: CGFloat {
        isGIF ? 7 : 7 + 7 + 4
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        mark.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        label.font = Theme.Typeface.reading(size: 10.5, weight: .semibold)
        addSubview(mark)
        addSubview(label)
        setAccessibilityElement(false)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + labelX + 7, height: 18)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        mark.frame = CGRect(x: 7, y: (height - 8) / 2, width: 7, height: 8)
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: labelX, y: ((height - size.height) / 2).rounded(), width: ceil(size.width), height: size.height)
        layer?.cornerRadius = height / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// The reading capsule's materials: white (a dark gray in Dark), the hairline, dark ink.
    private func applyAppearance() {
        let ink = BadgeMaterial.apply(to: layer, in: self)
        label.textColor = ink
        mark.contentTintColor = ink
    }
}
