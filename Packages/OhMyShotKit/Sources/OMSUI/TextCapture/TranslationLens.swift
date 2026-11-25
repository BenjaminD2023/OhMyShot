import AppKit
import CoreGraphics
import Foundation
import OMSCore
import OMSDesign
import QuartzCore
import UniformTypeIdentifiers

/// Translate Area's result: the area as it was captured, with the translation drawn over its text, in a
/// panel exactly over the area, so the screen seems to change language where it was dragged over. It
/// takes keys without bringing the app forward: Escape closes it, ⌘C copies the translation, Return
/// opens it in the OCR panel, and Option held shows the original. While the pointer is over it, round
/// buttons for the same (plus an optional compact target-language switcher chip) wait just outside its
/// top right corner, never over the text. A click on it, or another window taking the keys, closes it
/// unless Keep Open is toggled on; nothing runs while it waits.
public final class TranslationLens {
    /// Opens the area in the OCR panel, translated.
    public var onOpenInPanel: (() -> Void)?
    /// Pins the rendered translated image as a floating screenshot when wired by the app.
    public var onPinImage: ((CGImage, CGFloat) -> Void)?
    /// Switches the target language right inside the floating lens without closing it (empty string for Automatic).
    public var onChangeTargetLanguage: ((String) -> Void)?
    /// Default directory for "Save Translated Image…".
    public var saveDirectory: URL = .desktopDirectory

    private var panel: LensPanel?
    private var windowLease: ActiveResources.Lease?
    private var isPinned = false
    private var isSavingImage = false
    private var isShowingMenu = false
    private var perShowChangeTargetLanguage: ((String) -> Void)?

    public init() {}

