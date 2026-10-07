import AppKit

/// A transparent, borderless panel covering one display, above full-screen apps, the menu bar, open
/// menus, and the Dock.
///
/// The level stays just above pop-up menus rather than at the screen-saver level: macOS's periodic
/// Screen Recording confirmation can appear on the first capture, and the overlay controller's watchdog
/// gets out of its way.
final class OverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
