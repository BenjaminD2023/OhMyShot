import CoreGraphics
import Foundation

/// One of the eight ways to hold a rectangular picture: turned by quarters and perhaps mirrored. The
/// whole capture has one (`CaptureTransform`), and each combined image its own.
nonisolated public struct Orientation: Codable, Sendable, Hashable {
    /// Clockwise quarter turns, 0 to 3, made after the mirror.
    public var quarterTurns: Int
    /// Flipped left to right, before the turns.
    public var mirrored: Bool

    public init(quarterTurns: Int = 0, mirrored: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.mirrored = mirrored
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            quarterTurns: try container.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0,
            mirrored: try container.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case quarterTurns, mirrored
    }

    public static let identity = Orientation()

    public var isIdentity: Bool { quarterTurns == 0 && !mirrored }

    /// Whether width and height trade places.
    public var swapsAxes: Bool { quarterTurns % 2 == 1 }

    /// The size of a picture of `source` size once held this way.
    public func size(of source: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: source.height, height: source.width) : source
    }

    /// Takes a point of a picture of `source` size to the same point of the picture held this way, both
    /// with the origin at the top left and y growing downward.
    public func transform(for source: CGSize) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        var size = source
        if mirrored {
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
        }
        for _ in 0..<quarterTurns {
            // (x, y) to (height - y, x): the top left corner goes to the top right.
            transform = transform.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0))
            size = CGSize(width: size.height, height: size.width)
        }
        return transform
    }

    /// The orientation after one more turn or flip, made on top of this one. A flip is of what is seen:
    /// left to right, or top to bottom, whichever way the picture is turned.
    public func applying(_ operation: PictureOperation) -> Orientation {
        switch operation {
        case .rotateRight: Orientation(quarterTurns: quarterTurns + 1, mirrored: mirrored)
        case .rotateLeft: Orientation(quarterTurns: quarterTurns - 1, mirrored: mirrored)
        // A mirror turns a rotation the other way about, so the turns are undone.
        case .flipHorizontally: Orientation(quarterTurns: -quarterTurns, mirrored: !mirrored)
        // Top to bottom is left to right and a half turn.
        case .flipVertically: Orientation(quarterTurns: 2 - quarterTurns, mirrored: !mirrored)
        case .resize: self
        }
    }
}

/// A change to the whole picture: the capture and every mark on it move together.
nonisolated public enum PictureOperation: Sendable, Equatable {
    case rotateRight
    case rotateLeft
    case flipHorizontally
    case flipVertically
    /// Scales the picture so the canvas has this size in pixels.
    case resize(to: CGSize)
}

/// How the capture was turned, flipped, and resized since it was taken. The capture's own pixels are never
/// changed: the document keeps this beside them, and the picture is made from the two whenever it is drawn,
/// so a capture opened again can be turned back, and undone like any other edit.
nonisolated public struct CaptureTransform: Codable, Sendable, Hashable {
    public var orientation: Orientation
    /// The picture's size in pixels once it is resized; nil keeps the size it has when turned.
    public var size: CGSize?

    public init(orientation: Orientation = .identity, size: CGSize? = nil) {
        self.orientation = orientation
        self.size = size
    }

    /// The picture's size in pixels, for a capture of `source` size.
    public func pictureSize(for source: CGSize) -> CGSize {
        size ?? orientation.size(of: source)
    }

    /// This with a size that is only the turned size left out, or nil when it leaves a capture of `source`
    /// size as it was taken.
    func normalized(for source: CGSize) -> CaptureTransform? {
        var transform = self
        if transform.size == orientation.size(of: source) { transform.size = nil }
        return transform.orientation.isIdentity && transform.size == nil ? nil : transform
    }
}

