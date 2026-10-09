import CoreGraphics
import Foundation

/// The outlines of the vector marks, in pixels. Every arrow, line, shape, and stroke is drawn as one
/// filled path, so a translucent color never doubles where parts overlap, and hit testing tests the
/// same path that is drawn.
nonisolated enum MarkPaths {
    /// The filled outline of a vector mark; nil for text, counters, redactions, spots, and images, which
    /// are laid out rather than outlined.
    static func outline(of item: Annotation, scale: CGFloat) -> CGPath? {
        let width = max(item.style.lineWidth * scale, 0.5)
        switch item.shape {
        case .arrow(let arrow):
            return ArrowPath.outline(arrow, width: width, scale: scale)
        case .line(let line):
            let path = CGMutablePath()
            path.move(to: line.start)
            path.addLine(to: line.end)
            let dashed = line.dashed ? path.copy(dashingWithPhase: 0, lengths: [width * 1.5, width * 2.5]) : path
            return dashed.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        case .rectangle(let box):
            let rect = box.rect.standardized
            let radius = min(box.cornerRadius * scale, rect.width / 2, rect.height / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: max(radius, 0), cornerHeight: max(radius, 0), transform: nil)
            if box.filled { return path }
            return path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: radius > 0 ? .round : .miter, miterLimit: 10)
        case .ellipse(let box):
            let path = CGPath(ellipseIn: box.rect.standardized, transform: nil)
            if box.filled { return path }
            return path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        case .pen(let stroke), .highlighter(let stroke):
            guard let first = stroke.points.first else { return nil }
            if stroke.points.count == 1 || stroke.points.allSatisfy({ hypot($0.x - first.x, $0.y - first.y) < 0.5 }) {
                return CGPath(ellipseIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width), transform: nil)
            }
            return smoothPath(through: stroke.points).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        case .textHighlight(let highlight):
            // One path, filled once: where the bands of two lines meet, the color does not double.
            let path = CGMutablePath()
            for rect in highlight.rects.map(\.standardized) where rect.width > 0 && rect.height > 0 {
                let radius = min(rect.height * 0.2, rect.width / 2)
                path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            }
            return path.isEmpty ? nil : path
        case .text, .counter, .redaction, .spotlight, .image:
            return nil
        }
    }

    /// A smooth curve through `points` (Catmull-Rom, as cubic Béziers), so a freehand stroke drawn from
    /// sampled mouse positions has no corners at the samples.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

