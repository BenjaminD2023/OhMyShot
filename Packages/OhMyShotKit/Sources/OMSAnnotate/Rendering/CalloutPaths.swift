import CoreGraphics
import Foundation

/// The outlines of marks that point at something: a speech bubble's plate and tail, a counter's disc and pointer.
/// Each is one outline, the tail joined to what it comes out of, so both fill at once under one shadow, and the
/// pointer reads as part of the mark rather than laid against it.
///
/// A tail is a wedge from the middle of its plate or disc, square to its direction and narrowing to the tip; the part
/// of it inside the plate is hidden in the plate, so it leaves the edge as wide as the plate allows in any direction.
nonisolated enum CalloutPaths {
    /// A bubble's tip when it has none of its own: under its plate and toward its left, about a line below.
    static func defaultTip(for frame: CGRect, lineHeight: CGFloat) -> CGPoint {
        CGPoint(x: frame.minX + min(frame.width * 0.25, lineHeight * 1.5), y: frame.maxY + lineHeight * 0.9)
    }

    /// A wedge from `base`, `width` across square to its direction, narrowing to `tip`; nil when the two meet.
    static func wedge(from base: CGPoint, to tip: CGPoint, width: CGFloat) -> CGPath? {
        let dx = tip.x - base.x, dy = tip.y - base.y
        let length = hypot(dx, dy)
        guard length > 0.5, width > 0 else { return nil }
        let nx = -dy / length * width / 2, ny = dx / length * width / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: base.x + nx, y: base.y + ny))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: base.x - nx, y: base.y - ny))
        path.closeSubpath()
        return path
    }

    /// A bubble's outline: its rounded plate in `frame` and a tail to `tip`, unless the tip lies on the plate.
    static func bubble(frame: CGRect, cornerRadius: CGFloat, tip: CGPoint) -> CGPath {
        let plate = CGPath(roundedRect: frame, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        // Narrower than the plate's height and half its width, so the base never shows past the plate's sides.
        let width = min(frame.height * 0.9, frame.width * 0.5)
        guard !plate.contains(tip), let tail = wedge(from: CGPoint(x: frame.midX, y: frame.midY), to: tip, width: width) else { return plate }
        return plate.union(tail)
    }

    /// A counter's outline: its disc, and a pointer to `tip` when it has one outside the disc.
    static func counter(center: CGPoint, diameter: CGFloat, tip: CGPoint?) -> CGPath {
        let disc = CGPath(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter), transform: nil)
        guard let tip, hypot(tip.x - center.x, tip.y - center.y) > diameter / 2,
              let pointer = wedge(from: center, to: tip, width: diameter * 0.6) else { return disc }
        return disc.union(pointer)
    }

    /// Where a counter's pointer handle rests while it has none: on the disc's edge, down and to the left.
    static func restingTip(center: CGPoint, diameter: CGFloat) -> CGPoint {
        let reach = diameter / 2 * 0.7071
        return CGPoint(x: center.x - reach, y: center.y + reach)
    }
}
