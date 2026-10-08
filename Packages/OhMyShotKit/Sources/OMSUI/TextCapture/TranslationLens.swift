import AppKit
import OMSCore

/// Translate Area's result: the area as it was captured, with the translation drawn over its text, in a
/// panel exactly over the area, so the screen seems to change language where it was dragged over. It
/// takes keys without bringing the app forward: Escape closes it, ⌘C copies the translation, Return
/// opens it in the OCR panel, and Option held shows the original. While the pointer is over it, round
/// buttons for the same wait just outside its top right corner, never over the text. A click on it, or
/// another window taking the keys, closes it; nothing runs while it waits.
public final class TranslationLens {
    /// Opens the area in the OCR panel, translated.
    public var onOpenInPanel: (() -> Void)?

    private var panel: LensPanel?
    private var windowLease: ActiveResources.Lease?

    public init() {}

    /// Shows `image` (pixels, `scale` per point) over `frame`, in AppKit's global coordinates, with
    /// `original` beneath it for Option. `text` is the translation for Copy and VoiceOver, its
    /// `translated` ranges in `language`; `summary` names its languages ("English → Chinese, Simplified").
    /// `shortened`: some of it was cut short to fit, which VoiceOver hears with where to read it all.
    public func show(
        _ image: CGImage, original: CGImage, scale: CGFloat, over frame: CGRect,
        text: String, translated: [NSRange], language: String, summary: String, shortened: Bool = false
    ) {
        close(animated: false)
        let frame = frame.integral
        let layout = LensLayout(lens: frame, screen: NSScreen.screens.first { $0.frame.intersects(frame) }?.frame ?? frame)
        let panel = LensPanel(frame: layout.window)
        let spoken = NSMutableAttributedString(string: text)
        for range in translated where NSMaxRange(range) <= spoken.length {
            spoken.addAttribute(.accessibilityLanguage, value: language, range: range)
        }
        let view = LensView(image: image, original: original, scale: scale, layout: layout, text: spoken, summary: summary)
        view.onCopy = { [weak self] in self?.copy(text) }
        view.onOpenInPanel = { [weak self] in
            let open = self?.onOpenInPanel
            self?.close(animated: false)
            open?()
        }
        view.onClose = { [weak self] in self?.close(animated: true) }
        panel.contentView = view
        panel.onResignKey = { [weak self, weak panel] in
            // Only this lens: one shown since has its own panel.
            guard let self, self.panel === panel else { return }
            self.close(animated: true)
        }
        self.panel = panel
        if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        // A lens that opens under the pointer (a picked window, a drag that ended inside) gets no
        // entered event until the pointer leaves and comes back.
        view.syncHover()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        Self.announce(shortened
            ? String(localized: "Translated, \(summary). Some lines are shortened; Return opens them all. Escape closes it.", bundle: .module)
            : String(localized: "Translated, \(summary). Escape closes it.", bundle: .module))
    }

    public func close(animated: Bool) {
        guard let panel else { return }
        self.panel = nil
        onOpenInPanel = nil
        panel.onResignKey = nil
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            panel.orderOut(nil)
            panel.contentView = nil
            if self?.panel == nil { self?.windowLease = nil }
        }
    }

    #if DEBUG
    /// Shows the buttons without the pointer, for scripted screenshots.
    public func revealControls() {
        (panel?.contentView as? LensView)?.setControlsVisible(true)
    }
    #endif

    /// Copies the translation and keeps the lens: the button shows a checkmark, VoiceOver hears it.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        (panel?.contentView as? LensView)?.showCopied()
        Self.announce(String(localized: "Translation copied", bundle: .module))
    }

    private static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// Where the lens and its buttons go: the lens exactly over the area; the buttons in a row ending at its
/// right edge, 6 pt above it, or below it when the area reaches the top of the screen, or inside its
/// corner when it fills the screen's height. The window holds both, so the pointer can go from one to
/// the other without leaving it.
struct LensLayout {
    static let buttonSize: CGFloat = 24
    static let spacing: CGFloat = 6
    static let buttonCount: CGFloat = 3