    /// Shows `image` (pixels, `scale` per point) over `frame`, in AppKit's global coordinates, with
    /// `original` beneath it for Option. `text` is the translation for Copy and VoiceOver, its
    /// `translated` ranges in `language`; `summary` names its languages ("English → Chinese, Simplified").
    /// `shortened`: some of it was cut short to fit, which VoiceOver hears with where to read it all.
    /// `needsDownload`: one or more detected languages need a macOS translation pack download.
    /// `targetLanguage` and `availableTargetLanguages`: when `availableTargetLanguages` is non-empty,
    /// exposes a compact target-language switcher chip and context submenu so the user can change the
    /// target language directly inside the floating lens without closing it.
    public func show(
        _ image: CGImage, original: CGImage, scale: CGFloat, over frame: CGRect,
        text: String, translated: [NSRange], language: String, summary: String,
        shortened: Bool = false, needsDownload: Bool = false,
        targetLanguage: Locale.Language? = nil,
        availableTargetLanguages: [(id: String, name: String)] = [],
        onChangeTargetLanguage: ((String) -> Void)? = nil
    ) {
        close(animated: false)
        isPinned = false
        perShowChangeTargetLanguage = onChangeTargetLanguage
        let frame = frame.integral
        let hasLanguageSwitcher = !availableTargetLanguages.isEmpty
        let chipTitle = hasLanguageSwitcher
            ? Self.languageChipTitle(targetLanguage: targetLanguage, availableTargetLanguages: availableTargetLanguages)
            : nil
        let chipWidth = chipTitle.map { LensLanguageButton.preferredWidth(for: $0) } ?? 0
        let layout = LensLayout(
            lens: frame,
            screen: NSScreen.screens.first { $0.frame.intersects(frame) }?.frame ?? frame,
            extraControlWidth: chipWidth
        )
        let panel = LensPanel(frame: layout.window)
        let spoken = NSMutableAttributedString(string: text)
        for range in translated where NSMaxRange(range) <= spoken.length {
            spoken.addAttribute(.accessibilityLanguage, value: language, range: range)
        }
        let badge = Self.badgeText(shortened: shortened, needsDownload: needsDownload)
        let view = LensView(
            image: image, original: original, scale: scale, layout: layout,
            text: spoken, summary: summary, badge: badge, canPinImage: onPinImage != nil,
            targetLanguage: targetLanguage,
            availableTargetLanguages: availableTargetLanguages,
            languageChipTitle: chipTitle
        )
        view.onCopy = { [weak self] in self?.copy(text) }
        view.onCopyImage = { [weak self] in self?.copyImage(image, scale: scale) }
        view.onSaveImage = { [weak self] in self?.saveImage(image, scale: scale) }
        if onPinImage != nil {
            view.onPinImage = { [weak self] in
                guard let self, let pin = self.onPinImage else { return }
                self.close(animated: false)
                pin(image, scale)
            }
        }
        view.onTogglePinned = { [weak self] pinned in
            self?.isPinned = pinned
        }
        view.onMenuVisibilityChanged = { [weak self] open in
            self?.isShowingMenu = open
        }
        view.onChangeTargetLanguage = { [weak self] identifier in
            guard let self else { return }
            if let perShow = self.perShowChangeTargetLanguage {
                perShow(identifier)
            } else {
                self.onChangeTargetLanguage?(identifier)
            }
        }
        view.onOpenInPanel = { [weak self] in
            let open = self?.onOpenInPanel
            self?.close(animated: false)
            open?()
        }
        view.onClose = { [weak self] in self?.close(animated: true) }
        panel.contentView = view
        panel.onResignKey = { [weak self, weak panel] in
            // Only this lens: one shown since has its own panel. Keep Open, Save panel, or language menu holds it.
            guard let self, self.panel === panel, !self.isPinned, !self.isSavingImage, !self.isShowingMenu else { return }
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
        if needsDownload {
            VoiceOver.announce(String(localized: "Translated, \(summary). Some languages need a download; Return opens the panel. Escape closes it.", bundle: .module))
        } else {
            VoiceOver.announce(shortened
                ? String(localized: "Translated, \(summary). Some lines are shortened; Return opens them all. Escape closes it.", bundle: .module)
                : String(localized: "Translated, \(summary). Escape closes it.", bundle: .module))
        }
    }

    static func badgeText(shortened: Bool, needsDownload: Bool) -> String? {
        if needsDownload {
            return String(localized: "Language pack needed · Return for panel", bundle: .module)
        }
        if shortened {
            return String(localized: "Some lines shortened · Return for full text", bundle: .module)
        }
        return nil
    }

    static func matchesTarget(_ target: Locale.Language?, identifier: String) -> Bool {
        guard let target else { return identifier.isEmpty }
        guard !identifier.isEmpty else { return false }
        return target.minimalIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
            || target.minimalIdentifier.caseInsensitiveCompare(Locale.Language(identifier: identifier).minimalIdentifier) == .orderedSame
    }

    static func languageChipTitle(
        targetLanguage: Locale.Language?,
        availableTargetLanguages: [(id: String, name: String)]
    ) -> String {
        guard let targetLanguage else {
            return String(localized: "Automatic", bundle: .module)
        }
        if let match = availableTargetLanguages.first(where: { matchesTarget(targetLanguage, identifier: $0.id) }) {
            return match.name
        }
        return Locale.current.localizedString(forIdentifier: targetLanguage.minimalIdentifier) ?? targetLanguage.minimalIdentifier
    }

    public func close(animated: Bool) {
        isPinned = false
        isShowingMenu = false
        perShowChangeTargetLanguage = nil
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
        VoiceOver.announce(String(localized: "Translation copied", bundle: .module))
    }

    /// Copies the rendered translated image to the clipboard.
    private func copyImage(_ image: CGImage, scale: CGFloat) {
        guard let png = try? ImageExporter.encoded(image, as: .png, pixelsPerPoint: Double(scale)) else {
            NSSound.beep()
            return
        }
        PasteboardWriter.write(png: png, image: image)
        (panel?.contentView as? LensView)?.showCopied()
        VoiceOver.announce(String(localized: "Translated image copied", bundle: .module))
    }

    /// Saves the rendered translated image through the system Save panel.
    private func saveImage(_ image: CGImage, scale: CGFloat) {
        let directory = saveDirectory
        isSavingImage = true
        Task { [weak self] in
            let url = await SavePanel.ask(
                name: String(localized: "Translated Image", bundle: .module),
                types: [.png, .jpeg, .heic],
                directory: directory
            )
            self?.isSavingImage = false
            guard let url else { return }
            let format: ImageExporter.Format = switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": .jpeg
            case "heic", "heif": .heic
            default: .png
            }
            do {
                try await ImageExporter.write(image, to: url, format: format, pixelsPerPoint: Double(scale))
                VoiceOver.announce(String(localized: "Translated image saved", bundle: .module))
            } catch {
                NSSound.beep()
            }
        }
    }
}

