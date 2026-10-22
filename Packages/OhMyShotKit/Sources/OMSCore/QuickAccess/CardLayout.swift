import CoreGraphics
import Foundation

/// Where the stack of Quick Access cards stands on a display.
public enum QuickAccessPlacement {
    /// How far the cards stand from the edges of the display's visible frame.
    public static let edge: CGFloat = 26

    /// The panel that holds the stack, `margin` wider than the cards on each side (room for their shadows), with
    /// the cards `edge` from the bottom and from the side of `corner`.
    public static func panelFrame(corner: QuickAccessCorner, visible: CGRect, panelWidth: CGFloat, panelHeight: CGFloat, margin: CGFloat) -> CGRect {
        let x = switch corner {
        case .bottomLeft: visible.minX + edge - margin
        case .bottomRight: visible.maxX - edge + margin - panelWidth
        }
        return CGRect(x: x, y: visible.minY + edge - margin, width: panelWidth, height: panelHeight)
    }

    /// The tallest the stack of cards can be on a display, margins left out.
    public static func tallestStack(visible: CGRect) -> CGFloat {
        visible.height - edge * 2
    }

    /// The display the stack goes to for a capture taken on `capture`: the one with the pointer when that is
    /// asked for and known.
    public static func display(forCaptureOn capture: CGDirectDisplayID, pointerOn pointer: CGDirectDisplayID?, followsPointer: Bool) -> CGDirectDisplayID {
        followsPointer ? pointer ?? capture : capture
    }
}

/// Where the small buttons of a card's hover state stand. Columns run down the card's two sides under the
/// Close and More buttons, and each button has a place of its own there, so none moves while the pointer is over
/// the card (an upload that starts or ends leaves its place empty rather than moving the others up). A card too
/// short for a button's place leaves it to its menu, which has every action anyway.
public enum CardControlLayout {
    public static let buttonSize: CGFloat = 24
    public static let gap: CGFloat = 6
    /// From the card's edges to its corner buttons.
    public static let inset: CGFloat = 8

    public enum Side: Equatable, Sendable {
        case leading
        case trailing
    }

    public struct Slot: Equatable, Sendable {
        public let side: Side
        /// 0 is the first below the corner button.
        public let row: Int

        public init(side: Side, row: Int) {
            self.side = side
            self.row = row
        }
    }

    /// The side buttons a card can have.
    public enum Extra: Equatable, Sendable {
        /// Annotate, or Edit or Play on a recording.
        case annotate
        case pin
        case upload
        case recognizeText
        case trash
    }

    /// How many buttons fit in a column of a card `height` tall below its corner button, with `reserve` points
    /// kept free at the bottom.
    public static func rows(height: CGFloat, reserve: CGFloat = 0) -> Int {
        let room = height - inset * 2 - reserve - buttonSize
        guard room >= buttonSize else { return 0 }
        return Int((room + gap) / (buttonSize + gap))
    }

    /// A button's place, whether or not the card has room for it. A screenshot's editor, Pin, and Upload run down
    /// the leading side and Recognize Text and Trash down the trailing one; a recording's editor and Upload run down
    /// the leading side and Trash stands under More. Trash is never beside Close, and Upload is last on its side,
    /// the first to give way on a short card, since its badge and the menu have it too.
    public static func place(of extra: Extra, onRecording: Bool) -> Slot? {
        switch (extra, onRecording) {
        case (.annotate, _): Slot(side: .leading, row: 0)
        case (.pin, false): Slot(side: .leading, row: 1)
        case (.upload, false): Slot(side: .leading, row: 2)
        case (.recognizeText, false): Slot(side: .trailing, row: 0)
        case (.trash, false): Slot(side: .trailing, row: 1)
        case (.upload, true): Slot(side: .leading, row: 1)
        case (.trash, true): Slot(side: .trailing, row: 0)
        case (.pin, true), (.recognizeText, true): nil
        }
    }

    /// The place of each of `extras` on a card `height` tall, or nil for one it has no room for. `leadingReserve` is
    /// the height the leading column keeps free at the bottom (a recording's length badge stands there).
    public static func slots(for extras: [Extra], onRecording: Bool, height: CGFloat, leadingReserve: CGFloat = 0) -> [Slot?] {
        let rows: [Side: Int] = [.leading: rows(height: height, reserve: leadingReserve), .trailing: rows(height: height)]
        return extras.map { extra in
            guard let slot = place(of: extra, onRecording: onRecording), slot.row < rows[slot.side] ?? 0 else { return nil }
            return slot
        }
    }

    /// The top of a slot's button, measured down from the card's top.
    public static func top(of slot: Slot) -> CGFloat {
        inset + CGFloat(slot.row + 1) * (buttonSize + gap)
    }

    /// The left of a slot's button in a card `width` wide.
    public static func left(of slot: Slot, width: CGFloat) -> CGFloat {
        slot.side == .leading ? inset : width - inset - buttonSize
    }
}
