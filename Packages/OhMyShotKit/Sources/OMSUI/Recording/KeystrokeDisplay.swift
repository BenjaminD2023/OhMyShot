import AppKit
import OMSCore
import QuartzCore

/// The keys pressed while recording, shown near the bottom of what is recorded and recorded with it: a
/// large reading capsule (its materials, light or dark with the system, and its rounded face) that fades a
/// moment after the last key.
///
/// Its window is on screen, clear, for as long as the recording runs, so the recording's content filter can
/// take it in from the start; only the capsule comes and goes.
public final class KeystrokeDisplay {
    private var panel: NSPanel?
    private let capsule = CALayer()
    private let label = CATextLayer()
    private var caption: KeystrokeCaption
    private var fade: Task<Void, Never>?

    /// How far up from the bottom of what is recorded the capsule reaches: the control bar keeps above it.
    public static let reservedHeight: CGFloat = bottom + height

    /// The capsule's distance from the bottom of what is recorded.
    private static let bottom: CGFloat = 28
    /// How long a caption stays after its last key.
    private static let lingering: Duration = .milliseconds(1400)
    private static let fontSize: CGFloat = 26
    private static let height: CGFloat = 52
    /// Room around the capsule for its shadow.
    private static let margin: CGFloat = 14

    public init(mode: KeystrokeMode) {
        caption = KeystrokeCaption(mode: mode)
    }

    /// The window, for the recording's filter to take in; nil until shown.
    public var windowID: CGWindowID? {
        panel.map { CGWindowID($0.windowNumber) }
    }

    /// Puts the (empty) display at the bottom of `area`, in global points.
    public func show(in area: CGRect) {
        let frame = CGRect(x: area.minX, y: area.minY + Self.bottom - Self.margin, width: area.width, height: Self.height + Self.margin * 2)
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        layout()
    }

    public func hide() {
        fade?.cancel()
        fade = nil
        caption.clear()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Takes a key pressed; shows it when the mode does.
    public func take(_ key: Keystroke) {
        guard panel != nil, caption.add(key) else { return }
        label.string = caption.text
        applyAppearance()
        layout()
        setVisible(true)
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: Self.lingering)
            guard !Task.isCancelled, let self else { return }
            setVisible(false)
            caption.clear()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Above what is recorded and the Dock, which a recording of a whole display takes in at its foot;
        // under menus.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        guard let host = view.layer else { return panel }
        capsule.opacity = 0
        capsule.shadowColor = .black
        capsule.shadowOpacity = 0.18
        capsule.shadowRadius = 8
        capsule.shadowOffset = CGSize(width: 0, height: -2)
        label.font = Theme.Typeface.reading(size: Self.fontSize, weight: .semibold)
        label.fontSize = Self.fontSize
        label.alignmentMode = .center
        label.truncationMode = .start
        label.contentsScale = panel.backingScaleFactor
        capsule.addSublayer(label)
        host.addSublayer(capsule)
        return panel
    }

    /// The reading capsule's materials, for the system's appearance now; under Increase Contrast, the 1 pt
    /// contrast hairline.
    private func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96)
        capsule.borderWidth = contrast ? 1 : 0.5
        capsule.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
        label.foregroundColor = dark ? CGColor(gray: 1, alpha: 0.92) : CGColor(gray: 0, alpha: 0.85)
        CATransaction.commit()
    }

    /// The capsule around the caption, centered at the bottom of the panel.
    private func layout() {
        guard let view = panel?.contentView else { return }
        let font = Theme.Typeface.reading(size: Self.fontSize, weight: .semibold)
        let text = (label.string as? String) ?? ""
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let width = min(max(textWidth + 44, Self.height), view.bounds.width - Self.margin * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = CGRect(x: (view.bounds.width - width) / 2, y: Self.margin, width: width, height: Self.height)
        capsule.cornerRadius = Self.height / 2
        capsule.shadowPath = CGPath(roundedRect: capsule.bounds, cornerWidth: Self.height / 2, cornerHeight: Self.height / 2, transform: nil)
        let lineHeight = ceil(font.ascender - font.descender)
        label.frame = CGRect(x: 22, y: (Self.height - lineHeight) / 2, width: width - 44, height: lineHeight)
        label.contentsScale = panel?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    private func setVisible(_ visible: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : Theme.Motion.fade)
        capsule.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    #if DEBUG
    /// Shows `keys` in a display behind the desktop picture, for rendering checks; returns its window.
    public func debugShowBehindWallpaper(_ keys: [Keystroke], width: CGFloat) -> NSWindow? {
        let screen = NSScreen.screens.first?.frame ?? .zero
        show(in: CGRect(x: screen.midX - width / 2, y: screen.midY - 60, width: width, height: 120))
        panel?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        for key in keys { take(key) }
        fade?.cancel()
        return panel
    }
    #endif
}
