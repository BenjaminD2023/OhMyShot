import AppKit
import ImageIO
import OMSCore
import QuartzCore
import UniformTypeIdentifiers
import VisionKit

/// How pins look, from Settings; every pin takes it again when it changes.
struct PinAppearance: Equatable {
    var cornerRadius: CGFloat
    var shadow: Bool
    var border: Bool
}

/// One pin's window: borderless, above every app's normal windows, on every Space and over full-screen
/// apps, so a reference stays in view wherever the work goes. Clicked, it takes the keys without bringing
/// OhMyShot forward, as Spotlight does: Escape, the arrows, and ⌘C reach it while the app in front stays
/// in front. Its shadow is the system window shadow, as the Translation Lens's, and lies outside the
/// window, so nothing around a pin catches the pointer.
final class PinWindow: NSPanel {
    let pin: PinController.Pin
    /// The pin's size in points at 100 percent.
    let baseSize: CGSize
    private(set) var zoom: CGFloat
    private var previousZoom: CGFloat?
    private(set) var opacity: CGFloat = 1
    private(set) var isLocked = false
    private(set) var lockBadgePanel: NSPanel?
    private let pinView: PinView
    private let actions: PinController.Actions

    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    /// Locked or unlocked: the menu bar's Unlock Pins follows.
    var onChange: (() -> Void)?

    /// `textReader` reads a picture's text for Live Text.
    init(
        pin: PinController.Pin, frame: CGRect, zoom: CGFloat, appearance: PinAppearance, actions: PinController.Actions,
        textReader: PinTextReader? = nil
    ) {
        self.pin = pin
        baseSize = Self.baseSize(of: pin.content)
        self.zoom = zoom
        self.actions = actions
        pinView = PinView(content: pin.content, appearance: appearance, textReader: textReader)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = appearance.shadow
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        pinView.frame = CGRect(origin: .zero, size: frame.size)
        pinView.autoresizingMask = [.width, .height]
        contentView = pinView
        pinView.pinWindow = self
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A color's swatch, in points.
    static let swatchSize = CGSize(width: 128, height: 128)

    /// How large a pin of `content` is at 100 percent: a picture at its own size, a text card as its text
    /// lays out, a color as a swatch.
    static func baseSize(of content: PinController.Content) -> CGSize {
        switch content {
        case .image(let image, let scale): CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        case .text(let text): PinText.cardSize(for: text)
        case .color: swatchSize
        }
    }

    var isPicture: Bool {
        if case .image = pin.content { true } else { false }
    }

    override var canBecomeKey: Bool { !isLocked }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        pinView.isFocused = true
        pinView.readTextIfNeeded()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown where [53, 123, 124, 125, 126].contains(event.keyCode) && firstResponder !== pinView:
            // Escape and the arrows stay the pin's even while Live Text holds the keyboard.
            pinView.keyDown(with: event)
            return
        case .leftMouseDown, .rightMouseDown:
            // Key before the press is delivered: Live Text's text takes no first mouse, so on a pin that was
            // not key the first press on text only made it key.
            if canBecomeKey, !isKeyWindow { makeKey() }
        default:
            break
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        pinView.isFocused = false
    }

    func apply(_ appearance: PinAppearance) {
        hasShadow = appearance.shadow
        pinView.apply(appearance)
        invalidateShadow()
    }

    // MARK: Zoom, opacity, place

    /// Zooms to `newZoom`, keeping `anchor` (global points; the pin's center when nil) where it is.
    func setZoom(_ newZoom: CGFloat, around anchor: CGPoint? = nil) {
        let clamped = PinGeometry.clamp(newZoom, to: PinGeometry.zoomRange)
        guard abs(clamped - zoom) > 0.0001 else { return }
        let point = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let next = PinGeometry.zoomed(frame, to: CGSize(width: baseSize.width * clamped, height: baseSize.height * clamped), around: point)
        zoom = clamped
        setFrame(next, display: true)
        updateLockBadgePanelFrame()
        invalidateShadow()
        pinView.showReading(String(localized: "\(Int((zoom * 100).rounded()))%", bundle: .module))
        updateAccessibilityValue()
    }

    /// Toggles between 100% actual size and the previous zoom (or 200% when already at 100%), anchored at `anchor`.
    func toggleZoom(around anchor: CGPoint? = nil) {
        if abs(zoom - 1.0) > 0.01 {
            previousZoom = zoom
            setZoom(1.0, around: anchor)
        } else {
            let target = previousZoom ?? 2.0
            previousZoom = nil
            setZoom(target, around: anchor)
        }
    }

