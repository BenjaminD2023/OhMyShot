import AppKit
import Foundation
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
final class PinWindow: NSPanel, NSWindowDelegate {
    private(set) var pin: PinController.Pin
    /// The pin's size in points at 100 percent.
    private(set) var baseSize: CGSize
    private(set) var zoom: CGFloat
    private var previousZoom: CGFloat?
    private(set) var opacity: CGFloat = 1
    private(set) var isLocked = false
    private(set) var lockBadgePanel: NSPanel?
    private var baseAppearance: PinAppearance
    private(set) var shadowOverride: Bool?
    private(set) var borderOverride: Bool?
    private(set) var rotationSteps = 0
    private(set) var flippedHorizontal = false
    private(set) var flippedVertical = false
    private(set) var isTransformed = false
    private var tempDragFileURL: URL?
    private let pinView: PinView
    private let actions: PinController.Actions

    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    /// Locked or unlocked: the menu bar's Unlock Pins follows.
    var onChange: (() -> Void)?
    /// Moved, zoomed, faded, or per-pin appearance toggled: what is kept for the next launch follows.
    var onAdjust: (() -> Void)?
    /// Picture replaced in place (edited or transformed): re-archives the PNG for relaunch persistence.
    var onImageUpdated: ((PinWindow) -> Void)?
    /// Clicked, so in front of the other pins: the order kept for the next launch follows.
    var onRaise: ((PinWindow) -> Void)?
    var onTranslateImage: ((CGImage) -> Void)?
    var hasTranslateImageHandler: (() -> Bool)?

    var resolvedAppearance: PinAppearance {
        PinAppearance(
            cornerRadius: baseAppearance.cornerRadius,
            shadow: shadowOverride ?? baseAppearance.shadow,
            border: borderOverride ?? baseAppearance.border
        )
    }

    var showsShadow: Bool { resolvedAppearance.shadow }
    var showsBorder: Bool { resolvedAppearance.border }
    var canTranslate: Bool { isPicture && (actions.translate != nil || hasTranslateImageHandler?() == true) }

    /// `textReader` reads a picture's text for Live Text. `opacity` is the picture's, as a pin brought back after a
    /// relaunch had it.
    init(
        pin: PinController.Pin, frame: CGRect, zoom: CGFloat, opacity: CGFloat = 1, appearance: PinAppearance, actions: PinController.Actions,
        textReader: PinTextReader? = nil
    ) {
        self.pin = pin
        baseSize = Self.baseSize(of: pin.content)
        self.zoom = zoom
        self.baseAppearance = appearance
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
        pinView.pinWindow = self
        pinView.frame = CGRect(origin: .zero, size: frame.size)
        pinView.autoresizingMask = [.width, .height]
        contentView = pinView
        pinView.needsLayout = true
        self.opacity = PinGeometry.clamp(opacity, to: PinGeometry.opacityRange)
        pinView.setPictureOpacity(self.opacity)
        delegate = self
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
            if event.type == .leftMouseDown { onRaise?(self) }
        default:
            break
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        pinView.isFocused = false
    }

    /// Brings the pin in front of every app's windows, with its shadow following its rounded picture and the lock badge
    /// of a pin locked while out of sight.
    func show() {
        orderFrontRegardless()
        if let panel = lockBadgePanel, panel.parent == nil { addChildWindow(panel, ordered: .above) }
        // It takes the keys only when clicked: a pin stays, and taking them now would leave the app in front unable
        // to type.
        invalidateShadow()
    }

    /// The pin as it is kept for the next launch.
    var record: PinArchive.Record? {
        PinArchive.Record(
            pin, frame: frame, zoom: zoom, opacity: opacity, locked: isLocked,
            shadowOverride: shadowOverride, borderOverride: borderOverride, isTransformed: isTransformed ? true : nil
        )
    }

    func windowDidMove(_ notification: Notification) {
        onAdjust?()
    }

    func windowDidResize(_ notification: Notification) {
        onAdjust?()
    }

