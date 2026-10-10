import AppKit
import Carbon.HIToolbox

/// Which keys a recording shows.
public enum KeystrokeMode: String, CaseIterable, Sendable {
    /// Every key: typing runs on as it is typed, shortcuts and special keys by name.
    case all
    /// Shortcuts only (keys held with Command, Control, or Option) and function keys.
    case shortcuts
}

/// What the keystroke display shows: a shortcut as it is pressed ("⌘⇧4"), or typing as it runs ("hello↩").
public struct KeystrokeCaption: Equatable, Sendable {
    public let mode: KeystrokeMode
    public private(set) var text = ""
    /// Whether `text` is typing that the next typed key carries on.
    private var isTyping = false

    /// The longest typing kept: older characters give way to an ellipsis.
    static let longest = 24

    public init(mode: KeystrokeMode) {
        self.mode = mode
    }

    /// Takes a key press; returns whether the caption changed and should show. Held-down keys repeating show
    /// once.
    public mutating func add(_ press: Keystroke) -> Bool {
        guard !press.isRepeat else { return false }
        let isShortcut = !press.modifiers.isDisjoint(with: [.command, .control, .option])
        let special = Self.specialName(press.keyCode)
        let isFunctionKey = Self.functionKeys.contains(Int(press.keyCode))
        if isShortcut || isFunctionKey {
            text = Self.modifierSymbols(press.modifiers) + (special ?? press.keyCharacters.uppercased())
            isTyping = false
            return !text.isEmpty
        }
        guard mode == .all else { return false }
        // Typing: characters as typed; special keys by their symbols, Space as a space within typing.
        let typed: String = if press.keyCode == UInt16(kVK_Space) {
            " "
        } else if let special {
            special
        } else {
            press.characters
        }
        guard !typed.isEmpty, !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if press.keyCode == UInt16(kVK_Space), !isTyping {
            text = "␣"
            isTyping = false
            return true
        }
        text = isTyping ? text + typed : (press.modifiers.contains(.shift) && special != nil ? "⇧" + typed : typed)
        if text.count > Self.longest { text = "…" + text.suffix(Self.longest - 1) }
        isTyping = true
        return true
    }

    /// The caption shown has faded: what comes next starts afresh.
    public mutating func clear() {
        text = ""
        isTyping = false
    }

    /// Modifier symbols in the Mac's order: ⌃⌥⇧⌘.
    static func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }

    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// The name of a key that types nothing, or types something unseen: a symbol where the Mac has one.
    static func specialName(_ keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Return: "↩"
        case kVK_ANSI_KeypadEnter: "⌅"
        case kVK_Tab: "⇥"
        case kVK_Space: "␣"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "⎋"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_DownArrow: "↓"
        case kVK_UpArrow: "↑"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_Help: "Help"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_F16: "F16"
        case kVK_F17: "F17"
        case kVK_F18: "F18"
        case kVK_F19: "F19"
        case kVK_F20: "F20"
        default: nil
        }
    }
}
