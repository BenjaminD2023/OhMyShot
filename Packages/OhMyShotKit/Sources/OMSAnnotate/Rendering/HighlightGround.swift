import CoreGraphics
import Foundation

/// What a highlight lies on, which decides how it takes to the picture. Light ground takes it multiplied,
/// as ink on paper: dark text stays dark and the ground takes the color. Dark ground takes a deep tint of
/// it screened, the same thing turned over: light text stays light and the ground takes the tint, where
/// multiplying would leave nothing to see.
nonisolated public enum HighlightGround: Sendable, Equatable {
    case light
    case dark

    /// The ground under `item` in `picture`, whose top-left corner is at `origin` in the document: dark
    /// when the shade that covers most of it is darker than mid-gray. The most common shade, not the
    /// average, so a line's glyphs do not count against the ground they stand on.
    static func under(_ item: Annotation, in picture: CGImage, origin: CGPoint, scale: CGFloat) -> HighlightGround {
        let bounds = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let squares = samples(of: item, scale: scale).compactMap { square -> CGRect? in
            let region = square.offsetBy(dx: -origin.x, dy: -origin.y).integral.intersection(bounds)
            return region.isNull || region.width < 1 || region.height < 1 ? nil : region
        }
        guard !squares.isEmpty else { return .light }
        // Each square read at 8 × 8, side by side in one strip: as quick for a highlight across the
        // picture as for one word.
        let slot = 8
        let width = squares.count * slot
        var shades = [UInt8](repeating: 255, count: width * slot)
        let drawn = shades.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: slot, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            for (index, region) in squares.enumerated() {
                guard let part = picture.cropping(to: region) else { continue }
                context.draw(part, in: CGRect(x: index * slot, y: 0, width: slot, height: slot))
            }
            return true
        }
        guard drawn else { return .light }
        var histogram = [Int](repeating: 0, count: 16)
        for shade in shades { histogram[Int(shade) >> 4] += 1 }
        let common = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 15
        return common < 8 ? .dark : .light
    }

    /// Squares that cover what `item` covers and little else, at most 48 spread evenly over it: along
    /// each band of a highlight snapped to text, as tall as the band; along a stroke, as wide as it. So a
    /// long stroke across the picture reads the strip it covers, not the whole box around it.
    private static func samples(of item: Annotation, scale: CGFloat) -> [CGRect] {
        var squares: [CGRect] = []
        func along(_ points: [CGPoint], side: CGFloat) {
            guard let first = points.first else { return }
            func square(_ point: CGPoint) {
                squares.append(CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
            }
            square(first)
            // How far along the line the last square is.
            var since: CGFloat = 0
            for (a, b) in zip(points, points.dropFirst()) {
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 0 else { continue }
                var distance = side - since
                while distance <= length {
                    square(CGPoint(x: a.x + (b.x - a.x) * distance / length, y: a.y + (b.y - a.y) * distance / length))
                    distance += side
                }
                since = length - (distance - side)
            }
            if since > side / 2, let last = points.last { square(last) }
        }
        switch item.shape {
        case .textHighlight(let highlight):
            for band in highlight.rects.map(\.standardized) where band.height > 0 {
                let side = min(band.height, band.width)
                along([CGPoint(x: band.minX + side / 2, y: band.midY), CGPoint(x: band.maxX - side / 2, y: band.midY)], side: side)
            }
        case .highlighter(let stroke):
            along(stroke.points, side: max(item.style.lineWidth * scale, 1))
        default:
            squares = [item.bounds(scale: scale)]
        }
        guard squares.count > 48 else { return squares }
        return (0..<48).map { squares[$0 * squares.count / 48] }
    }
}

nonisolated extension RGBA {
    /// The color as a highlight on dark ground: the same hue at a tenth of white's luminance, deep enough
    /// that light text over it stays readable. A color darker than that already is kept.
    public var deepTint: RGBA {
        let target = 0.1
        guard luminance > target else { return self }
        let factor = target / luminance
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func encoded(_ value: Double) -> Double {
            value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        return RGBA(red: encoded(linear(red) * factor), green: encoded(linear(green) * factor), blue: encoded(linear(blue) * factor), alpha: alpha)
    }
}
