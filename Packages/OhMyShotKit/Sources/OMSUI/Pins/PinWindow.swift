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
    /// The picture's size in points at 100 percent.
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
        baseSize = CGSize(width: CGFloat(pin.image.width) / pin.scale, height: CGFloat(pin.image.height) / pin.scale)
        self.zoom = zoom
        self.actions = actions
        pinView = PinView(image: pin.image, scale: pin.scale, appearance: appearance)
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
        let next = PinGeometry.zoomed(frame, by: clamped / zoom, around: point)
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

    // MARK: Actions

    func copyPin() {
        actions.copy(pin)
        pinView.showReading(String(localized: "Copied", bundle: .module))
    }

    func savePin() {
        actions.save(pin)
    }

    func savePinAs() {
        actions.saveAs(pin)
    }

    func annotatePin() {
        actions.annotate(pin)
    }

    func recognizePinText() {
        actions.recognizeText(pin)
    }

    func closePin() {
        onClose?(self)
    }

    func closeAllPins() {
        onCloseAll?()
    }
}

/// A pin's picture: rounded as Settings says, a hairline edge, an accent ring while it has the keys, the
/// Close and More buttons on hover, and a reading capsule for its zoom and opacity as they change.
final class PinView: NSView {
    weak var pinWindow: PinWindow?

    private let imageLayer = CALayer()
    private let ring = CALayer()
    private let reading = ReadingCapsule()
    /// A locked pin's lasting mark: a small dark disc in the card corner button's style, the one kind of
    /// dark control that sits over a picture; the reading says "Locked" once as it locks.
    private let lockMark = CardButton(style: .round, title: String(localized: "Locked", bundle: .module), symbolName: "lock.fill")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private let moreButton = CardButton(style: .round, title: String(localized: "More", bundle: .module), symbolName: "ellipsis")
    private var look: PinAppearance
    private var tracking: NSTrackingArea?
    private var hovered = false
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

    init(image: CGImage, scale: CGFloat, appearance: PinAppearance) {
        look = appearance
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        imageLayer.contents = image
        imageLayer.contentsScale = scale
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.masksToBounds = true
        imageLayer.cornerCurve = .continuous
        layer?.addSublayer(imageLayer)
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
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Pin, \(Int(CGFloat(image.width) / scale)) by \(Int(CGFloat(image.height) / scale)) points", bundle: .module))
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Copy", bundle: .module)) { [weak self] in self?.pinWindow?.copyPin(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Save", bundle: .module)) { [weak self] in self?.pinWindow?.savePin(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Annotate", bundle: .module)) { [weak self] in self?.pinWindow?.annotatePin(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Recognize Text", bundle: .module)) { [weak self] in self?.pinWindow?.recognizePinText(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Lock", bundle: .module)) { [weak self] in self?.pinWindow?.setLocked(true); return true },
            NSAccessibilityCustomAction(name: String(localized: "Close", bundle: .module)) { [weak self] in self?.pinWindow?.closePin(); return true },
        ])
        apply(appearance)
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
        imageLayer.cornerRadius = appearance.cornerRadius
        ring.cornerRadius = appearance.cornerRadius
        // A hairline, so a white picture reads against a white window: 0.5 pt black 0.18, 1 pt black 0.35
        // with Increase Contrast (always shown then).
        let border = appearance.border || contrast
        imageLayer.borderWidth = border ? (contrast ? 1 : 0.5) : 0
        imageLayer.borderColor = CGColor(gray: 0, alpha: contrast ? 0.35 : 0.18)
        reading.applyAppearance(dark: dark, contrast: contrast)
        CATransaction.commit()
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
        imageLayer.frame = bounds
        ring.frame = bounds
        // The reading 10 pt above the bottom edge, centered.
        let size = reading.layer.bounds.size
        reading.layer.frame.origin = CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: min(10, max(bounds.height - size.height, 0) / 2))
        CATransaction.commit()
        // Close and More 8 pt in from the top corners; a locked pin's mark where More would be.
        let button = closeButton.intrinsicContentSize.width
        closeButton.frame = CGRect(x: 8, y: bounds.height - 8 - button, width: button, height: button)
        moreButton.frame = CGRect(x: bounds.width - 8 - button, y: bounds.height - 8 - button, width: button, height: button)
        lockMark.frame = moreButton.frame
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
        imageLayer.opacity = Float(opacity)
        CATransaction.commit()
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

    /// Close and More show on hover, when the pin is large enough to hold them clear of each other.
    private func setControlsVisible(_ visible: Bool) {
        hovered = visible
        let roomy = bounds.width >= 72 && bounds.height >= 56
        let shown = visible && roomy && !isLocked
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            closeButton.animator().alphaValue = shown ? 1 : 0
            moreButton.animator().alphaValue = shown ? 1 : 0
        }
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
        case "s": event.modifierFlags.contains(.shift) ? pin.savePinAs() : pin.savePin()
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
        menu.addItem(item(String(localized: "Copy", bundle: .module), "doc.on.doc", key: "c") { pin.copyPin() })
        menu.addItem(item(String(localized: "Save", bundle: .module), "square.and.arrow.down", key: "s") { pin.savePin() })
        menu.addItem(item(String(localized: "Save As…", bundle: .module), "square.and.arrow.down.on.square", key: "s", modifiers: [.command, .shift]) { pin.savePinAs() })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Annotate…", bundle: .module), "pencil.tip.crop.circle") { pin.annotatePin() })
        menu.addItem(item(String(localized: "Recognize Text…", bundle: .module), "text.viewfinder") { pin.recognizePinText() })
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
