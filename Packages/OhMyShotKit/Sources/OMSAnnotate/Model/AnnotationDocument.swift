import CoreGraphics
import Foundation

/// What the editor edits: a capture and the marks drawn over it, all in the capture's own pixels, with
/// the origin at the top left and y growing downward, as the picture is stored.
///
/// A value type: undo keeps whole snapshots, and an export takes one off the main actor. Sizes a person
/// picks (stroke widths, type sizes, corner radii) are in points of the screen the capture came from, and
/// `scale` turns them into pixels, so a 4 pt arrow is 8 px wide on a Retina capture and looks as it would
/// have drawn over the original window.
nonisolated public struct AnnotationDocument: Codable, Sendable, Equatable {
    /// The capture's size in pixels.
    public var pixelSize: CGSize
    /// Pixels per point of the screen the capture came from (2 for a Retina capture).
    public var scale: CGFloat
    /// The part of the picture that is kept, in pixels: the whole capture unless it was cropped. Reaching
    /// past the capture's edges adds empty canvas there.
    public var canvas: CGRect
    /// Back to front.
    public var items: [Annotation]
    /// The background the capture sits on, if any. Marks may reach onto it.
    public var backdrop: Backdrop?

    public init(pixelSize: CGSize, scale: CGFloat, items: [Annotation] = [], backdrop: Backdrop? = nil) {
        self.pixelSize = pixelSize
        self.scale = scale > 0 ? scale : 1
        canvas = CGRect(origin: .zero, size: pixelSize)
        self.items = items
        self.backdrop = backdrop
    }

    /// The capture itself, in its own pixels.
    public var imageBounds: CGRect { CGRect(origin: .zero, size: pixelSize) }

    /// Nothing drawn, cropped, or set behind the capture: it is what was taken.
    public var isEmpty: Bool { items.isEmpty && canvas == imageBounds && backdrop == nil }

    public func index(of id: Annotation.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    public func item(_ id: Annotation.ID) -> Annotation? {
        items.first { $0.id == id }
    }

    /// The next value a new counter in `numbering` should show: one past the highest of that numbering
    /// so far. Each numbering counts on its own: after 1, 2, the first letter is A, not C.
    public func nextCounterValue(for numbering: Counter.Numbering) -> Int {
        let values = items.compactMap { item -> Int? in
            if case .counter(let counter) = item.shape, counter.numbering == numbering { return counter.value }
            return nil
        }
        return (values.max() ?? 0) + 1
    }
}

/// One mark on the capture.
nonisolated public struct Annotation: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var shape: Shape
    public var style: Style

    public init(id: UUID = UUID(), shape: Shape, style: Style) {
        self.id = id
        self.shape = shape
        self.style = style
    }
}

/// What a mark is, with its geometry in pixels.
nonisolated public enum Shape: Codable, Sendable, Equatable {
    case arrow(Arrow)
    case line(Line)
    case rectangle(Box)
    case ellipse(Box)
    /// Freehand.
    case pen(Stroke)
    /// A translucent marker that darkens the picture under it, so text stays legible.
    case highlighter(Stroke)
    case text(TextBlock)
    case counter(Counter)
    case redaction(Redaction)
    /// Dims everything but the spot. All spots share one dimming.
    case spotlight(Spot)
    /// Another picture combined into the capture. Images are part of the picture: they lie under the
    /// spotlight and every other mark.
    case image(PlacedImage)
}

nonisolated public struct Arrow: Codable, Sendable, Equatable {
    public enum Head: String, Codable, Sendable, CaseIterable {
        /// A line with a filled head.
        case classic
        /// A body that widens from tail to head, like a brush stroke.
        case tapered
        /// A line with an open, chevron head.
        case open
        /// Heads at both ends.
        case double
    }

    public var start: CGPoint
    public var end: CGPoint
    /// How far the arrow's middle bows away from the straight line between its ends, in pixels: positive
    /// to the right of the direction of travel as seen on screen, negative to the left; 0 is straight.
    public var bend: CGFloat
    public var head: Head

    public init(start: CGPoint, end: CGPoint, bend: CGFloat = 0, head: Head = .classic) {
        self.start = start
        self.end = end
        self.bend = bend
        self.head = head
    }
}

nonisolated public struct Line: Codable, Sendable, Equatable {
    public var start: CGPoint
    public var end: CGPoint
    public var dashed: Bool

    public init(start: CGPoint, end: CGPoint, dashed: Bool = false) {
        self.start = start
        self.end = end
        self.dashed = dashed
    }
}

/// A rectangle or an ellipse. The stroke is centered on the edge of `rect`.
nonisolated public struct Box: Codable, Sendable, Equatable {
    public var rect: CGRect
    /// Filled with the color instead of outlined.
    public var filled: Bool
    /// In points; ignored by ellipses.
    public var cornerRadius: CGFloat

    public init(rect: CGRect, filled: Bool = false, cornerRadius: CGFloat = 0) {
        self.rect = rect
        self.filled = filled
        self.cornerRadius = cornerRadius
    }
}

nonisolated public struct Stroke: Codable, Sendable, Equatable {
    public var points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }
}

