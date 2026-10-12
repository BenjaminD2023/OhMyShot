import AppKit
import OMSCore

/// The frame around an area chosen on the overlay while it is set up for what comes next (a recording, a
/// scrolling capture): its handles, how a drag on one resizes it, the cursors over them, where the bar under
/// it goes, and the overlay's points from the display's top-left corner against global ones.
enum AreaFrame {
    enum Handle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// Corners reach this far for a press, edges this far, shrinking on small frames.
    static let cornerReach: CGFloat = 12
    static let edgeReach: CGFloat = 6
    /// The smallest area, in points.
    static let smallest: CGFloat = 16

    /// The handle under `point`: the corners and edges of `frame` as drawn in `bounds`.
    static func handle(at point: CGPoint, of frame: CGRect, in bounds: CGRect) -> Handle? {
        let rect = SelectionChromeView.drawnFrame(for: frame, in: bounds)
        let cornerReach = max(min(Self.cornerReach, rect.width / 4, rect.height / 4), 4)
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)), (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        ]
        if let corner = corners.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= cornerReach }) {
            return corner.0
        }
        let reach = max(min(edgeReach, rect.width / 6, rect.height / 6), 3)
        let insideX = point.x > rect.minX && point.x < rect.maxX
        let insideY = point.y > rect.minY && point.y < rect.maxY
        if insideX, abs(point.y - rect.minY) <= reach { return .top }
        if insideX, abs(point.y - rect.maxY) <= reach { return .bottom }
        if insideY, abs(point.x - rect.minX) <= reach { return .left }
        if insideY, abs(point.x - rect.maxX) <= reach { return .right }
        return nil
    }

    /// `rect` with the side or corner `handle` dragged to `point` (flipped points, as the overlay's views use).
    static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    static func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .topLeft: NSCursor.frameResize(position: .topLeft, directions: .all)
        case .top: NSCursor.frameResize(position: .top, directions: .all)
        case .topRight: NSCursor.frameResize(position: .topRight, directions: .all)
        case .right: NSCursor.frameResize(position: .right, directions: .all)
        case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .bottom: NSCursor.frameResize(position: .bottom, directions: .all)
        case .bottomLeft: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        case .left: NSCursor.frameResize(position: .left, directions: .all)
        }
    }

    /// Edges on the display's pixels, as the overlay's selection keeps them.
    static func snapped(_ rect: CGRect, pixelsPerPoint scale: CGFloat) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX), maxX = snap(rect.maxX), minY = snap(rect.minY), maxY = snap(rect.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where a bar of `size` goes for `frame` in `bounds` (flipped points): under the frame, centered on it;
    /// above it when there is no room below; inside its bottom edge when neither has room (a whole display, a
    /// window filling the screen). Always on the display.
    static func barFrame(size: CGSize, for frame: CGRect, in bounds: CGRect) -> CGRect {
        let drawn = SelectionChromeView.drawnFrame(for: frame, in: bounds)
        let room = bounds.insetBy(dx: 8, dy: 8)
        let below = CGRect(x: drawn.midX - size.width / 2, y: drawn.maxY + 12, width: size.width, height: size.height)
        let above = CGRect(x: below.minX, y: drawn.minY - 12 - size.height, width: size.width, height: size.height)
        let inside = CGRect(x: below.minX, y: drawn.maxY - 40 - size.height, width: size.width, height: size.height)
        var placed = [below, above].first { room.contains($0) } ?? inside
        placed.origin.x = min(max(placed.minX, room.minX), room.maxX - size.width)
        placed.origin.y = min(max(placed.minY, room.minY), room.maxY - size.height)
        return placed.integral
    }

    /// Global points (y up) to the overlay's points from `display`'s top-left corner (y down), and back.
    static func local(_ rect: CGRect, on display: DisplayInfo) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func global(_ rect: CGRect, on display: DisplayInfo) -> CGRect {
        CGRect(x: display.frame.minX + rect.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
