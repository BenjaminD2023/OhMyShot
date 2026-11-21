import CoreGraphics
import Foundation

/// Where a pin goes and how it grows and fades: the arithmetic, apart from the windows.
enum PinGeometry {
    static let zoomRange: ClosedRange<CGFloat> = 0.1...8
    static let opacityRange: ClosedRange<CGFloat> = 0.2...1
    /// The opacities the pin's menu offers.
    static let opacitySteps: [CGFloat] = [1, 0.8, 0.6, 0.4, 0.2]

    /// Where a pin of `size` points first appears, and at what zoom. Over `requested` (the screen area a
    /// capture came from) at 1:1, so nothing seems to move until it is dragged; centered on it when the
    /// picture is larger (a window's shadow). Without one, centered in `visible`, scaled down to fit
    /// 80 percent of it when larger.
    static func initialFrame(size: CGSize, requested: CGRect?, visible: CGRect) -> (frame: CGRect, zoom: CGFloat) {
        if let requested {
            if abs(size.width - requested.width) < 1, abs(size.height - requested.height) < 1 {
                return (requested, 1)
            }
            return (CGRect(x: requested.midX - size.width / 2, y: requested.midY - size.height / 2, width: size.width, height: size.height), 1)
        }
        let fit = min(1, 0.8 * visible.width / max(size.width, 1), 0.8 * visible.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * fit, height: size.height * fit)
        return (CGRect(x: visible.midX - fitted.width / 2, y: visible.midY - fitted.height / 2, width: fitted.width, height: fitted.height), fit)
    }

    /// The zoom a pin brought back after a relaunch opens at: the one it had, which is below `zoomRange` when a long
    /// picture was scaled down to fit its display as it opened, up to the largest; 100 percent when it has none.
    static func keptZoom(_ zoom: CGFloat) -> CGFloat {
        zoom > 0 ? min(zoom, zoomRange.upperBound) : 1
    }

    /// The zooms a pin at `zoom` can go to: `zoomRange`, reaching down to its own zoom when it was fitted below it as it
    /// opened, so zooming out never makes it larger.
    static func zoomRange(from zoom: CGFloat) -> ClosedRange<CGFloat> {
        min(zoomRange.lowerBound, zoom) ... zoomRange.upperBound
    }