nonisolated public struct TextBlock: Codable, Sendable, Equatable {
    public enum Look: String, Codable, Sendable, CaseIterable {
        /// The text in the color.
        case plain
        /// The text in the color, edged in white (black for light colors), legible on anything.
        case outlined
        /// White (or black) text on a rounded label in the color.
        case label
    }

    /// The top left of the text, in pixels.
    public var origin: CGPoint
    public var string: String
    /// In points.
    public var fontSize: CGFloat
    public var look: Look
    /// Lines wrap at this width, in pixels; nil sizes the block to its longest line.
    public var width: CGFloat?

    public init(origin: CGPoint, string: String, fontSize: CGFloat = 20, look: Look = .plain, width: CGFloat? = nil) {
        self.origin = origin
        self.string = string
        self.fontSize = fontSize
        self.look = look
        self.width = width
    }
}

nonisolated public struct Counter: Codable, Sendable, Equatable {
    public enum Numbering: String, Codable, Sendable, CaseIterable {
        case numbers
        case letters
        case roman
    }

    public var center: CGPoint
    public var value: Int
    public var numbering: Numbering

    public init(center: CGPoint, value: Int, numbering: Numbering = .numbers) {
        self.center = center
        self.value = value
        self.numbering = numbering
    }

    /// What the counter shows: 1, 2, 3; A, B, … Z, AA; I, II, III.
    public var label: String {
        let value = max(self.value, 1)
        switch numbering {
        case .numbers:
            return String(value)
        case .letters:
            var remaining = value
            var letters = ""
            while remaining > 0 {
                remaining -= 1
                letters = String(UnicodeScalar(UInt8(65 + remaining % 26))) + letters
                remaining /= 26
            }
            return letters
        case .roman:
            let numerals: [(Int, String)] = [
                (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
            ]
            var remaining = min(value, 3999)
            var roman = ""
            for (amount, numeral) in numerals {
                while remaining >= amount {
                    roman += numeral
                    remaining -= amount
                }
            }
            return roman
        }
    }
}

nonisolated public struct Redaction: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        /// Covered with the color (black by default): nothing of what was there survives.
        case solid
        /// Blurred past reading.
        case blur
        /// Large blocks, each nudged by a little noise so the original cannot be worked back out.
        case pixelate
    }

    public var rect: CGRect
    public var method: Method

    public init(rect: CGRect, method: Method = .solid) {
        self.rect = rect
        self.method = method
    }
}

/// A picture combined into the capture, kept in the picture store.
nonisolated public struct PlacedImage: Codable, Sendable, Equatable {
    /// Where it lies, in pixels.
    public var rect: CGRect
    /// Its name in the picture store.
    public var name: String

    public init(rect: CGRect, name: String) {
        self.rect = rect
        self.name = name
    }
}

nonisolated public struct Spot: Codable, Sendable, Equatable {
    public var rect: CGRect
    public var oval: Bool

    public init(rect: CGRect, oval: Bool = false) {
        self.rect = rect
        self.oval = oval
    }
}

/// How a mark is drawn.
nonisolated public struct Style: Codable, Sendable, Equatable {
    public var color: RGBA
    /// In points. Counters grow with it.
    public var lineWidth: CGFloat
    /// A soft shadow under the mark, so it holds on busy pictures.
    public var shadow: Bool

    public init(color: RGBA = .red, lineWidth: CGFloat = 4, shadow: Bool = true) {
        self.color = color
        self.lineWidth = lineWidth
        self.shadow = shadow
    }
}

/// A color in sRGB.
nonisolated public struct RGBA: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a color in any space; nil when it cannot be converted to sRGB.
    public init?(_ color: CGColor) {
        guard
            let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
            let components = converted.components, components.count >= 3
        else { return nil }
        red = Double(components[0])
        green = Double(components[1])
        blue = Double(components[2])
        alpha = components.count > 3 ? Double(components[3]) : 1
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// These components read in `space` rather than sRGB: a color taken from a capture's own pixels.
    public func cgColor(in space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space, components: [red, green, blue, alpha].map { CGFloat($0) }) ?? cgColor
    }

    /// Relative luminance (WCAG), 0 for black to 1 for white.
    public var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Whether white or black reads better on this color: white unless the color is light.
    public var prefersDarkInk: Bool { luminance > 0.45 }

    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    // The system's colors, in sRGB, as marks are usually drawn.
    public static let red = RGBA(red: 1, green: 0.231, blue: 0.188)
    public static let orange = RGBA(red: 1, green: 0.584, blue: 0)
    public static let yellow = RGBA(red: 1, green: 0.8, blue: 0)
    public static let green = RGBA(red: 0.204, green: 0.78, blue: 0.349)
    public static let blue = RGBA(red: 0, green: 0.478, blue: 1)
    public static let purple = RGBA(red: 0.686, green: 0.322, blue: 0.871)
    public static let pink = RGBA(red: 1, green: 0.176, blue: 0.333)
    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)
    /// The marker yellow of the highlighter.
    public static let marker = RGBA(red: 1, green: 0.906, blue: 0.29)
}
