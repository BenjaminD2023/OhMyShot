import AppKit
import CoreGraphics
import OMSCore
import Testing
@testable import OMSUI

/// The Quick Access panel's keys and the sizes of its cards. Nothing is shown on screen: the panel and the
/// stack are never ordered in, and the events are made in memory.
@MainActor
struct QuickAccessKeyboardTests {
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code
        ))
    }

    private func item(width: Int, height: Int) throws -> QuickAccessItem {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return QuickAccessItem(
            id: UUID(), fileURL: URL(filePath: "/tmp/none.png"), thumbnail: try #require(context.makeImage()),
            pixelWidth: width, pixelHeight: height, displayID: 0
        )
    }

    /// The command the stack passes on for a key, or nil when it passes none. A key with ⌘ arrives as a key
    /// equivalent, any other as a key down.
    private func command(for event: NSEvent) -> CardCommand? {
        let stack = CardStackView(frame: .zero)
        var received: CardCommand?
        stack.onKey = { command in
            received = command
            return true
        }
        if event.modifierFlags.contains(.command) {
            _ = stack.performKeyEquivalent(with: event)
        } else {
            stack.keyDown(with: event)
        }
        return received
    }

    @Test func thePanelTakesTheKeysOnlyWhenAskedTo() {
        let panel = QuickAccessPanel()
        #expect(!panel.canBecomeKey)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        panel.allowsKey = true
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func thePanelSaysWhenItLosesTheKeys() {
        let panel = QuickAccessPanel()
        var lost = 0
        panel.onResignKey = { lost += 1 }
        panel.resignKey()
        #expect(lost == 1)
    }

    @Test func commandKeysReachTheStackAsCommands() throws {
        #expect(try command(for: key("c", code: 8, modifiers: .command)) == CardCommand.copy)
        #expect(try command(for: key("s", code: 1, modifiers: [.command, .shift])) == CardCommand.saveAs)
        #expect(try command(for: key("p", code: 35, modifiers: [.command, .shift])) == CardCommand.pin)
        #expect(try command(for: key("p", code: 35, modifiers: .command)) == CardCommand.print)
        #expect(try command(for: key("\u{8}", code: 51, modifiers: .command)) == CardCommand.moveToTrash)
    }

    @Test func plainKeysReachTheStackAsCommands() throws {
        #expect(try command(for: key("\u{1B}", code: 53)) == CardCommand.close)
        #expect(try command(for: key(" ", code: 49)) == CardCommand.quickLook)
        #expect(try command(for: key("\u{8}", code: 51)) == CardCommand.moveToTrash)
        #expect(try command(for: key("\u{F700}", code: 126)) == CardCommand.selectOlder)
        #expect(try command(for: key("\u{F701}", code: 125)) == CardCommand.selectNewer)
    }

    @Test func aKeyThatMeansNothingIsNotTaken() throws {
        let stack = CardStackView(frame: .zero)
        var asked = false
        stack.onKey = { _ in
            asked = true
            return true
        }
        #expect(try !stack.performKeyEquivalent(with: key("q", code: 12, modifiers: .command)))
        #expect(!asked)
    }

    @Test func aStackWithoutAnOwnerTakesNoKeys() throws {
        let stack = CardStackView(frame: .zero)
        #expect(try !stack.performKeyEquivalent(with: key("c", code: 8, modifiers: .command)))
    }

    @Test func cardsGrowWithTheirSizeAndKeepTheirShapeWithinBounds() throws {
        let standard = try item(width: 800, height: 600)
        #expect(CaptureCardView.preferredHeight(for: standard) == 165)
        #expect(CaptureCardView.preferredHeight(for: standard, size: .small) == 135)
        #expect(CaptureCardView.preferredHeight(for: standard, size: .large) == 195)
        let strip = try item(width: 3000, height: 100)
        for size in QuickAccessSize.allCases {
            #expect(CaptureCardView.preferredHeight(for: strip, size: size) == QuickAccessSize.shortest)
        }
    }

    @Test func theStackIsAsWideAndTallAsItsCards() throws {
        let items = [try item(width: 800, height: 600), try item(width: 600, height: 1200)]
        let margin = CardStackView.margin
        #expect(CardStackView.width(for: .medium) == 220 + margin * 2)
        #expect(CardStackView.width(for: .large) == 260 + margin * 2)
        // 165 + 172 and one 12 pt gap, between the margins.
        #expect(CardStackView.height(for: items, size: .medium) == 165 + 172 + CardStackView.gap + margin * 2)
        #expect(CardStackView.height(for: [], size: .medium) == margin * 2)
    }
}
