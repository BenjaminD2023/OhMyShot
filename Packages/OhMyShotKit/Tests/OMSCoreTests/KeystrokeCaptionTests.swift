import AppKit
import Carbon.HIToolbox
import Testing
@testable import OMSCore

struct KeystrokeCaptionTests {
    private func key(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [], label: String? = nil, repeating: Bool = false) -> Keystroke {
        Keystroke(keyCode: UInt16(code), modifiers: modifiers, characters: characters, keyCharacters: label ?? characters.lowercased(), isRepeat: repeating)
    }

    /// Adds the presses in order; returns whether each changed the caption.
    private func type(_ presses: [Keystroke], into caption: inout KeystrokeCaption) -> [Bool] {
        presses.map { caption.add($0) }
    }

    @Test func shortcutsShowTheirModifiersInTheMacsOrder() {
        var caption = KeystrokeCaption(mode: .all)
        #expect(type([key(kVK_ANSI_4, "$", [.shift, .command], label: "4")], into: &caption) == [true])
        #expect(caption.text == "⇧⌘4")
        #expect(type([key(kVK_LeftArrow, "", [.control, .option])], into: &caption) == [true])
        #expect(caption.text == "⌃⌥←")
        #expect(type([key(kVK_ANSI_C, "c", [.command])], into: &caption) == [true])
        #expect(caption.text == "⌘C")
    }

    @Test func typingRunsOnAndGivesWayToAShortcut() {
        var caption = KeystrokeCaption(mode: .all)
        let typing = [key(kVK_ANSI_H, "H", [.shift]), key(kVK_ANSI_I, "i"), key(kVK_Space, " "), key(kVK_ANSI_A, "a"), key(kVK_Return, "\r")]
        #expect(type(typing, into: &caption) == [true, true, true, true, true])
        #expect(caption.text == "Hi a↩")
        #expect(type([key(kVK_ANSI_S, "s", [.command])], into: &caption) == [true])
        #expect(caption.text == "⌘S")
        // Typing after a shortcut starts afresh.
        #expect(type([key(kVK_ANSI_X, "x")], into: &caption) == [true])
        #expect(caption.text == "x")
    }

    @Test func longTypingKeepsItsEnd() {
        var caption = KeystrokeCaption(mode: .all)
        _ = type(Array(repeating: key(kVK_ANSI_A, "a"), count: 40) + [key(kVK_ANSI_B, "b")], into: &caption)
        #expect(caption.text.count == KeystrokeCaption.longest)
        #expect(caption.text.hasPrefix("…") && caption.text.hasSuffix("ab"))
    }

    @Test func shortcutsOnlyLeavesTypingOutButShowsFunctionKeys() {
        var caption = KeystrokeCaption(mode: .shortcuts)
        #expect(type([key(kVK_ANSI_A, "a"), key(kVK_Return, "\r")], into: &caption) == [false, false])
        #expect(type([key(kVK_F5, "")], into: &caption) == [true])
        #expect(caption.text == "F5")
        #expect(type([key(kVK_ANSI_Z, "Z", [.command, .shift], label: "z")], into: &caption) == [true])
        #expect(caption.text == "⇧⌘Z")
    }

    @Test func repeatsShowOnceAndASpaceAloneShows() {
        var caption = KeystrokeCaption(mode: .all)
        #expect(type([key(kVK_ANSI_K, "k"), key(kVK_ANSI_K, "k", repeating: true)], into: &caption) == [true, false])
        #expect(caption.text == "k")
        caption.clear()
        #expect(type([key(kVK_Space, " ")], into: &caption) == [true])
        #expect(caption.text == "␣")
    }
}
