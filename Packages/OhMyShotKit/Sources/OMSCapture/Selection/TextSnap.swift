import CoreGraphics

/// Snaps the edges of a selection being dragged over a frozen screen to the blocks of text on it, so a drag
/// around a paragraph lands on it with a little room all round. An edge within `reach` of a block's edge
/// moves to just outside it (`margin`): edges only ever enclose a block, never cut into its first or last
/// line, and never stand in the way of another block.
///
/// Coordinates are AppKit's global points, y up, as the selection's are; the blocks are found on the
/// screen's pixels and arrive here as rectangles in those points (see `block(fromPixels:in:pixelsPerPoint:)`).
nonisolated public struct TextSnap: Equatable, Sendable {
    /// How far an edge may be from a block's edge and still snap to it, in points.
    public static let reach: CGFloat = 8
    /// How far outside the block an edge lands, in points.
    public static let margin: CGFloat = 4

    /// The edges of a selection that snapped, for the overlay to mark.
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let left = Edges(rawValue: 1 << 0)
        public static let right = Edges(rawValue: 1 << 1)
        /// The edge with the greater y: the one at the top of the screen.
        public static let top = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)
    }

    /// The blocks of text, in global points.
    public let blocks: [CGRect]

    public init(blocks: [CGRect]) {
        self.blocks = blocks
    }

    /// A block found in a frame's pixels (origin at the top left) as a rectangle in the global points the
    /// frame covers.
    public static func block(fromPixels rect: CGRect, in frame: CGRect, pixelsPerPoint scale: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX / scale, y: frame.maxY - rect.maxY / scale,
            width: rect.width / scale, height: rect.height / scale
        )
    }

    /// `rect` with each edge that lies within `reach` of a block's edge moved to `margin` outside it, kept
    /// inside `bounds`, and which edges those were. A block counts for an edge only where the selection
    /// reaches it along the other axis, so a left edge does not snap to a block far above or below.
    public func snapped(_ rect: CGRect, within bounds: CGRect) -> (rect: CGRect, edges: Edges) {
        guard !blocks.isEmpty else { return (rect, []) }
        let horizontal = snappedSpan(rect.minX...rect.maxX, across: rect.minY...rect.maxY, bounds: bounds.minX...bounds.maxX) { block in
            (block.minX...block.maxX, block.minY...block.maxY)
        }
        let vertical = snappedSpan(rect.minY...rect.maxY, across: rect.minX...rect.maxX, bounds: bounds.minY...bounds.maxY) { block in
            (block.minY...block.maxY, block.minX...block.maxX)
        }
        var edges: Edges = []
        if horizontal.low != nil { edges.insert(.left) }
        if horizontal.high != nil { edges.insert(.right) }
        if vertical.low != nil { edges.insert(.bottom) }
        if vertical.high != nil { edges.insert(.top) }
        let snapped = CGRect(
            x: horizontal.low ?? rect.minX, y: vertical.low ?? rect.minY,
            width: (horizontal.high ?? rect.maxX) - (horizontal.low ?? rect.minX),
            height: (vertical.high ?? rect.maxY) - (vertical.low ?? rect.minY)
        )
        return (snapped, edges)
    }

    /// Where the two ends of `span` snap along one axis: nil where one stays. `extent` gives a block's span
    /// along the axis and across it.
    private func snappedSpan(
        _ span: ClosedRange<CGFloat>, across: ClosedRange<CGFloat>, bounds: ClosedRange<CGFloat>,
        extent: (CGRect) -> (along: ClosedRange<CGFloat>, across: ClosedRange<CGFloat>)
    ) -> (low: CGFloat?, high: CGFloat?) {
        // The blocks the selection reaches across, as they lie along this axis.
        let reached = blocks.map(extent).filter { $0.across.upperBound > across.lowerBound && $0.across.lowerBound < across.upperBound }.map(\.along)
        guard !reached.isEmpty else { return (nil, nil) }
        var low = nearest(to: span.lowerBound, among: reached, outward: .low, bounds: bounds)
        var high = nearest(to: span.upperBound, among: reached, outward: .high, bounds: bounds)
        // Never a selection turned inside out by its own snapping.
        if (high ?? span.upperBound) <= (low ?? span.lowerBound) {
            low = nil
            high = nil
        }
        return (low, high)
    }

    private enum Side { case low, high }

    /// The place `margin` outside the edge of a block, on `outward`'s side, nearest to `value` and within
    /// `reach` of that edge; nil when there is none. It never lies inside another block, nor farther from
    /// a neighbor on that side than halfway to it, so two blocks set close together are each enclosed
    /// without one's margin running over the other.
    private func nearest(to value: CGFloat, among reached: [ClosedRange<CGFloat>], outward side: Side, bounds: ClosedRange<CGFloat>) -> CGFloat? {
        var best: CGFloat?
        for block in reached {
            let edge = side == .low ? block.lowerBound : block.upperBound
            guard abs(value - edge) <= Self.reach else { continue }
            var place = side == .low ? edge - Self.margin : edge + Self.margin
            for other in reached where other != block {
                if side == .low, other.upperBound <= block.lowerBound { place = max(place, (other.upperBound + block.lowerBound) / 2) }
                if side == .high, other.lowerBound >= block.upperBound { place = min(place, (block.upperBound + other.lowerBound) / 2) }
            }
            guard bounds.contains(place), !reached.contains(where: { $0.lowerBound < place && place < $0.upperBound }) else { continue }
            if best.map({ abs(place - value) < abs($0 - value) }) ?? true { best = place }
        }
        return best
    }
}

/// What the overlay needs to snap a selection to text: whether the person wants that, and a way to find the
/// blocks of text in a frozen frame. Finding them takes a text detector this module does not have, so the app
/// supplies it.
nonisolated public struct TextBlockFinder: Sendable {
    /// Asked as a session begins: whether selections snap to text now.
    public var isOn: @MainActor @Sendable () -> Bool
    /// The blocks of text in a frame's pixels (origin at the top left). Called off the main actor.
    public var find: @Sendable (CGImage) async -> [CGRect]

    public init(isOn: @escaping @MainActor @Sendable () -> Bool, find: @escaping @Sendable (CGImage) async -> [CGRect]) {
        self.isOn = isOn
        self.find = find
    }
}
