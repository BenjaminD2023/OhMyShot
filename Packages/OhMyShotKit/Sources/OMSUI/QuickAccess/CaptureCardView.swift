import AppKit
import Foundation
import OMSCore
import OMSDesign
import QuartzCore

/// One capture: the picture with rounded corners and a soft shadow; on hover, buttons to copy or save
/// it, close it, or reach the rest of its actions.
final class CaptureCardView: NSView, NSDraggingSource, NSMenuDelegate {
    /// What its buttons, its menu, VoiceOver, a double-click, or a swipe asked of the capture: Undo on a card
    /// waiting to go to the Trash too. Share, Send by Email, and Copy Error are the card's own, as they need the card
    /// (a sheet beside it) or only its upload.
    var onCommand: ((CardCommand) -> Void)?
    var fileToHandOver: (() -> URL?)?
    var uploadMenu: () -> UploadMenu = { .hidden }
    var hasLink: () -> Bool = { false }
    var canDeleteFromStorage: () -> Bool = { false }
    var pictureOffer: () -> PictureChangeOffer = { .unsupported }
    var cardCount: () -> Int = { 1 }
    /// The card is kept from closing, or let go (see `CardCountdown.Hold`).
    var onHold: ((CardCountdown.Hold, Bool) -> Void)?
    /// The card was clicked: the keyboard goes to it.
    var onFocus: (() -> Void)?
    /// The pointer actively crossed into or out of the card (`mouseEntered`/`mouseExited`).
    var onPointerHover: ((Bool) -> Void)?

    /// How large the card is; its Copy and Save capsules narrow with it.
    var size: QuickAccessSize {
        didSet {
            guard size != oldValue else { return }
            for button in [copyButton, saveButton, undoButton] { button.pillWidth = size == .small ? 96 : 112 }
            needsLayout = true
        }
    }

