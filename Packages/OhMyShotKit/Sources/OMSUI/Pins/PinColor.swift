import CoreGraphics
import Foundation
import OMSCore

/// A pinned color: the color as it came, for the swatch, and its sRGB/Display P3 values for readings. A color
/// outside sRGB (Display P3 or wide-gamut OKLCH, say) shows as itself, keeps its true Display P3 & OKLCH
/// readings via `ScreenColor`, and clamps only its sRGB notations.
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

    /// A color from anywhere (the pasteboard's, a picked one), converted to sRGB for its clamped readings while
    /// preserving `color` in its original color space.
    public init?(_ color: CGColor) {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let srgb = color.converted(to: space, intent: .defaultIntent, options: nil),
            let parts = srgb.components, parts.count >= 3
        else { return nil }
        red = Self.unit(parts[0])
        green = Self.unit(parts[1])
        blue = Self.unit(parts[2])
        alpha = Self.unit(parts.count > 3 ? parts[3] : color.alpha)
        original = color
    }

    /// Full wide-gamut color representation backed by `ScreenColor` (`OMSCore`).
    public var screenColor: ScreenColor {
        ScreenColor(original) ?? ScreenColor(srgbRed: red, green: green, blue: blue)!
    }

    /// Formatted value in any `ColorFormat` (`HEX`, `RGB`, `HSL`, `OKLCH`, `Display P3`).
    public func string(in format: ColorFormat) -> String {
        switch format {
        case .hex: hex
        case .rgb: rgb
        case .hsl: hsl
        case .oklch: oklch
        case .displayP3: displayP3
        }
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
        return "rgba(\(channels), \(Self.alphaString(alpha)))"
    }

    /// "hsl(225, 100%, 60%)", or "hsla(225, 100%, 60%, 0.5)" when it is not opaque.
    public var hsl: String {
        let color = screenColor
        guard alpha < 1 else { return color.hsl }
        let (hue, saturation, lightness) = color.hslComponents
        return "hsla(\(Int(hue.rounded()) % 360), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%, \(Self.alphaString(alpha)))"
    }

    /// "oklch(62.8% 0.258 29.2)", or with `/ alpha` when it is not opaque.
    public var oklch: String {
        let base = screenColor.oklch
        guard alpha < 1, base.hasSuffix(")") else { return base }
        return "\(base.dropLast()) / \(Self.alphaString(alpha)))"
    }

    /// "color(display-p3 0.271 0.392 0.961)", or with `/ alpha` when it is not opaque.
    public var displayP3: String {
        let base = screenColor.displayP3
        guard alpha < 1, base.hasSuffix(")") else { return base }
        return "\(base.dropLast()) / \(Self.alphaString(alpha)))"
    }

    /// The color a whole string spells, and nothing else: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`,
    /// `rgb(...)`, `rgba(...)`, `hsl(...)`, `hsla(...)`, `oklch(...)`, or `color(display-p3 ...)`,
    /// surrounding space allowed. A bare number is not a color.
    public static func parse(_ text: String) -> PinColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { return parseHex(String(trimmed.dropFirst())) }
        let lowered = trimmed.lowercased()
        guard lowered.hasSuffix(")") else { return nil }
        if lowered.hasPrefix("rgba(") { return parseRGB(lowered.dropFirst(5).dropLast()) }
        if lowered.hasPrefix("rgb(") { return parseRGB(lowered.dropFirst(4).dropLast()) }
        if lowered.hasPrefix("hsla(") { return parseHSL(lowered.dropFirst(5).dropLast()) }
        if lowered.hasPrefix("hsl(") { return parseHSL(lowered.dropFirst(4).dropLast()) }
        if lowered.hasPrefix("oklch(") { return parseOKLCH(lowered.dropFirst(6).dropLast()) }
        if lowered.hasPrefix("color(") { return parseColorFunction(lowered.dropFirst(6).dropLast()) }
        return nil
    }

    private static func parseHex(_ digits: String) -> PinColor? {
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

    private static func parseRGB(_ inside: Substring) -> PinColor? {
        let parts = tokenize(inside)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        var channels: [Double] = []
        for part in parts.prefix(3) {
            if part.hasSuffix("%"), let percent = Double(part.dropLast()), (0...100).contains(percent) {
                channels.append(percent / 100)
            } else if let value = Double(part), (0...255).contains(value) {
                channels.append(value / 255)
            } else {
                return nil
            }
        }
        guard let alpha = parts.count == 4 ? parseAlpha(parts[3]) : 1.0 else { return nil }
        return PinColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }

    private static func parseHSL(_ inside: Substring) -> PinColor? {
        let parts = tokenize(inside)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let hue = parseAngle(parts[0]),
              parts[1].hasSuffix("%"), let satPct = Double(parts[1].dropLast()), (0...100).contains(satPct),
              parts[2].hasSuffix("%"), let lightPct = Double(parts[2].dropLast()), (0...100).contains(lightPct)
        else { return nil }
        guard let alpha = parts.count == 4 ? parseAlpha(parts[3]) : 1.0 else { return nil }

        let s = satPct / 100
        let l = lightPct / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = hue / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) = switch Int(floor(hPrime)) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return PinColor(srgbRed: r1 + m, green: g1 + m, blue: b1 + m, alpha: alpha)
    }

    private static func parseOKLCH(_ inside: Substring) -> PinColor? {
        let parts = tokenize(inside)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let lightness: Double
        if parts[0] == "none" {
            lightness = 0
        } else if parts[0].hasSuffix("%"), let pct = Double(parts[0].dropLast()), (0...100).contains(pct) {
            lightness = pct / 100
        } else if let value = Double(parts[0]), (0...1).contains(value) {
            lightness = value
        } else {
            return nil
        }
        let chroma: Double
        if parts[1] == "none" {
            chroma = 0
        } else if parts[1].hasSuffix("%"), let pct = Double(parts[1].dropLast()), (0...100).contains(pct) {
            chroma = pct / 100 * 0.4
        } else if let value = Double(parts[1]), value >= 0, value <= 1 {
            chroma = value
        } else {
            return nil
        }
        let hue: Double
        if parts[2] == "none" {
            hue = 0
        } else if let angle = parseAngle(parts[2]) {
            hue = angle
        } else {
            return nil
        }
        guard let alpha = parts.count == 4 ? parseAlpha(parts[3]) : 1.0 else { return nil }

        // Inverse of Björn Ottosson's Oklab transform (matching `ScreenColor.oklchComponents`).
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let bb = chroma * sin(radians)
        let l_ = lightness + 0.3963377774 * a + 0.2158037573 * bb
        let m_ = lightness - 0.1055613458 * a - 0.0638541728 * bb
        let s_ = lightness - 0.0894841775 * a - 1.2914855480 * bb
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let linearR = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let linearG = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let linearB = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        let gammaR = srgbGamma(linearR)
        let gammaG = srgbGamma(linearG)
        let gammaB = srgbGamma(linearB)
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let extended = CGColor(colorSpace: space, components: [gammaR, gammaG, gammaB, alpha])
        else { return nil }
        return PinColor(extended)
    }

    private static func parseColorFunction(_ inside: Substring) -> PinColor? {
        let parts = tokenize(inside)
        guard parts.count == 4 || parts.count == 5, parts[0] == "display-p3" else { return nil }
        var channels: [Double] = []
        for part in parts[1...3] {
            if part == "none" {
                channels.append(0)
            } else if part.hasSuffix("%"), let pct = Double(part.dropLast()), (0...100).contains(pct) {
                channels.append(pct / 100)
            } else if let value = Double(part), (0...1).contains(value) {
                channels.append(value)
            } else {
                return nil
            }
        }
        guard let alpha = parts.count == 5 ? parseAlpha(parts[4]) : 1.0,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let p3 = CGColor(colorSpace: space, components: [channels[0], channels[1], channels[2], alpha])
        else { return nil }
        return PinColor(p3)
    }

    private static func tokenize(_ inside: Substring) -> [String] {
        inside
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
            .map(String.init)
    }

    private static func parseAlpha(_ raw: String) -> Double? {
        if raw.hasSuffix("%"), let percent = Double(raw.dropLast()), (0...100).contains(percent) {
            return percent / 100
        }
        if let value = Double(raw), (0...1).contains(value) {
            return value
        }
        return nil
    }

    private static func parseAngle(_ raw: String) -> Double? {
        let degrees: Double
        if raw.hasSuffix("deg"), let value = Double(raw.dropLast(3)) {
            degrees = value
        } else if raw.hasSuffix("rad"), let value = Double(raw.dropLast(3)) {
            degrees = value * 180 / .pi
        } else if raw.hasSuffix("grad"), let value = Double(raw.dropLast(4)) {
            degrees = value * 0.9
        } else if raw.hasSuffix("turn"), let value = Double(raw.dropLast(4)) {
            degrees = value * 360
        } else if let value = Double(raw) {
            degrees = value
        } else {
            return nil
        }
        guard degrees.isFinite else { return nil }
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return normalized
    }

    private static func srgbGamma(_ value: Double) -> Double {
        let magnitude = abs(value)
        let result = magnitude <= 0.0031308 ? 12.92 * magnitude : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return value < 0 ? -result : result
    }

    private static func alphaString(_ alpha: Double) -> String {
        let opacity = (alpha * 100).rounded() / 100
        return opacity.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }
}
