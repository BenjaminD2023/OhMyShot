import CoreGraphics
import Foundation

/// A point on a selected mark that reshapes it when dragged.
nonisolated public enum Handle: String, Hashable, Sendable, CaseIterable {
    case start
    case end
    /// The middle of an arrow: dragging it bends the arrow.
    case bend
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

nonisolated extension Annotation {
    /// What the mark covers, in pixels.
    public func bounds(scale: CGFloat) -> CGRect {
        switch shape {
        case .text(let block):
            return CGRect(origin: block.origin, size: TextLayout(block, scale: scale).size)
        case .counter(let counter):
            return CounterLayout(counter, lineWidth: style.lineWidth, scale: scale).rect(at: counter.center)
        case .redaction(let redaction):
            return redaction.rect.standardized
        case .spotlight(let spot):
            return spot.rect.standardized
        case .image(let image):
            return image.rect.standardized
        case .arrow, .line, .rectangle, .ellipse, .highlightBox, .pen, .highlighter, .textHighlight:
            return MarkPaths.outline(of: self, scale: scale)?.boundingBoxOfPath ?? .null
        }
    }

    /// Everything drawing may touch, its shadow included.
    public func drawingBounds(scale: CGFloat) -> CGRect {
        let bounds = bounds(scale: scale)
        guard !bounds.isNull else { return bounds }
        let shadow = style.shadow && castsShadow ? (AnnotationRenderer.shadowBlur * 2 + AnnotationRenderer.shadowDrop) * scale : 0
        return bounds.insetBy(dx: -(shadow + 2), dy: -(shadow + 2))
    }

    /// Parts of the picture rather than marks over it: spots, drawn as one dimming, and combined
    /// images, which lie under every mark.
    public var isPicturePart: Bool {
        switch shape {
        case .spotlight, .image: true
        default: false
        }
    }

    /// Highlighter marks, which darken what is under them as ink on paper does.
    public var multiplies: Bool {
        switch shape {
        case .highlighter, .textHighlight, .highlightBox: true
        default: false
        }
    }

    /// Marks that would hide what they cover if the shadow fell on it never cast one.
    public var castsShadow: Bool {
        switch shape {
        case .highlighter, .textHighlight, .highlightBox, .redaction, .spotlight: false
        default: true
        }
    }

    /// Marks that cover an area: a new mark may start inside them, so only their edges catch the pointer
    /// unless they are already selected.
    public var coversArea: Bool {
        switch shape {
        case .redaction, .spotlight, .highlighter, .textHighlight, .highlightBox, .image: true
        case .rectangle(let box), .ellipse(let box): box.filled
        default: false
        }
    }

    /// Whether `point` (pixels) is on the mark, within `tolerance` pixels. With `interior` false, marks
    /// that cover an area answer only near their edges.
    public func contains(_ point: CGPoint, tolerance: CGFloat, scale: CGFloat, interior: Bool = true) -> Bool {
        let edgeOnly = !interior && coversArea
        switch shape {
        case .text, .counter:
            return bounds(scale: scale).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .redaction, .spotlight, .image:
            let rect = bounds(scale: scale)
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            guard outer.contains(point) else { return false }
            if !edgeOnly { return true }
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return inner.isNull || !inner.contains(point)
        case .arrow, .line, .rectangle, .ellipse, .highlightBox, .pen, .highlighter, .textHighlight:
            guard let path = MarkPaths.outline(of: self, scale: scale) else { return false }
            guard path.boundingBoxOfPath.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            let edge = path.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            if edge.contains(point) { return true }
            return !edgeOnly && path.contains(point)
        }
    }

    /// Where the mark's handles are, in pixels.
    public func handles(scale: CGFloat) -> [(handle: Handle, point: CGPoint)] {
        switch shape {
        case .arrow(let arrow):
            return [(.start, arrow.start), (.end, arrow.end), (.bend, ArrowPath.middle(of: arrow))]
        case .line(let line):
            return [(.start, line.start), (.end, line.end)]
        case .rectangle(let box), .ellipse(let box), .highlightBox(let box):
            return Self.handles(of: box.rect)
        case .redaction(let redaction):
            return Self.handles(of: redaction.rect)
        case .spotlight(let spot):
            return Self.handles(of: spot.rect)
        case .image(let image):
            // Corners only: an image stretched along one side is a distorted image.
            return Self.handles(of: image.rect).filter { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains($0.handle) }
        case .text:
            let frame = bounds(scale: scale)
            return [(.right, CGPoint(x: frame.maxX, y: frame.midY))]
        // A highlight snapped to text is drawn again rather than reshaped: its ends belong to words.
        case .pen, .highlighter, .textHighlight, .counter:
            return []
        }
    }

    private static func handles(of rect: CGRect) -> [(handle: Handle, point: CGPoint)] {
        let rect = rect.standardized
        return [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
        ]
    }

    /// The mark with `handle` dragged to `point`. Apply it to the mark as it was when the drag began.
    /// `constrained` (Shift) snaps ends to 45° steps, straightens arrows, and keeps a box's proportions.
    public func moving(_ handle: Handle, to point: CGPoint, constrained: Bool, scale: CGFloat) -> Annotation {
        var copy = self
        switch shape {
        case .arrow(var arrow):
            switch handle {
            case .start: arrow.start = constrained ? Geometry.snapped(point, from: arrow.end) : point
            case .end: arrow.end = constrained ? Geometry.snapped(point, from: arrow.start) : point
            case .bend:
                let middle = CGPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
                let normal = ArrowPath.normal(from: arrow.start, to: arrow.end)
                let bend = (point.x - middle.x) * normal.dx + (point.y - middle.y) * normal.dy
                // Close to straight snaps straight.
                arrow.bend = constrained || abs(bend) < 4 * scale ? 0 : bend
            default: break
            }
            copy.shape = .arrow(arrow)
        case .line(var line):
            switch handle {
            case .start: line.start = constrained ? Geometry.snapped(point, from: line.end) : point
            case .end: line.end = constrained ? Geometry.snapped(point, from: line.start) : point
            default: break
            }
            copy.shape = .line(line)
        case .rectangle(var box):
            box.rect = Geometry.resized(box.rect, dragging: handle, to: point, keepingAspect: constrained)
            copy.shape = .rectangle(box)
        case .ellipse(var box):
            box.rect = Geometry.resized(box.rect, dragging: handle, to: point, keepingAspect: constrained)
            copy.shape = .ellipse(box)
        case .highlightBox(var box):
            box.rect = Geometry.resized(box.rect, dragging: handle, to: point, keepingAspect: constrained)
            copy.shape = .highlightBox(box)
        case .redaction(var redaction):
            redaction.rect = Geometry.resized(redaction.rect, dragging: handle, to: point, keepingAspect: constrained)
            copy.shape = .redaction(redaction)
        case .spotlight(var spot):
            spot.rect = Geometry.resized(spot.rect, dragging: handle, to: point, keepingAspect: constrained)
            copy.shape = .spotlight(spot)
        case .image(var image):
            // An image keeps its proportions unless Shift frees them.
            image.rect = Geometry.resized(image.rect, dragging: handle, to: point, keepingAspect: !constrained)
            copy.shape = .image(image)
        case .text(var block):
            guard handle == .right else { break }
            let inset = block.look == .label ? block.fontSize * scale * 0.4 : 0
            block.width = max(point.x - block.origin.x - inset * 2, block.fontSize * scale * 2) + inset * 2
            copy.shape = .text(block)
        case .pen, .highlighter, .textHighlight, .counter:
            break
        }
        return copy
    }

    /// The mark moved by `delta` pixels.
    public func translated(by delta: CGSize) -> Annotation {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.width, y: point.y + delta.height) }
        func move(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: delta.width, dy: delta.height) }
        var copy = self
        switch shape {
        case .arrow(var arrow):
            arrow.start = move(arrow.start)
            arrow.end = move(arrow.end)
            copy.shape = .arrow(arrow)
        case .line(var line):
            line.start = move(line.start)
            line.end = move(line.end)
            copy.shape = .line(line)
        case .rectangle(var box):
            box.rect = move(box.rect)
            copy.shape = .rectangle(box)
        case .ellipse(var box):
            box.rect = move(box.rect)
            copy.shape = .ellipse(box)
        case .highlightBox(var box):
            box.rect = move(box.rect)
            copy.shape = .highlightBox(box)
        case .pen(var stroke):
            stroke.points = stroke.points.map(move)
            copy.shape = .pen(stroke)
        case .highlighter(var stroke):
            stroke.points = stroke.points.map(move)
            copy.shape = .highlighter(stroke)
        case .textHighlight(var highlight):
            highlight.rects = highlight.rects.map(move)
            copy.shape = .textHighlight(highlight)
        case .text(var block):
            block.origin = move(block.origin)
            copy.shape = .text(block)
        case .counter(var counter):
            counter.center = move(counter.center)
            copy.shape = .counter(counter)
        case .redaction(var redaction):
            redaction.rect = move(redaction.rect)
            copy.shape = .redaction(redaction)
        case .spotlight(var spot):
            spot.rect = move(spot.rect)
            copy.shape = .spotlight(spot)
        case .image(var image):
            image.rect = move(image.rect)
            copy.shape = .image(image)
        }
        return copy
    }
}