nonisolated extension AnnotationDocument {
    /// The most pixels along a side, and in all, that resizing makes: past these a picture could not be
    /// drawn or kept.
    public static let maxPictureSide = 16384
    public static let maxPictureArea = 100_000_000

    /// The orientation of the capture.
    public var orientation: Orientation { transform?.orientation ?? .identity }

    /// The picture's size in pixels: the capture as it was taken, turned and resized.
    public var pictureSize: CGSize { transform?.pictureSize(for: pixelSize) ?? pixelSize }

    /// The document after `operation`: the capture turned, flipped, or resized, every mark and the canvas
    /// carried with it, and the document left as it was where the picture is not touched (the background
    /// goes on around whatever the picture is). Resizing also scales `scale`, so the point sizes marks are
    /// drawn in (strokes, type, corners) stay in proportion to the picture. Nil when the operation changes
    /// nothing, or asks for a size no picture can have.
    public func applying(_ operation: PictureOperation) -> AnnotationDocument? {
        let size = pictureSize
        var result = self
        var transform = self.transform ?? CaptureTransform()
        let mapping: PictureMapping
        switch operation {
        case .rotateRight, .rotateLeft, .flipHorizontally, .flipVertically:
            let turn = Orientation.identity.applying(operation)
            mapping = PictureMapping(affine: turn.transform(for: size), operation: operation, lengthFactor: 1)
            result.canvas = canvas.standardized.applying(mapping.affine).standardized
            transform.orientation = transform.orientation.applying(operation)
            // A resized picture stays as big as it was, turned.
            if turn.swapsAxes, let drawn = transform.size {
                transform.size = CGSize(width: drawn.height, height: drawn.width)
            }
        case .resize(let target):
            let canvas = canvas.standardized
            guard let picture = resizedPictureSize(forCanvas: target) else { return nil }
            let target = CGSize(width: target.width.rounded(), height: target.height.rounded())
            // The factors the picture really goes by, which whole pixels make a little unlike the asked.
            let factorX = picture.width / size.width
            let factorY = picture.height / size.height
            mapping = PictureMapping(
                affine: CGAffineTransform(scaleX: factorX, y: factorY), operation: operation, lengthFactor: (factorX * factorY).squareRoot()
            )
            result.canvas = Self.scaled(canvas, by: mapping.affine, to: target, within: imageBounds.contains(canvas) ? CGRect(origin: .zero, size: picture) : nil)
            result.scale = scale * mapping.lengthFactor
            transform.size = picture
        }
        result.items = items.map { $0.mapped(by: mapping, scale: scale) }
        result.transform = transform.normalized(for: pixelSize)
        return result == self ? nil : result
    }

    /// The size the picture takes for the canvas to be `target` pixels across, or nil when no picture could
    /// be that big (past `maxPictureSide` or `maxPictureArea`) or the canvas has no size to scale.
    func resizedPictureSize(forCanvas target: CGSize) -> CGSize? {
        let canvas = canvas.standardized
        let target = CGSize(width: target.width.rounded(), height: target.height.rounded())
        guard canvas.width >= 1, canvas.height >= 1, target.width >= 1, target.height >= 1 else { return nil }
        let size = pictureSize
        let picture = CGSize(width: (size.width * target.width / canvas.width).rounded(), height: (size.height * target.height / canvas.height).rounded())
        guard picture.width >= 1, picture.height >= 1,
              picture.width <= CGFloat(Self.maxPictureSide), picture.height <= CGFloat(Self.maxPictureSide),
              picture.width * picture.height <= CGFloat(Self.maxPictureArea) else { return nil }
        return picture
    }

    /// `canvas` scaled by `affine`, exactly `target` pixels across on whole pixels, and kept within `limit`
    /// when it lay within the picture before.
    private static func scaled(_ canvas: CGRect, by affine: CGAffineTransform, to target: CGSize, within limit: CGRect?) -> CGRect {
        var rect = CGRect(x: (canvas.minX * affine.a).rounded(), y: (canvas.minY * affine.d).rounded(), width: target.width, height: target.height)
        if let limit {
            rect.size.width = min(rect.width, limit.width)
            rect.size.height = min(rect.height, limit.height)
            rect.origin.x = max(min(rect.minX, limit.maxX - rect.width), limit.minX)
            rect.origin.y = max(min(rect.minY, limit.maxY - rect.height), limit.minY)
        }
        return rect
    }
}

