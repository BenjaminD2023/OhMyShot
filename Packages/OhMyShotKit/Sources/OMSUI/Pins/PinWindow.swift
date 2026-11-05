import AppKit
import OMSCore

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
        do {
            try ImageExporter.write(ImageExporter.encoded(image, as: .png), to: tempURL)
            return tempURL
        } catch {
            return nil
        }
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
