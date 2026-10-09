import CoreGraphics
import Foundation

/// A pinned color: the color as it came, for the swatch, and its sRGB value for the readings. A color
/// outside sRGB (Display P3, say) shows as itself, and its hex is the clamped sRGB value, nothing more
/// precise than that.
public struct PinColor {
    /// sRGB components, 0...1.
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    /// The color as it came, in its own color space.
    public let original: CGColor

    public init(srgbRed red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.alpha = Self.unit(alpha)
        original = CGColor(srgbRed: self.red, green: self.green, blue: self.blue, alpha: self.alpha)
    }

    /// A color from anywhere (the pasteboard's, a picked one), converted to sRGB for its readings.
    public init?(_ color: CGColor) {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let srgb = color.converted(to: space, intent: .defaultIntent, options: nil),
            let parts = srgb.components, parts.count >= 3
        else { return nil }
        red = Self.unit(parts[0])
        green = Self.unit(parts[1])
        blue = Self.unit(parts[2])
        alpha = Self.unit(parts.count > 3 ? parts[3] : 1)
        original = color
    }

    /// "#3366FF", or "#3366FF80" when it is not opaque.
    public var hex: String {
        let base = String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
        return alpha < 1 ? base + String(format: "%02X", Self.byte(alpha)) : base
    }

    /// "rgb(51, 102, 255)", or "rgba(51, 102, 255, 0.5)" when it is not opaque.
    public var rgb: String {
        let channels = "\(Self.byte(red)), \(Self.byte(green)), \(Self.byte(blue))"
        guard alpha < 1 else { return "rgb(\(channels))" }
        let opacity = (alpha * 100).rounded() / 100
        return "rgba(\(channels), \(opacity.formatted(.number.precision(.fractionLength(0...2)))))"
    }

    /// The color a whole string spells, and nothing else: "#RGB", "#RGBA", "#RRGGBB", "#RRGGBBAA",
    /// "rgb(r, g, b)", or "rgba(r, g, b, a)", surrounding space allowed. A bare number is not a color.
    public static func parse(_ text: String) -> PinColor? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { return hex(String(text.dropFirst())) }
        return function(text)
    }

    private static func hex(_ digits: String) -> PinColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        var bytes: [Double] = []
        var index = expanded.startIndex
        while index < expanded.endIndex {
            let next = expanded.index(index, offsetBy: 2)
            guard let byte = UInt8(expanded[index..<next], radix: 16) else { return nil }
            bytes.append(Double(byte) / 255)
            index = next
        }
        return PinColor(srgbRed: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count > 3 ? bytes[3] : 1)
    }

    private static func function(_ text: String) -> PinColor? {
        let lowered = text.lowercased()
        let name = lowered.hasPrefix("rgba(") ? "rgba(" : lowered.hasPrefix("rgb(") ? "rgb(" : nil
        guard let name, lowered.hasSuffix(")") else { return nil }
        let inside = lowered.dropFirst(name.count).dropLast()
        let parts = inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        var channels: [Double] = []
        for part in parts.prefix(3) {
            guard let value = Double(part), value >= 0, value <= 255 else { return nil }
            channels.append(value / 255)
        }
        var alpha = 1.0
        if parts.count == 4 {
            let raw = parts[3]
            if raw.hasSuffix("%"), let percent = Double(raw.dropLast()), (0...100).contains(percent) {
                alpha = percent / 100
            } else if let value = Double(raw), (0...1).contains(value) {
                alpha = value
            } else {
                return nil
            }
        }
        return PinColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }
}
