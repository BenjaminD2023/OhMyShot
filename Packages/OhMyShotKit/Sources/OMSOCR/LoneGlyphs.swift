import CoreGraphics
import Foundation

/// Finds rows of a code listing that hold a glyph or two and nothing Vision read: closing brackets alone
/// on their lines, which neither Vision's recognizer nor its text detector reports.
enum LoneGlyphs {
    /// - Parameters:
    ///   - lines: what was read, in image pixels with a top-left origin.
    ///   - characterWidth: the width of one character of the listing's monospaced font.
    /// - Returns: the box of each unread row narrow enough to be one or two characters.
    static func find(in image: CGImage, around lines: [OCRLine], characterWidth: CGFloat) -> [CGRect] {
        guard let first = lines.first else { return [] }
        let listing = lines.dropFirst().reduce(first.box) { $0.union($1.box) }
        let rowHeight = lines.map(\.box.height).sorted()[lines.count / 2]
        // From the listing's first row to the bottom of the image: the last closing brace sits below
        // every line that was read.
        let area = CGRect(
            x: listing.minX - characterWidth,
            y: listing.minY,
            width: listing.width + characterWidth * 2,
            height: CGFloat(image.height) - listing.minY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !area.isNull, area.width >= 4, area.height >= 4, let ink = InkGrid(image: image, area: area) else { return [] }

        // Bands of rows that hold ink, with a pixel or two of slack for antialiasing.
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        var blank = 0
        for y in 0..<ink.height {
            if ink.rowHasInk(y) {
                if start == nil { start = y }
                blank = 0
            } else if let open = start {
                blank += 1
                if blank > 2 {
                    bands.append(open...(y - blank))
                    start = nil
                }
            }
        }
        if let open = start { bands.append(open...(ink.height - 1)) }

        return bands.compactMap { band -> CGRect? in
            let top = area.minY + CGFloat(band.lowerBound)
            let height = CGFloat(band.count)
            guard height >= rowHeight * 0.4, height <= rowHeight * 1.6 else { return nil }
            // Rows a read line already covers are not lone.
            let covered = lines.contains { line in
                let overlap = min(line.box.maxY, top + height) - max(line.box.minY, top)
                return overlap > height * 0.3
            }
            guard !covered, let columns = ink.inkColumns(in: band) else { return nil }
            let width = CGFloat(columns.count)
            guard width <= characterWidth * 2.2 else { return nil }
            return CGRect(x: area.minX + CGFloat(columns.lowerBound), y: top, width: width, height: height)
        }
    }
}

/// Which pixels of an area hold ink, against the area's background (its most common shade, which in a
/// code listing is the editor's background).
struct InkGrid {
    let width: Int
    let height: Int
    private let ink: [Bool]

    init?(image: CGImage, area: CGRect) {
        guard let cropped = image.cropping(to: area) else { return nil }
        width = Int(area.width)
        height = Int(area.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let (w, h) = (width, height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let background = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        ink = pixels.map { abs(Int($0) - background) > 48 }
    }

    func rowHasInk(_ y: Int) -> Bool {
        (0..<width).contains { ink[y * width + $0] }
    }

    /// The span of columns with ink within a band of rows.
    func inkColumns(in rows: ClosedRange<Int>) -> ClosedRange<Int>? {
        var first: Int?
        var last: Int?
        for x in 0..<width where rows.contains(where: { ink[$0 * width + x] }) {
            if first == nil { first = x }
            last = x
        }
        guard let first, let last else { return nil }
        return first...last
    }
}
