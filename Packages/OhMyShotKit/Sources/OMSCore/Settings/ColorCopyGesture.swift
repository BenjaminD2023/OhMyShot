import Foundation

/// A local modifier-click that copies a color without ending the capture or color-picking session.
public enum ColorCopyGesture: String, CaseIterable, Sendable {
    case disabled
    case option
    case control
    case command
    case shiftOption
    case commandOption

    /// The modifier keys; the interface supplies the localized mouse-button label.
    public var modifierSymbols: String {
        switch self {
        case .disabled: ""
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        case .shiftOption: "⇧⌥"
        case .commandOption: "⌥⌘"
        }
    }
}
