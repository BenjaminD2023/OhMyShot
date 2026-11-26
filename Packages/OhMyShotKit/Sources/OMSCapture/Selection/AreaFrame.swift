import AppKit
import OMSCore
import OMSDesign

/// The frame around an area chosen on the overlay while it is set up for what comes next (a recording, a
/// scrolling capture): its handles, how a drag on one resizes it, the cursors over them, where the bar under
/// it goes, and the overlay's points from the display's top-left corner against global ones.
enum AreaFrame {
    enum Handle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// What a drag on the frame does, from where it began (flipped points): moves the frame as it was, resizes it by a
    /// handle, or, begun outside it, chooses a new area. A resize keeps `grip`, how far the handle lay from the press
    /// (`grip(of:on:pressedAt:)`), so the edge moves with the pointer instead of jumping to it.
    enum Adjustment {
        case moving(start: CGPoint, original: CGRect)
        case resizing(Handle, original: CGRect, grip: CGVector = .zero)
        case selecting(start: CGPoint)
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

    /// How far `handle` of `rect` lies from a press at `point`, along the axes the handle moves: a side's
    /// distance across it, a corner's both ways. Added to the pointer while it drags, it keeps the edge where it was
    /// taken hold of.
    static func grip(of handle: Handle, on rect: CGRect, pressedAt point: CGPoint) -> CGVector {
        let x: CGFloat? = switch handle {
        case .topLeft, .left, .bottomLeft: rect.minX
        case .topRight, .right, .bottomRight: rect.maxX
        case .top, .bottom: nil
        }
        let y: CGFloat? = switch handle {
        case .topLeft, .top, .topRight: rect.minY
        case .bottomLeft, .bottom, .bottomRight: rect.maxY
        case .left, .right: nil
        }
        return CGVector(dx: x.map { $0 - point.x } ?? 0, dy: y.map { $0 - point.y } ?? 0)
    }

    /// Where the edges under `handle` of `rect` meet, nudged half of `pixel` inside it (flipped points): the middle of
    /// the pixel just inside the dragged corner, or, for a side, of the one across from `pointer`. The magnifier
    /// centers there while the edge is dragged. The dragged edge is the side nearer the pointer, which stays with
    /// it even once it has been dragged past the opposite one.
    static func edgePoint(of handle: Handle, on rect: CGRect, near pointer: CGPoint, pixel: CGFloat) -> CGPoint {
        let half = pixel / 2
        func along(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value, low + half), max(low + half, high - half))
        }
        func nearer(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            abs(value - low) <= abs(value - high) ? low + half : high - half
        }
        let movesX = handle != .top && handle != .bottom
        let movesY = handle != .left && handle != .right
        return CGPoint(
            x: movesX ? nearer(pointer.x, rect.minX, rect.maxX) : along(pointer.x, rect.minX, rect.maxX),
            y: movesY ? nearer(pointer.y, rect.minY, rect.maxY) : along(pointer.y, rect.minY, rect.maxY)
        )
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

