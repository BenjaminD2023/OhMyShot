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
/// Close and More buttons; buttons fill them alternately, left first. A card too short for them all leaves the
/// last ones to its menu, which has every action anyway.
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

    /// How many buttons fit in a column of a card `height` tall below its corner button, with `reserve` points
    /// kept free at the bottom.
    public static func rows(height: CGFloat, reserve: CGFloat = 0) -> Int {
        let room = height - inset * 2 - reserve - buttonSize
        guard room >= buttonSize else { return 0 }
        return Int((room + gap) / (buttonSize + gap))
    }

    /// The slot of each of `count` buttons in order, or nil for one that has no room. `leadingReserve` is the
    /// height the leading column keeps free at the bottom (a recording's length badge stands there).
    public static func slots(count: Int, height: CGFloat, leadingReserve: CGFloat = 0) -> [Slot?] {
        var free: [Side: Int] = [.leading: rows(height: height, reserve: leadingReserve), .trailing: rows(height: height)]
        var used: [Side: Int] = [.leading: 0, .trailing: 0]
        var side = Side.leading
        return (0..<count).map { _ in
            let other: Side = side == .leading ? .trailing : .leading
            let chosen: Side? = (free[side] ?? 0) > (used[side] ?? 0) ? side : (free[other] ?? 0) > (used[other] ?? 0) ? other : nil
            guard let chosen else { return nil }
            defer {
                used[chosen, default: 0] += 1
                side = chosen == .leading ? .trailing : .leading
            }
            return Slot(side: chosen, row: used[chosen] ?? 0)
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
