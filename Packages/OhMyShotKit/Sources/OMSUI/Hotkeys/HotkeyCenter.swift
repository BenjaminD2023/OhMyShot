import AppKit
import Foundation
import KeyboardShortcuts

/// The global shortcuts that start a capture.
public enum CaptureShortcut: String, CaseIterable, Sendable {
    case captureArea
    /// Choose an area and mark it up in place, on the frozen screen.
    case annotateArea
    /// Choose an area and pin it where it is.
    case pinArea
    case captureFullscreen
    case captureWindow
    case capturePreviousArea
    case allInOne
    case selfTimer
    /// Choose the part that scrolls and capture all of it as one long picture; pressed again while capturing,
    /// finishes.
    case scrollingCapture
    case captureText
    /// Capture Text with the lines of each paragraph joined.
    case captureTextJoined
    /// Drag over text and its translation covers it, in place.
    case translateArea
    /// Take a color off the frozen screen.
    case pickColor
    /// Measure the frozen screen.
    case measure
    /// Choose an area, a window, or a display, and record it; pressed again while recording, stops.
    case recordScreen
    /// Saves the last 15 seconds of each display the replay keeps (macOS 27).
    case saveReplay
    case openHistory
    /// Copies the newest Quick Access card's capture, so it can be reached without the pointer.
    case copyLatestCapture

    public var name: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name(rawValue)
    }

    /// Whether this Mac has what the shortcut does: the replay needs macOS 27.
    public var isAvailable: Bool {
        guard self == .saveReplay else { return true }
        if #available(macOS 27, *) { return true }
        return false
    }

    public var title: String {
        switch self {
        case .captureArea: String(localized: "Capture Area", bundle: .module)
        case .annotateArea: String(localized: "Annotate Area", bundle: .module)
        case .pinArea: String(localized: "Capture Area and Pin", bundle: .module)
        case .captureFullscreen: String(localized: "Capture Fullscreen", bundle: .module)
        case .captureWindow: String(localized: "Capture Window", bundle: .module)
        case .capturePreviousArea: String(localized: "Capture Previous Area", bundle: .module)
        case .allInOne: String(localized: "All-In-One", bundle: .module)
        case .selfTimer: String(localized: "Self-Timer", bundle: .module)
        case .scrollingCapture: String(localized: "Scrolling Capture", bundle: .module)
        case .captureText: String(localized: "Capture Text", bundle: .module)
        case .captureTextJoined: String(localized: "Capture Text, Joining Lines", bundle: .module)
        case .translateArea: String(localized: "Translate Area", bundle: .module)
        case .pickColor: String(localized: "Pick Color", bundle: .module)
        case .measure: String(localized: "Measure", bundle: .module)
        case .recordScreen: String(localized: "Record Screen", bundle: .module)
        case .saveReplay: String(localized: "Save Last 15 Seconds", bundle: .module)
        case .openHistory: String(localized: "Open Capture History", bundle: .module)
        case .copyLatestCapture: String(localized: "Copy Latest Capture", bundle: .module)
        }
    }
}

/// Registers global shortcuts as Carbon hot keys (through KeyboardShortcuts). They cost nothing until
/// pressed and need no permission, unlike event taps.
public final class HotkeyCenter {
    /// Debug builds default to ⌃⌥⌘ shortcuts so they never collide with a release build.
    public enum Profile: Sendable {
        case development
        case release
    }

    private let profile: Profile
    private let defaults: UserDefaults

    public init(profile: Profile, defaults: UserDefaults = .standard) {
        self.profile = profile
        self.defaults = defaults
    }

    /// Assigns each shortcut's default once, the first launch that knows the shortcut, so a shortcut the
    /// user cleared stays cleared and one added later still gets its default. A default already taken
    /// by another shortcut is left out.
    public func installDefaultShortcutsIfNeeded() {
        let key = "installedDefaultShortcuts"
        var installed = Set(defaults.stringArray(forKey: key) ?? [])
        if defaults.object(forKey: key) == nil, defaults.bool(forKey: "didInstallDefaultShortcuts") {
            // Installed before shortcuts were tracked one by one: every one that existed then.
            installed = Set(CaptureShortcut.allCases.filter { ![.translateArea, .annotateArea, .pinArea, .pickColor, .measure, .recordScreen].contains($0) }.map(\.rawValue))
        }
        for shortcut in CaptureShortcut.allCases where shortcut.isAvailable && !installed.contains(shortcut.rawValue) {
            let taken = CaptureShortcut.allCases.compactMap { KeyboardShortcuts.getShortcut(for: $0.name) }
            if let candidate = defaultShortcut(for: shortcut), !taken.contains(candidate) {
                KeyboardShortcuts.setShortcut(candidate, for: shortcut.name)
            }
            installed.insert(shortcut.rawValue)
        }
        defaults.set(installed.sorted(), forKey: key)
    }

    /// The keys a shortcut is set to, as the menu shows them (such as "⌃⌥⌘7"); nil when it has none.
    public func keys(for shortcut: CaptureShortcut) -> String? {
        KeyboardShortcuts.getShortcut(for: shortcut.name)?.description
    }

    /// Starts listening. The handler runs on key down, so the overlay can appear before the keys are
    /// released.
    public func activate(_ handler: @escaping (CaptureShortcut) -> Void) {
        for shortcut in CaptureShortcut.allCases where shortcut.isAvailable {
            KeyboardShortcuts.onKeyDown(for: shortcut.name) {
                handler(shortcut)
            }
        }
    }

    func defaultShortcut(for shortcut: CaptureShortcut) -> KeyboardShortcuts.Shortcut? {
        let modifiers: NSEvent.ModifierFlags = switch profile {
        case .development: [.control, .option, .command]
        case .release: [.shift, .command]
        }
        return switch shortcut {
        case .translateArea: KeyboardShortcuts.Shortcut(.one, modifiers: modifiers)
        case .captureText: KeyboardShortcuts.Shortcut(.two, modifiers: modifiers)
        case .captureFullscreen: KeyboardShortcuts.Shortcut(.three, modifiers: modifiers)
        case .captureArea: KeyboardShortcuts.Shortcut(.four, modifiers: modifiers)
        case .allInOne: KeyboardShortcuts.Shortcut(.five, modifiers: modifiers)
        case .annotateArea: KeyboardShortcuts.Shortcut(.six, modifiers: modifiers)
        // ⇧⌘7 types a slash on German and other layouts, and ⇧⌘8 and ⇧⌘9 brackets: the release build leaves
        // them unset.
        case .pinArea: profile == .development ? KeyboardShortcuts.Shortcut(.seven, modifiers: modifiers) : nil
        case .pickColor: profile == .development ? KeyboardShortcuts.Shortcut(.eight, modifiers: modifiers) : nil
        case .measure: profile == .development ? KeyboardShortcuts.Shortcut(.nine, modifiers: modifiers) : nil
        // ⇧⌘0 is ⌘= on German and other layouts, which zooms in many apps: the release build leaves it unset.
        case .recordScreen: profile == .development ? KeyboardShortcuts.Shortcut(.zero, modifiers: modifiers) : nil
        // The digits are taken; the release build leaves it for the user to choose.
        case .saveReplay: profile == .development ? KeyboardShortcuts.Shortcut(.minus, modifiers: modifiers) : nil
        case .scrollingCapture: profile == .development ? KeyboardShortcuts.Shortcut(.equal, modifiers: modifiers) : nil
        case .captureWindow, .capturePreviousArea, .selfTimer, .captureTextJoined, .openHistory, .copyLatestCapture: nil
        }
    }
}