nonisolated enum Geometry {
    /// `point` turned about `anchor` to the nearest multiple of 45°, keeping its distance.
    static func snapped(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let length = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    /// The rect between two corners; `square` makes it a square along the longer drag.
    static func rect(from start: CGPoint, to end: CGPoint, square: Bool) -> CGRect {
        var dx = end.x - start.x
        var dy = end.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: start.x, y: start.y, width: dx, height: dy).standardized
    }

    /// `rect` with the edges under `handle` moved to `point`; corners keep `rect`'s proportions when
    /// `keepingAspect`.
    static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint, keepingAspect: Bool) -> CGRect {
        let rect = rect.standardized
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        switch handle {
        case .topLeft: (minX, minY) = (point.x, point.y)
        case .top: minY = point.y
        case .topRight: (maxX, minY) = (point.x, point.y)
        case .right: maxX = point.x
        case .bottomRight: (maxX, maxY) = (point.x, point.y)
        case .bottom: maxY = point.y
        case .bottomLeft: (minX, maxY) = (point.x, point.y)
        case .left: minX = point.x
        case .start, .end, .bend: break
        }
        let corners: Set<Handle> = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if keepingAspect, corners.contains(handle), rect.width > 0, rect.height > 0 {
            // Hold the opposite corner and grow along the longer of the two drags.
            let anchorX = [.topLeft, .bottomLeft].contains(handle) ? rect.maxX : rect.minX
            let anchorY = [.topLeft, .topRight].contains(handle) ? rect.maxY : rect.minY
            let movingX = anchorX == rect.maxX ? minX : maxX
            let movingY = anchorY == rect.maxY ? minY : maxY
            let factor = max(abs(movingX - anchorX) / rect.width, abs(movingY - anchorY) / rect.height)
            let width = rect.width * factor * (movingX < anchorX ? -1 : 1)
            let height = rect.height * factor * (movingY < anchorY ? -1 : 1)
            return CGRect(x: anchorX, y: anchorY, width: width, height: height).standardized
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }
}
