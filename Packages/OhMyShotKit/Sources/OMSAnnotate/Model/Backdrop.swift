import CoreGraphics
import Foundation

/// A background for sharing a capture: the capture set on a gradient, a color, a picture, or a blur of
/// itself, with room around it, its corners rounded, and a soft shadow under it.
///
/// Room is measured against the capture's size (the side of a square of its area), so a background
/// looks the same on a small capture and a whole screen; corners and the shadow are in points, like a
/// window's.
nonisolated public struct Backdrop: Codable, Sendable, Equatable {
    public enum Fill: Codable, Sendable, Hashable {
        /// Nothing: the room around the capture is transparent, so only its shadow shows.
        case clear
        case gradient(BackdropGradient)
        case color(RGBA)
        /// The capture itself, blurred until only its colors are left.
        case blur
        /// A picture the person chose, kept in the backgrounds folder under this name.
        case picture(String)
    }

    /// The shape of the finished picture, width to height.
    public struct Ratio: Codable, Sendable, Hashable {
        public var width: Int
        public var height: Int

        public init(_ width: Int, _ height: Int) {
            self.width = max(width, 1)
            self.height = max(height, 1)
        }

        public var value: CGFloat { CGFloat(width) / CGFloat(height) }

        /// The shapes offered: square, the common landscape ones, and two portrait ones for phones.
        public static let presets: [Ratio] = [Ratio(1, 1), Ratio(4, 3), Ratio(3, 2), Ratio(16, 10), Ratio(16, 9), Ratio(4, 5), Ratio(9, 16)]
    }

    /// Where the capture sits when the picture's shape leaves more room on one side than the other.
    public enum Alignment: String, Codable, Sendable, CaseIterable {
        case topLeft, top, topRight
        case left, center, right
        case bottomLeft, bottom, bottomRight

        /// The capture's place along each axis: 0 at the left or top, 1 at the right or bottom.
        public var unit: CGPoint {
            let x: CGFloat = switch self {
            case .topLeft, .left, .bottomLeft: 0
            case .top, .center, .bottom: 0.5
            case .topRight, .right, .bottomRight: 1
            }
            let y: CGFloat = switch self {
            case .topLeft, .top, .topRight: 0
            case .left, .center, .right: 0.5
            case .bottomLeft, .bottom, .bottomRight: 1
            }
            return CGPoint(x: x, y: y)
        }
    }

    public var fill: Fill
    /// The room around the capture, as a fraction of its size.
    public var padding: CGFloat
    /// Room added inside the capture's edge, in the edge's own color, as a fraction of its size. Only
    /// a capture whose edge is one color has it.
    public var inset: CGFloat
    /// Evens out the room around what the capture shows, in its edge color, so it sits centered.
    public var balanced: Bool
    /// The capture's corners, in points.
    public var cornerRadius: CGFloat
    /// The capture's shadow, from 0 (none) to 1 (deepest).
    public var shadow: CGFloat
    /// The finished picture's shape; nil keeps even room all round.
    public var ratio: Ratio?
    public var alignment: Alignment

    public init(
        fill: Fill = .gradient(.sky), padding: CGFloat = 0.08, inset: CGFloat = 0, balanced: Bool = false,
        cornerRadius: CGFloat = 12, shadow: CGFloat = 0.5, ratio: Ratio? = nil, alignment: Alignment = .center
    ) {
        self.fill = fill
        self.padding = padding
        self.inset = inset
        self.balanced = balanced
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.ratio = ratio
        self.alignment = alignment
    }

    /// The ranges the controls offer.
    public static let paddingRange: ClosedRange<CGFloat> = 0...0.25
    public static let insetRange: ClosedRange<CGFloat> = 0...0.12
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...40
    public static let shadowRange: ClosedRange<CGFloat> = 0...1
}

/// The built-in backgrounds: soft gradients in the manner of a desktop picture, light and dark.
nonisolated public enum BackdropGradient: String, Codable, Sendable, CaseIterable {
    case sky
    case lilac
    case rose
    case peach
    case citrus
    case mint
    case ocean
    case dusk
    case graphite
    case paper
}

