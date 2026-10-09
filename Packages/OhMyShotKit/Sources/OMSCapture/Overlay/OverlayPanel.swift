import AppKit

/// A transparent, borderless panel covering one display, above full-screen apps, the menu bar, open
/// menus, and the Dock.
///
/// While an area is chosen it sits at the screen-saver level: just above pop-up menus, macOS 26 and
/// later kept handing presses in the menu bar's band to the menu bar, so a selection could neither start
/// there nor be dragged up into it, and a press there opened a menu. It still never hides macOS's
/// periodic Screen Recording confirmation: a frozen overlay appears only once a frame has arrived, and a
/// live one is dismissed by the overlay controller's watchdog when none does. In-place annotation goes
/// back just above pop-up menus, under input methods' candidate windows.
final class OverlayPanel: NSPanel {
    static let selectionLevel = NSWindow.Level.screenSaver
    static let annotationLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Self.selectionLevel
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