    /// Where a pin at `frame` goes when the displays change, or when it comes back after a relaunch: nil while enough of
    /// it to take hold of (`grip` points each way, or all of it when it is smaller) is on one of `screens` (frames and
    /// visible frames, global points), in its visible frame: under the menu bar or the Dock it can't be taken. Else onto the screen nearest its center, inside that screen's visible frame, at the
    /// same size: as near as it fits to where it was, and its top left corner first when it is larger.
    static func recovered(_ frame: CGRect, on screens: [(frame: CGRect, visible: CGRect)], grip: CGFloat = 20) -> CGRect? {
        let needed = CGSize(width: min(grip, frame.width), height: min(grip, frame.height))
        let shown = screens.contains { screen in
            let part = screen.visible.intersection(frame)
            return !part.isNull && part.width >= needed.width && part.height >= needed.height
        }
        guard !shown else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        func distance(to rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - center.x, 0, center.x - rect.maxX), max(rect.minY - center.y, 0, center.y - rect.maxY))
        }
        guard let visible = screens.min(by: { distance(to: $0.frame) < distance(to: $1.frame) })?.visible else { return nil }
        let x = frame.width > visible.width ? visible.minX : min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        let y = frame.height > visible.height ? visible.maxY - frame.height : min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    /// `frame` at `size`, keeping `anchor` (a point in the same space: the pointer, or the pin's center)
    /// where it is in it. The size comes from the pin's own size and zoom, never from `frame`: the window
    /// server rounds a window's frame to whole points, and sizes scaled from rounded frames drift apart step
    /// by step, until a pin zoomed in and out no longer has its picture's shape.
    static func zoomed(_ frame: CGRect, to size: CGSize, around anchor: CGPoint) -> CGRect {
        let fx = frame.width > 0 ? (anchor.x - frame.minX) / frame.width : 0.5
        let fy = frame.height > 0 ? (anchor.y - frame.minY) / frame.height : 0.5
        return CGRect(x: anchor.x - fx * size.width, y: anchor.y - fy * size.height, width: size.width, height: size.height)
    }

    /// The zoom after scrolling up (positive) or down by `delta`: points from a trackpad, lines from a
    /// wheel, about 10 percent a line.
    static func zoom(_ zoom: CGFloat, scrolledBy delta: CGFloat, precise: Bool) -> CGFloat {
        clamp(zoom * exp(delta * (precise ? 0.005 : 0.1)), to: zoomRange(from: zoom))
    }

    /// The opacity after scrolling up (more opaque) or down by `delta`: 5 percent a wheel line.
    static func opacity(_ opacity: CGFloat, scrolledBy delta: CGFloat, precise: Bool) -> CGFloat {
        clamp(opacity + delta * (precise ? 0.005 : 0.05), to: opacityRange)
    }

    /// Where Close and More stand on a pin of `size` points, in its own coordinates (origin at the bottom
    /// left): `button` points square, 8 pt in from the top corners, or centered in the height on a pin too
    /// short to leave 8 pt above them, so a one-line text card has them too. Each is nil where it does not
    /// fit: Close needs 8 pt beside it and 6 pt above and below, More 8 pt between it and Close.
    /// `trailing` is More's place whether or not it fits, for a locked pin's mark.
    static func cornerButtons(in size: CGSize, button: CGFloat) -> (close: CGRect?, more: CGRect?, trailing: CGRect) {
        let inset: CGFloat = 8
        let top = min(inset, (size.height - button) / 2)
        let y = size.height - top - button
        let trailing = CGRect(x: size.width - inset - button, y: y, width: button, height: button)
        guard size.width >= button + 2 * inset, size.height >= button + 12 else { return (nil, nil, trailing) }
        let close = CGRect(x: inset, y: y, width: button, height: button)
        return (close, size.width >= 2 * button + 3 * inset ? trailing : nil, trailing)
    }

    static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    enum Corner: CaseIterable, Equatable, Sendable {
        case bottomLeft, bottomRight, topLeft, topRight
    }

    /// Which corner of a pin of `size` points `point` (origin at the bottom left) falls within `reach` of.
    static func resizeCorner(at point: CGPoint, in size: CGSize, reach: CGFloat = 10) -> Corner? {
        guard size.width >= reach * 2, size.height >= reach * 2,
              CGRect(origin: .zero, size: size).contains(point) else { return nil }
        let left = point.x <= reach
        let right = point.x >= size.width - reach
        let bottom = point.y <= reach
        let top = point.y >= size.height - reach
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        if left && top { return .topLeft }
        if right && top { return .topRight }
        return nil
    }

    /// The corner opposite `corner` in `frame` (origin at the bottom left), which stays fixed while `corner` drags.
    static func oppositeCorner(of corner: Corner, in frame: CGRect) -> CGPoint {
        switch corner {
        case .bottomLeft: CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomRight: CGPoint(x: frame.minX, y: frame.maxY)
        case .topLeft: CGPoint(x: frame.maxX, y: frame.minY)
        case .topRight: CGPoint(x: frame.minX, y: frame.minY)
        }
    }

    /// The new zoom and fixed anchor when `corner` of `frame` is dragged to `point` (in the same space),
    /// keeping the pin's proportions (`baseSize`), never below `zoomRange(from: zoom)` for the pin's `zoom` now (its own,
    /// not its frame's: the window server rounds a frame to whole points).
    static func resizedZoom(
        dragging corner: Corner, of frame: CGRect, baseSize: CGSize, zoom: CGFloat = 1, to point: CGPoint
    ) -> (zoom: CGFloat, anchor: CGPoint) {
        let anchor = oppositeCorner(of: corner, in: frame)
        let dx = abs(point.x - anchor.x)
        let dy = abs(point.y - anchor.y)
        let scale = max(dx / max(baseSize.width, 1), dy / max(baseSize.height, 1))
        return (clamp(scale, to: zoomRange(from: zoom)), anchor)
    }
}
