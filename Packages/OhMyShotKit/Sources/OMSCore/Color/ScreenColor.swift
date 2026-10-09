import CoreGraphics
import Foundation

/// A color read off the screen, in the two spaces people ask for: sRGB, which hex, rgb(), and hsl() are
/// written in, and Display P3, which Mac displays show. sRGB is kept extended, so a P3 color outside it
/// keeps its true OKLCH; only its sRGB notations are clamped.
public struct ScreenColor: Sendable, Equatable {
    /// Extended sRGB, gamma-encoded: outside 0...1 for colors sRGB cannot show.
    public let red: Double
    public let green: Double
    public let blue: Double
    /// Display P3, gamma-encoded.
    public let p3Red: Double
    public let p3Green: Double
    public let p3Blue: Double

    /// `color` in sRGB and Display P3, from whatever space it is in; nil if it cannot be converted.
    public init?(_ color: CGColor) {
        guard
            let srgbSpace = CGColorSpace(name: CGColorSpace.extendedSRGB),
            let p3Space = CGColorSpace(name: CGColorSpace.extendedDisplayP3),
            let srgb = color.converted(to: srgbSpace, intent: .defaultIntent, options: nil)?.components, srgb.count >= 3,
            let p3 = color.converted(to: p3Space, intent: .defaultIntent, options: nil)?.components, p3.count >= 3
        else { return nil }
        red = Double(srgb[0])
        green = Double(srgb[1])
        blue = Double(srgb[2])
        p3Red = Double(p3[0])
        p3Green = Double(p3[1])
        p3Blue = Double(p3[2])
    }

    /// An sRGB color, 0...1.
    public init?(srgbRed red: Double, green: Double, blue: Double) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(colorSpace: space, components: [red, green, blue, 1]) else { return nil }
        self.init(color)
    }

    /// The color as Display P3, which holds every color a Mac display shows.
    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [p3Red, p3Green, p3Blue, 1])!
    }

    /// Whether sRGB can show the color, so its sRGB notations are as good as exact.
    public var isInSRGB: Bool {
        // Three steps of slack, about 1 percent: an sRGB color read off an 8-bit Display P3 frame comes back
        // a little past the edges, which no one could see.
        let slack: Double = 3 / 255
        return [red, green, blue].allSatisfy { (channel: Double) in channel > -slack && channel < 1 + slack }
    }

    // MARK: Notations

    public func string(in format: ColorFormat) -> String {
        switch format {
        case .hex: hex
        case .rgb: rgb
        case .hsl: hsl
        case .oklch: oklch
        case .displayP3: displayP3
        }
    }

    /// "#3366FF", clamped to sRGB.
    public var hex: String {
        let bytes = clampedSRGB.map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    /// "rgb(51, 102, 255)", clamped to sRGB.
    public var rgb: String {
        let bytes = clampedSRGB.map { Int(($0 * 255).rounded()) }
        return "rgb(\(bytes[0]), \(bytes[1]), \(bytes[2]))"
    }

    /// "hsl(225, 100%, 60%)", clamped to sRGB.
    public var hsl: String {
        let (hue, saturation, lightness) = hslComponents
        return "hsl(\(Int(hue.rounded()) % 360), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
    }

    /// "oklch(62.8% 0.258 29.2)", from the unclamped color, so it holds for P3 colors too.
    public var oklch: String {
        let (lightness, chroma, hue) = oklchComponents
        // Below this chroma the hue says nothing: grays are written with hue 0.
        let gray = chroma < 0.0005
        return "oklch(\(Self.number(lightness * 100, places: 1))% \(gray ? "0" : Self.number(chroma, places: 3)) \(gray ? "0" : Self.number(hue, places: 1)))"
    }

    /// "color(display-p3 0.271 0.392 0.961)".
    public var displayP3: String {
        let values = [p3Red, p3Green, p3Blue].map { Self.number(min(max($0, 0), 1), places: 3) }
        return "color(display-p3 \(values.joined(separator: " ")))"
    }

    /// Hue in degrees, saturation and lightness 0...1, of the clamped sRGB color.
    public var hslComponents: (hue: Double, saturation: Double, lightness: Double) {
        let channels = clampedSRGB
        let (r, g, b) = (channels[0], channels[1], channels[2])
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 1e-9 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maximum == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    /// OKLCH lightness 0...1, chroma, and hue in degrees, from the unclamped color (Björn Ottosson's Oklab).
    public var oklchComponents: (lightness: Double, chroma: Double, hue: Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (lightness, (a * a + bb * bb).squareRoot(), hue)
    }

    // MARK: Contrast

    /// WCAG 2's contrast ratio between two colors, 1...21, from their clamped sRGB.
    public func wcagContrast(with other: ScreenColor) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The ratio as people read it, "4.6:1": rounded down, so a color that fails never reads as passing.
    public static func ratioText(_ ratio: Double) -> String {
        "\(number((ratio * 10).rounded(.down) / 10, places: 1)):1"
    }

    /// APCA's lightness contrast (APCA-W3 0.0.98G-4g) of `text` on `background`: about 0 to 106 for dark
    /// text on a light background, about 0 to -108 for light text on a dark one.
    public static func apcaContrast(text: ScreenColor, background: ScreenColor) -> Double {
        let textY = text.apcaLuminance, backgroundY = background.apcaLuminance
        guard abs(backgroundY - textY) >= 0.0005 else { return 0 }
        if backgroundY > textY {
            let contrast = (pow(backgroundY, 0.56) - pow(textY, 0.57)) * 1.14
            return contrast < 0.1 ? 0 : (contrast - 0.027) * 100
        } else {
            let contrast = (pow(backgroundY, 0.65) - pow(textY, 0.62)) * 1.14
            return contrast > -0.1 ? 0 : (contrast + 0.027) * 100
        }
    }

    /// WCAG 2's relative luminance.
    var luminance: Double {
        let channels = clampedSRGB.map(Self.linear)
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    /// APCA's screen luminance: a plain 2.4 gamma, with the soft clamp near black.
    private var apcaLuminance: Double {
        let channels = clampedSRGB
        let y = 0.2126729 * pow(channels[0], 2.4) + 0.7151522 * pow(channels[1], 2.4) + 0.0721750 * pow(channels[2], 2.4)
        return y < 0.022 ? y + pow(0.022 - y, 1.414) : y
    }

    // MARK: Helpers

    private var clampedSRGB: [Double] {
        [red, green, blue].map { min(max($0, 0), 1) }
    }

    /// The sRGB transfer function, inverted; odd, so extended values keep their sign.
    private static func linear(_ value: Double) -> Double {
        let magnitude = abs(value)
        let result = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return value < 0 ? -result : result
    }

    /// `value` with at most `places` decimals, trailing zeros dropped ("0.25", "29.2", "100").
    static func number(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

/// How a picked color goes to the clipboard.
public enum ColorFormat: String, CaseIterable, Sendable {
    case hex
    case rgb
    case hsl
    case oklch
    case displayP3

    /// The notation's name; the same in every language.
    public var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .oklch: "OKLCH"
        case .displayP3: "Display P3"
        }
    }
}
