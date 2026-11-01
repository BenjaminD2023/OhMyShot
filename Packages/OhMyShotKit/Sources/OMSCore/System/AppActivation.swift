import AppKit

/// Bringing the app's own windows forward when the user asks for them (Settings, Capture History, the
/// editor, the OCR panel, Studio).
///
/// While any standard titled window is open on screen, the app promotes its activation policy to `.regular`
/// so it appears in Command-Tab (the App Switcher) and the Dock; once the last standard window closes, it
/// returns to `.accessory` so the menu bar app stays out of Command-Tab when idle or showing floating overlays.
@MainActor
public enum AppActivation {
    private static let trackedWindows = NSHashTable<NSWindow>.weakObjects()
    private static var closeObserver: NSObjectProtocol?

    /// Whether `window` is a standard titled window that should place the app in Command-Tab while open.
    public static func isStandardWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.level == .normal
    }

    /// Whether any standard titled window is currently open (excluding `closing` when it is on its way out).
    public static func hasOpenStandardWindows(closing: NSWindow? = nil) -> Bool {
        if trackedWindows.allObjects.contains(where: { $0 !== closing && $0.isVisible && isStandardWindow($0) }) {
            return true
        }
        return NSApp?.windows.contains(where: { $0 !== closing && $0.isVisible && isStandardWindow($0) }) ?? false
    }

    /// Activates the app and puts `window` in front, as the key window.
    public static func bringForward(_ window: NSWindow?) {
        guard let window else { return }
        if isStandardWindow(window) {
            trackedWindows.add(window)
            observeWindowCloseIfNeeded()
            if NSApp?.activationPolicy() != .regular {
                _ = NSApp?.setActivationPolicy(.regular)
            }
        }
        NSApp?.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // When opened from the status bar menu or immediately after promoting from `.accessory` to `.regular`,
        // WindowServer may finish the policy/menu transition on the next turn; re-assert key focus so the first
        // click inside the window operates controls directly instead of merely activating the window.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            if !window.isKeyWindow || NSApp?.isActive == false {
                NSApp?.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Reconciles the app's activation policy when `window` is closing.
    public static func windowWillClose(_ window: NSWindow?) {
        if let window { trackedWindows.remove(window) }
        reconcilePolicy(closing: window)
    }

    private static func observeWindowCloseIfNeeded() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            let closing = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let closing { trackedWindows.remove(closing) }
                // Check on the next turn too in case `isVisible` clears after `willCloseNotification`.
                reconcilePolicy(closing: closing)
                DispatchQueue.main.async {
                    reconcilePolicy(closing: nil)
                }
            }
        }
    }

    private static func reconcilePolicy(closing: NSWindow?) {
        guard !hasOpenStandardWindows(closing: closing) else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if NSApp?.activationPolicy() == .regular {
            _ = NSApp?.setActivationPolicy(.accessory)
        }
    }

    /// The app's icon, read from the icon file the asset catalog compiles into the bundle.
    /// `NSApp.applicationIconImage` comes back as the generic app icon for an icon made in Icon Composer
    /// (macOS 27.2 beta), and asking the system's icon service at launch can give the generic one too
    /// while it is still preparing a freshly built app's icon, so the app sets this one at launch.
    public static var appIcon: NSImage {
        Bundle.main.image(forResource: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}