/// Where the lens and its buttons go: the lens exactly over the area; the buttons in a row ending at its
/// right edge, 6 pt above it, or below it when the area reaches the top of the screen, or inside its
/// corner when it fills the screen's height. The window holds both, so the pointer can go from one to
/// the other without leaving it.
struct LensLayout {
    static let buttonSize: CGFloat = 24
    static let spacing: CGFloat = 6
    static let buttonCount: CGFloat = 4

    /// The window's frame, in AppKit's global coordinates.
    let window: CGRect
    /// The lens and the button row, in the window's coordinates (origin bottom left).
    let lens: CGRect
    let buttons: CGRect
    /// Whether the buttons lie outside the lens; inside its corner otherwise.
    let outside: Bool

    init(lens frame: CGRect, screen: CGRect, extraControlWidth: CGFloat = 0) {
        let buttonsWidth = Self.buttonCount * Self.buttonSize + (Self.buttonCount - 1) * Self.spacing
        let totalWidth = extraControlWidth > 0 ? buttonsWidth + Self.spacing + extraControlWidth : buttonsWidth
        let size = CGSize(width: totalWidth, height: Self.buttonSize)
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
        // Keep the control row inside the display's leading edge when the lens sits near the left edge.
        if buttons.minX < screen.minX {
            buttons.origin.x = screen.minX
        }
        // A lens narrower than the row: expand the window so the whole row fits.
        if buttons.minX < window.minX {
            window.size.width += window.minX - buttons.minX
            window.origin.x = buttons.minX
        }
        if buttons.maxX > window.maxX {
            window.size.width = buttons.maxX - window.minX
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
    var onCopyImage: (() -> Void)?
    var onSaveImage: (() -> Void)?
    var onPinImage: (() -> Void)?
    var onTogglePinned: ((Bool) -> Void)?
    var onMenuVisibilityChanged: ((Bool) -> Void)?
    var onChangeTargetLanguage: ((String) -> Void)?
    var onOpenInPanel: (() -> Void)?
    var onClose: (() -> Void)?

    private let translated: CGImage
    private let original: CGImage
    private let layout: LensLayout
    private let targetLanguage: Locale.Language?
    private let availableTargetLanguages: [(id: String, name: String)]
    private let imageLayer = CALayer()
    /// A film too faint to see between the lens and its buttons, so the window keeps the pointer there:
    /// fully transparent parts of a window let the pointer through to the one below.
    private let bridge = CALayer()
    private let controls = NSStackView()
    private var languageButton: LensLanguageButton?
    private let copyButton = CardButton(style: .round, title: String(localized: "Copy Translation", bundle: .module), symbolName: "doc.on.doc")
    private let pinButton = CardButton(style: .round, title: String(localized: "Keep Open", bundle: .module), symbolName: "pin")
    private let panelButton = CardButton(style: .round, title: String(localized: "Open in Panel", bundle: .module), symbolName: "macwindow")
    private let closeButton = CardButton(style: .round, title: String(localized: "Close", bundle: .module), symbolName: "xmark")
    private var badgeView: LensBadgeView?
    private var tracking: NSTrackingArea?
    private var showsOriginal = false {
        didSet { if showsOriginal != oldValue { swapImage() } }
    }
    private var isPinned = false {
        didSet {
            guard isPinned != oldValue else { return }
            pinButton.symbolName = isPinned ? "pin.fill" : "pin"
            pinButton.title = isPinned
                ? String(localized: "Unpin", bundle: .module)
                : String(localized: "Keep Open", bundle: .module)
            onTogglePinned?(isPinned)
        }
    }
    private var copiedReset: Task<Void, Never>?
    private var displayOptions: NSObjectProtocol?
    /// The translation for VoiceOver, its translated parts tagged with their language.
    private var spoken = NSAttributedString()

    init(
        image: CGImage, original: CGImage, scale: CGFloat, layout: LensLayout,
        text: NSAttributedString, summary: String, badge: String?, canPinImage: Bool,
        targetLanguage: Locale.Language?,
        availableTargetLanguages: [(id: String, name: String)],
        languageChipTitle: String?
    ) {
        translated = image
        self.original = original
        self.layout = layout
        self.targetLanguage = targetLanguage
        self.availableTargetLanguages = availableTargetLanguages
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

        if let languageChipTitle, !availableTargetLanguages.isEmpty {
            let chip = LensLanguageButton(title: languageChipTitle)
            chip.target = self
            chip.action = #selector(languageChipClicked)
            controls.addArrangedSubview(chip)
            languageButton = chip
        }

        for (button, action) in [
            (copyButton, #selector(copyClicked)),
            (pinButton, #selector(togglePinned)),
            (panelButton, #selector(panelClicked)),
            (closeButton, #selector(closeClicked)),
        ] {
            button.target = self
            button.action = action
            controls.addArrangedSubview(button)
        }
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = LensLayout.spacing
        controls.frame = layout.buttons
        controls.alphaValue = 0
        addSubview(controls)

        if let badge, layout.lens.width >= 90, layout.lens.height >= 40 {
            let badgeView = LensBadgeView(text: badge)
            let maxWidth = max(60, layout.lens.width - 12)
            let size = badgeView.fittingSize(maxWidth: maxWidth)
            badgeView.frame = CGRect(
                x: (layout.lens.midX - size.width / 2).rounded(),
                y: (layout.lens.minY + 6).rounded(),
                width: size.width,
                height: size.height
            )
            addSubview(badgeView)
            self.badgeView = badgeView
        }

        spoken = text
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Translation, \(summary)", bundle: .module))
        var actions: [NSAccessibilityCustomAction] = [
            NSAccessibilityCustomAction(name: String(localized: "Copy Translation", bundle: .module)) { [weak self] in self?.onCopy?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Copy Translated Image", bundle: .module)) { [weak self] in self?.onCopyImage?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Save Translated Image…", bundle: .module)) { [weak self] in self?.onSaveImage?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Keep Open", bundle: .module)) { [weak self] in self?.isPinned.toggle(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Open in Panel", bundle: .module)) { [weak self] in self?.onOpenInPanel?(); return true },
            NSAccessibilityCustomAction(name: String(localized: "Close", bundle: .module)) { [weak self] in self?.onClose?(); return true },
        ]
        if canPinImage {
            actions.insert(
                NSAccessibilityCustomAction(name: String(localized: "Pin Translated Image", bundle: .module)) { [weak self] in self?.onPinImage?(); return true },
                at: 3
            )
        }
        if !availableTargetLanguages.isEmpty {
            actions.insert(
                NSAccessibilityCustomAction(name: String(localized: "Translate Into", bundle: .module)) { [weak self] in
                    self?.languageChipClicked()
                    return true
                },
                at: 0
            )
        }
        setAccessibilityCustomActions(actions)
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
            MainActor.assumeIsolated {
                self?.applyEdge()
                self?.badgeView?.applyAppearance()
                self?.languageButton?.needsDisplay = true
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        badgeView?.applyAppearance()
        languageButton?.needsDisplay = true
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

    /// A click on the translation itself closes it, as on a popover, unless Keep Open is active; beside the buttons it does nothing.
    override func mouseUp(with event: NSEvent) {
        guard !isPinned, layout.lens.contains(convert(event.locationInWindow, from: nil)) else { return }
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

    private func makeLanguageMenu() -> NSMenu {
        let submenu = NSMenu(title: String(localized: "Translate Into", bundle: .module))
        let automatic = NSMenuItem(
            title: String(localized: "Automatic", bundle: .module),
            action: #selector(languageMenuItemChosen(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.representedObject = ""
        automatic.state = TranslationLens.matchesTarget(targetLanguage, identifier: "") ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())
        for option in availableTargetLanguages {
            let item = NSMenuItem(
                title: option.name,
                action: #selector(languageMenuItemChosen(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.id
            item.state = TranslationLens.matchesTarget(targetLanguage, identifier: option.id) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy Translation", bundle: .module), action: #selector(copyClicked), keyEquivalent: "c").target = self
        menu.addItem(withTitle: String(localized: "Copy Translated Image", bundle: .module), action: #selector(copyImageClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Save Translated Image…", bundle: .module), action: #selector(saveImageClicked), keyEquivalent: "").target = self
        if onPinImage != nil {
            menu.addItem(withTitle: String(localized: "Pin Translated Image", bundle: .module), action: #selector(pinImageClicked), keyEquivalent: "").target = self
        }
        if !availableTargetLanguages.isEmpty {
            menu.addItem(.separator())
            let languageItem = NSMenuItem(title: String(localized: "Translate Into", bundle: .module), action: nil, keyEquivalent: "")
            languageItem.submenu = makeLanguageMenu()
            menu.addItem(languageItem)
        }
        menu.addItem(.separator())
        let pinned = menu.addItem(withTitle: String(localized: "Keep Open", bundle: .module), action: #selector(togglePinned), keyEquivalent: "")
        pinned.target = self
        pinned.state = isPinned ? .on : .off
        let original = menu.addItem(withTitle: String(localized: "Show Original", bundle: .module), action: #selector(toggleOriginal), keyEquivalent: "")
        original.target = self
        original.state = showsOriginal ? .on : .off
        menu.addItem(withTitle: String(localized: "Open in Panel", bundle: .module), action: #selector(panelClicked), keyEquivalent: "\r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close", bundle: .module), action: #selector(closeClicked), keyEquivalent: "\u{1b}").target = self
        return menu
    }

    @objc private func languageChipClicked() {
        guard !availableTargetLanguages.isEmpty else { return }
        let menu = makeLanguageMenu()
        let anchorView: NSView = languageButton ?? self
        let origin = languageButton != nil
            ? NSPoint(x: 0, y: -4)
            : NSPoint(x: layout.lens.midX, y: layout.lens.maxY)
        onMenuVisibilityChanged?(true)
        menu.popUp(positioning: nil, at: origin, in: anchorView)
        onMenuVisibilityChanged?(false)
    }

    @objc private func languageMenuItemChosen(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        onChangeTargetLanguage?(identifier)
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func copyImageClicked() { onCopyImage?() }
    @objc private func saveImageClicked() { onSaveImage?() }
    @objc private func pinImageClicked() { onPinImage?() }
    @objc private func togglePinned() { isPinned.toggle() }
    @objc private func panelClicked() { onOpenInPanel?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func toggleOriginal() { showsOriginal.toggle() }
}

/// Compact dark-translucent language picker chip matching the 24 pt round lens controls.
private final class LensLanguageButton: NSControl {
    private static let height: CGFloat = LensLayout.buttonSize
    private static let minWidth: CGFloat = 56
    private static let maxWidth: CGFloat = 132
    private static let horizontalPadding: CGFloat = 8
    private static let iconGap: CGFloat = 4
    private static let font = Theme.Typeface.label(size: 11, weight: .medium)

    private var titleText: String
    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(title: String) {
        self.titleText = title
        super.init(frame: .zero)
        setFrameSize(intrinsicContentSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(String(localized: "Translate Into", bundle: .module))
        setAccessibilityValue(title)
        toolTip = String(localized: "Translate Into", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func preferredWidth(for title: String) -> CGFloat {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let globeWidth: CGFloat = 12
        let chevronWidth: CGFloat = 9
        let width = horizontalPadding * 2 + globeWidth + iconGap + textWidth + iconGap + chevronWidth
        return min(max(width, minWidth), maxWidth)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth(for: titleText), height: Self.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        defer { pressed = false }
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: sendAction(action, to: target)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let radius = bounds.height / 2
        NSColor(white: 0, alpha: pressed ? 0.72 : hovering ? 0.62 : 0.5).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if increaseContrast {
            NSColor(white: 1, alpha: 0.7).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            outline.stroke()
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .semibold)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.85)]))
        let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)

        var x = Self.horizontalPadding
        if let globe {
            let size = globe.size
            globe.draw(in: CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            x += size.width + Self.iconGap
        }
        let chevronWidth = chevron?.size.width ?? 0
        let trailingReserve = Self.horizontalPadding + (chevron != nil ? Self.iconGap + chevronWidth : 0)
        let textWidth = max(0, bounds.width - x - trailingReserve)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: titleText, attributes: attributes)
        let textSize = attributed.size()
        attributed.draw(
            with: CGRect(x: x, y: ((bounds.height - textSize.height) / 2).rounded(), width: textWidth, height: textSize.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
        if let chevron {
            let size = chevron.size
            let cx = bounds.width - Self.horizontalPadding - size.width
            chevron.draw(in: CGRect(x: cx, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

/// Subtle bottom capsule inside the lens when lines were shortened or a language pack download is needed.
private final class LensBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.stringValue = text
        label.font = Theme.Typeface.label(size: 10.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        addSubview(label)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let intrinsic = label.intrinsicContentSize
        let width = min(maxWidth, ceil(intrinsic.width) + 16)
        return CGSize(width: width, height: 20)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 8, y: ((bounds.height - textHeight) / 2).rounded(), width: max(0, bounds.width - 16), height: textHeight)
    }

    func applyAppearance() {
        let dark = effectiveAppearance.isDark
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = Theme.Material.cardFill(dark: dark)
        layer?.borderWidth = Theme.Material.edgeWidth(contrast: contrast)
        layer?.borderColor = Theme.Material.edge(dark: dark, contrast: contrast)
    }
}
