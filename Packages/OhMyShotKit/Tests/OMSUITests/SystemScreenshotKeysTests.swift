import AppKit
import KeyboardShortcuts
import Testing
@testable import OMSUI

struct SystemScreenshotKeysTests {
    private static let releaseBindings = SystemScreenshotKeys.defaultBindings(for: .release)

    private static func binding(_ shortcut: CaptureShortcut, _ key: KeyboardShortcuts.Key, _ modifiers: NSEvent.ModifierFlags) -> SystemScreenshotKeys.Binding {
        SystemScreenshotKeys.Binding(shortcut, KeyboardShortcuts.Shortcut(key, modifiers: modifiers))
    }

    /// An entry as macOS writes it: the character, the key code, and the modifier flags.
    private static func entry(enabled: Bool, character: Int, keyCode: Int, modifiers: NSEvent.ModifierFlags) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [character, keyCode, Int(modifiers.rawValue)], "type": "standard"]]
    }

    @Test func onAMacWhoseKeysWereNeverChangedMacOSTakesTheReleaseDefaults() {
        let clashes = SystemScreenshotKeys.clashes(hotKeys: nil, bindings: Self.releaseBindings)

        // In macOS's order, not OhMyShot's (Capture Area comes first there).
        #expect(clashes.map(\.shortcut) == [.captureFullscreen, .captureArea, .allInOne])
        #expect(clashes.allSatisfy { $0.takenByMacOS })
        #expect(clashes.map(\.keys) == ["⇧⌘3", "⇧⌘4", "⇧⌘5"])
    }

    @Test func keysTurnedOffInKeyboardSettingsAreOhMyShots() {
        let off = Dictionary(uniqueKeysWithValues: ["28", "29", "30", "31", "184"].map { ($0, ["enabled": false] as [String: Any]) })

        let clashes = SystemScreenshotKeys.clashes(hotKeys: off, bindings: Self.releaseBindings)

        #expect(clashes.count == 3)
        #expect(!clashes.contains { $0.takenByMacOS })
    }

    @Test func aScreenshotKeyMovedElsewhereNoLongerClashes() {
        // Save picture of selected area moved to ⌥⇧⌘4 and still on; its clipboard twin (⌃⇧⌘4) never clashed.
        let moved = ["30": Self.entry(enabled: true, character: 52, keyCode: 21, modifiers: [.option, .shift, .command])]

        let clashes = SystemScreenshotKeys.clashes(hotKeys: moved, bindings: Self.releaseBindings)

        #expect(clashes.map(\.shortcut) == [.captureFullscreen, .allInOne])
    }

    @Test func anOhMyShotShortcutOnAMovedKeyClashesWithItThere() {
        let moved = ["30": Self.entry(enabled: true, character: 52, keyCode: 21, modifiers: [.option, .shift, .command])]
        let bindings = [Self.binding(.captureArea, .four, [.option, .shift, .command])]

        let clashes = SystemScreenshotKeys.clashes(hotKeys: moved, bindings: bindings)

        #expect(clashes.map(\.shortcut) == [.captureArea])
        #expect(clashes.first?.takenByMacOS == true)
    }

    @Test func theDebugBuildsKeysNeverClash() {
        #expect(SystemScreenshotKeys.clashes(hotKeys: nil, bindings: SystemScreenshotKeys.defaultBindings(for: .development)).isEmpty)
    }
}
