import Foundation

/// What a Quick Access card can be told to do, from its menu, its buttons, or the keyboard.
public enum CardCommand: Equatable, Sendable {
    case copy
    case save
    case saveAs
    case annotate
    case open
    case quickLook
    case recognizeText
    case pin
    case print
    /// To the default destination.
    case upload
    /// Turns, flips, or scales the capture's picture.
    case picture(PictureChange)
    case moveToTrash
    case close
    /// Every card of the stack.
    case saveAll
    case closeAll
    /// Moves the keyboard to the card above or below.
    case selectOlder
    case selectNewer
}

/// The keys of a card that has the keyboard, in one table that the panel answers and the menu shows.
/// Pure: the panel turns an event into a `Key` and `Modifiers`, so the table is tested without events.
public enum CardKeys {
    public enum Key: Equatable, Sendable {
        /// A character key, as a lowercase letter or the character itself.
        case character(Character)
        case escape
        case delete
        case space
        case left
        case right
        case up
        case down
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public struct Binding: Equatable, Sendable {
        public let key: Key
        public let modifiers: Modifiers
        public let command: CardCommand
    }

    /// Every binding. A command with two keys is shown with the first.
    public static let bindings: [Binding] = [
        Binding(key: .character("c"), modifiers: .command, command: .copy),
        Binding(key: .character("s"), modifiers: .command, command: .save),
        Binding(key: .character("s"), modifiers: [.command, .shift], command: .saveAs),
        Binding(key: .character("s"), modifiers: [.command, .option], command: .saveAll),
        Binding(key: .character("e"), modifiers: .command, command: .annotate),
        Binding(key: .character("o"), modifiers: .command, command: .open),
        Binding(key: .space, modifiers: [], command: .quickLook),
        Binding(key: .character("t"), modifiers: [.command, .shift], command: .recognizeText),
        Binding(key: .character("p"), modifiers: [.command, .shift], command: .pin),
        Binding(key: .character("p"), modifiers: .command, command: .print),
        Binding(key: .character("u"), modifiers: [.command, .shift], command: .upload),
        Binding(key: .character("l"), modifiers: .command, command: .picture(.rotateLeft)),
        Binding(key: .character("r"), modifiers: .command, command: .picture(.rotateRight)),
        Binding(key: .delete, modifiers: .command, command: .moveToTrash),
        Binding(key: .delete, modifiers: [], command: .moveToTrash),
        Binding(key: .escape, modifiers: [], command: .close),
        Binding(key: .character("w"), modifiers: .command, command: .close),
        Binding(key: .character("w"), modifiers: [.command, .option], command: .closeAll),
        Binding(key: .up, modifiers: [], command: .selectOlder),
        Binding(key: .left, modifiers: [], command: .selectOlder),
        Binding(key: .down, modifiers: [], command: .selectNewer),
        Binding(key: .right, modifiers: [], command: .selectNewer),
    ]

    /// What a key means to a card that has the keyboard, if anything.
    public static func command(for key: Key, modifiers: Modifiers) -> CardCommand? {
        bindings.first { $0.key == key && $0.modifiers == modifiers }?.command
    }

    /// The key a menu shows beside a command, if it has one.
    public static func binding(for command: CardCommand) -> Binding? {
        bindings.first { $0.command == command }
    }

    /// The `keyEquivalent` string a menu item uses for a key.
    public static func menuEquivalent(for key: Key) -> String {
        switch key {
        case .character(let character): String(character)
        case .escape: "\u{1B}"
        case .delete: "\u{8}"
        case .space: " "
        case .left: "\u{F702}"
        case .right: "\u{F703}"
        case .up: "\u{F700}"
        case .down: "\u{F701}"
        }
    }
}