    /// Returns a file URL suitable for dragging this picture pin into another app.
    func fileForDrag() -> URL? {
        if let url = actions.fileForDrag?(pin) { return url }
        guard case .image(let image, _) = pin.content else { return nil }
        if case .file(let url) = pin.origin, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }
        let tempURL = FileManager.default.temporaryDirectory.appending(path: "OhMyShot Pin \(pin.id.uuidString).png")
        if FileManager.default.fileExists(atPath: tempURL.path(percentEncoded: false)) {
            return tempURL
        }
        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? tempURL : nil
    }

    /// Fades the picture only: its readings, buttons, and ring stay solid, so the reading that says how
    /// faint it is can still be read.
    func setOpacity(_ newOpacity: CGFloat) {
        opacity = PinGeometry.clamp(newOpacity, to: PinGeometry.opacityRange)
        pinView.setPictureOpacity(opacity)
        invalidateShadow()
        pinView.showReading(String(localized: "Opacity \(Int((opacity * 100).rounded()))%", bundle: .module))
        updateAccessibilityValue()
    }

    func move(by delta: CGVector) {
        setFrameOrigin(CGPoint(x: frame.minX + delta.dx, y: frame.minY + delta.dy))
        updateLockBadgePanelFrame()
    }

    /// Lets every click through to what is under the pin, except on its lock badge, which unlocks this pin alone.
    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        ignoresMouseEvents = locked
        if locked, isKeyWindow { resignKey() }
        pinView.isLocked = locked
        if locked {
            pinView.showReading(String(localized: "Locked", bundle: .module))
            installLockBadgePanel()
        } else {
            removeLockBadgePanel()
        }
        onChange?()
    }

    @objc private func unlockFromBadge() {
        setLocked(false)
    }

    private func installLockBadgePanel() {
        removeLockBadgePanel()
        pinView.layoutSubtreeIfNeeded()
        let button = CardButton(style: .round, title: String(localized: "Unlock", bundle: .module), symbolName: "lock.fill")
        button.target = self
        button.action = #selector(unlockFromBadge)
        button.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        let badgeRect = convertToScreen(pinView.lockMarkFrame)
        let panel = NSPanel(contentRect: badgeRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = collectionBehavior
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.contentView = button
        if isVisible {
            addChildWindow(panel, ordered: .above)
        }
        lockBadgePanel = panel
    }

    private func updateLockBadgePanelFrame() {
        guard let panel = lockBadgePanel else { return }
        pinView.layoutSubtreeIfNeeded()
        panel.setFrame(convertToScreen(pinView.lockMarkFrame), display: true)
    }

    private func removeLockBadgePanel() {
        guard let panel = lockBadgePanel else { return }
        lockBadgePanel = nil
        if panel.parent != nil { removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    private func updateAccessibilityValue() {
        pinView.setAccessibilityValue(String(localized: "\(Int((zoom * 100).rounded())) percent, opacity \(Int((opacity * 100).rounded())) percent", bundle: .module))
    }

    #if DEBUG
    func debugShowControls() {
        pinView.debugShowControls()
    }

    func debugReadText(selectAll: Bool) async -> Int {
        await pinView.debugReadText(selectAll: selectAll)
    }

    func debugSelectText(_ range: NSRange) {
        pinView.textView?.setSelectedRange(range)
    }
    #endif

    // MARK: Actions

    /// Copies what the pin holds: the picture, the text, or the color's hex.
    func copyPin() {
        switch pin.content {
        case .image: actions.copy(pin)
        case .text(let text): Self.copy(text)
        case .color(let color): Self.copy(color.hex)
        }
        pinView.showReading(String(localized: "Copied", bundle: .module))
    }

    /// Copies text selected in the picture with Live Text.
    func copySelectedText(_ text: String) {
        Self.copy(text)
        pinView.showReading(String(localized: "Copied", bundle: .module))
    }

    /// Copies a color pin's value as rgb().
    func copyRGB() {
        guard case .color(let color) = pin.content else { return }
        Self.copy(color.rgb)
        pinView.showReading(String(localized: "Copied", bundle: .module))
    }

    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Saving, marking up, and reading text are for pictures.

    func savePin() {
        if isPicture { actions.save(pin) }
    }

    func savePinAs() {
        if isPicture { actions.saveAs(pin) }
    }

    func annotatePin() {
        if isPicture { actions.annotate(pin) }
    }

    /// Prints the picture as it was pinned, at its own size.
    func printPin() {
        guard case .image(let image, let scale) = pin.content else { return }
        ImagePrinter.print(image, pixelsPerPoint: scale, title: String(localized: "Pin", bundle: .module))
    }

    /// File › Print… while the pin is in front.
    @objc func printCapture(_ sender: Any?) {
        printPin()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printCapture(_:)) { return isPicture }
        return super.validateMenuItem(menuItem)
    }

    func recognizePinText() {
        if isPicture { actions.recognizeText(pin) }
    }

    func closePin() {
        removeLockBadgePanel()
        onClose?(self)
    }

    func closeAllPins() {
        onCloseAll?()
    }
}

/// What a pin shows: a picture, a text card, or a color swatch, rounded as Settings says, with a hairline
/// edge, an accent ring while it has the keys, the Close and More buttons on hover, and a reading capsule
/// for its zoom and opacity as they change (a color's value rests there). A picture's text can be selected
/// in place with Live Text once VisionKit has read it.
final class PinView: NSView, NSDraggingSource {
    weak var pinWindow: PinWindow?

    private let content: PinController.Content
    /// The picture, the card's fill, or the swatch's checkerboard: what corners, edge, and opacity apply to.
    private let contentLayer = CALayer()
    private let swatch = CALayer()
    private let checker = PinCheckerLayer()
    /// A text card's text, which selects.
    let textView: PinTextView?
    /// What the reading shows when nothing else is: a color's hex.
    private var restingReading: String?
    private let ring = CALayer()
    private let reading = ReadingCapsule()
    /// A locked pin's lasting mark: a small dark disc in the card corner button's style, the one kind of
    /// dark control that sits over a picture; the reading says "Locked" once as it locks. Clicking it unlocks the pin.
    let lockMark = CardButton(style: .round, title: String(localized: "Unlock", bundle: .module), symbolName: "lock.fill")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private let moreButton = CardButton(style: .round, title: String(localized: "More", bundle: .module), symbolName: "ellipsis")
    private var look: PinAppearance
    private var tracking: NSTrackingArea?
    /// Close and More show while the pointer is over an unlocked pin, and take clicks only then.
    private var controlsShown = false
    private var resizingCorner: PinGeometry.Corner?
    private var optionDragStart: CGPoint?

    var lockMarkFrame: CGRect { lockMark.frame }
    private let textReader: PinTextReader?
    private var textReading: Task<Void, Never>?
    /// Live Text over the picture, once VisionKit has found text or a code in it.
    private var liveText: ImageAnalysisOverlayView?
    private var readingFade: Task<Void, Never>?
    private var displayOptions: NSObjectProtocol?

    var isFocused = false {
        didSet { if isFocused != oldValue { updateRing() } }
    }

    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            if isLocked {
                liveText?.resetSelection()
                textView?.clearSelection()
            }
            lockMark.isHidden = !isLocked
            setControlsVisible(false)
            updateRing()
            needsLayout = true
        }
    }

    init(content: PinController.Content, appearance: PinAppearance, textReader: PinTextReader? = nil) {
        self.content = content
        look = appearance
        if case .image = content { self.textReader = textReader } else { self.textReader = nil }
        if case .text(let text) = content {
            textView = PinTextView(text: text)
        } else {
            textView = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        contentLayer.masksToBounds = true
        contentLayer.cornerCurve = .continuous
        layer?.addSublayer(contentLayer)
        var scale: CGFloat = 2
        switch content {
        case .image(let image, let pictureScale):
            scale = pictureScale
            contentLayer.contents = image
            contentLayer.contentsScale = pictureScale
            contentLayer.contentsGravity = .resize
            contentLayer.minificationFilter = .trilinear
        case .text:
            if let textView {
                addSubview(textView)
                textView.delegate = self
                textView.onCopy = { [weak self] text in self?.pinWindow?.copySelectedText(text) }
            }
        case .color(let color):
            // Translucent colors over the checkerboard, so the value never seems more solid than it is.
            if color.alpha < 1 { contentLayer.addSublayer(checker) }
            swatch.backgroundColor = color.original
            contentLayer.addSublayer(swatch)
            restingReading = color.hex
        }
        ring.cornerCurve = .continuous
        // Inside the picture's edge, so kept to 1.5 pt, most of it over the hairline.
        ring.borderWidth = 1.5
        ring.isHidden = true
        ring.zPosition = 1
        layer?.addSublayer(ring)
        reading.setScale(scale)
        reading.layer.zPosition = 1
        layer?.addSublayer(reading.layer)
        reading.layer.opacity = 0
        reading.layer.isHidden = false
        lockMark.isHidden = true
        lockMark.target = self
        lockMark.action = #selector(unlockClicked)
        lockMark.setAccessibilityLabel(String(localized: "Unlock", bundle: .module))
        addSubview(lockMark)

        for (button, action) in [(closeButton, #selector(closeClicked)), (moreButton, #selector(moreClicked(_:)))] {
            button.target = self
            button.action = action
            button.alphaValue = 0
            addSubview(button)
        }
        setAccessibilityElement(true)
        var actions: [NSAccessibilityCustomAction] = []
        func action(_ name: String, _ run: @escaping (PinWindow) -> Void) {
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let window = self?.pinWindow else { return false }
                run(window)
                return true
            })
        }
        switch content {
        case .image(let image, let pictureScale):
            setAccessibilityRole(.image)
            setAccessibilityLabel(String(localized: "Pin, \(Int(CGFloat(image.width) / pictureScale)) by \(Int(CGFloat(image.height) / pictureScale)) points", bundle: .module))
            action(String(localized: "Copy", bundle: .module)) { $0.copyPin() }
            action(String(localized: "Save", bundle: .module)) { $0.savePin() }
            action(String(localized: "Print", bundle: .module)) { $0.printPin() }
            action(String(localized: "Annotate", bundle: .module)) { $0.annotatePin() }
            action(String(localized: "Recognize Text", bundle: .module)) { $0.recognizePinText() }
        case .text(let text):
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(String(localized: "Text pin: \(PinText.displayed(text))", bundle: .module))
            action(String(localized: "Copy", bundle: .module)) { $0.copyPin() }
        case .color(let color):
            setAccessibilityRole(.image)
            setAccessibilityLabel(String(localized: "Color pin, \(color.hex)", bundle: .module))
            action(String(localized: "Copy Hex", bundle: .module)) { $0.copyPin() }
            action(String(localized: "Copy RGB", bundle: .module)) { $0.copyRGB() }
        }
        action(String(localized: "Lock", bundle: .module)) { $0.setLocked(true) }
        action(String(localized: "Close", bundle: .module)) { $0.closePin() }
        setAccessibilityCustomActions(actions)
        apply(appearance)
        if let restingReading {
            reading.text = restingReading
            reading.layer.opacity = 1
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        textReading?.cancel()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

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
                self.apply(self.look)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(look)
    }

    func apply(_ appearance: PinAppearance) {
        look = appearance
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.cornerRadius = appearance.cornerRadius
        ring.cornerRadius = appearance.cornerRadius
        liveText?.layer?.cornerRadius = appearance.cornerRadius
        let border = appearance.border || contrast
        contentLayer.borderWidth = border ? (contrast ? 1 : 0.5) : 0
        if case .text = content {
            // The Text Result Card's materials: the reading capsule's fill and hairline at card size.
            let fill = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.96) : CGColor(gray: 1, alpha: 0.97)
            contentLayer.backgroundColor = fill
            contentLayer.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
            // On a short card Close and More stand over the ends of a line: the card under them hides
            // the letters they cover, which would show through the dark disc.
            let backdrop = fill.copy(alpha: 1).flatMap(NSColor.init(cgColor:))
            closeButton.backdrop = backdrop
            moreButton.backdrop = backdrop
        } else {
            // A hairline, so a white picture or swatch reads against a white window: 0.5 pt black 0.18,
            // 1 pt black 0.35 with Increase Contrast (always shown then).
            contentLayer.borderColor = CGColor(gray: 0, alpha: contrast ? 0.35 : 0.18)
        }
        reading.applyAppearance(dark: dark, contrast: contrast)
        // The checkerboard token: quiet in either appearance, a little firmer with Increase Contrast.
        checker.colors = dark
            ? (CGColor(gray: 0.20, alpha: 1), CGColor(gray: contrast ? 0.30 : 0.25, alpha: 1))
            : (CGColor(gray: 1, alpha: 1), CGColor(gray: contrast ? 0.84 : 0.91, alpha: 1))
        CATransaction.commit()
        textView?.needsDisplay = true
        updateRing()
    }

    /// The accent ring marks the pin the keys go to.
    private func updateRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.borderColor = Theme.cgColor(.keyboardFocusIndicatorColor, for: effectiveAppearance)
        ring.isHidden = !isFocused || isLocked
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        swatch.frame = contentLayer.bounds
        checker.frame = contentLayer.bounds
        ring.frame = bounds
        // The reading 10 pt above the bottom edge, centered.
        let size = reading.layer.bounds.size
        reading.layer.frame.origin = CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: min(10, max(bounds.height - size.height, 0) / 2))
        // A color's value rests there only while the swatch has room for it around the capsule.
        if let restingReading, reading.text == restingReading {
            reading.layer.opacity = bounds.width >= size.width + 16 && bounds.height >= size.height + 16 ? 1 : 0
        }
        CATransaction.commit()
        // Close and More where they fit, 8 pt in from the top corners or centered in a short pin's
        // height; a locked pin's mark where More would be.
        let buttons = PinGeometry.cornerButtons(in: bounds.size, button: closeButton.intrinsicContentSize.width)
        closeButton.isHidden = buttons.close == nil
        moreButton.isHidden = buttons.more == nil
        if let close = buttons.close { closeButton.frame = close }
        if let more = buttons.more { moreButton.frame = more }
        lockMark.frame = buttons.trailing
        liveText?.setContentsRectNeedsUpdate()
        if let textView {
            let zoom = pinWindow?.zoom ?? 1
            textView.zoom = zoom
            textView.frame = bounds.insetBy(dx: PinText.padding.width * zoom, dy: PinText.padding.height * zoom)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        checker.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Shows `text` in the reading capsule, then lets it fade after a moment.
    func showReading(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reading.text = text
        needsLayout = true
        layoutSubtreeIfNeeded()
        reading.layer.removeAllAnimations()
        reading.layer.opacity = 1
        CATransaction.commit()
        readingFade?.cancel()
        readingFade = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            // A color's value comes back in place of the passing reading.
            if let resting = self.restingReading {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.reading.text = resting
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
                CATransaction.commit()
                return
            }
            let fade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
            CATransaction.begin()
            CATransaction.setAnimationDuration(fade)
            self.reading.layer.opacity = 0
            CATransaction.commit()
        }
    }

    func setPictureOpacity(_ opacity: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.opacity = Float(opacity)
        CATransaction.commit()
        textView?.alphaValue = opacity
        liveText?.alphaValue = opacity
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect]
        if window?.frame.contains(NSEvent.mouseLocation) == true {
            options.insert(.assumeInside)
            // A pin that opens under the pointer gets no mouseEntered.
            readTextIfNeeded()
        }
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
        readTextIfNeeded()
    }

    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: event.locationInWindow) }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if let window, window.frame.contains(NSEvent.mouseLocation) {
            updateCursor(at: window.convertPoint(fromScreen: NSEvent.mouseLocation))
        }
    }

    /// Which corner of an unlocked pin `point` (in the pin's coordinates) grabs to resize it, leaving Close and More
    /// to take their clicks while they show.
    func resizeCorner(at point: CGPoint) -> PinGeometry.Corner? {
        guard !isLocked else { return nil }
        if controlsShown {
            if !closeButton.isHidden, closeButton.frame.contains(point) { return nil }
            if !moreButton.isHidden, moreButton.frame.contains(point) { return nil }
        }
        return PinGeometry.resizeCorner(at: point, in: bounds.size)
    }

    private static func cursor(for corner: PinGeometry.Corner) -> NSCursor {
        switch corner {
        case .topLeft: NSCursor.frameResize(position: .topLeft, directions: .all)
        case .topRight: NSCursor.frameResize(position: .topRight, directions: .all)
        case .bottomLeft: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
    }

    /// The resize cursor at the corners, the I-beam where a press would go to the picture's or the card's text,
    /// the arrow everywhere else: by the border, with ⌘ held, over the corner buttons.
    private func updateCursor(at windowPoint: CGPoint) {
        let local = convert(windowPoint, from: nil)
        if let corner = resizeCorner(at: local) {
            Self.cursor(for: corner).set()
            return
        }
        guard let text: NSView = liveText ?? textView else {
            NSCursor.arrow.set()
            return
        }
        let target = hitTest(superview?.convert(windowPoint, from: nil) ?? windowPoint)
        let onText = target.map { $0 === text || $0.isDescendant(of: text) } ?? false
        (onText ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    /// Close and More fade in on hover wherever they fit (`PinGeometry.cornerButtons`), never on a locked pin.
    private func setControlsVisible(_ visible: Bool) {
        controlsShown = visible && !isLocked
        let shown = controlsShown
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            closeButton.animator().alphaValue = shown ? 1 : 0
            moreButton.animator().alphaValue = shown ? 1 : 0
        }
    }

    #if DEBUG
    /// Shows Close and More as the pointer would, for scripted renders.
    func debugShowControls() {
        setControlsVisible(true)
    }

    /// Reads the picture's text now and waits for it, for scripted checks; selects all of it when asked.
    func debugReadText(selectAll: Bool) async -> Int {
        readTextIfNeeded()
        await textReading?.value
        guard let liveText else { return 0 }
        if selectAll { liveText.selectedRanges = [liveText.text.startIndex..<liveText.text.endIndex] }
        return liveText.text.count
    }

    /// Whether Live Text has text or a detected item at `point`, in the pin's coordinates.
    func debugHasText(at point: CGPoint) -> Bool {
        guard let liveText else { return false }
        return liveText.hasInteractiveItem(at: liveText.analysisPoint(point, from: self))
    }
    #endif

    /// Faded out, Close and More let the pin take the click, so it drags from under them. Live Text covers
    /// the whole picture, and a card's text its card inside the padding, but they take only the presses
    /// `takesTextPress(at:)` gives them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if isLocked, !lockMark.isHidden, lockMark.frame.contains(local) { return lockMark }
        let hit = super.hitTest(point)
        if !controlsShown, let hit, hit === closeButton || hit === moreButton { return self }
        if let text: NSView = liveText ?? textView, let hit, hit === text || hit.isDescendant(of: text) {
            return takesTextPress(at: local) ? hit : self
        }
        return hit
    }

    // MARK: Live Text

    /// Reads the picture's text the first time the pointer comes to the pin: VisionKit takes a fraction of a
    /// second, spent only on pins someone reaches for.
    func readTextIfNeeded() {
        guard textReading == nil, let textReader, case .image(let image, _) = content else { return }
        textReading = Task { [weak self] in
            let probe = LatencyProbe("pin.livetext")
            let analysis = await textReader.read(image)
            probe.end()
            guard let self, !Task.isCancelled, let analysis else { return }
            self.showLiveText(analysis)
        }
    }

    private func showLiveText(_ analysis: ImageAnalysis) {
        let overlay = ImageAnalysisOverlayView(self)
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        // Its own Live Text button stays hidden: the text is selectable without it.
        overlay.isSupplementaryInterfaceHidden = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        // A selection is part of the picture: rounded and faded with it.
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        overlay.layer?.cornerCurve = .continuous
        overlay.layer?.cornerRadius = look.cornerRadius
        overlay.alphaValue = pinWindow?.opacity ?? 1
        overlay.analysis = analysis
        // Under the corner buttons and the lock mark.
        addSubview(overlay, positioned: .below, relativeTo: lockMark)
        liveText = overlay
        // VoiceOver can take the text the screen shows.
        let copyText = NSAccessibilityCustomAction(name: String(localized: "Copy Text", bundle: .module)) { [weak self] in
            guard let self, let text = self.liveText?.text, !text.isEmpty else { return false }
            self.pinWindow?.copySelectedText(text)
            return true
        }
        var actions = accessibilityCustomActions() ?? []
        actions.insert(copyText, at: min(1, actions.count))
        setAccessibilityCustomActions(actions)
        if case .image(let image, let pictureScale) = content {
            setAccessibilityLabel(String(localized: "Pin with text, \(Int(CGFloat(image.width) / pictureScale)) by \(Int(CGFloat(image.height) / pictureScale)) points", bundle: .module))
        }
    }

    /// The border by which a picture filled with text still drags.
    private static let grabBorder: CGFloat = 6

    /// Whether a press at `point` (in the pin's coordinates) goes to the picture's or the card's text, as in
    /// Preview: a press on text; on a picture, a right press also on a detected item (a link's or a code's
    /// menu), so a drag across a QR code still moves the pin. Never by the border, and never with ⌘ held,
    /// which drags from anywhere.
    private func takesTextPress(at point: CGPoint) -> Bool {
        guard !NSEvent.modifierFlags.contains(.command), bounds.insetBy(dx: Self.grabBorder, dy: Self.grabBorder).contains(point) else { return false }
        if let textView { return textView.isOnText(textView.convert(point, from: self)) }
        guard let liveText else { return false }
        let location = liveText.analysisPoint(point, from: self)
        return NSApp.currentEvent?.type == .rightMouseDown ? liveText.hasInteractiveItem(at: location) : liveText.hasText(at: location)
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let corner = resizeCorner(at: point) {
            resizingCorner = corner
            optionDragStart = nil
            window?.makeKey()
            return
        }
        resizingCorner = nil
        if event.clickCount == 2, !isLocked, !takesTextPress(at: point) {
            optionDragStart = nil
            window?.makeKey()
            let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            pinWindow?.toggleZoom(around: screenPoint)
            return
        }
        if event.modifierFlags.contains(.option), !isLocked, case .image = content {
            optionDragStart = point
            window?.makeKey()
            return
        }
        optionDragStart = nil
        // A press on the picture away from its text clears a selection, as a click elsewhere does in Preview;
        // one by the border or with ⌘ held only moves the pin. (The drag returns at once, so whether the pin
        // moved is not known here.)
        if !event.modifierFlags.contains(.command), bounds.insetBy(dx: Self.grabBorder, dy: Self.grabBorder).contains(point) {
            liveText?.resetSelection()
            textView?.clearSelection()
        }
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = optionDragStart, case .image(let image, _) = content {
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            optionDragStart = nil
            guard let fileURL = pinWindow?.fileForDrag() else { return }
            let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            draggingItem.setDraggingFrame(bounds, contents: NSImage(cgImage: image, size: bounds.size))
            beginDraggingSession(with: [draggingItem], event: event, source: self)
            return
        }
        guard let corner = resizingCorner, let pin = pinWindow else {
            super.mouseDragged(with: event)
            return
        }
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        let (newZoom, anchor) = PinGeometry.resizedZoom(dragging: corner, of: pin.frame, baseSize: pin.baseSize, to: screenPoint)
        pin.setZoom(newZoom, around: anchor)
    }

    override func mouseUp(with event: NSEvent) {
        optionDragStart = nil
        if resizingCorner != nil {
            resizingCorner = nil
            return
        }
        super.mouseUp(with: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    /// A middle click closes the pin.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { pinWindow?.closePin() } else { super.otherMouseDown(with: event) }
    }

    /// Scrolling zooms around the pointer; with Option it fades or firms the pin.
    override func scrollWheel(with event: NSEvent) {
        // A trackpad's coasting after the fingers lift would go on zooming: only the gesture itself counts.
        guard let pin = pinWindow, event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        guard delta != 0 else { return }
        if event.modifierFlags.contains(.option) {
            pin.setOpacity(PinGeometry.opacity(pin.opacity, scrolledBy: delta, precise: event.hasPreciseScrollingDeltas))
        } else {
            pin.setZoom(PinGeometry.zoom(pin.zoom, scrolledBy: delta, precise: event.hasPreciseScrollingDeltas), around: NSEvent.mouseLocation)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let pin = pinWindow else { return }
        pin.setZoom(pin.zoom * (1 + event.magnification), around: NSEvent.mouseLocation)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let pin = pinWindow else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53:
            // A selection in the picture's or the card's text goes first.
            if let liveText, liveText.hasActiveTextSelection {
                liveText.resetSelection()
            } else if let textView, textView.selectedRange().length > 0 {
                textView.clearSelection()
            } else {
                pin.closePin()
            }
        case 123: pin.move(by: CGVector(dx: -step, dy: 0))
        case 124: pin.move(by: CGVector(dx: step, dy: 0))
        case 125: pin.move(by: CGVector(dx: 0, dy: -step))
        case 126: pin.move(by: CGVector(dx: 0, dy: step))
        default: super.keyDown(with: event)
        }
    }

    /// An accessory app's menu bar is not there to route ⌘ keys, so the pin answers its own.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let pin = pinWindow, pin.isKeyWindow, event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            if liveText?.hasActiveTextSelection == true || textView?.selectionToCopy != nil { copySelectedText() } else { pin.copyPin() }
        case "a":
            guard liveText != nil || textView != nil else { return false }
            selectAllText()
        case "s" where pin.isPicture: event.modifierFlags.contains(.shift) ? pin.savePinAs() : pin.savePin()
        case "p" where pin.isPicture && event.modifierFlags.isDisjoint(with: [.shift, .option, .control]): pin.printPin()
        case "w": pin.closePin()
        case "=", "+": pin.setZoom(pin.zoom * 1.25)
        case "-": pin.setZoom(pin.zoom / 1.25)
        case "0": pin.setZoom(1)
        default: return false
        }
        return true
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    /// Copies what the selection in the picture's or the card's text holds.
    private func copySelectedText() {
        if let textView, let text = textView.selectionToCopy {
            pinWindow?.copySelectedText(text)
            return
        }
        guard let liveText, liveText.hasActiveTextSelection else { return }
        pinWindow?.copySelectedText(liveText.selectedText)
    }

    private func selectAllText() {
        if let textView {
            textView.selectAll(nil)
            return
        }
        guard let liveText else { return }
        liveText.selectedRanges = [liveText.text.startIndex..<liveText.text.endIndex]
    }

    @objc private func moreClicked(_ sender: NSView) {
        makeMenu().popUp(beside: sender, outside: self)
    }

    @objc private func closeClicked() {
        pinWindow?.closePin()
    }

    @objc private func unlockClicked() {
        pinWindow?.setLocked(false)
    }

    /// `afterLiveText`: the pin's items follow Live Text's own, or the card text's own, over the text, which
    /// copy the selection. Either way ⌘C goes where it goes on the keyboard: to the selection when there is
    /// one, else to the picture or the whole text.
    func makeMenu(afterLiveText: Bool = false) -> NSMenu {
        let menu = NSMenu()
        guard let pin = pinWindow else { return menu }
        func item(_ title: String, _ symbol: String?, key: String = "", modifiers: NSEvent.ModifierFlags = .command, _ action: @escaping () -> Void) -> NSMenuItem {
            let closure = MenuClosure(action)
            let menuItem = NSMenuItem(title: title, action: #selector(MenuClosure.invoke), keyEquivalent: key)
            // The item keeps its closure alive; the target is held weakly.
            menuItem.target = closure
            menuItem.representedObject = closure
            menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            if let symbol { menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return menuItem
        }
        switch content {
        case .image:
            let selection = liveText?.hasActiveTextSelection == true
            if afterLiveText {
                menu.addItem(item(String(localized: "Copy Image", bundle: .module), "photo", key: selection ? "" : "c") { pin.copyPin() })
            } else if selection {
                menu.addItem(item(String(localized: "Copy Text", bundle: .module), "doc.on.doc", key: "c") { [weak self] in self?.copySelectedText() })
                menu.addItem(item(String(localized: "Copy Image", bundle: .module), "photo") { pin.copyPin() })
            } else {
                menu.addItem(item(String(localized: "Copy", bundle: .module), "doc.on.doc", key: "c") { pin.copyPin() })
            }
            if !afterLiveText, liveText != nil {
                menu.addItem(item(String(localized: "Select All Text", bundle: .module), "character.cursor.ibeam", key: "a") { [weak self] in self?.selectAllText() })
            }
            menu.addItem(item(String(localized: "Save", bundle: .module), "square.and.arrow.down", key: "s") { pin.savePin() })
            menu.addItem(item(String(localized: "Save As…", bundle: .module), "square.and.arrow.down.on.square", key: "s", modifiers: [.command, .shift]) { pin.savePinAs() })
            menu.addItem(item(String(localized: "Print…", bundle: .module), "printer", key: "p") { pin.printPin() })
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Annotate…", bundle: .module), "pencil.and.scribble") { pin.annotatePin() })
            menu.addItem(item(String(localized: "Recognize Text…", bundle: .module), "text.viewfinder") { pin.recognizePinText() })
        case .text:
            let selection = textView?.selectionToCopy != nil
            if afterLiveText {
                menu.addItem(item(String(localized: "Copy All Text", bundle: .module), "doc.on.doc", key: selection ? "" : "c") { pin.copyPin() })
            } else if selection {
                menu.addItem(item(String(localized: "Copy", bundle: .module), "doc.on.doc", key: "c") { [weak self] in self?.copySelectedText() })
                menu.addItem(item(String(localized: "Copy All Text", bundle: .module), "doc.on.doc") { pin.copyPin() })
            } else {
                menu.addItem(item(String(localized: "Copy Text", bundle: .module), "doc.on.doc", key: "c") { pin.copyPin() })
            }
            if !afterLiveText {
                menu.addItem(item(String(localized: "Select All Text", bundle: .module), "character.cursor.ibeam", key: "a") { [weak self] in self?.selectAllText() })
            }
        case .color:
            menu.addItem(item(String(localized: "Copy Hex", bundle: .module), "number", key: "c") { pin.copyPin() })
            menu.addItem(item(String(localized: "Copy RGB", bundle: .module), "eyedropper") { pin.copyRGB() })
        }
        menu.addItem(.separator())
        let zoom = NSMenu()
        zoom.addItem(item(String(localized: "Actual Size", bundle: .module), nil, key: "0") { pin.setZoom(1) })
        zoom.addItem(item(String(localized: "Zoom In", bundle: .module), nil, key: "=") { pin.setZoom(pin.zoom * 1.25) })
        zoom.addItem(item(String(localized: "Zoom Out", bundle: .module), nil, key: "-") { pin.setZoom(pin.zoom / 1.25) })
        let zoomItem = NSMenuItem(title: String(localized: "Zoom", bundle: .module), action: nil, keyEquivalent: "")
        zoomItem.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)
        zoomItem.submenu = zoom
        menu.addItem(zoomItem)
        let opacity = NSMenu()
        for step in PinGeometry.opacitySteps {
            let stepItem = item(String(localized: "\(Int(step * 100))%", bundle: .module), nil) { pin.setOpacity(step) }
            stepItem.state = abs(pin.opacity - step) < 0.01 ? .on : .off
            opacity.addItem(stepItem)
        }
        let opacityItem = NSMenuItem(title: String(localized: "Opacity", bundle: .module), action: nil, keyEquivalent: "")
        opacityItem.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        opacityItem.submenu = opacity
        menu.addItem(opacityItem)
        let lock = item(String(localized: "Lock", bundle: .module), "lock") { pin.setLocked(true) }
        lock.toolTip = String(localized: "Clicks go through the pin to what is under it. Unlock it from the menu bar.", bundle: .module)
        menu.addItem(lock)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Close", bundle: .module), "xmark") { pin.closePin() })
        menu.addItem(item(String(localized: "Close All Pins", bundle: .module), nil) { pin.closeAllPins() })
        return menu
    }
}

extension PinView: NSTextViewDelegate {
    /// Over a card's text, the text's own menu (Copy, Look Up, Translate, and the like), then the pin's.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        let pinMenu = makeMenu(afterLiveText: true)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for item in pinMenu.items {
            pinMenu.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }
}