    /// Whether the card has the keyboard: ringed, and its keys answered.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            selectionRing.isHidden = !isSelected
            setAccessibilitySelected(isSelected)
        }
    }

    /// The capture's upload, shown in the capsule at the top. A finished one goes again after a moment; the
    /// menu keeps Copy Link.
    var upload: CardUpload? {
        didSet {
            guard upload != oldValue else { return }
            uploadBadge.show(upload)
            updateAccessibility()
            if isHovering { updateExtras() }
            finishedReset?.cancel()
            guard case .finished? = upload else { return }
            finishedReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, case .finished? = upload else { return }
                uploadBadge.show(nil)
            }
        }
    }

    /// Moved to the Trash and waiting to go, which `QuickAccessController` holds off for a few seconds: the picture is
    /// shaded under "Moved to Trash" and an Undo capsule, and the card does nothing else.
    var isTrashing = false {
        didSet {
            guard isTrashing != oldValue else { return }
            if isTrashing {
                setHovering(false)
                noticeReset?.cancel()
                noticeBadge.show(String(localized: "Moved to Trash", bundle: .module), symbol: "trash")
            } else {
                noticeBadge.hide()
            }
            undoButton.isHidden = !isTrashing
            for badge in [savedBadge, durationBadge, uploadBadge] as [NSView] { badge.alphaValue = isTrashing ? 0 : 1 }
            CATransaction.begin()
            CATransaction.setDisableActions(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            hoverShade.opacity = isTrashing ? 1 : 0
            CATransaction.commit()
            updateAccessibility()
            needsLayout = true
        }
    }

    var item: QuickAccessItem {
        didSet {
            if item.thumbnail !== oldValue.thumbnail {
                picture.contents = Self.shownPart(of: item.thumbnail)
            }
            updateDuration()
            updateAccessibility()
            if isHovering { updateExtras() }
        }
    }

    private let picture = CALayer()
    private let hoverShade = CALayer()
    /// The ring of a card that has the keyboard, like a pin's.
    private let selectionRing = CALayer()
    /// A subtle progress ring around the top-left Close button while the card counts down to close by itself, over a
    /// soft dark line so it reads on a light picture as the selection's white edge does.
    private let countdownRing = CAShapeLayer()
    private let countdownOutline = CAShapeLayer()
    let actions = NSStackView()
    let copyButton = CardButton(style: .pill, title: String(localized: "Copy", bundle: .module), symbolName: "doc.on.doc")
    let saveButton = CardButton(style: .pill, title: String(localized: "Save", bundle: .module), symbolName: "square.and.arrow.down")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private let moreButton = CardButton(style: .round, title: String(localized: "More", bundle: .module), symbolName: "ellipsis")
    // The small buttons down the card's sides, which `CardControlLayout` places.
    private let annotateButton = CardButton(style: .round, title: String(localized: "Annotate", bundle: .module), symbolName: "pencil.and.scribble")
    private let pinButton = CardButton(style: .round, title: String(localized: "Pin to Screen", bundle: .module), symbolName: "pin")
    private let uploadButton = CardButton(style: .round, title: String(localized: "Upload", bundle: .module), symbolName: "icloud.and.arrow.up")
    private let recognizeButton = CardButton(style: .round, title: String(localized: "Recognize Text", bundle: .module), symbolName: "text.viewfinder")
    private let trashButton = CardButton(style: .round, title: String(localized: "Move to Trash", bundle: .module), symbolName: "trash")
    /// "Copied" over a card copied while the pointer is elsewhere, or "Moved to Trash" over one waiting to go.
    private let noticeBadge = CardNoticeBadge()
    /// Brings back a card moved to the Trash, while it waits to go.
    private let undoButton = CardButton(style: .pill, title: String(localized: "Undo", bundle: .module), symbolName: "arrow.uturn.backward")
    private var noticeReset: Task<Void, Never>?
    /// The side buttons this capture has now, each with what it is.
    private var wantedExtras: [(CardButton, CardControlLayout.Extra)] = []
    /// Side buttons that are away for now but keep their places, so the columns spread the same.
    private var heldExtras: [CardControlLayout.Extra] = []
    private var isHovering = false
    private let savedBadge = NSImageView()
    /// A recording's length and a play mark, in a small capsule in the corner.
    private let durationBadge = DurationBadge()
    private let uploadBadge = CardUploadBadge()
    private var displayOptions: (any NSObjectProtocol)?
    private var finishedReset: Task<Void, Never>?
    private var mouseDownPoint: CGPoint?
    private var swipeDistance: CGFloat = 0
    var slidesFromLeft = true
    private(set) var swipeTranslation: CGFloat = 0
    private(set) var countdownState: (remaining: TimeInterval, interval: TimeInterval)?
    var isCountdownRingVisible: Bool { !countdownRing.isHidden }
    private var copiedReset: Task<Void, Never>?
    private var hoverGeneration = 0

    init(item: QuickAccessItem, size: QuickAccessSize) {
        self.item = item
        self.size = size
        super.init(frame: .zero)
        if item.kind == .screenshot {
            let hint = String(localized: "Hover and press Space to preview. Double-click to edit.", bundle: .module)
            toolTip = hint
            setAccessibilityHelp(hint)
        }
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
        hoverShade.backgroundColor = CGColor(gray: 0, alpha: 0.22)
        hoverShade.cornerRadius = Theme.Radius.card
        hoverShade.cornerCurve = .continuous
        hoverShade.opacity = 0
        selectionRing.borderWidth = 1.5
        selectionRing.cornerRadius = Theme.Radius.card
        selectionRing.cornerCurve = .continuous
        selectionRing.isHidden = true
        layer.addSublayer(picture)
        layer.addSublayer(hoverShade)
        layer.addSublayer(selectionRing)
        countdownOutline.fillColor = nil
        countdownOutline.strokeColor = CGColor(gray: 0, alpha: Theme.Overlay.outlineOpacity)
        countdownOutline.lineWidth = 2.5
        countdownOutline.lineCap = .round
        countdownRing.fillColor = nil
        countdownRing.strokeColor = CGColor(gray: 1, alpha: 0.85)
        countdownRing.lineWidth = 1.5
        countdownRing.lineCap = .round
        for line in [countdownOutline, countdownRing] {
            line.isHidden = true
            line.zPosition = 2
            layer.addSublayer(line)
        }
        for button in [copyButton, saveButton, undoButton] { button.pillWidth = size == .small ? 96 : 112 }

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
        for (button, action) in [
            (annotateButton, #selector(annotateClicked)), (pinButton, #selector(pinClicked)), (uploadButton, #selector(uploadClicked)),
            (recognizeButton, #selector(recognizeTextClicked)), (trashButton, #selector(trashClicked)),
        ] {
            button.target = self
            button.action = action
        }
        // The buttons stand in columns down the card's sides: each names itself beside it, into the card, never over
        // the button below.
        for button in [closeButton, annotateButton, pinButton, uploadButton] { button.hoverTagEdge = .maxX }
        for button in [moreButton, recognizeButton, trashButton] { button.hoverTagEdge = .minX }
        for view in allHoverControls {
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
        addSubview(noticeBadge)
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        undoButton.isHidden = true
        addSubview(undoButton)
        uploadBadge.onAction = { [weak self] in
            guard let self else { return }
            if case .failed? = upload { onCommand?(.retryUpload) } else { onCommand?(.cancelUpload) }
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
    static func preferredHeight(for item: QuickAccessItem, size: QuickAccessSize = .medium) -> CGFloat {
        size.cardHeight(pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight)
    }

    /// The part of a capture the card shows (`CardPicture`). Thumbnails made for cards are that part already.
    static func shownPart(of image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        return CardPicture.shownPart(of: image)
    }

    /// Every control that shows while the pointer is over the card.
    private var allHoverControls: [NSView] {
        [actions, closeButton, moreButton, annotateButton, pinButton, uploadButton, recognizeButton, trashButton]
    }

    /// The controls that show now: the capsules and corner buttons, and the side buttons that have room.
    private var hoverControls: [NSView] {
        [actions, closeButton, moreButton] + extraPlacements().map(\.button)
    }

    /// Which side buttons this capture has, in the order they take places: the editor, Pin, Upload when there
    /// is a destination and no upload is going or waiting on Retry (the badge has those), Recognize Text, and
    /// Move to Trash. A recording has the editor (or Play), Upload, and Trash.
    private func updateExtras() {
        annotateButton.title = item.media.openTitle
        annotateButton.symbolName = item.media.openSymbolName
        let uploads: Bool
        switch upload {
        case .uploading?, .failed?: uploads = false
        default: uploads = !uploadMenu().isHidden
        }
        var wanted: [(CardButton, CardControlLayout.Extra)] = [(annotateButton, .annotate)]
        if item.kind == .screenshot { wanted.append((pinButton, .pin)) }
        if uploads { wanted.append((uploadButton, .upload)) }
        if item.kind == .screenshot { wanted.append((recognizeButton, .recognizeText)) }
        wanted.append((trashButton, .trash))
        wantedExtras = wanted
        // Upload keeps its place while an upload goes on or waits on Retry, so the column doesn't close up under the pointer.
        heldExtras = !uploads && !uploadMenu().isHidden ? [.upload] : []
        needsLayout = true
    }

    /// The side buttons that have a place at the card's height, with their places, which are fixed
    /// (`CardControlLayout.place(of:onRecording:)`), so a button that comes or goes moves no other.
    private func extraPlacements() -> [(button: CardButton, slot: CardControlLayout.Slot)] {
        let recording = item.kind == .recording
        let slots = CardControlLayout.slots(for: wantedExtras.map(\.1), onRecording: recording, height: bounds.height, leadingReserve: recording ? 24 : 0)
        return zip(wantedExtras, slots).compactMap { wanted, slot in slot.map { (wanted.0, $0) } }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        hoverShade.frame = bounds
        selectionRing.frame = bounds
        layer?.shadowPath = .continuousRoundedRect(bounds, radius: Theme.Radius.card)
        CATransaction.commit()
        let compactActions = bounds.height > 0 && bounds.height < 124
        let desiredPillHeight: CGFloat = compactActions ? 26 : 30
        let desiredSpacing: CGFloat = compactActions ? 4 : 8
        if copyButton.pillHeight != desiredPillHeight {
            copyButton.pillHeight = desiredPillHeight
            saveButton.pillHeight = desiredPillHeight
        }
        if actions.spacing != desiredSpacing {
            actions.spacing = desiredSpacing
        }
        let actionsSize = actions.fittingSize
        actions.frame = CGRect(x: (bounds.width - actionsSize.width) / 2, y: (bounds.height - actionsSize.height) / 2, width: actionsSize.width, height: actionsSize.height)
        closeButton.frame = CGRect(x: 8, y: 8, width: 24, height: 24)
        // The ring starts at twelve o'clock and runs clockwise, as the upload's and the Self-Timer's do (the view is
        // flipped, so a growing angle turns clockwise); as the time runs out it shrinks back to twelve.
        let ringBounds = CGRect(x: 7, y: 7, width: 26, height: 26)
        let ringPath = CGMutablePath()
        ringPath.addArc(center: CGPoint(x: 13, y: 13), radius: 12, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
        for line in [countdownOutline, countdownRing] {
            line.frame = ringBounds
            line.path = ringPath
        }
        moreButton.frame = CGRect(x: bounds.width - 32, y: 8, width: 24, height: 24)
        let placed = extraPlacements()
        let recording = item.kind == .recording
        let extras = wantedExtras.map(\.1) + heldExtras
        let spacing = { (side: CardControlLayout.Side) in
            CardControlLayout.spacing(on: side, for: extras, onRecording: recording, height: self.bounds.height, reserve: side == .leading && recording ? 24 : 0)
        }
        let spacings = [CardControlLayout.Side.leading: spacing(.leading), .trailing: spacing(.trailing)]
        for button in [annotateButton, pinButton, uploadButton, recognizeButton, trashButton] where !placed.contains(where: { $0.button === button }) {
            button.isHidden = true
        }
        for (button, slot) in placed {
            button.frame = CGRect(
                x: CardControlLayout.left(of: slot, width: bounds.width), y: CardControlLayout.top(of: slot, spacing: spacings[slot.side] ?? CardControlLayout.gap),
                width: CardControlLayout.buttonSize, height: CardControlLayout.buttonSize
            )
            // One that has come while the pointer is over the card (an upload ended) shows at once.
            if isHovering, button.isHidden {
                button.alphaValue = 1
                button.isHidden = false
            }
        }
        savedBadge.frame = CGRect(x: bounds.width - 26, y: bounds.height - 26, width: 18, height: 18)
        let badge = durationBadge.fittingSize
        durationBadge.frame = CGRect(x: 8, y: bounds.height - 8 - badge.height, width: badge.width, height: badge.height)
        // Between the corner buttons, level with them.
        uploadBadge.widest = max(bounds.width - 68, 0)
        let upload = uploadBadge.fittingSize
        uploadBadge.frame = CGRect(x: ((bounds.width - upload.width) / 2).rounded(), y: 8, width: upload.width, height: upload.height)
        // Centered, and over a card waiting to go, above its Undo capsule.
        noticeBadge.widest = max(bounds.width - 16, 0)
        let notice = noticeBadge.fittingSize
        let undo = undoButton.intrinsicContentSize
        let group = isTrashing ? notice.height + 8 + undo.height : notice.height
        let top = ((bounds.height - group) / 2).rounded()
        noticeBadge.frame = CGRect(x: ((bounds.width - notice.width) / 2).rounded(), y: top, width: notice.width, height: notice.height)
        undoButton.frame = CGRect(x: ((bounds.width - undo.width) / 2).rounded(), y: top + notice.height + 8, width: undo.width, height: undo.height)
    }

    /// A recording shows its length in the bottom-left corner, after a play mark, or "GIF" for a GIF.
    private func updateDuration() {
        guard item.kind == .recording, let duration = item.duration else {
            durationBadge.isHidden = true
            return
        }
        let isGIF = item.media == .gif
        durationBadge.isGIF = isGIF
        durationBadge.text = isGIF ? "GIF \(Self.format(duration))" : Self.format(duration)
        durationBadge.isHidden = false
        needsLayout = true
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

    /// Increase Contrast switched while the card is up: its picture's edge and its badges take it at once.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        guard window != nil else { return }
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyAppearance()
                for badge in [self.noticeBadge, self.durationBadge, self.uploadBadge] as [NSView] {
                    badge.viewDidChangeEffectiveAppearance()
                }
            }
        }
    }

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
    }

    private func applyAppearance() {
        let dark = effectiveAppearance.isDark
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        picture.borderColor = Theme.PictureBorder.color(dark: dark, contrast: contrast)
        picture.borderWidth = Theme.PictureBorder.width(contrast: contrast)
        picture.backgroundColor = Theme.cgColor(.controlBackgroundColor, for: effectiveAppearance)
        selectionRing.borderColor = Theme.cgColor(.keyboardFocusIndicatorColor, for: effectiveAppearance)
    }

    private func updateAccessibility() {
        let label = switch item.media {
        case .screenshot: String(localized: "Screenshot, \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
        case .movie: String(localized: "Recording, \(item.duration.map(Self.format) ?? ""), \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
        case .gif: String(localized: "GIF, \(item.duration.map(Self.format) ?? ""), \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
        }
        setAccessibilityLabel(label)
        if isTrashing {
            setAccessibilityValue(String(localized: "Moved to Trash", bundle: .module))
            return
        }
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
        if isTrashing { return [action(String(localized: "Undo", bundle: .module)) { [weak self] in self?.onCommand?(.undoTrash) }] }
        // A recording is played, saved, or sent on; marking up, reading text, and pinning are for pictures.
        let isPicture = item.kind == .screenshot
        var actions = [
            action(String(localized: "Copy", bundle: .module)) { [weak self] in self?.onCommand?(.copy) },
            action(String(localized: "Save", bundle: .module)) { [weak self] in self?.onCommand?(.save) },
        ]
        if isPicture { actions.append(action(String(localized: "Annotate", bundle: .module)) { [weak self] in self?.onCommand?(.annotate) }) }
        actions.append(action(String(localized: "Open", bundle: .module)) { [weak self] in self?.onCommand?(.open) })
        actions.append(action(isPicture ? String(localized: "Preview", bundle: .module) : String(localized: "Quick Look", bundle: .module)) { [weak self] in self?.onCommand?(.quickLook) })
        if isPicture {
            actions.append(action(String(localized: "Recognize Text", bundle: .module)) { [weak self] in self?.onCommand?(.recognizeText) })
            actions.append(action(String(localized: "Pin to Screen", bundle: .module)) { [weak self] in self?.onCommand?(.pin) })
            let offer = pictureOffer()
            if offer.availability == .available {
                for (title, change) in pictureChanges(for: offer) {
                    actions.append(action(title) { [weak self] in self?.onCommand?(.picture(change)) })
                }
            }
        }
        actions.append(action(String(localized: "Share", bundle: .module)) { [weak self] in self?.shareClicked() })
        if EmailSharing.canSend(item.fileURL) {
            actions.append(action(String(localized: "Send by Email", bundle: .module)) { [weak self] in self?.emailClicked() })
        }
        for entry in sharingEntries() {
            if case .uploadTo(let targets) = entry {
                for target in targets {
                    actions.append(action(SharingEntry.uploadTitle(to: target)) { [weak self] in self?.onCommand?(.uploadTo(target.id)) })
                }
            } else {
                actions.append(action(entry.actionTitle) { [weak self] in self?.run(entry) })
            }
        }
        actions.append(action(String(localized: "Move to Trash", bundle: .module)) { [weak self] in self?.onCommand?(.moveToTrash) })
        actions.append(action(String(localized: "Close", bundle: .module)) { [weak self] in self?.onCommand?(.close) })
        if cardCount() > 1 {
            actions.append(action(String(localized: "Save All", bundle: .module)) { [weak self] in self?.onCommand?(.saveAll) })
            actions.append(action(String(localized: "Close All", bundle: .module)) { [weak self] in self?.onCommand?(.closeAll) })
        }
        return actions
    }

    /// The changes to the picture the menu and VoiceOver offer, with their names; Scale to 1× only above one pixel
    /// per point.
    private func pictureChanges(for offer: PictureChangeOffer) -> [(String, PictureChange)] {
        var changes: [(String, PictureChange)] = [
            (String(localized: "Rotate Left", bundle: .module), .rotateLeft),
            (String(localized: "Rotate Right", bundle: .module), .rotateRight),
            (String(localized: "Flip Horizontal", bundle: .module), .flipHorizontal),
            (String(localized: "Flip Vertical", bundle: .module), .flipVertical),
        ]
        if offer.pixelsPerPoint > 1 {
            changes.append((String(localized: "Scale to 1×", bundle: .module), .scaleToOneX(pixelsPerPoint: offer.pixelsPerPoint)))
        }
        return changes
    }

    /// The card slides in from the screen edge with a short ease-out, or simply appears with Reduce
    /// Motion on.
    func slideIn(fromLeft: Bool = true) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = fromLeft ? -36 : 36
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
        // Copied from the keyboard, or the Copy Latest Capture shortcut, the capsule that says so is not showing.
        if !isHovering, !isTrashing {
            noticeBadge.show(String(localized: "Copied", bundle: .module), symbol: "checkmark.circle.fill", colors: [.white, .systemGreen])
            noticeReset?.cancel()
            noticeReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, let self, !isTrashing else { return }
                noticeBadge.hide()
            }
        }
        VoiceOver.announce(String(localized: "Copied", bundle: .module), from: self)
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
        savedBadge.isHidden = isHovering
        updateAccessibility()
    }

    /// The saved copy is of an earlier picture: the card offers Save again.
    func showUnsaved() {
        saveButton.title = String(localized: "Save", bundle: .module)
        saveButton.symbolName = "square.and.arrow.down"
        saveButton.toolTip = nil
        savedBadge.isHidden = true
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
        if !isTrashing { onPointerHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        onPointerHover?(false)
    }

    /// The shade and the buttons fade in over a moment, or simply appear with Reduce Motion on.
    func setHovering(_ hovering: Bool) {
        // A card waiting to go to the Trash offers only Undo.
        let hovering = hovering && !isTrashing
        guard hovering != isHovering else { return }
        hoverGeneration += 1
        let generation = hoverGeneration
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        isHovering = hovering
        onHold?(.pointer, hovering)
        if hovering {
            // Which side buttons the capture has is asked each time: an upload may have ended, or a destination
            // been added, since the pointer was last here.
            updateExtras()
            let shown = hoverControls
            for control in allHoverControls { control.isHidden = !shown.contains { $0 === control } }
            savedBadge.isHidden = true
            noticeReset?.cancel()
            noticeBadge.hide()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(duration == 0)
        hoverShade.opacity = hovering || isTrashing ? 1 : 0
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            allHoverControls.forEach { $0.animator().alphaValue = hovering ? 1 : 0 }
        }
        guard !hovering else { return }
        // Hidden once faded, so invisible buttons never take clicks.
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard let self, generation == hoverGeneration else { return }
            allHoverControls.forEach { $0.isHidden = true }
            savedBadge.isHidden = item.savedURL == nil
        }
    }

    // MARK: Click, drag, swipe, menu

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Clicking a card must not pull this app in front of the one being worked in.
        NSApp.preventWindowOrdering()
        guard !isTrashing else { return }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        // A picture opens in the editor; a recording in the recording window.
        if event.clickCount == 2 { onCommand?(.annotate) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        // The file in the format Settings choose, made now when it is not the capture itself.
        let draggingItem = NSDraggingItem(pasteboardWriter: (fileToHandOver?() ?? item.fileURL) as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: NSImage(cgImage: item.thumbnail, size: bounds.size))
        onHold?(.drag, true)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// A click on the picture, not a drag, gives the card the keyboard.
    override func mouseUp(with event: NSEvent) {
        let clicked = mouseDownPoint != nil && event.clickCount == 1
        mouseDownPoint = nil
        if clicked { onFocus?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onHold?(.drag, false)
    }

    override func scrollWheel(with event: NSEvent) {
        applySwipePhase(event.phase, deltaX: event.scrollingDeltaX)
    }

    func applySwipePhase(_ phase: NSEvent.Phase, deltaX: CGFloat) {
        guard !isTrashing else { return }
        switch phase {
        case .began:
            swipeDistance = 0
            setSwipeOffset(0, animated: false)
        case .changed:
            swipeDistance += deltaX
            let towardEdge = slidesFromLeft ? swipeDistance <= 0 : swipeDistance >= 0
            let offset = towardEdge ? swipeDistance : swipeDistance * 0.35
            setSwipeOffset(offset, animated: false)
        case .ended:
            let shouldClose = abs(swipeDistance) > 50
            swipeDistance = 0
            if shouldClose {
                onCommand?(.close)
            } else {
                setSwipeOffset(0, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        case .cancelled:
            swipeDistance = 0
            setSwipeOffset(0, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        default:
            break
        }
    }

    private func setSwipeOffset(_ offset: CGFloat, animated: Bool) {
        swipeTranslation = offset
        let targetAlpha = max(0.4, 1 - abs(offset) / 140)
        let duration = animated ? Theme.Motion.slide : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(duration == 0)
        layer?.sublayerTransform = offset == 0 ? CATransform3DIdentity : CATransform3DMakeTranslation(offset, 0, 0)
        CATransaction.commit()
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = targetAlpha
            }
        } else {
            alphaValue = targetAlpha
        }
    }

    /// Shows or hides the zero-wakeup Core Animation countdown ring around the top-left corner.
    /// Under Reduce Motion the ring steps down once a second, as the Self-Timer's does, rather than gliding.
    func setCountdown(_ state: (remaining: TimeInterval, interval: TimeInterval)?) {
        countdownState = state
        let lines = [countdownOutline, countdownRing]
        lines.forEach { $0.removeAllAnimations() }
        guard let state, state.remaining > 0, !isTrashing else {
            lines.forEach { $0.isHidden = true }
            return
        }
        let interval = max(state.interval, 0.1)
        let fraction = CGFloat(min(max(state.remaining / interval, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for line in lines {
            line.isHidden = false
            line.strokeStart = 0
            line.strokeEnd = 0
        }
        CATransaction.commit()
        let animation: CAAnimation
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Each whole second's length held until the next: discrete steps, still without waking the app.
            let seconds = Int(state.remaining.rounded(.up))
            let stepping = CAKeyframeAnimation(keyPath: "strokeEnd")
            let times = (0...seconds).map { min(Double($0), state.remaining) }
            stepping.values = times.map { CGFloat(max(0, (state.remaining - $0) / interval)) }
            stepping.keyTimes = times.map { NSNumber(value: $0 / state.remaining) }
            stepping.calculationMode = .discrete
            animation = stepping
        } else {
            let gliding = CABasicAnimation(keyPath: "strokeEnd")
            gliding.fromValue = fraction
            gliding.toValue = 0
            gliding.timingFunction = CAMediaTimingFunction(name: .linear)
            animation = gliding
        }
        animation.duration = state.remaining
        lines.forEach { $0.add(animation, forKey: "countdown") }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        isTrashing ? nil : makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // Items are enabled by what the card allows, not by whether a target answers.
        menu.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ symbol: String, _ action: Selector, _ command: CardCommand? = nil) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menuItem.target = self
            if let command { Self.showKey(of: command, on: menuItem) }
            menu.addItem(menuItem)
            return menuItem
        }
        add(String(localized: "Copy", bundle: .module), "doc.on.doc", #selector(copyClicked), .copy)
        add(String(localized: "Save", bundle: .module), "square.and.arrow.down", #selector(saveClicked), .save)
        add(String(localized: "Save As…", bundle: .module), "square.and.arrow.down.on.square", #selector(saveAsClicked), .saveAs)
        menu.addItem(.separator())
        // A picture is marked up, a movie trimmed and made smaller; a GIF only plays (`CaptureMedia.openMenuTitle`).
        add(item.media.openMenuTitle, item.media.openSymbolName, #selector(annotateClicked), .annotate)
        add(String(localized: "Open", bundle: .module), "arrow.up.forward.app", #selector(openClicked), .open)
        add(item.kind == .screenshot ? String(localized: "Preview", bundle: .module) : String(localized: "Quick Look", bundle: .module), "eye", #selector(quickLookClicked), .quickLook)
        if item.kind == .screenshot {
            add(String(localized: "Recognize Text…", bundle: .module), "text.viewfinder", #selector(recognizeTextClicked), .recognizeText)
            add(String(localized: "Pin to Screen", bundle: .module), "pin", #selector(pinClicked), .pin)
            add(String(localized: "Print…", bundle: .module), "printer", #selector(printClicked), .print)
            addPictureItems(to: menu)
        }
        add(String(localized: "Show in Finder", bundle: .module), "folder", #selector(revealClicked))
        menu.addItem(.separator())
        addSharingItems(to: menu, add: add)
        add(String(localized: "Move to Trash", bundle: .module), "trash", #selector(trashClicked), .moveToTrash)
        add(String(localized: "Close", bundle: .module), "xmark", #selector(closeClicked), .close)
        // What the whole stack can do, once there is more than one card.
        if cardCount() > 1 {
            menu.addItem(.separator())
            add(String(localized: "Save All", bundle: .module), "square.and.arrow.down.on.square", #selector(saveAllClicked), .saveAll)
            add(String(localized: "Close All", bundle: .module), "xmark.square", #selector(closeAllClicked), .closeAll)
        }
        return menu
    }

    /// Shows the key a command has on the keyboard beside its menu item. (The item is not answered by that key:
    /// the cards answer their own keys, see `CardStackView`.)
    private static func showKey(of command: CardCommand, on menuItem: NSMenuItem) {
        guard let binding = CardKeys.binding(for: command) else { return }
        menuItem.keyEquivalent = CardKeys.menuEquivalent(for: binding.key)
        var mask: NSEvent.ModifierFlags = []
        if binding.modifiers.contains(.command) { mask.insert(.command) }
        if binding.modifiers.contains(.shift) { mask.insert(.shift) }
        if binding.modifiers.contains(.option) { mask.insert(.option) }
        if binding.modifiers.contains(.control) { mask.insert(.control) }
        menuItem.keyEquivalentModifierMask = mask
    }

    /// Transform: turn, flip, or scale the picture. Offered to a screenshot whose picture the card can change;
    /// dimmed, with the reason as a tooltip, while it cannot (edited, on a background, or open in the editor).
    private func addPictureItems(to menu: NSMenu) {
        let offer = pictureOffer()
        guard offer.availability != .unsupported else { return }
        let reason: String? = switch offer.availability {
        case .marked: String(localized: "This capture has marks or a background. They would stay as they were.", bundle: .module)
        case .beingEdited: String(localized: "Close the capture’s editor first.", bundle: .module)
        default: nil
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (title, change) in pictureChanges(for: offer) {
            let entry = NSMenuItem(title: title, action: #selector(pictureChangeClicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = change
            entry.isEnabled = offer.availability == .available
            entry.toolTip = reason
            Self.showKey(of: .picture(change), on: entry)
            submenu.addItem(entry)
        }
        if offer.pixelsPerPoint <= 1 {
            // Already at one pixel per point: the entry stays, dimmed, so the menu does not change shape.
            let entry = NSMenuItem(title: String(localized: "Scale to 1×", bundle: .module), action: nil, keyEquivalent: "")
            entry.isEnabled = false
            entry.toolTip = String(localized: "Already one pixel per point.", bundle: .module)
            submenu.addItem(entry)
        }
        let parent = NSMenuItem(title: String(localized: "Transform", bundle: .module), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: nil)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    func menuWillOpen(_ menu: NSMenu) {
        onHold?(.menu, true)
    }

    func menuDidClose(_ menu: NSMenu) {
        onHold?(.menu, false)
    }

    /// Share, always, and Send by Email while a message can be started; then the upload entries, which exist
    /// only for a person who set up a destination.
    private func addSharingItems(to menu: NSMenu, add: (String, String, Selector, CardCommand?) -> NSMenuItem) {
        // Not the system's own Share item, which draws an icon the rest of this menu does not have.
        _ = add(String(localized: "Share…", bundle: .module), "square.and.arrow.up", #selector(shareClicked), nil)
        if EmailSharing.canSend(item.fileURL) {
            _ = add(String(localized: "Send by Email", bundle: .module), "envelope", #selector(emailClicked), nil)
        }
        for entry in sharingEntries() {
            guard case .uploadTo(let targets) = entry else {
                // The plain Upload shows the key it has.
                let key: CardCommand? = if case .upload = entry { .upload } else { nil }
                add(entry.menuTitle, entry.symbolName, #selector(sharingEntryClicked(_:)), key).representedObject = entry
                continue
            }
            let choice = NSMenuItem(title: entry.menuTitle, action: nil, keyEquivalent: "")
            choice.image = NSImage(systemSymbolName: entry.symbolName, accessibilityDescription: nil)
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
        menu.addItem(.separator())
    }

    /// The upload entries the card offers now, for its menu and VoiceOver alike.
    private func sharingEntries() -> [SharingEntry] {
        let state: UploadState = switch upload {
        case .uploading?: .uploading
        case .failed?: .failed
        case .finished?, nil: .idle
        }
        return uploadMenu().entries(state: state, hasLink: hasLink(), canDelete: canDeleteFromStorage())
    }

    /// Does what an upload entry of the menu or VoiceOver says; Upload To is a destination's own entry.
    private func run(_ entry: SharingEntry) {
        switch entry {
        case .cancelUpload: onCommand?(.cancelUpload)
        case .retryUpload: onCommand?(.retryUpload)
        case .copyError: copyError()
        case .upload: onCommand?(.upload)
        case .uploadTo: break
        case .copyLink: onCommand?(.copyLink)
        case .deleteFromStorage: onCommand?(.deleteFromStorage)
        }
    }

    @objc private func uploadClicked() { onCommand?(.upload) }
    @objc private func uploadToClicked(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? UUID else { return }
        onCommand?(.uploadTo(destination))
    }
    @objc private func sharingEntryClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SharingEntry else { return }
        run(entry)
    }
    /// Puts the failure's sentence on the clipboard, for a bug report or a server's owner.
    private func copyError() {
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

    /// As Share, the file in the format Settings choose.
    @objc private func emailClicked() { EmailSharing.send(fileToHandOver?() ?? item.fileURL) }

    @objc private func copyClicked() { onCommand?(.copy) }
    @objc private func saveClicked() { onCommand?(.save) }
    @objc private func saveAsClicked() { onCommand?(.saveAs) }
    @objc private func openClicked() { onCommand?(.open) }
    @objc private func annotateClicked() { onCommand?(.annotate) }
    @objc private func revealClicked() { onCommand?(.reveal) }
    @objc private func recognizeTextClicked() { onCommand?(.recognizeText) }
    @objc private func pinClicked() { onCommand?(.pin) }
    @objc private func printClicked() { onCommand?(.print) }
    @objc private func trashClicked() { onCommand?(.moveToTrash) }
    @objc private func undoClicked() { onCommand?(.undoTrash) }
    @objc private func closeClicked() { onCommand?(.close) }
    @objc private func quickLookClicked() { onCommand?(.quickLook) }
    @objc private func saveAllClicked() { onCommand?(.saveAll) }
    @objc private func closeAllClicked() { onCommand?(.closeAll) }
    @objc private func pictureChangeClicked(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? PictureChange else { return }
        onCommand?(.picture(change))
    }

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
