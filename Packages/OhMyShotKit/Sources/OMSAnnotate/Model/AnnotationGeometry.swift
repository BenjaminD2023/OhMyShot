import CoreGraphics
import Foundation

/// A point on a selected mark that reshapes it when dragged.
nonisolated public enum Handle: String, Hashable, Sendable, CaseIterable {
    case start
    case end
    /// The middle of an arrow: dragging it bends the arrow.
    case bend
    /// A bubble's tip, or the end of a counter's pointer (on the disc's edge while it has none).
    case tail
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
    /// What the mark covers, in pixels: for a turned mark, the upright box around it as it is turned.
    public func bounds(scale: CGFloat) -> CGRect {
        if isTurned {
            let upright = upright(scale: scale)
            let frame = upright.bounds(scale: scale)
            return Self.box(around: frame, turnedBy: angle, about: frame.middle)
        }
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
        case .magnifier(let magnifier):
            return magnifier.lensRect
        case .arrow, .line, .rectangle, .ellipse, .highlightBox, .pen, .highlighter, .textHighlight:
            return MarkPaths.outline(of: self, scale: scale)?.boundingBoxOfPath ?? .null
        }
    }

    /// Everything drawing may touch, its shadow included: a bubble's or a counter's tail too, which `bounds` leaves
    /// out, so the selection's frame, its handles, and alignment go by the plate or disc alone.
    public func drawingBounds(scale: CGFloat) -> CGRect {
        if isTurned {
            let upright = upright(scale: scale)
            return Self.box(around: upright.drawingBounds(scale: scale), turnedBy: angle, about: upright.bounds(scale: scale).middle)
        }
        // The lens's shadow, and the ring and line at what it magnifies.
        if case .magnifier(let magnifier) = shape { return MagnifierPainter.drawingBounds(of: magnifier, scale: scale) }
        var bounds = bounds(scale: scale)
        guard !bounds.isNull else { return bounds }
        if let tip = tip(scale: scale) { bounds = bounds.union(CGRect(origin: tip, size: .zero)) }
        let shadow = style.shadow && castsShadow ? (AnnotationRenderer.shadowBlur * 2 + AnnotationRenderer.shadowDrop) * scale : 0
        return bounds.insetBy(dx: -(shadow + 2), dy: -(shadow + 2))
    }

    /// Where a bubble's tail or a counter's pointer ends, in pixels; nil for marks without one.
    func tip(scale: CGFloat) -> CGPoint? {
        if isTurned {
            let upright = upright(scale: scale)
            return upright.tip(scale: scale).map { Self.turn($0, about: upright.bounds(scale: scale).middle, by: angle) }
        }
        return switch shape {
        case .text(let block) where block.look == .bubble: TextLayout(block, scale: scale).tip(of: block)
        case .counter(let counter): counter.tail
        default: nil
        }
    }

    /// A bubble's or a pointing counter's whole outline, tail included; nil for every other mark.
    func calloutOutline(scale: CGFloat) -> CGPath? {
        switch shape {
        case .text(let block) where block.look == .bubble:
            return TextLayout(block, scale: scale).bubblePath(of: block)
        case .counter(let counter) where counter.tail != nil:
            let diameter = CounterLayout(counter, lineWidth: style.lineWidth, scale: scale).diameter
            return CalloutPaths.counter(center: counter.center, diameter: diameter, tip: counter.tail)
        default:
            return nil
        }
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

    /// Marks that would hide what they cover if the shadow fell on it never cast one. A magnifier's lens has a
    /// shadow of its own, the loupe's, rather than the mark shadow.
    public var castsShadow: Bool {
        switch shape {
        case .highlighter, .textHighlight, .highlightBox, .redaction, .spotlight, .magnifier: false
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

    /// Whether changing ink color applies to this mark.
    public var supportsColor: Bool {
        switch shape {
        case .spotlight, .image, .magnifier: false
        case .redaction(let redaction): redaction.method == .solid
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .highlightBox, .textHighlight, .text, .counter: true
        }
    }

    /// Whether changing stroke width / counter size applies to this mark.
    public var supportsLineWidth: Bool {
        switch shape {
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .counter: true
        case .text, .redaction, .spotlight, .highlightBox, .textHighlight, .image, .magnifier: false
        }
    }

    /// Whether `point` (pixels) is on the mark, within `tolerance` pixels. With `interior` false, marks
    /// that cover an area answer only near their edges.
    public func contains(_ point: CGPoint, tolerance: CGFloat, scale: CGFloat, interior: Bool = true) -> Bool {
        if isTurned {
            let upright = upright(scale: scale)
            let local = Self.turn(point, about: upright.bounds(scale: scale).middle, by: -angle)
            return upright.contains(local, tolerance: tolerance, scale: scale, interior: interior)
        }
        let edgeOnly = !interior && coversArea
        switch shape {
        case .text, .counter:
            if bounds(scale: scale).insetBy(dx: -tolerance, dy: -tolerance).contains(point) { return true }
            // On a bubble's tail or a counter's pointer.
            guard let outline = calloutOutline(scale: scale) else { return false }
            return outline.contains(point) || outline.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        case .redaction, .spotlight, .image:
            let rect = bounds(scale: scale)
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            guard outer.contains(point) else { return false }
            if !edgeOnly { return true }
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return inner.isNull || !inner.contains(point)
        case .magnifier(let magnifier):
            // The lens: what it magnifies is reached by its handle once it is selected.
            return hypot(point.x - magnifier.center.x, point.y - magnifier.center.y) <= magnifier.radius + tolerance
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
        if isTurned {
            let upright = upright(scale: scale)
            let center = upright.bounds(scale: scale).middle
            return upright.handles(scale: scale).map { ($0.handle, Self.turn($0.point, about: center, by: angle)) }
        }
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
        case .text(let block):
            let frame = bounds(scale: scale)
            let width = (handle: Handle.right, point: CGPoint(x: frame.maxX, y: frame.midY))
            guard block.look == .bubble, let tip = tip(scale: scale) else { return [width] }
            return [width, (.tail, tip)]
        case .counter(let counter):
            // Pulled out of the disc's edge, a pointer; pushed back in, gone.
            let diameter = CounterLayout(counter, lineWidth: style.lineWidth, scale: scale).diameter
            return [(.tail, counter.tail ?? CalloutPaths.restingTip(center: counter.center, diameter: diameter))]
        case .magnifier(let magnifier):
            // Corners that size the lens about its middle; once it stands apart, what it magnifies moves by its own.
            let corners = Self.handles(of: magnifier.lensRect).filter { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains($0.handle) }
            return magnifier.isDetached ? corners + [(.start, magnifier.source)] : corners
        // A highlight snapped to text is drawn again rather than reshaped: its ends belong to words.
        case .pen, .highlighter, .textHighlight:
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
        if isTurned {
            // Reshaped upright in its own frame, then turned again; the side across from the handle stays where it was
            // on the picture, though the middle it turns about has moved.
            let upright = upright(scale: scale)
            let before = upright.bounds(scale: scale)
            let local = Self.turn(point, about: before.middle, by: -angle)
            let reshaped = upright.moving(handle, to: local, constrained: constrained, scale: scale)
            let after = reshaped.bounds(scale: scale)
            let anchor = handle.opposite
            let was = Self.turn(anchor.point(on: before), about: before.middle, by: angle)
            let now = Self.turn(anchor.point(on: after), about: after.middle, by: angle)
            return Self.turned(reshaped, by: angle, scale: scale).translated(by: CGSize(width: was.x - now.x, height: was.y - now.y))
        }
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
            if handle == .tail, block.look == .bubble {
                let frame = bounds(scale: scale)
                block.tail = constrained ? Geometry.snapped(point, from: CGPoint(x: frame.midX, y: frame.midY)) : point
                copy.shape = .text(block)
                break
            }
            guard handle == .right else { break }
            let inset = block.look.hasPlate ? block.fontSize * scale * 0.4 : 0
            block.width = max(point.x - block.origin.x - inset * 2, block.fontSize * scale * 2) + inset * 2
            copy.shape = .text(block)
        case .counter(var counter):
            guard handle == .tail else { break }
            let diameter = CounterLayout(counter, lineWidth: style.lineWidth, scale: scale).diameter
            let tip = constrained ? Geometry.snapped(point, from: counter.center) : point
            // Back on the disc, the pointer goes.
            counter.tail = hypot(tip.x - counter.center.x, tip.y - counter.center.y) <= diameter / 2 * 1.1 ? nil : tip
            copy.shape = .counter(counter)
        case .magnifier(var magnifier):
            if handle == .start {
                magnifier.source = constrained ? Geometry.snapped(point, from: magnifier.center) : point
            } else {
                // A circle sized about its middle, never smaller than a thumb's width.
                let reach = max(abs(point.x - magnifier.center.x), abs(point.y - magnifier.center.y))
                magnifier.radius = max(reach, Magnifier.smallestRadius * scale)
            }
            copy.shape = .magnifier(magnifier)
        case .pen, .highlighter, .textHighlight:
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
            block.tail = block.tail.map(move)
            copy.shape = .text(block)
        case .counter(var counter):
            counter.center = move(counter.center)
            counter.tail = counter.tail.map(move)
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
        case .magnifier(var magnifier):
            magnifier.source = move(magnifier.source)
            magnifier.center = move(magnifier.center)
            copy.shape = .magnifier(magnifier)
        }
        return copy
    }

    /// The mark as a drag on it alone moves it by `delta` pixels: a magnifier's lens alone, what it magnifies
    /// staying where it is (back over it, the lens settles there); any other mark whole.
    public func dragged(by delta: CGSize) -> Annotation {
        guard case .magnifier(var magnifier) = shape else { return translated(by: delta) }
        let center = CGPoint(x: magnifier.center.x + delta.width, y: magnifier.center.y + delta.height)
        let settles = hypot(center.x - magnifier.source.x, center.y - magnifier.source.y) <= magnifier.sourceRadius
        magnifier.center = settles ? magnifier.source : center
        var copy = self
        copy.shape = .magnifier(magnifier)
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

    /// How far the edges under `handle` of `rect` lie from a press at `point`, along the axes the handle
    /// moves: a side's distance across it, a corner's both ways; zero for the handles of lines. Added to the
    /// pointer while it drags, it keeps the edge where it was taken hold of instead of jumping to the pointer.
    static func grip(of handle: Handle, on rect: CGRect, pressedAt point: CGPoint) -> CGVector {
        let rect = rect.standardized
        let x: CGFloat? = switch handle {
        case .topLeft, .left, .bottomLeft: rect.minX
        case .topRight, .right, .bottomRight: rect.maxX
        case .top, .bottom, .start, .end, .bend, .tail: nil
        }
        let y: CGFloat? = switch handle {
        case .topLeft, .top, .topRight: rect.minY
        case .bottomLeft, .bottom, .bottomRight: rect.maxY
        case .left, .right, .start, .end, .bend, .tail: nil
        }
        return CGVector(dx: x.map { $0 - point.x } ?? 0, dy: y.map { $0 - point.y } ?? 0)
    }

    /// Where the edges under `handle` of `rect` meet, nudged half of `pixel` inside it: the middle of the
    /// pixel just inside the dragged corner, or, for a side, of the one across from `pointer`. A magnifier
    /// centered there shows the edge against what it cuts off. The dragged edge is the side nearer the
    /// pointer, which stays with it even once it has been dragged past the opposite one.
    static func edgePoint(of handle: Handle, on rect: CGRect, near pointer: CGPoint, pixel: CGFloat) -> CGPoint {
        let rect = rect.standardized
        let half = pixel / 2
        func along(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value, low + half), max(low + half, high - half))
        }
        func nearer(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            abs(value - low) <= abs(value - high) ? low + half : high - half
        }
        let movesX: Bool = switch handle {
        case .topLeft, .left, .bottomLeft, .topRight, .right, .bottomRight: true
        case .top, .bottom, .start, .end, .bend, .tail: false
        }
        let movesY: Bool = switch handle {
        case .topLeft, .top, .topRight, .bottomLeft, .bottom, .bottomRight: true
        case .left, .right, .start, .end, .bend, .tail: false
        }
        return CGPoint(
            x: movesX ? nearer(pointer.x, rect.minX, rect.maxX) : along(pointer.x, rect.minX, rect.maxX),
            y: movesY ? nearer(pointer.y, rect.minY, rect.maxY) : along(pointer.y, rect.minY, rect.maxY)
        )
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
        case .start, .end, .bend, .tail: break
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
