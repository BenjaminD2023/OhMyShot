import Foundation

/// What the ruler reads in: points, as interfaces are laid out (CSS pixels, Figma, SwiftUI), or the
/// display's pixels.
public enum MeasureUnit: String, CaseIterable, Sendable {
    case points
    case pixels

    /// The unit after a reading: "pt" or "px".
    public var symbol: String {
        switch self {
        case .points: "pt"
        case .pixels: "px"
        }
    }

    public var toggled: MeasureUnit {
        self == .points ? .pixels : .points
    }

    /// `pixels` in this unit, as a reading: "120 pt", "30.5 pt", "61 px".
    public func reading(_ pixels: Int, pixelsPerPoint: CGFloat) -> String {
        "\(number(pixels, pixelsPerPoint: pixelsPerPoint)) \(symbol)"
    }

    /// A box's size in this unit, as a reading: "48 × 48 pt".
    public func reading(width: Int, height: Int, pixelsPerPoint: CGFloat) -> String {
        "\(number(width, pixelsPerPoint: pixelsPerPoint)) × \(number(height, pixelsPerPoint: pixelsPerPoint)) \(symbol)"
    }

    /// Whole pixels, or points to a tenth, without a trailing ".0".
    private func number(_ pixels: Int, pixelsPerPoint: CGFloat) -> String {
        guard self == .points, pixelsPerPoint > 0 else { return "\(pixels)" }
        let tenths = (Double(pixels) / Double(pixelsPerPoint) * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))" : String(format: "%.1f", tenths / 10)
    }
}
