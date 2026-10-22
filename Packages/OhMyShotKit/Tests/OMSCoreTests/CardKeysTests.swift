import Testing
@testable import OMSCore

/// The keys of a Quick Access card that has the keyboard.
struct CardKeysTests {
    @Test func theNamedKeysDoWhatTheyAreMeantTo() {
        #expect(CardKeys.command(for: .character("c"), modifiers: .command) == .copy)
        #expect(CardKeys.command(for: .character("s"), modifiers: .command) == .save)
        #expect(CardKeys.command(for: .character("s"), modifiers: [.command, .shift]) == .saveAs)
        #expect(CardKeys.command(for: .character("e"), modifiers: .command) == .annotate)
        #expect(CardKeys.command(for: .space, modifiers: []) == .quickLook)
        #expect(CardKeys.command(for: .escape, modifiers: []) == .close)
        #expect(CardKeys.command(for: .delete, modifiers: .command) == .moveToTrash)
        #expect(CardKeys.command(for: .character("z"), modifiers: .command) == .undoTrash)
    }

    /// Delete alone means nothing: a card keeps the keys after a click, and a Delete typed for the app in front must
    /// not throw a capture away.
    @Test func deleteAloneDoesNotTrash() {
        #expect(CardKeys.command(for: .delete, modifiers: []) == nil)
    }

    /// ⌘P is Print, as it is in a pin's menu; Pin to Screen has its own keys.
    @Test func printAndPinDoNotShareAKey() {
        #expect(CardKeys.command(for: .character("p"), modifiers: .command) == .print)
        #expect(CardKeys.command(for: .character("p"), modifiers: [.command, .shift]) == .pin)
    }

    @Test func theArrowsMoveBetweenCards() {
        #expect(CardKeys.command(for: .up, modifiers: []) == .selectOlder)
        #expect(CardKeys.command(for: .left, modifiers: []) == .selectOlder)
        #expect(CardKeys.command(for: .down, modifiers: []) == .selectNewer)
        #expect(CardKeys.command(for: .right, modifiers: []) == .selectNewer)
    }

    @Test func aKeyWithTheWrongModifiersMeansNothing() {
        #expect(CardKeys.command(for: .character("c"), modifiers: []) == nil)
        #expect(CardKeys.command(for: .space, modifiers: .command) == nil)
        #expect(CardKeys.command(for: .character("c"), modifiers: [.command, .control]) == nil)
        #expect(CardKeys.command(for: .character("q"), modifiers: .command) == nil)
    }

    @Test func noTwoBindingsShareKeys() {
        let keys = CardKeys.bindings.map { "\($0.key)-\($0.modifiers.rawValue)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func everyBindingIsFoundByItsKeys() {
        for binding in CardKeys.bindings {
            #expect(CardKeys.command(for: binding.key, modifiers: binding.modifiers) == binding.command)
        }
    }

    /// What the menu shows beside an item is a binding the card answers.
    @Test func everyMenuCommandWithAKeyShowsOne() {
        let shown: [CardCommand] = [
            .copy, .save, .saveAs, .annotate, .open, .quickLook, .recognizeText, .pin, .print, .upload,
            .picture(.rotateLeft), .picture(.rotateRight), .moveToTrash, .close, .saveAll, .closeAll,
        ]
        for command in shown {
            let binding = CardKeys.binding(for: command)
            #expect(binding != nil, "\(command) has no key")
            if let binding { #expect(CardKeys.command(for: binding.key, modifiers: binding.modifiers) == command) }
        }
        // Flips and Scale to 1× are in the menu only.
        #expect(CardKeys.binding(for: .picture(.flipHorizontal)) == nil)
        #expect(CardKeys.binding(for: .picture(.scaleToOneX(pixelsPerPoint: 2))) == nil)
    }

    @Test func theTrashIsShownWithCommandDeleteAsHistoryHasIt() {
        #expect(CardKeys.binding(for: .moveToTrash)?.modifiers == .command)
        #expect(CardKeys.binding(for: .moveToTrash)?.key == .delete)
    }

    @Test func menuEquivalentsAreWhatAMenuItemWants() {
        #expect(CardKeys.menuEquivalent(for: .character("c")) == "c")
        #expect(CardKeys.menuEquivalent(for: .space) == " ")
        #expect(CardKeys.menuEquivalent(for: .escape) == "\u{1B}")
        #expect(CardKeys.menuEquivalent(for: .delete) == "\u{8}")
    }
}
