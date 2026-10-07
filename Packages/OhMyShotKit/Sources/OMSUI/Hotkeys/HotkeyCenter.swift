import AppKit
import Foundation
import KeyboardShortcuts

/// The global shortcuts that start a capture.
public enum CaptureShortcut: String, CaseIterable, Sendable {
    case captureArea
    case captureFullscreen
    case captureWindow
    case capturePreviousArea
    case allInOne
    case selfTimer
    case captureText
    /// Capture Text with the lines of each paragraph joined.
    case captureTextJoined
    case openHistory
    /// Copies the newest Quick Access card's capture, so it can be reached without the pointer.
    case copyLatestCapture

    public var name: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name(rawValue)
    }

    public var title: String {
        switch self {
        case .captureArea: String(localized: "Capture Area", bundle: .module)
        case .captureFullscreen: String(localized: "Capture Fullscreen", bundle: .module)
        case .captureWindow: String(localized: "Capture Window", bundle: .module)
        case .capturePreviousArea: String(localized: "Capture Previous Area", bundle: .module)
        case .allInOne: String(localized: "All-In-One", bundle: .module)
        case .selfTimer: String(localized: "Self-Timer", bundle: .module)
        case .captureText: String(localized: "Capture Text", bundle: .module)
        case .captureTextJoined: String(localized: "Capture Text, Joining Lines", bundle: .module)
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

    /// Assigns the default shortcuts on the first launch of this build flavor only, so a shortcut the
    /// user cleared stays cleared.
    public func installDefaultShortcutsIfNeeded() {
        let key = "didInstallDefaultShortcuts"
        guard !defaults.bool(forKey: key) else { return }
        for shortcut in CaptureShortcut.allCases {
            if let defaultShortcut = defaultShortcut(for: shortcut) {
                KeyboardShortcuts.setShortcut(defaultShortcut, for: shortcut.name)
            }
        }
        defaults.set(true, forKey: key)
    }

    /// Starts listening. The handler runs on key down, so the overlay can appear before the keys are
    /// released.
    public func activate(_ handler: @escaping (CaptureShortcut) -> Void) {
        for shortcut in CaptureShortcut.allCases {
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
        case .captureText: KeyboardShortcuts.Shortcut(.two, modifiers: modifiers)
        case .captureFullscreen: KeyboardShortcuts.Shortcut(.three, modifiers: modifiers)
        case .captureArea: KeyboardShortcuts.Shortcut(.four, modifiers: modifiers)
        case .allInOne: KeyboardShortcuts.Shortcut(.five, modifiers: modifiers)
        case .captureWindow, .capturePreviousArea, .selfTimer, .captureTextJoined, .openHistory, .copyLatestCapture: nil
        }
    }
}
