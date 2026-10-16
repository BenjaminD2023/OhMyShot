import CoreGraphics
import Foundation

/// A shape to keep, width to height: All-In-One's area keeps one while it is resized, and Shift keeps one (a square
/// unless Settings say another) while an area is dragged out.
public struct AspectRatio: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// The sides a label may name: anything a screen's area could be, and nothing the shape math would choke on.
    private static let sides: ClosedRange<Double> = 0.01...100

    /// The ratio a label names ("16:9", "1.85:1"); nil for anything else, or a side outside 0.01 to 100.
    public init?(label: String) {
        let sides = label.split(separator: ":", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard sides.count == 2, let width = sides[0], let height = sides[1],
              Self.sides.contains(width), Self.sides.contains(height) else { return nil }
        self.init(width: width, height: height)
    }

    public var value: CGFloat { width / height }

    /// "16:9", "1:1", "1.85:1".
    public var label: String {
        func text(_ number: CGFloat) -> String {
            number.rounded() == number && abs(number) < 1e9 ? String(Int(number)) : String(format: "%.2f", number).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        }
        return "\(text(width)):\(text(height))"
    }

    /// A square, the shape Shift keeps unless Settings say another.
    public static let square = AspectRatio(width: 1, height: 1)

    /// The shapes the ratio menu offers: square, then landscape, then portrait.
    public static let presets: [AspectRatio] = [
        square,
        AspectRatio(width: 4, height: 3), AspectRatio(width: 3, height: 2), AspectRatio(width: 16, height: 10), AspectRatio(width: 16, height: 9),
        AspectRatio(width: 21, height: 9),
        AspectRatio(width: 3, height: 4), AspectRatio(width: 2, height: 3), AspectRatio(width: 9, height: 16),
    ]
}
