import CoreGraphics
import Foundation

/// A laser pointer's trail, which fades as it is drawn: each point keeps the time it was put down, and its width
/// narrows with age, so the newest end is full and the tail tapers to nothing within `life`. The whole trail is one
/// outline filled at once, so where it crosses itself it does not grow darker.
///
/// After SnowAir's `LaserStroke` (Apache-2.0, credited in Acknowledgments): the same life, the same easing of the
/// width (1 − age²), the same following of the pointer and thinning of the points drawn, written again here.
nonisolated public struct LaserTrail: Sendable {
    /// How long a point takes to go from full width to nothing.
    public static let life: TimeInterval = 0.6
    /// A memory bound only: the trail's length comes from `life`.
    static let mostPoints = 512
    /// At most this many points are drawn in a frame; more are thinned evenly.
    static let mostDrawn = 160
    /// How far a new point goes toward the pointer from the last one: a little behind, so the trail is smooth.
    static let follow: CGFloat = 0.6

    struct Point: Sendable {
        var location: CGPoint
        var time: TimeInterval
    }

    private(set) var points: [Point] = []
    /// The trail's width at its newest end, in the units it is drawn in.
    public var width: CGFloat
    private var last: CGPoint?

    public init(width: CGFloat) {
        self.width = width
    }

    /// Adds where the pointer is at `time`: points past their life go, a repeat of the last place adds nothing (a
    /// pointer held still lets the trail fade), and the new point follows the pointer part of the way.
    public mutating func add(_ location: CGPoint, at time: TimeInterval) {
        while points.count > 1, time - points[1].time >= Self.life { points.removeFirst() }
        if let newest = points.last, time - newest.time >= Self.life { points.removeAll() }
        guard location != last else { return }
        last = location
        var point = Point(location: location, time: time)
        if let previous = points.last {
            point.location = CGPoint(
                x: previous.location.x + (location.x - previous.location.x) * Self.follow,
                y: previous.location.y + (location.y - previous.location.y) * Self.follow
            )
        }
        if points.count >= Self.mostPoints { points.removeFirst() }
        points.append(point)
    }

    /// Whether the trail is over by `time`: its newest point has lived out its life, or it never had one.
    public func isDone(at time: TimeInterval) -> Bool {
        points.last.map { time - $0.time >= Self.life } ?? true
    }

    /// Whether anything of the trail still shows at `time`.
    public func isVisible(at time: TimeInterval) -> Bool {
        guard points.count >= 2, let newest = points.last else { return false }
        return time - newest.time < Self.life
    }

    /// The radius of a point at `time`: full while new, narrowing as 1 − (age / life)², nothing at the end of its life.
    func radius(of point: Point, at time: TimeInterval) -> CGFloat {
        let age = min(max(time - point.time, 0), Self.life) / Self.life
        return max(width, 1) / 2 * (1 - CGFloat(age * age))
    }

    /// The trail's outline at `time`: both sides along the points' normals, a round cap at each end, every corner
    /// smoothed through the middles of its neighbors. Nil once it has faded.
    public func outline(at time: TimeInterval) -> CGPath? {
        guard isVisible(at: time) else { return nil }
        var live = points.filter { radius(of: $0, at: time) > 0.2 }
        guard live.count >= 2 else { return nil }
        if live.count > Self.mostDrawn {
            let stride = Double(live.count - 1) / Double(Self.mostDrawn - 1)
            live = (0..<Self.mostDrawn).map { live[Int((Double($0) * stride).rounded())] }
        }
        let vertices = live.map { (location: $0.location, radius: max(0.01, radius(of: $0, at: time))) }
        let count = vertices.count
        func direction(_ from: CGPoint, _ to: CGPoint) -> CGVector {
            let dx = to.x - from.x, dy = to.y - from.y
            let length = hypot(dx, dy)
            return length < 0.0001 ? CGVector(dx: 1, dy: 0) : CGVector(dx: dx / length, dy: dy / length)
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in 0..<count {
            let along = direction(vertices[max(0, index - 1)].location, vertices[min(count - 1, index + 1)].location)
            let normal = CGVector(dx: -along.dy, dy: along.dx)
            let p = vertices[index]
            left.append(CGPoint(x: p.location.x - normal.dx * p.radius, y: p.location.y - normal.dy * p.radius))
            right.append(CGPoint(x: p.location.x + normal.dx * p.radius, y: p.location.y + normal.dy * p.radius))
        }
        let segments = 8
        func cap(at vertex: (location: CGPoint, radius: CGFloat), heading: CGVector, from side: CGFloat) -> [CGPoint] {
            let normal = CGVector(dx: -heading.dy, dy: heading.dx)
            return (1..<segments).map { step in
                let angle = CGFloat.pi * CGFloat(step) / CGFloat(segments)
                let c = cos(angle), s = sin(angle)
                return CGPoint(
                    x: vertex.location.x + (side * -normal.dx * c + heading.dx * s) * vertex.radius,
                    y: vertex.location.y + (side * -normal.dy * c + heading.dy * s) * vertex.radius
                )
            }
        }
        var outline = left
        outline += cap(at: vertices[count - 1], heading: direction(vertices[count - 2].location, vertices[count - 1].location), from: 1)
        outline += right.reversed()
        outline += cap(at: vertices[0], heading: direction(vertices[1].location, vertices[0].location), from: 1)
        // The outline's points as control points, the middles between them as the curve's points: smooth all round.
        let path = CGMutablePath()
        func middle(_ a: Int, _ b: Int) -> CGPoint {
            let p = outline[a % outline.count], q = outline[b % outline.count]
            return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        }
        path.move(to: middle(outline.count - 1, 0))
        for index in outline.indices { path.addQuadCurve(to: middle(index, index + 1), control: outline[index]) }
        path.closeSubpath()
        return path
    }
}