/// Arrows: a body along a straight or bent path, and one or two heads.
nonisolated enum ArrowPath {
    /// How long a head is for a stroke `width` pixels wide.
    static func headLength(width: CGFloat, scale: CGFloat) -> CGFloat {
        width * 3 + 4 * scale
    }

    /// The control point of the quadratic curve whose middle lies `bend` pixels off the straight line,
    /// toward the line's normal (its direction turned a quarter to the left in math coordinates).
    static func control(start: CGPoint, end: CGPoint, bend: CGFloat) -> CGPoint {
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let normal = self.normal(from: start, to: end)
        return CGPoint(x: middle.x + normal.dx * bend * 2, y: middle.y + normal.dy * bend * 2)
    }

    /// The unit normal of the line from `start` to `end`.
    static func normal(from start: CGPoint, to end: CGPoint) -> CGVector {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), .ulpOfOne)
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    /// The point on the arrow's curve halfway along it, where its bend handle sits.
    static func middle(of arrow: Arrow) -> CGPoint {
        point(at: 0.5, start: arrow.start, control: control(start: arrow.start, end: arrow.end, bend: arrow.bend), end: arrow.end)
    }

    static func outline(_ arrow: Arrow, width: CGFloat, scale: CGFloat) -> CGPath? {
        let start = arrow.start
        let end = arrow.end
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length >= 1 else { return nil }
        let control = control(start: start, end: end, bend: arrow.bend)
        // Short arrows keep a head in proportion rather than all head.
        let head = min(headLength(width: width, scale: scale), length * (arrow.head == .double ? 0.4 : 0.6))

        switch arrow.head {
        case .classic, .double:
            let doubled = arrow.head == .double
            let tEnd = parameter(atDistance: head * 0.72, fromEndOf: start, control, end, reversed: false)
            let tStart = doubled ? parameter(atDistance: head * 0.72, fromEndOf: start, control, end, reversed: true) : 0
            let body = subcurve(start, control, end, from: tStart, to: tEnd)
                .copy(strokingWithWidth: width, lineCap: doubled ? .butt : .round, lineJoin: .round, miterLimit: 10)
            var shape = body.union(classicHead(tip: end, direction: tangent(at: 1, start, control, end), length: head))
            if doubled {
                let backward = tangent(at: 0, start, control, end)
                shape = shape.union(classicHead(tip: start, direction: CGVector(dx: -backward.dx, dy: -backward.dy), length: head))
            }
            return shape
        case .tapered:
            let tEnd = parameter(atDistance: head * 0.7, fromEndOf: start, control, end, reversed: false)
            let tailHalf = max(width * 0.16, 0.5 * scale)
            let headHalf = width * 0.62
            let body = taperedBody(start, control, end, to: tEnd, from: tailHalf, to: headHalf)
            let tail = CGPath(ellipseIn: CGRect(x: start.x - tailHalf, y: start.y - tailHalf, width: tailHalf * 2, height: tailHalf * 2), transform: nil)
            let tip = classicHead(tip: end, direction: tangent(at: 1, start, control, end), length: head, halfWidth: max(head * 0.62, headHalf * 1.8))
            return body.union(tail).union(tip)
        case .open:
            let direction = tangent(at: 1, start, control, end)
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let back = CGPoint(x: end.x - direction.dx * head * 0.85, y: end.y - direction.dy * head * 0.85)
            let chevron = CGMutablePath()
            chevron.move(to: CGPoint(x: back.x + normal.dx * head * 0.5, y: back.y + normal.dy * head * 0.5))
            chevron.addLine(to: end)
            chevron.addLine(to: CGPoint(x: back.x - normal.dx * head * 0.5, y: back.y - normal.dy * head * 0.5))
            let body = subcurve(start, control, end, from: 0, to: 1)
            return body.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .union(chevron.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
    }

    /// A filled head with a notched back, its tip at `tip`, pointing along `direction`.
    private static func classicHead(tip: CGPoint, direction: CGVector, length: CGFloat, halfWidth: CGFloat? = nil) -> CGPath {
        let half = halfWidth ?? length * 0.6
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let back = CGPoint(x: tip.x - direction.dx * length, y: tip.y - direction.dy * length)
        let notch = CGPoint(x: tip.x - direction.dx * length * 0.72, y: tip.y - direction.dy * length * 0.72)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: back.x + normal.dx * half, y: back.y + normal.dy * half))
        path.addLine(to: notch)
        path.addLine(to: CGPoint(x: back.x - normal.dx * half, y: back.y - normal.dy * half))
        path.closeSubpath()
        return path
    }

    /// A body that widens from `tailHalf` to `headHalf` (half widths, in pixels) along the curve up to `t1`.
    private static func taperedBody(_ p0: CGPoint, _ c: CGPoint, _ p2: CGPoint, to t1: CGFloat, from tailHalf: CGFloat, to headHalf: CGFloat) -> CGPath {
        let samples = 32
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for index in 0...samples {
            let fraction = CGFloat(index) / CGFloat(samples)
            let t = t1 * fraction
            let point = point(at: t, start: p0, control: c, end: p2)
            let direction = tangent(at: t, p0, c, p2)
            let half = tailHalf + (headHalf - tailHalf) * fraction
            left.append(CGPoint(x: point.x - direction.dy * half, y: point.y + direction.dx * half))
            right.append(CGPoint(x: point.x + direction.dy * half, y: point.y - direction.dx * half))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }

    static func point(at t: CGFloat, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    /// The unit direction of travel at `t`.
    static func tangent(at t: CGFloat, _ p0: CGPoint, _ c: CGPoint, _ p2: CGPoint) -> CGVector {
        var dx = 2 * (1 - t) * (c.x - p0.x) + 2 * t * (p2.x - c.x)
        var dy = 2 * (1 - t) * (c.y - p0.y) + 2 * t * (p2.y - c.y)
        if hypot(dx, dy) < .ulpOfOne {
            dx = p2.x - p0.x
            dy = p2.y - p0.y
        }
        let length = max(hypot(dx, dy), .ulpOfOne)
        return CGVector(dx: dx / length, dy: dy / length)
    }

    /// The curve between `t0` and `t1`, as its own quadratic.
    private static func subcurve(_ p0: CGPoint, _ c: CGPoint, _ p2: CGPoint, from t0: CGFloat, to t1: CGFloat) -> CGPath {
        let start = point(at: t0, start: p0, control: c, end: p2)
        let end = point(at: t1, start: p0, control: c, end: p2)
        // The new control point: the start plus half the span times the derivative there.
        let dx = 2 * (1 - t0) * (c.x - p0.x) + 2 * t0 * (p2.x - c.x)
        let dy = 2 * (1 - t0) * (c.y - p0.y) + 2 * t0 * (p2.y - c.y)
        let control = CGPoint(x: start.x + (t1 - t0) / 2 * dx, y: start.y + (t1 - t0) / 2 * dy)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// The parameter where the curve is `distance` pixels (in a straight line) from its end, or from its
    /// start when `reversed`.
    private static func parameter(atDistance distance: CGFloat, fromEndOf p0: CGPoint, _ c: CGPoint, _ p2: CGPoint, reversed: Bool) -> CGFloat {
        let anchor = reversed ? p0 : p2
        let steps = 64
        for index in 0...steps {
            let t = reversed ? CGFloat(index) / CGFloat(steps) : 1 - CGFloat(index) / CGFloat(steps)
            let point = point(at: t, start: p0, control: c, end: p2)
            if hypot(point.x - anchor.x, point.y - anchor.y) >= distance { return t }
        }
        return reversed ? 1 : 0
    }
}