/// Where everything goes in a picture with a background, in the document's pixels.
nonisolated public struct BackdropLayout: Equatable, Sendable {
    /// The whole finished picture.
    public var output: CGRect
    /// The capture as it sits on the background, with the room its inset and balance add.
    public var card: CGRect
    /// The kept part of the capture (the canvas) inside the card.
    public var picture: CGRect
    /// Fills the card under the capture: the room its inset and balance add, and canvas reaching past
    /// the capture (images combined beside it). The capture's edge color, in the capture's color space,
    /// or white for canvas past a capture whose edge has no one color. Nil leaves the card clear.
    public var matte: RGBA?
    /// The card's corners, in pixels.
    public var cornerRadius: CGFloat
    /// No card is drawn: a window captured with its shadow keeps its own corners and shadow.
    public var isBare: Bool
}

nonisolated extension AnnotationDocument {
    /// The size the background's room is measured against: the side of a square of the canvas's area.
    var backdropMeasure: CGFloat {
        let canvas = canvas.standardized
        return (max(canvas.width, 1) * max(canvas.height, 1)).squareRoot()
    }

    /// Whether the canvas reaches past the capture, as when images are combined beside it.
    public var canvasReachesPastCapture: Bool {
        !imageBounds.contains(canvas.standardized)
    }

    /// What fills canvas reaching past the capture when there is no background: the capture's edge
    /// color, or white where its edge has no one color, so a combined picture reads as one and never
    /// carries clear slivers (which some apps show black). Nil when the canvas stays within the
    /// capture, or the capture is a window with its shadow, whose surroundings stay clear.
    public func canvasMatte(edges: EdgeAnalysis) -> RGBA? {
        guard canvasReachesPastCapture, edges.opaque else { return nil }
        return edges.edgeColor ?? .white
    }

    /// Where the background, the card, and the capture go, or nil without a background. `edges`
    /// describes the canvas's part of the capture (`EdgeAnalysis.of(_:canvas:)`).
    public func backdropLayout(edges: EdgeAnalysis) -> BackdropLayout? {
        guard let backdrop else { return nil }
        let picture = canvas.standardized
        let measure = backdropMeasure
        var card = picture
        var matte: RGBA?
        var radius: CGFloat = 0
        let isBare = !edges.opaque
        if !isBare {
            // Canvas past the capture is filled too, so a card holding combined images reads as one.
            matte = edges.edgeColor ?? (canvasReachesPastCapture ? .white : nil)
            if let edge = edges.edgeColor {
                if backdrop.balanced, let content = edges.content {
                    // Each side gets the room of the wider one across from it, so what the capture shows
                    // sits centered without anything being cut.
                    let left = content.minX - picture.minX
                    let right = picture.maxX - content.maxX
                    let top = content.minY - picture.minY
                    let bottom = picture.maxY - content.maxY
                    let across = max(left, right)
                    let down = max(top, bottom)
                    card = CGRect(
                        x: picture.minX - (across - left), y: picture.minY - (down - top),
                        width: picture.width + (across - left) + (across - right),
                        height: picture.height + (down - top) + (down - bottom)
                    )
                }
                let inset = (min(max(backdrop.inset, 0), Backdrop.insetRange.upperBound) * measure).rounded()
                card = card.insetBy(dx: -inset, dy: -inset)
                matte = edge
            }
            radius = min(max(backdrop.cornerRadius, 0) * scale, min(card.width, card.height) / 2)
        }
        let padding = (min(max(backdrop.padding, 0), Backdrop.paddingRange.upperBound) * measure).rounded()
        var output = card.insetBy(dx: -padding, dy: -padding)
        if let ratio = backdrop.ratio {
            // Only ever grows: the room the shape adds goes to the sides the alignment leaves open.
            let unit = backdrop.alignment.unit
            if output.width / output.height < ratio.value {
                let width = (output.height * ratio.value).rounded()
                output.origin.x -= ((width - output.width) * unit.x).rounded()
                output.size.width = width
            } else {
                let height = (output.width / ratio.value).rounded()
                output.origin.y -= ((height - output.height) * unit.y).rounded()
                output.size.height = height
            }
        }
        return BackdropLayout(output: output, card: card, picture: picture, matte: matte, cornerRadius: radius, isBare: isBare)
    }
}
