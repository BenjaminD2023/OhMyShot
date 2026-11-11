import CoreGraphics
import Foundation

/// What a background needs to know about a capture's edge: whether its corners are opaque (a window
/// captured with its shadow is not), the one color most of the edge shares, and where the capture
/// differs from that color, so a background can even out the room around it.
///
/// A deterministic function of the capture and the canvas, so the screen and an export agree.
nonisolated public struct EdgeAnalysis: Equatable, Sendable {
    /// Whether the capture's four corners are opaque.
    public var opaque: Bool
    /// The color most of the edge shares, in the capture's own color space; nil when no color holds
    /// most of it.
    public var edgeColor: RGBA?
    /// Where the capture differs from its edge color, in the document's pixels; nil when nothing does,
    /// or the edge has no one color.
    public var content: CGRect?
    /// The color canvas past the capture takes: the color the largest group of like colors along the
    /// edge starts from, whether or not it holds most of the edge, in the capture's own color space; nil
    /// when the edge has no opaque pixel.
    public var canvasColor: RGBA?

    public init(opaque: Bool, edgeColor: RGBA?, content: CGRect?, canvasColor: RGBA? = nil) {
        self.opaque = opaque
        self.edgeColor = edgeColor
        self.content = content
        self.canvasColor = canvasColor
    }

    /// The share of the edge one color must hold to count as the edge's color.
    static let dominantShare = 0.6
    /// How far a channel may stray (of 255) and still match the edge color.
    static let tolerance = 12
    /// How far apart two colors may be (of 255, green weighed most) and still be grouped together when
    /// choosing the canvas color.
    static let groupingDistance = 39

    /// Reads the part of `base` the canvas keeps (the document's pixels).
    public static func of(_ base: CGImage, canvas: CGRect) -> EdgeAnalysis {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let region = canvas.standardized.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1 else {
            return EdgeAnalysis(opaque: false, edgeColor: nil, content: nil)
        }
        let minX = Int(region.minX), minY = Int(region.minY)
        let width = Int(region.width), height = Int(region.height)
        guard
            let top = Bitmap(base, crop: CGRect(x: minX, y: minY, width: width, height: 1)),
            let bottom = Bitmap(base, crop: CGRect(x: minX, y: minY + height - 1, width: width, height: 1)),
            let left = Bitmap(base, crop: CGRect(x: minX, y: minY, width: 1, height: height)),
            let right = Bitmap(base, crop: CGRect(x: minX + width - 1, y: minY, width: 1, height: height))
        else { return EdgeAnalysis(opaque: true, edgeColor: nil, content: nil) }

        let corners = [top.pixel(0, 0), top.pixel(width - 1, 0), bottom.pixel(0, 0), bottom.pixel(width - 1, 0)]
        let opaque = corners.allSatisfy { $0.alpha == 255 }
        let canvasColor = commonColor(of: [top, bottom, left, right])

        // The most common color along the edge, counted in coarse buckets and averaged within its own.
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        var total = 0
        for strip in [top, bottom, left, right] {
            for y in 0..<strip.height {
                for x in 0..<strip.width {
                    let pixel = strip.pixel(x, y)
                    total += 1
                    guard pixel.alpha == 255 else { continue }
                    let key = Int(pixel.red >> 4) << 8 | Int(pixel.green >> 4) << 4 | Int(pixel.blue >> 4)
                    var bucket = buckets[key] ?? (0, 0, 0, 0)
                    bucket.count += 1
                    bucket.red += Int(pixel.red)
                    bucket.green += Int(pixel.green)
                    bucket.blue += Int(pixel.blue)
                    buckets[key] = bucket
                }
            }
        }
        guard let dominant = buckets.values.max(by: { $0.count < $1.count }), total > 0 else {
            return EdgeAnalysis(opaque: opaque, edgeColor: nil, content: nil, canvasColor: canvasColor)
        }
        let edge = Pixel(
            alpha: 255,
            red: UInt8(dominant.red / dominant.count),
            green: UInt8(dominant.green / dominant.count),
            blue: UInt8(dominant.blue / dominant.count)
        )
        var matching = 0
        for strip in [top, bottom, left, right] {
            for y in 0..<strip.height {
                for x in 0..<strip.width where strip.pixel(x, y).matches(edge) {
                    matching += 1
                }
            }
        }
        guard Double(matching) / Double(total) >= dominantShare else {
            return EdgeAnalysis(opaque: opaque, edgeColor: nil, content: nil, canvasColor: canvasColor)
        }
        let edgeColor = RGBA(red: Double(edge.red) / 255, green: Double(edge.green) / 255, blue: Double(edge.blue) / 255)

        // Where the capture stops being its edge color, read in bands from each side inward.
        guard let firstRow = firstLine(in: base, region: region, edge: edge, rows: true, forward: true) else {
            return EdgeAnalysis(opaque: opaque, edgeColor: edgeColor, content: nil, canvasColor: canvasColor)
        }
        let lastRow = firstLine(in: base, region: region, edge: edge, rows: true, forward: false) ?? firstRow
        let rows = CGRect(x: region.minX, y: CGFloat(firstRow), width: region.width, height: CGFloat(lastRow - firstRow + 1))
        let firstColumn = firstLine(in: base, region: rows, edge: edge, rows: false, forward: true) ?? minX
        let lastColumn = firstLine(in: base, region: rows, edge: edge, rows: false, forward: false) ?? (minX + width - 1)
        let content = CGRect(x: firstColumn, y: firstRow, width: lastColumn - firstColumn + 1, height: lastRow - firstRow + 1)
        return EdgeAnalysis(opaque: opaque, edgeColor: edgeColor, content: content, canvasColor: canvasColor)
    }

    /// The edge's most common color, as Shottr picks the color of canvas it adds: every opaque color along
    /// the edge counted exactly, the most common first, each joining the nearest group begun by a more
    /// common one within `groupingDistance` or beginning its own; the color that began the largest group.
    /// The distance weighs green most and blue least, as the eye does. Nil without an opaque pixel.
    static func commonColor(of strips: [Bitmap]) -> RGBA? {
        var counts: [UInt32: Int] = [:]
        for strip in strips {
            for y in 0..<strip.height {
                for x in 0..<strip.width {
                    let pixel = strip.pixel(x, y)
                    guard pixel.alpha == 255 else { continue }
                    counts[UInt32(pixel.red) << 16 | UInt32(pixel.green) << 8 | UInt32(pixel.blue), default: 0] += 1
                }
            }
        }
        // Ties go to the lower color, so the screen and an export always pick the same one.
        let colors = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var groups: [(color: UInt32, count: Int)] = []
        for (color, count) in colors {
            var nearest: (index: Int, distance: Int)?
            for (index, group) in groups.enumerated() {
                let distance = Self.distance(color, group.color)
                if distance < (nearest?.distance ?? .max) { nearest = (index, distance) }
            }
            if let nearest, nearest.distance <= groupingDistance {
                groups[nearest.index].count += count
            } else {
                groups.append((color, count))
            }
        }
        // The first of the largest, which began with the more common color.
        guard let largest = groups.enumerated().max(by: { $0.element.count != $1.element.count ? $0.element.count < $1.element.count : $0.offset > $1.offset }) else {
            return nil
        }
        let color = largest.element.color
        return RGBA(red: Double(color >> 16 & 0xFF) / 255, green: Double(color >> 8 & 0xFF) / 255, blue: Double(color & 0xFF) / 255)
    }

    /// How far apart two colors packed as 0xRRGGBB look, of 255: three tenths red, half green, a fifth blue.
    private static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        let red = abs(Int(a >> 16 & 0xFF) - Int(b >> 16 & 0xFF))
        let green = abs(Int(a >> 8 & 0xFF) - Int(b >> 8 & 0xFF))
        let blue = abs(Int(a & 0xFF) - Int(b & 0xFF))
        return (3 * red + 5 * green + 2 * blue) / 10
    }

    /// The first row (or column) of `region`, from its start or its end, holding a pixel that is not the
    /// edge color; in the capture's pixels. Read in bands, so a large capture is never copied whole.
    private static func firstLine(in base: CGImage, region: CGRect, edge: Pixel, rows: Bool, forward: Bool) -> Int? {
        let band = rows ? 32 : 64
        let length = Int(rows ? region.height : region.width)
        var done = 0
        while done < length {
            let count = min(band, length - done)
            let start = forward ? done : length - done - count
            let crop = rows
                ? CGRect(x: Int(region.minX), y: Int(region.minY) + start, width: Int(region.width), height: count)
                : CGRect(x: Int(region.minX) + start, y: Int(region.minY), width: count, height: Int(region.height))
            guard let bitmap = Bitmap(base, crop: crop) else { return nil }
            let found: Int? = bitmap.bytes.withUnsafeBufferPointer { bytes in
                for step in 0..<count {
                    let line = forward ? step : count - 1 - step
                    let differs = rows
                        ? (0..<bitmap.width).contains { !edge.matches(bytes, at: line * bitmap.rowBytes + $0 * 4) }
                        : (0..<bitmap.height).contains { !edge.matches(bytes, at: $0 * bitmap.rowBytes + line * 4) }
                    if differs { return line }
                }
                return nil
            }
            if let found {
                return (rows ? Int(region.minY) : Int(region.minX)) + start + found
            }
            done += count
        }
        return nil
    }
}

/// One pixel of a `Bitmap`, premultiplied.
nonisolated struct Pixel: Equatable {
    var alpha: UInt8
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    /// Opaque and within the edge tolerance of `other` in every channel.
    func matches(_ other: Pixel) -> Bool {
        let tolerance = EdgeAnalysis.tolerance
        return alpha == 255
            && abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
    }

    /// Whether the pixel at byte `index` of a bitmap's bytes matches this one, as `matches(_:)`: the
    /// scans for content read millions of pixels, so this skips building them.
    @inline(__always)
    func matches(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        let pixel = base + index
        if pixel[0] != 255 { return false }
        let tolerance = EdgeAnalysis.tolerance
        return abs(Int(pixel[1]) - Int(red)) <= tolerance
            && abs(Int(pixel[2]) - Int(green)) <= tolerance
            && abs(Int(pixel[3]) - Int(blue)) <= tolerance
    }
}

nonisolated extension Bitmap {
    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let index = y * rowBytes + x * 4
        return Pixel(alpha: bytes[index], red: bytes[index + 1], green: bytes[index + 2], blue: bytes[index + 3])
    }
}