    /// The window's frame, in AppKit's global coordinates.
    let window: CGRect
    /// The lens and the button row, in the window's coordinates (origin bottom left).
    let lens: CGRect
    let buttons: CGRect
    /// Whether the buttons lie outside the lens; inside its corner otherwise.
    let outside: Bool

    init(lens frame: CGRect, screen: CGRect) {
        let size = CGSize(width: Self.buttonCount * Self.buttonSize + (Self.buttonCount - 1) * Self.spacing, height: Self.buttonSize)
        let strip = size.height + Self.spacing
        var window = frame
        var buttons = CGRect(x: frame.maxX - size.width, y: frame.maxY + Self.spacing, width: size.width, height: size.height)
        if frame.maxY + strip <= screen.maxY {
            window.size.height += strip
            outside = true
        } else if frame.minY - strip >= screen.minY {
            window.origin.y -= strip
            window.size.height += strip
            buttons.origin.y = frame.minY - strip
            outside = true
        } else {
            buttons.origin = CGPoint(x: frame.maxX - size.width - Self.spacing, y: frame.maxY - size.height - Self.spacing)
            outside = false
        }
        // A lens narrower than the row: the window reaches left so the whole row fits.
        if buttons.minX < window.minX {
            window.size.width += window.minX - buttons.minX
            window.origin.x = buttons.minX
        }
        self.window = window
        self.lens = frame.offsetBy(dx: -window.minX, dy: -window.minY)
        self.buttons = buttons.offsetBy(dx: -window.minX, dy: -window.minY)
    }
}

/// A borderless panel that takes keys without activating the app, as Spotlight does, just below the
/// level of menus: over the menu bar and the Dock, under its own context menu.
private final class LensPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// The translated area and its buttons.
private final class LensView: NSView {
    var onCopy: (() -> Void)?
    var onOpenInPanel: (() -> Void)?
    var onClose: (() -> Void)?

    private let translated: CGImage
    private let original: CGImage
    private let layout: LensLayout
    private let imageLayer = CALayer()
    /// A film too faint to see between the lens and its buttons, so the window keeps the pointer there:
    /// fully transparent parts of a window let the pointer through to the one below.
    private let bridge = CALayer()
    private let controls = NSStackView()
    private let copyButton = CardButton(style: .round, title: String(localized: "Copy Translation", bundle: .module), symbolName: "doc.on.doc")
    private let panelButton = CardButton(style: .round, title: String(localized: "Open in Panel", bundle: .module), symbolName: "macwindow")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private var tracking: NSTrackingArea?
    private var showsOriginal = false {
        didSet { if showsOriginal != oldValue { swapImage() } }
    }
    private var copiedReset: Task<Void, Never>?
    private var displayOptions: NSObjectProtocol?
    /// The translation for VoiceOver, its translated parts tagged with their language.
    private var spoken = NSAttributedString()

