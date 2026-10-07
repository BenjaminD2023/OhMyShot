import CoreGraphics

/// The rectangle being dragged out on one display, kept on that display and on its pixel grid.
///
/// Coordinates are AppKit global points. Edges snap to the display's framebuffer pixels, so a
/// selection always captures whole pixels and its reported size is exact.
public struct SelectionModel: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Keep the selection square (Shift).
        public static let square = Modifiers(rawValue: 1 << 0)
        /// Grow from the starting point in every direction (Option).
        public static let fromCenter = Modifiers(rawValue: 1 << 1)
    }

    /// The display's frame; the selection never leaves it.
    public let bounds: CGRect
    public let pixelsPerPoint: CGFloat

    public private(set) var anchor: CGPoint?
    public private(set) var rect: CGRect?

    public init(bounds: CGRect, pixelsPerPoint: CGFloat) {
        self.bounds = bounds
        self.pixelsPerPoint = max(pixelsPerPoint, 1)
    }

    public mutating func begin(at point: CGPoint) {
        anchor = snapped(clamped(point))
        rect = nil
    }

    public mutating func drag(to point: CGPoint, modifiers: Modifiers = []) {
        guard let anchor else { return }
        let current = clamped(point)
        var dx = current.x - anchor.x
        var dy = current.y - anchor.y
        if modifiers.contains(.square) {
            let side = max(abs(dx), abs(dy))
            dx = side * (dx < 0 ? -1 : 1)
            dy = side * (dy < 0 ? -1 : 1)
        }
        var next: CGRect
        if modifiers.contains(.fromCenter) {
            next = CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        } else {
            next = CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
        }
        next = next.intersection(bounds)
        rect = next.isNull ? nil : snapped(next)
    }

    /// Moves the whole selection, as when Space is held during a drag. It stops at the display edges.
    public mutating func move(by delta: CGVector) {
        guard let rect else { return }
        var moved = rect.offsetBy(dx: delta.dx, dy: delta.dy)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        self.rect = snapped(moved)
        anchor = anchor.map { CGPoint(x: $0.x + (moved.minX - rect.minX), y: $0.y + (moved.minY - rect.minY)) }
    }

    public mutating func reset() {
        anchor = nil
        rect = nil
    }

    /// The selection's size in framebuffer pixels, which is exactly the captured image's size.
    public var pixelSize: (width: Int, height: Int) {
        guard let rect else { return (0, 0) }
        return (Int((rect.width * pixelsPerPoint).rounded()), Int((rect.height * pixelsPerPoint).rounded()))
    }

    /// Too small to be a deliberate selection (a click, not a drag).
    public var isTooSmall: Bool {
        let size = pixelSize
        return size.width < 4 || size.height < 4
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: snap(point.x, origin: bounds.minX), y: snap(point.y, origin: bounds.minY))
    }

    private func snapped(_ rect: CGRect) -> CGRect {
        let minX = snap(rect.minX, origin: bounds.minX), maxX = snap(rect.maxX, origin: bounds.minX)
        let minY = snap(rect.minY, origin: bounds.minY), maxY = snap(rect.maxY, origin: bounds.minY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func snap(_ value: CGFloat, origin: CGFloat) -> CGFloat {
        origin + ((value - origin) * pixelsPerPoint).rounded() / pixelsPerPoint
    }
}