    /// `rect` with `handle` dragged to `point` (flipped points) keeping `ratio` (width over height): a corner grows the
    /// area from the opposite corner, on whichever side the pointer reaches further; an edge resizes its side and the
    /// other side follows, centered where it was.
    static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint, keeping ratio: CGFloat) -> CGRect {
        let free = resized(rect, dragging: handle, to: point)
        guard ratio > 0 else { return free }
        switch handle {
        case .left, .right:
            let height = free.width / ratio
            return CGRect(x: free.minX, y: rect.midY - height / 2, width: free.width, height: height)
        case .top, .bottom:
            let width = free.height * ratio
            return CGRect(x: rect.midX - width / 2, y: free.minY, width: width, height: free.height)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            var width = free.width, height = free.height
            if width / max(height, 0.001) > ratio { height = width / ratio } else { width = height * ratio }
            // The corner opposite the one dragged stays put, on whichever side of it the pointer went.
            let anchor = CGPoint(
                x: handle == .topLeft || handle == .bottomLeft ? rect.maxX : rect.minX,
                y: handle == .topLeft || handle == .topRight ? rect.maxY : rect.minY
            )
            let x = point.x < anchor.x ? anchor.x - width : anchor.x
            let y = point.y < anchor.y ? anchor.y - height : anchor.y
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// `rect` with `handle` dragged to `point` (flipped points) keeping `ratio` (width over height) inside `bounds`:
    /// smoothly clamps to the largest rectangle inside `bounds` that preserves `ratio` instead of distorting or
    /// freezing when one axis hits a display edge.
    static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint, in bounds: CGRect, keeping ratio: CGFloat) -> CGRect {
        let free = resized(rect, dragging: handle, to: point)
        guard ratio > 0 else { return free }
        switch handle {
        case .left, .right:
            let anchorX = handle == .left ? rect.maxX : rect.minX
            let goesLeft = point.x < anchorX
            let maxWidth = max(0, goesLeft ? anchorX - bounds.minX : bounds.maxX - anchorX)
            let limitWidth = min(maxWidth, bounds.height * ratio)
            let width = min(free.width, limitWidth)
            let height = min(width / ratio, bounds.height)
            let finalWidth = min(height * ratio, maxWidth)
            let x = goesLeft ? (finalWidth >= maxWidth ? bounds.minX : anchorX - finalWidth) : anchorX
            let y = min(max(rect.midY - height / 2, bounds.minY), bounds.maxY - height)
            return CGRect(x: x, y: y, width: finalWidth, height: height)
        case .top, .bottom:
            let anchorY = handle == .top ? rect.maxY : rect.minY
            let goesUp = point.y < anchorY
            let maxHeight = max(0, goesUp ? anchorY - bounds.minY : bounds.maxY - anchorY)
            let limitHeight = min(maxHeight, bounds.width / ratio)
            let height = min(free.height, limitHeight)
            let width = min(height * ratio, bounds.width)
            let finalHeight = min(width / ratio, maxHeight)
            let x = min(max(rect.midX - width / 2, bounds.minX), bounds.maxX - width)
            let y = goesUp ? (finalHeight >= maxHeight ? bounds.minY : anchorY - finalHeight) : anchorY
            return CGRect(x: x, y: y, width: width, height: finalHeight)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            let anchor = CGPoint(
                x: handle == .topLeft || handle == .bottomLeft ? rect.maxX : rect.minX,
                y: handle == .topLeft || handle == .topRight ? rect.maxY : rect.minY
            )
            let goesLeft = point.x < anchor.x
            let goesUp = point.y < anchor.y
            let maxWidth = max(0, goesLeft ? anchor.x - bounds.minX : bounds.maxX - anchor.x)
            let maxHeight = max(0, goesUp ? anchor.y - bounds.minY : bounds.maxY - anchor.y)
            var width = free.width, height = free.height
            if width / max(height, 0.001) > ratio { height = width / ratio } else { width = height * ratio }
            let limitWidth = min(maxWidth, maxHeight * ratio)
            if width > limitWidth {
                width = limitWidth
                height = min(width / ratio, maxHeight)
                width = min(height * ratio, maxWidth)
            }
            let x = goesLeft ? (width >= maxWidth ? bounds.minX : anchor.x - width) : anchor.x
            let y = goesUp ? (height >= maxHeight ? bounds.minY : anchor.y - height) : anchor.y
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// The area `adjustment` makes with the pointer at `point` (flipped points) in `bounds`, keeping `ratio` (width over
    /// height) when one is kept: moved, kept inside the bounds whole; resized, or a new area, with the pointer held to
    /// the bounds. Cut to the bounds it may still have to be (`fitted`).
    static func adjusted(_ adjustment: Adjustment, to point: CGPoint, in bounds: CGRect, keeping ratio: CGFloat? = nil) -> CGRect {
        func clampedToBounds(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        }
        let clamped = clampedToBounds(point)
        switch adjustment {
        case .moving(let start, let original):
            return placed(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y), in: bounds)
        case .resizing(let handle, let original, let grip):
            // The edge where the pointer took hold of it, then held to the bounds.
            let clamped = clampedToBounds(CGPoint(x: point.x + grip.dx, y: point.y + grip.dy))
            return if let ratio {
                resized(original, dragging: handle, to: clamped, in: bounds, keeping: ratio)
            } else {
                resized(original, dragging: handle, to: clamped)
            }
        case .selecting(let start):
            let anchor = clampedToBounds(start)
            return if let ratio {
                resized(CGRect(origin: anchor, size: .zero), dragging: .bottomRight, to: clamped, in: bounds, keeping: ratio)
            } else {
                CGRect(x: min(start.x, clamped.x), y: min(start.y, clamped.y), width: abs(clamped.x - start.x), height: abs(clamped.y - start.y))
            }
        }
    }

    /// `rect` cut to `bounds`, in whatever space both are; nil when what is left is smaller than the smallest area.
    static func fitted(_ rect: CGRect, in bounds: CGRect) -> CGRect? {
        let kept = rect.intersection(bounds)
        guard !kept.isNull, kept.width >= smallest, kept.height >= smallest else { return nil }
        return kept
    }

    /// `rect` reshaped to `ratio` around its center, as large as it was across its longer side would allow while
    /// staying inside `bounds`.
    static func shaped(_ rect: CGRect, to ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0 else { return rect }
        var width = rect.width, height = rect.width / ratio
        if height < rect.height { height = rect.height; width = height * ratio }
        // Never past the bounds: shrink, keeping the shape.
        let fit = min(1, bounds.width / width, bounds.height / height)
        width *= fit
        height *= fit
        return placed(CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height), in: bounds)
    }

    /// The least area that holds `content` (flipped points): at least the smallest area each way and, when `ratio` (width
    /// over height) is kept, in that shape, centered on the content and moved inside `bounds`. An area of that shape that
    /// held the content already fits, so the content stays inside.
    static func holding(_ content: CGRect, keeping ratio: CGFloat? = nil, in bounds: CGRect) -> CGRect {
        var width = max(content.width, smallest), height = max(content.height, smallest)
        if let ratio, ratio > 0 {
            if width / height > ratio { height = width / ratio } else { width = height * ratio }
        }
        return placed(CGRect(x: content.midX - width / 2, y: content.midY - height / 2, width: width, height: height), in: bounds)
    }

    /// `rect` at `size` (points) from its top-left corner (flipped points), moved back inside `bounds` where it would
    /// reach past them and no larger than they are.
    static func sized(_ rect: CGRect, to size: CGSize, in bounds: CGRect) -> CGRect {
        let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
        return placed(CGRect(x: rect.minX, y: rect.minY, width: width, height: height), in: bounds)
    }

    /// `area` (global points) as the size and shape control first frames it on `display`: reshaped to `ratio` around its
    /// middle when one is kept, inside the display, on its pixels.
    static func framed(_ area: CGRect, on display: DisplayInfo, keeping ratio: AspectRatio?) -> CGRect {
        let bounds = CGRect(origin: .zero, size: display.frame.size)
        let flipped = local(area, on: display).intersection(bounds)
        guard !flipped.isNull else { return area }
        let reshaped = ratio.map { shaped(flipped, to: $0.value, in: bounds) } ?? flipped
        return global(snapped(reshaped, pixelsPerPoint: display.pixelsPerPoint), on: display)
    }

    /// The area a size is typed for when none was dragged: a third of the display across, centered on `point` (global
    /// points), in the shape kept, moved back inside the display.
    static func starting(around point: CGPoint, on display: DisplayInfo, keeping ratio: AspectRatio?) -> CGRect {
        let bounds = CGRect(origin: .zero, size: display.frame.size)
        let middle = local(CGRect(origin: point, size: .zero), on: display).origin
        let size = CGSize(width: (bounds.width / 3).rounded(), height: (bounds.height / 3).rounded())
        let third = placed(CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2, width: size.width, height: size.height), in: bounds)
        return framed(global(third, on: display), on: display, keeping: ratio)
    }

    /// `rect` moved inside `bounds`, its size kept (it must fit).
    static func placed(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
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

    /// An area's size in pixels, as it will be captured: "1280 × 720".
    static func pixelReading(_ size: CGSize, pixelsPerPoint scale: CGFloat) -> String {
        "\(Int((size.width * scale).rounded())) × \(Int((size.height * scale).rounded()))"
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

    /// Global points (y up) to the overlay's points from `display`'s top-left corner (y down), and back. ScreenCaptureKit
    /// measures a part of a display the same way, so what it is asked to capture is this too.
    static func local(_ rect: CGRect, on display: DisplayInfo) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func global(_ rect: CGRect, on display: DisplayInfo) -> CGRect {
        CGRect(x: display.frame.minX + rect.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
