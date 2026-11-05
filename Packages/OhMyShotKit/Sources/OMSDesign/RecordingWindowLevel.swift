import AppKit

/// Where the windows an area recording shows on screen lie in the stack, so the one that dims the rest of
/// the screen stays under those recorded with the area.
public enum RecordingWindowLevel {
    /// The control bar, the keystrokes, and the click rings: above what is recorded and the Dock, under menus.
    public static let chrome = NSWindow.Level.statusBar
    /// The dim over the rest of the screen: just under `chrome`, so none of those windows is dimmed.
    public static let dim = NSWindow.Level(rawValue: chrome.rawValue - 1)
}