    init(image: CGImage, original: CGImage, scale: CGFloat, layout: LensLayout, text: NSAttributedString, summary: String) {
        translated = image
        self.original = original
        self.layout = layout
        super.init(frame: CGRect(origin: .zero, size: layout.window.size))
        wantsLayer = true
        imageLayer.frame = layout.lens
        imageLayer.contents = image
        imageLayer.contentsScale = scale
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
        if layout.outside {
            let above = layout.buttons.minY >= layout.lens.maxY
            bridge.frame = above
                ? CGRect(x: layout.buttons.minX, y: layout.lens.maxY, width: layout.buttons.width, height: layout.buttons.maxY - layout.lens.maxY)
                : CGRect(x: layout.buttons.minX, y: layout.buttons.minY, width: layout.buttons.width, height: layout.lens.minY - layout.buttons.minY)
            bridge.backgroundColor = CGColor(gray: 0, alpha: 1.0 / 255)
            layer?.addSublayer(bridge)
        }
        applyEdge()

        for (button, action) in [(copyButton, #selector(copyClicked)), (panelButton, #selector(panelClicked)), (closeButton, #selector(closeClicked))] {
            button.target = self
            button.action = action
            controls.addArrangedSubview(button)
        }
        controls.orientation = .horizontal
        controls.spacing = LensLayout.spacing
        controls.frame = layout.buttons
        controls.alphaValue = 0
        addSubview(controls)

        spoken = text
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Translation, \(summary)", bundle: .module))
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Copy Translation", bundle: .module)) { [weak self] in self?.onCopy?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Open in Panel", bundle: .module)) { [weak self] in self?.onOpenInPanel?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Close", bundle: .module)) { [weak self] in self?.onClose?(); return true },
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: VoiceOver

    // The translation as text with ranges, the way VoiceOver asks a text element for it: through the
    // ranged calls it also finds each part's language, and reads it in that language's voice.
    override func accessibilityValue() -> Any? { spoken.string }

    override func accessibilityNumberOfCharacters() -> Int { spoken.length }

    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: spoken.length) }

    override func accessibilityString(for range: NSRange) -> String? {
        guard NSMaxRange(range) <= spoken.length else { return nil }
        return spoken.attributedSubstring(from: range).string
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard NSMaxRange(range) <= spoken.length else { return nil }
        return spoken.attributedSubstring(from: range)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        guard window != nil else { return }
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEdge() }
        }
    }

    /// A hairline, so the lens reads as lying over the screen rather than being it: 0.5 pt black 0.18,
    /// 1 pt black 0.35 with Increase Contrast.
    private func applyEdge() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        imageLayer.borderWidth = contrast ? 1 : 0.5
        imageLayer.borderColor = CGColor(gray: 0, alpha: contrast ? 0.35 : 0.18)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTracking()
    }

    /// Tracks the whole window; when the pointer is already inside, the first event is its leaving.
    private func installTracking() {
        if let tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if isPointerInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private var isPointerInside: Bool {
        window?.frame.contains(NSEvent.mouseLocation) == true
    }

    /// The buttons as the pointer is now, for a lens that opened under it.
    func syncHover() {
        installTracking()
        setControlsVisible(isPointerInside)
    }

    override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

    func setControlsVisible(_ visible: Bool) {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            controls.animator().alphaValue = visible ? 1 : 0
        }
        // The window's shadow follows what is drawn: the buttons outside the lens get theirs once shown.
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            self?.window?.invalidateShadow()
        }
    }

    func showCopied() {
        copyButton.symbolName = "checkmark"
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.copyButton.symbolName = "doc.on.doc"
        }
    }

    // MARK: The original

    private func swapImage() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12)
        imageLayer.contents = showsOriginal ? original : translated
        CATransaction.commit()
    }

    /// Option held shows the original under the translation.
    override func flagsChanged(with event: NSEvent) {
        showsOriginal = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
        super.flagsChanged(with: event)
    }

    // MARK: Clicks and keys

    /// A click on the translation itself closes it, as on a popover; beside the buttons it does nothing.
    override func mouseUp(with event: NSEvent) {
        guard layout.lens.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?() // Escape
        case 36, 76: onOpenInPanel?() // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "c" {
            onCopy?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy Translation", bundle: .module), action: #selector(copyClicked), keyEquivalent: "c").target = self
        let original = menu.addItem(withTitle: String(localized: "Show Original", bundle: .module), action: #selector(toggleOriginal), keyEquivalent: "")
        original.target = self
        original.state = showsOriginal ? .on : .off
        menu.addItem(withTitle: String(localized: "Open in Panel", bundle: .module), action: #selector(panelClicked), keyEquivalent: "\r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close", bundle: .module), action: #selector(closeClicked), keyEquivalent: "\u{1b}").target = self
        return menu
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func panelClicked() { onOpenInPanel?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func toggleOriginal() { showsOriginal.toggle() }
}
