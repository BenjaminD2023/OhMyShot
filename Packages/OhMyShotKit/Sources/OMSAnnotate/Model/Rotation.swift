import CoreGraphics
import Foundation

/// Turning a mark about its middle. A turned mark is its upright twin (`upright`) drawn, hit, and reshaped in a frame
/// turned by `angle` about `pivot`: the shapes' own geometry never knows about turning.
///
/// After SnowAir's rotation handle (Apache-2.0): the same knob above the selection and 15° steps with Shift, written
/// again here.
nonisolated extension Annotation {
    /// Marks that can be turned: boxes, ellipses, text, and images. Arrows, lines, and strokes already point where their
    /// ends are; redactions, spotlights, and highlights cover the picture's own upright pixels.
    public var isRotatable: Bool {
        switch shape {
        case .rectangle, .ellipse, .text, .image: true
        default: false
        }
    }

    /// The turn that applies: `rotation` on a mark that turns, else none.
    public var angle: CGFloat {
        isRotatable ? (rotation ?? 0) : 0
    }

    /// Whether the mark is turned at all.
    var isTurned: Bool { abs(angle) > 1e-9 }

    /// The mark upright, as it is in its own frame: no rotation, and a bubble's tip (which is where it points on the
    /// picture) brought into that frame. The mark itself when it is not turned.
    func upright(scale: CGFloat) -> Annotation {
        guard isTurned else { return self }
        var copy = self
        copy.rotation = nil
        if case .text(var block) = copy.shape, let tail = block.tail {
            block.tail = Self.turn(tail, about: copy.bounds(scale: scale).middle, by: -angle)
            copy.shape = .text(block)
        }
        return copy
    }

    /// What the mark turns about: the middle of its upright frame, in pixels.
    func pivot(scale: CGFloat) -> CGPoint {
        var upright = self
        upright.rotation = nil
        return upright.bounds(scale: scale).middle
    }

    /// `upright` (a mark in its own frame) turned by `angle` about its middle again: the rotation set, a bubble's tip
    /// taken back onto the picture.
    static func turned(_ upright: Annotation, by angle: CGFloat, scale: CGFloat) -> Annotation {
        var copy = upright
        copy.rotation = abs(angle) > 1e-9 ? angle : nil
        guard copy.isTurned else { return copy }
        if case .text(var block) = copy.shape, let tail = block.tail {
            block.tail = turn(tail, about: upright.bounds(scale: scale).middle, by: angle)
            copy.shape = .text(block)
        }
        return copy
    }

    /// `point` turned by `angle` radians about `center`, clockwise on a picture whose y runs down.
    static func turn(_ point: CGPoint, about center: CGPoint, by angle: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle)
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }

    /// The box around `rect` turned by `angle` about `center`.
    static func box(around rect: CGRect, turnedBy angle: CGFloat, about center: CGPoint) -> CGRect {
        guard !rect.isNull else { return rect }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { turn($0, about: center, by: angle) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The mark turned to `angle` (radians) about its middle; upright at 0.
    public func rotated(to angle: CGFloat) -> Annotation {
        guard isRotatable else { return self }
        var copy = self
        copy.rotation = abs(angle) > 1e-9 ? Self.normalized(angle) : nil
        // A bubble's tip stays where it points.
        return copy
    }

    /// `angle` within a half turn either way.
    static func normalized(_ angle: CGFloat) -> CGFloat {
        var angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if angle > .pi { angle -= 2 * .pi }
        if angle <= -.pi { angle += 2 * .pi }
        return angle
    }

    /// The angle a rotation drag gives: Shift takes 15° steps; near a quarter turn it settles on it.
    static func snappedAngle(_ angle: CGFloat, constrained: Bool) -> CGFloat {
        let step: CGFloat = .pi / 12
        if constrained { return normalized((angle / step).rounded() * step) }
        let quarter: CGFloat = .pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        return normalized(abs(angle - nearest) < .pi / 90 ? nearest : angle)
    }
}

nonisolated extension Handle {
    /// The handle across the box from this one: what stays put while this one is dragged.
    var opposite: Handle {
        switch self {
        case .topLeft: .bottomRight
        case .top: .bottom
        case .topRight: .bottomLeft
        case .right: .left
        case .bottomRight: .topLeft
        case .bottom: .top
        case .bottomLeft: .topRight
        case .left: .right
        case .start: .end
        case .end: .start
        case .bend, .tail: self
        }
    }

    /// Where this handle sits on `rect`, for the box's eight; the middle for the others.
    func point(on rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .start, .end, .bend, .tail: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// The box handle pointing the way this one does once turned by `angle`: what its resize pointer shows.
    func turned(by angle: CGFloat) -> Handle {
        let ring: [Handle] = [.top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft]
        guard let index = ring.firstIndex(of: self) else { return self }
        let steps = Int((angle / (.pi / 4)).rounded())
        return ring[((index + steps) % 8 + 8) % 8]
    }
}

nonisolated extension CGRect {
    var middle: CGPoint { CGPoint(x: midX, y: midY) }
}
