import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSCore
@testable import OMSUI

@MainActor
struct ColorCardTests {
    private func makeLaidOutCard() throws -> (ColorCard, ScreenColor) {
        let color = try #require(ScreenColor(srgbRed: 0.2, green: 0.4, blue: 1))
        let card = ColorCard()
        card.show(color, format: .hex)
        let size = card.fittingSize()
        card.frame = CGRect(origin: .zero, size: size)
        card.layoutSubtreeIfNeeded()
        return (card, color)
    }

    @Test func panelIsMovableAndHandlesEscapeAndClickEvents() throws {
        let panel = ColorCardPanel()
        #expect(panel.isMovable)

        var cancelled = 0
        var clicked = 0
        panel.onCancel = { cancelled += 1 }
        panel.onClick = { clicked += 1 }

        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        panel.sendEvent(escape)
        #expect(cancelled == 1)

        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        panel.sendEvent(click)
        #expect(clicked == 1)
    }

    @Test func headerIsDraggableOutsideCloseButtonAndRows() throws {
        let (card, _) = try makeLaidOutCard()
        let headerMid = CGPoint(x: card.headerDragRect.midX, y: card.headerDragRect.midY)
        #expect(card.isInHeaderDragArea(headerMid))

        // Close button corner is excluded from header dragging.
        let closeArea = CGPoint(x: card.headerDragRect.maxX - 20, y: card.headerDragRect.minY + 20)
        #expect(!card.isInHeaderDragArea(closeArea))

        // A notation row is not part of the header drag region.
        let firstRow = try #require(card.rows.first)
        let rowMid = CGPoint(x: firstRow.highlight.frame.midX, y: firstRow.highlight.frame.midY)
        #expect(!card.isInHeaderDragArea(rowMid))
    }

    @Test func clickingAnywhereOnANotationRowMapsToThatRowAndCopiesItsValue() throws {
        let (card, color) = try makeLaidOutCard()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        card.pasteboard = pasteboard

        for (index, row) in card.rows.enumerated() {
            // Label area, value area, and copy-button area all resolve to this row.
            let labelPoint = CGPoint(x: row.label.frame.midX, y: row.label.frame.midY)
            let valuePoint = CGPoint(x: row.value.frame.midX, y: row.value.frame.midY)
            let trailingPoint = CGPoint(x: row.copy.frame.midX, y: row.copy.frame.midY)
            #expect(card.rowIndex(at: labelPoint) == index)
            #expect(card.rowIndex(at: valuePoint) == index)
            #expect(card.rowIndex(at: trailingPoint) == index)

            // Label and value pass hit tests through to the card so clicking text copies the row.
            #expect(row.label.hitTest(CGPoint(x: 2, y: 2)) == nil)
            #expect(row.value.hitTest(CGPoint(x: 2, y: 2)) == nil)

            card.copyRow(at: index)
            #expect(pasteboard.string(forType: .string) == color.string(in: row.format))
        }
    }
}
