import AppKit
import OMSCore

extension ColorCopyGesture {
    /// Match only the four shortcut modifiers. Caps Lock and device flags do not change a shortcut,
    /// while another held shortcut modifier must not accidentally trigger it.
    nonisolated func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        let expected: NSEvent.ModifierFlags = switch self {
        case .disabled: []
        case .option: .option
        case .control: .control
        case .command: .command
        case .shiftOption: [.shift, .option]
        case .commandOption: [.command, .option]
        }
        return self != .disabled && flags.intersection([.command, .control, .option, .shift]) == expected
    }
}
