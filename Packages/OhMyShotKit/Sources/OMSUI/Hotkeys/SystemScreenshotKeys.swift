import AppKit
import KeyboardShortcuts

/// macOS's own screenshot shortcuts (Keyboard Settings › Keyboard Shortcuts › Screenshots), read and never written. The
/// release build's defaults are ⇧⌘3, ⇧⌘4, and ⇧⌘5, as macOS's are, and macOS answers its keys first while they are on.
public enum SystemScreenshotKeys {
    /// One of OhMyShot's shortcuts whose keys are also one of macOS's screenshot shortcuts.
    public struct Clash: Equatable, Identifiable {
        public let shortcut: CaptureShortcut
        /// The keys as a menu shows them: "⇧⌘4".
        public let keys: String
        /// Whether macOS still answers them, so OhMyShot never sees them.
        public let takenByMacOS: Bool
        public var id: CaptureShortcut { shortcut }
    }

    /// An OhMyShot shortcut's keys, as `clashes` compares them.
    public struct Binding {
        let shortcut: CaptureShortcut
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags
        let keys: String

        init(_ shortcut: CaptureShortcut, _ keys: KeyboardShortcuts.Shortcut) {
            self.shortcut = shortcut
            keyCode = keys.carbonKeyCode
            modifiers = keys.modifiers
            self.keys = keys.description
        }
    }

    /// The hot keys macOS lists under Screenshots, with the keys each has until it is changed: Save picture of screen as a
    /// file, Copy picture of screen to the clipboard, the same two for a selected area, and Screenshot and recording options.
    private static let screenshotHotKeys: [(id: String, keyCode: Int, modifiers: NSEvent.ModifierFlags)] = [
        ("28", 20, [.shift, .command]), ("29", 20, [.control, .shift, .command]),
        ("30", 21, [.shift, .command]), ("31", 21, [.control, .shift, .command]),
        ("184", 23, [.shift, .command]),
    ]

    private static let keyModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Where macOS keeps its hot keys: an entry each, `enabled` and the keys as [character, key code, modifier flags]. A
    /// hot key never changed has no entry, and is on with its own keys.
    nonisolated public static func readHotKeys() -> [String: Any]? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
    }

    /// OhMyShot's shortcuts as they are set now.
    public static func currentBindings() -> [Binding] {
        CaptureShortcut.allCases.compactMap { shortcut in KeyboardShortcuts.getShortcut(for: shortcut.name).map { Binding(shortcut, $0) } }
    }

    /// The keys a build's shortcuts have until someone changes them.
    public static func defaultBindings(for profile: HotkeyCenter.Profile) -> [Binding] {
        let center = HotkeyCenter(profile: profile)
        return CaptureShortcut.allCases.compactMap { shortcut in center.defaultShortcut(for: shortcut).map { Binding(shortcut, $0) } }
    }

    /// OhMyShot's shortcuts that have the keys of one of macOS's screenshot shortcuts, on or off, in the order macOS
    /// lists those (⇧⌘3, ⇧⌘4, ⇧⌘5). The debug build's ⌃⌥⌘ keys never clash.
    public static func clashes(hotKeys: [String: Any]?, bindings: [Binding]) -> [Clash] {
        let system = screenshotHotKeys.map { hotKey -> (keyCode: Int, modifiers: NSEvent.ModifierFlags, isOn: Bool) in
            let entry = hotKeys?[hotKey.id] as? [String: Any]
            let isOn = (entry?["enabled"] as? NSNumber)?.boolValue ?? true
            guard let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 else {
                return (hotKey.keyCode, hotKey.modifiers, isOn)
            }
            return (parameters[1], NSEvent.ModifierFlags(rawValue: UInt(parameters[2])).intersection(keyModifiers), isOn)
        }
        return bindings.compactMap { binding -> (order: Int, clash: Clash)? in
            let modifiers = binding.modifiers.intersection(keyModifiers)
            let same = system.indices.filter { system[$0].keyCode == binding.keyCode && system[$0].modifiers == modifiers }
            guard let first = same.first else { return nil }
            return (first, Clash(shortcut: binding.shortcut, keys: binding.keys, takenByMacOS: same.contains { system[$0].isOn }))
        }
        .sorted { $0.order < $1.order }
        .map(\.clash)
    }
}
