import AppKit
import OMSCore
import QuartzCore

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
    private(set) var opacity: CGFloat = 1
    private(set) var isLocked = false
    private let pinView: PinView
    private let actions: PinController.Actions

    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    /// Locked or unlocked: the menu bar's Unlock Pins follows.
    var onChange: (() -> Void)?

    init(pin: PinController.Pin, frame: CGRect, zoom: CGFloat, appearance: PinAppearance, actions: PinController.Actions) {
        self.pin = pin
        baseSize = Self.baseSize(of: pin.content)
        self.zoom = zoom
        self.actions = actions
        pinView = PinView(content: pin.content, appearance: appearance)
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
        invalidateShadow()
        pinView.showReading(String(localized: "\(Int((zoom * 100).rounded()))%", bundle: .module))
        updateAccessibilityValue()
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
    }

    /// Lets every click through to what is under the pin, or takes them again. A locked pin cannot be
    /// reached by the pointer, so it is unlocked from the menu bar; it wears a badge meanwhile.
    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        ignoresMouseEvents = locked
        if locked, isKeyWindow { resignKey() }
        pinView.isLocked = locked
        if locked { pinView.showReading(String(localized: "Locked", bundle: .module)) }
        onChange?()
    }

    private func updateAccessibilityValue() {
        pinView.setAccessibilityValue(String(localized: "\(Int((zoom * 100).rounded())) percent, opacity \(Int((opacity * 100).rounded())) percent", bundle: .module))
    }

    #if DEBUG
    func debugShowControls() {
        pinView.debugShowControls()
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

    func recognizePinText() {
        if isPicture { actions.recognizeText(pin) }
    }

    func closePin() {
        onClose?(self)
    }

    func closeAllPins() {
        onCloseAll?()
    }
}

/// What a pin shows: a picture, a text card, or a color swatch, rounded as Settings says, with a hairline
/// edge, an accent ring while it has the keys, the Close and More buttons on hover, and a reading capsule
/// for its zoom and opacity as they change (a color's value rests there).
final class PinView: NSView {
    weak var pinWindow: PinWindow?

    private let content: PinController.Content
    /// The picture, the card's fill, or the swatch's checkerboard: what corners, edge, and opacity apply to.
    private let contentLayer = CALayer()
    private let swatch = CALayer()
    private let checker = PinCheckerLayer()
    private let textView: PinTextView?
    /// What the reading shows when nothing else is: a color's hex.
    private var restingReading: String?
    private let ring = CALayer()
    private let reading = ReadingCapsule()
    /// A locked pin's lasting mark: a small dark disc in the card corner button's style, the one kind of
    /// dark control that sits over a picture; the reading says "Locked" once as it locks.
    private let lockMark = CardButton(style: .round, title: String(localized: "Locked", bundle: .module), symbolName: "lock.fill")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private let moreButton = CardButton(style: .round, title: String(localized: "More", bundle: .module), symbolName: "ellipsis")
    private var look: PinAppearance
    private var tracking: NSTrackingArea?
    /// Close and More show while the pointer is over an unlocked pin, and take clicks only then.
    private var controlsShown = false
    private var readingFade: Task<Void, Never>?
    private var displayOptions: NSObjectProtocol?

    var isFocused = false {
        didSet { if isFocused != oldValue { updateRing() } }
    }

    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            lockMark.isHidden = !isLocked
            setControlsVisible(false)
            updateRing()
            needsLayout = true
        }
    }

    init(content: PinController.Content, appearance: PinAppearance) {
        self.content = content
        look = appearance
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
            if let textView { addSubview(textView) }
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
        layer?.addSublayer(ring)
        reading.setScale(scale)
        reading.layer.zPosition = 1
        layer?.addSublayer(reading.layer)
        reading.layer.opacity = 0
        reading.layer.isHidden = false
        lockMark.isHidden = true
        lockMark.setAccessibilityLabel(String(localized: "Locked", bundle: .module))
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
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if window?.frame.contains(NSEvent.mouseLocation) == true { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

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
    #endif

    /// Faded out, Close and More let the pin take the click, so it drags from under them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if !controlsShown, let hit, hit === closeButton || hit === moreButton { return self }
        return hit
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.performDrag(with: event)
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
        case 53: pin.closePin()
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
        case "c": pin.copyPin()
        case "s" where pin.isPicture: event.modifierFlags.contains(.shift) ? pin.savePinAs() : pin.savePin()
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

    @objc private func moreClicked(_ sender: NSView) {
        makeMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func closeClicked() {
        pinWindow?.closePin()
    }

    private func makeMenu() -> NSMenu {
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
            menu.addItem(item(String(localized: "Copy", bundle: .module), "doc.on.doc", key: "c") { pin.copyPin() })
            menu.addItem(item(String(localized: "Save", bundle: .module), "square.and.arrow.down", key: "s") { pin.savePin() })
            menu.addItem(item(String(localized: "Save As…", bundle: .module), "square.and.arrow.down.on.square", key: "s", modifiers: [.command, .shift]) { pin.savePinAs() })
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Annotate…", bundle: .module), "pencil.tip.crop.circle") { pin.annotatePin() })
            menu.addItem(item(String(localized: "Recognize Text…", bundle: .module), "text.viewfinder") { pin.recognizePinText() })
        case .text:
            menu.addItem(item(String(localized: "Copy Text", bundle: .module), "doc.on.doc", key: "c") { pin.copyPin() })
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

/// A text card's text, laid out once at 100 percent and drawn scaled with the pin, so it wraps where it
/// did at 100 percent at any zoom and stays sharp. It takes no clicks and is no element of its own: the
/// pin drags from anywhere, and VoiceOver reads the pin, which carries the text.
private final class PinTextView: NSView {
    private let text: NSAttributedString
    private let size: CGSize
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { needsDisplay = true } }
    }

    init(text: String) {
        self.text = PinText.attributed(text)
        size = PinText.textSize(for: text)
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: zoom, y: zoom)
        text.draw(with: CGRect(origin: .zero, size: size), options: PinText.drawing, context: nil)
        context.restoreGState()
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