    func apply(_ appearance: PinAppearance) {
        baseAppearance = appearance
        let resolved = resolvedAppearance
        hasShadow = resolved.shadow
        pinView.apply(resolved)
        invalidateShadow()
    }

    func toggleShadow() {
        shadowOverride = !showsShadow
        apply(baseAppearance)
        onAdjust?()
    }

    func toggleBorder() {
        borderOverride = !showsBorder
        apply(baseAppearance)
        onAdjust?()
    }

    /// Restores persisted per-pin appearance overrides and transform metadata from `PinArchive.Record`.
    func restoreArchiveOverrides(shadow: Bool?, border: Bool?, isTransformed: Bool?) {
        shadowOverride = shadow
        borderOverride = border
        self.isTransformed = isTransformed == true
        apply(baseAppearance)
    }

    /// Rotates or flips a picture pin in place, updating its size, frame, Live Text, and archive cleanly.
    func transformImage(_ change: PictureChange) {
        guard case .image(let image, let scale) = pin.content,
              let transformed = change.apply(to: image) else { return }
        switch change {
        case .rotateRight: rotationSteps = (rotationSteps + 1) % 4
        case .rotateLeft: rotationSteps = (rotationSteps + 3) % 4
        case .flipHorizontal: flippedHorizontal.toggle()
        case .flipVertical: flippedVertical.toggle()
        case .scaleToOneX: break
        }
        isTransformed = true
        // Transformed pixels diverge from any history capture file, so handovers use this pin's own pixels.
        updateImage(transformed, scale: scale, pinnedAt: .distantPast, clearBackground: true)
    }

    /// Captures all state needed to restore this pin if closed accidentally.
    func closedSnapshot() -> PinController.ClosedSnapshot {
        PinController.ClosedSnapshot(
            content: pin.content,
            origin: pin.origin,
            pinnedAt: pin.pinnedAt,
            onBackground: pin.onBackground,
            requiresBackground: pin.requiresBackground,
            frame: frame,
            zoom: zoom,
            opacity: opacity,
            shadowOverride: shadowOverride,
            borderOverride: borderOverride,
            rotationSteps: rotationSteps,
            flippedHorizontal: flippedHorizontal,
            flippedVertical: flippedVertical,
            isTransformed: isTransformed
        )
    }

    /// Restores opacity, per-pin style overrides, and transform metadata without flashing readings.
    func restoreState(from snapshot: PinController.ClosedSnapshot) {
        opacity = PinGeometry.clamp(snapshot.opacity, to: PinGeometry.opacityRange)
        pinView.setPictureOpacity(opacity)
        shadowOverride = snapshot.shadowOverride
        borderOverride = snapshot.borderOverride
        rotationSteps = snapshot.rotationSteps
        flippedHorizontal = snapshot.flippedHorizontal
        flippedVertical = snapshot.flippedVertical
        isTransformed = snapshot.isTransformed
        apply(baseAppearance)
        updateAccessibilityValue()
    }

    // MARK: Zoom, opacity, place