/// Where each point of the picture goes: an axis-aligned map, a turn, a flip, or a scale.
nonisolated struct PictureMapping {
    var affine: CGAffineTransform
    var operation: PictureOperation
    /// How much lengths in pixels grow (the square root of the area's growth).
    var lengthFactor: CGFloat

    func point(_ point: CGPoint) -> CGPoint { point.applying(affine) }

    func rect(_ rect: CGRect) -> CGRect { rect.standardized.applying(affine).standardized }

    var isResize: Bool {
        if case .resize = operation { true } else { false }
    }

    /// Whether the map keeps every shape: turns, flips, and scales alike in both directions.
    var isSimilarity: Bool {
        abs(affine.a * affine.a + affine.b * affine.b - (affine.c * affine.c + affine.d * affine.d)) < 1e-9
            && abs(affine.a * affine.c + affine.b * affine.d) < 1e-9
    }

    /// Whether the map swaps left and right (a flip).
    var reflects: Bool { affine.a * affine.d - affine.b * affine.c < 0 }
}

nonisolated extension Annotation {
    /// The mark carried with the picture it lies on. Text and counters stay upright, so a turn moves
    /// them to where their middles go without turning their letters; combined images turn with the
    /// picture. `scale` is the document's scale before the operation.
    func mapped(by mapping: PictureMapping, scale: CGFloat) -> Annotation {
        var copy = self
        switch shape {
        case .arrow(var arrow):
            let control = ArrowPath.control(start: arrow.start, end: arrow.end, bend: arrow.bend)
            let start = mapping.point(arrow.start)
            let end = mapping.point(arrow.end)
            if mapping.isSimilarity {
                // Turned, flipped, or scaled alike: the bend scales with the picture, and a flip swaps what
                // is to the right of the direction of travel, and the bend with it.
                arrow.bend *= mapping.lengthFactor * (mapping.reflects ? -1 : 1)
            } else if arrow.bend != 0 {
                // Stretched unevenly: the curve's control point goes where the map takes it, and the bend is
                // read off the new line.
                let moved = mapping.point(control)
                let normal = ArrowPath.normal(from: start, to: end)
                let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                arrow.bend = ((moved.x - middle.x) * normal.dx + (moved.y - middle.y) * normal.dy) / 2
            }
            arrow.start = start
            arrow.end = end
            copy.shape = .arrow(arrow)
        case .line(var line):
            line.start = mapping.point(line.start)
            line.end = mapping.point(line.end)
            copy.shape = .line(line)
        case .rectangle(var box):
            box.rect = mapping.rect(box.rect)
            copy.shape = .rectangle(box)
        case .ellipse(var box):
            box.rect = mapping.rect(box.rect)
            copy.shape = .ellipse(box)
        case .highlightBox(var box):
            box.rect = mapping.rect(box.rect)
            copy.shape = .highlightBox(box)
        case .pen(var stroke):
            stroke.points = stroke.points.map(mapping.point)
            copy.shape = .pen(stroke)
        case .highlighter(var stroke):
            stroke.points = stroke.points.map(mapping.point)
            copy.shape = .highlighter(stroke)
        case .textHighlight(var highlight):
            highlight.rects = highlight.rects.map(mapping.rect)
            copy.shape = .textHighlight(highlight)
        case .text(var block):
            if mapping.isResize {
                // The block grows from its corner, and its wrapping width with it.
                block.origin = mapping.point(block.origin)
                block.width = block.width.map { $0 * mapping.affine.a }
            } else {
                let frame = bounds(scale: scale)
                let middle = mapping.point(CGPoint(x: frame.midX, y: frame.midY))
                block.origin = CGPoint(x: middle.x - frame.width / 2, y: middle.y - frame.height / 2)
            }
            copy.shape = .text(block)
        case .counter(var counter):
            counter.center = mapping.point(counter.center)
            copy.shape = .counter(counter)
        case .redaction(var redaction):
            redaction.rect = mapping.rect(redaction.rect)
            copy.shape = .redaction(redaction)
        case .spotlight(var spot):
            spot.rect = mapping.rect(spot.rect)
            copy.shape = .spotlight(spot)
        case .image(var image):
            image.rect = mapping.rect(image.rect)
            let orientation = (image.orientation ?? .identity).applying(mapping.operation)
            image.orientation = orientation.isIdentity ? nil : orientation
            copy.shape = .image(image)
        }
        return copy
    }
}