extension PinView: ImageAnalysisOverlayViewDelegate {
    /// The picture fills the pin.
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Escape and the arrows stay the pin's while Live Text has the keys.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        ![53, 123, 124, 125, 126].contains(event.keyCode)
    }

    /// Over the text, Live Text's menu (Copy, Look Up, Translate, and the like), then the pin's, in place of
    /// VisionKit's items for an image it does not hold.
    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent, at point: CGPoint) -> NSMenu {
        let imageTags: Set<Int> = [
            ImageAnalysisOverlayView.MenuTag.copyImage, ImageAnalysisOverlayView.MenuTag.shareImage,
            ImageAnalysisOverlayView.MenuTag.copySubject, ImageAnalysisOverlayView.MenuTag.shareSubject,
        ]
        for item in menu.items where imageTags.contains(item.tag) {
            menu.removeItem(item)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        let pinMenu = makeMenu(afterLiveText: true)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for item in pinMenu.items {
            pinMenu.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }
}

/// A text card's text, laid out once at 100 percent and drawn scaled with the pin, so it wraps where it
/// did at 100 percent at any zoom and stays sharp. It selects as text does: a drag on it selects, a double
/// click takes a word and a triple click a paragraph. The pin takes every other press, and drags
/// (`PinView.takesTextPress`), and it keeps the cursor. It is no element of its own: VoiceOver reads the
/// pin, which carries the text.
final class PinTextView: NSTextView {
    /// The whole text, past what the card lays out.
    let fullText: String
    /// Copies the selection's text, through the pin, which says "Copied".
    var onCopy: ((String) -> Void)?
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { scaleToZoom() } }
    }

    init(text: String) {
        fullText = text
        let size = PinText.textSize(for: text)
        let storage = NSTextStorage(attributedString: PinText.attributed(text))
        // TextKit 1, as the card's size is measured, so the lines break where the measure said.
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // As wide as the text measured at 100 percent, and as many lines as the card holds, the last one
        // cut with an ellipsis when there is more.
        let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = PinText.maxLines
        container.lineBreakMode = .byTruncatingTail
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: .zero, size: size), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFindBar = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scaleToZoom()
    }

    /// The text at 100 percent in the view's own coordinates, drawn at the zoom.
    private func scaleToZoom() {
        setBoundsSize(CGSize(width: frame.width / zoom, height: frame.height / zoom))
        needsDisplay = true
    }

    /// Whether `point`, in the view's own coordinates, is on the text: on a line, from its first glyph to a
    /// little past its last.
    func isOnText(_ point: CGPoint) -> Bool {
        guard let layoutManager, let textContainer, layoutManager.glyphRange(for: textContainer).length > 0 else { return false }
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        return layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).insetBy(dx: -4, dy: 0).contains(point)
    }

    /// What copying the selection takes (`PinText.copied`); nil with nothing selected.
    var selectionToCopy: String? {
        PinText.copied(selecting: selectedRange(), in: string, of: fullText)
    }

    /// Copy in the text's own menu goes as ⌘C does, through the pin.
    override func copy(_ sender: Any?) {
        guard let text = selectionToCopy else { return }
        onCopy?(text)
    }

    func clearSelection() {
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    // The pin sets the cursor: an I-beam only where a press selects.
    override func resetCursorRects() {}
    override func cursorUpdate(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {
        superview?.mouseMoved(with: event)
    }
}

/// The checkerboard under a translucent color: squares a fixed 8 pt on screen at any zoom, in the
/// checkerboard token's grays.
nonisolated private final class PinCheckerLayer: CALayer {
    var colors: (light: CGColor, dark: CGColor) = (CGColor(gray: 1, alpha: 1), CGColor(gray: 0.91, alpha: 1)) {
        didSet { setNeedsDisplay() }
    }
    private static let side: CGFloat = 8

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        contentsScale = 2
    }

    override init(layer: Any) {
        colors = (layer as? PinCheckerLayer)?.colors ?? colors
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        context.setFillColor(colors.light)
        context.fill(bounds)
        context.setFillColor(colors.dark)
        let side = Self.side
        var row = 0
        var y = bounds.minY
        while y < bounds.maxY {
            var x = bounds.minX + (row.isMultiple(of: 2) ? 0 : side)
            while x < bounds.maxX {
                context.fill(CGRect(x: x, y: y, width: side, height: side))
                x += 2 * side
            }
            y += side
            row += 1
        }
    }
}

/// A closure a menu item runs.
private final class MenuClosure: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func invoke() {
        run()
    }
}