    /// Zooms to `newZoom`, keeping `anchor` (global points; the pin's center when nil) where it is.
    func setZoom(_ newZoom: CGFloat, around anchor: CGPoint? = nil) {
        let clamped = PinGeometry.clamp(newZoom, to: PinGeometry.zoomRange(from: zoom))
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

    /// Returns a file URL suitable for dragging this picture pin into another app, or nil when nothing is to go.
    func fileForDrag() -> URL? {
        if !isTransformed, let provider = actions.fileForDrag {
            return provider(pin)
        }
        guard case .image(let image, let scale) = pin.content else { return nil }
        if !isTransformed, case .file(let url) = pin.origin, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }
        if let existing = tempDragFileURL, FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)) {
            return existing
        }
        let directory = ExportedFiles.standardFolder.appending(path: "Pins", directoryHint: .isDirectory)
        let tempURL = directory.appending(path: "OhMyShot Pin \(pin.id.uuidString).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ImageExporter.write(ImageExporter.encoded(image, as: .png, pixelsPerPoint: Double(scale)), to: tempURL)
            tempDragFileURL = tempURL
            return tempURL
        } catch {
            return nil
        }
    }

    /// Removes any temporary drag file created by this pin window itself.
    func cleanupDragFiles() {
        guard let url = tempDragFileURL else { return }
        tempDragFileURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Refreshes a picture pin in place with an updated image and scale.
    func updateImage(_ image: CGImage, scale: CGFloat, pinnedAt: Date = .now, clearBackground: Bool = true) {
        guard case .image = pin.content else { return }
        let updatedContent = PinController.Content.image(image, scale: scale)
        pin = PinController.Pin(
            id: pin.id, content: updatedContent, origin: pin.origin, pinnedAt: pinnedAt,
            onBackground: clearBackground ? nil : pin.onBackground,
            requiresBackground: clearBackground ? false : pin.requiresBackground
        )
        baseSize = Self.baseSize(of: updatedContent)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let next = PinGeometry.zoomed(frame, to: CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom), around: center)
        cleanupDragFiles()
        pinView.updateImage(image, scale: scale)
        setFrame(next, display: true)
        updateLockBadgePanelFrame()
        invalidateShadow()
        updateAccessibilityValue()
        onImageUpdated?(self)
    }

    /// Fades the picture only: its readings, buttons, and ring stay solid, so the reading that says how
    /// faint it is can still be read.
    func setOpacity(_ newOpacity: CGFloat) {
        opacity = PinGeometry.clamp(newOpacity, to: PinGeometry.opacityRange)
        pinView.setPictureOpacity(opacity)
        invalidateShadow()
        pinView.showReading(String(localized: "Opacity \(Int((opacity * 100).rounded()))%", bundle: .module))
        updateAccessibilityValue()
        onAdjust?()
    }

    func move(by delta: CGVector) {
        move(to: CGPoint(x: frame.minX + delta.dx, y: frame.minY + delta.dy))
    }

    func move(to origin: CGPoint) {
        setFrameOrigin(origin)
        updateLockBadgePanelFrame()
    }

    /// Hides or shows the pin together with its floating lock badge panel.
    func setWindowHidden(_ hidden: Bool) {
        if hidden {
            if let panel = lockBadgePanel {
                if panel.parent != nil { removeChildWindow(panel) }
                panel.orderOut(nil)
            }
            orderOut(nil)
        } else {
            show()
            if isLocked {
                if lockBadgePanel == nil { installLockBadgePanel() }
                updateLockBadgePanelFrame()
                if let panel = lockBadgePanel {
                    if panel.parent == nil { addChildWindow(panel, ordered: .above) }
                    panel.orderFrontRegardless()
                }
            }
        }
    }

    /// Explicitly removes any child lock badge panel, cleans up temp drag files, and orders out the window.
    func tearDown() {
        removeLockBadgePanel()
        cleanupDragFiles()
        orderOut(nil)
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
        button.setAccessibilityLabel(String(localized: "Unlock", bundle: .module))
        button.toolTip = String(localized: "Unlock Pin", bundle: .module)
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

    /// Copies a color pin's value in the requested `ColorFormat`.
    func copyColor(format: ColorFormat) {
        guard case .color(let color) = pin.content else { return }
        Self.copy(color.string(in: format))
        pinView.showReading(String(localized: "Copied", bundle: .module))
    }

    /// Copies a color pin's value as rgb().
    func copyRGB() {
        copyColor(format: .rgb)
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

    func translatePin() {
        guard case .image(let image, _) = pin.content else { return }
        if let translate = actions.translate {
            translate(pin)
        } else {
            onTranslateImage?(image)
        }
    }

    func closePin() {
        removeLockBadgePanel()
        cleanupDragFiles()
        onClose?(self)
    }

    func closeAllPins() {
        onCloseAll?()
    }
}
