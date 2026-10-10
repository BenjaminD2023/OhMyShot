import AppKit

/// Bringing the app's own windows forward when the user asks for them (Settings, Capture History, the
/// editor, the OCR panel).
///
/// macOS activates apps cooperatively: a request can be declined while another app is in front, as it
/// often is for a menu bar app whose status menu was clicked, and the window then opened behind the app in
/// use. The window is put in front of everything regardless, so it is never left behind; one click in it
/// activates the app if macOS did not.
@MainActor
public enum AppActivation {
    /// Activates the app and puts `window` in front, as the key window.
    public static func bringForward(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// The app's icon, read from the icon file the asset catalog compiles into the bundle.
    /// `NSApp.applicationIconImage` comes back as the generic app icon for an icon made in Icon Composer
    /// (macOS 27.2 beta), and asking the system's icon service at launch can give the generic one too
    /// while it is still preparing a freshly built app's icon, so the app sets this one at launch.
    public static var appIcon: NSImage {
        Bundle.main.image(forResource: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}
