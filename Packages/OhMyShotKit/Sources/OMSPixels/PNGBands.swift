import CoreGraphics
import Foundation

/// A PNG's rows, a run of them at a time, inflated as the file is read and laid out as ImageIO decodes them: a tall
/// picture can then be read in pieces without ever being decoded whole (Docs/perf.md › M6 — Pieces of a tall PNG).
///
/// Runs come in order, top to bottom, each starting no more than `overlap` rows before the furthest row read so far.
/// Only kinds whose layout is known are read here: not interlaced (Adam7 spreads every row over the whole file), no
/// transparency chunk (which turns ImageIO's layout into RGBA), and before the pixels no chunk but those that leave them
/// as they are. Anything else gives nil, for the caller to decode the picture another way.
public final class PNGBands {
    /// How the rows are laid out, as ImageIO lays out the decoded picture: 16-bit samples little-endian, RGB with a
    /// fourth byte, gray under 8 bits scaled up to 8, a palette's indices one a byte.
    public struct Layout: Equatable, Sendable {
        public var bitsPerComponent: Int
        public var bitsPerPixel: Int
        public var bitmapInfo: CGBitmapInfo
    }

    public let width: Int
    public let height: Int
    public let layout: Layout
    /// Bytes a row takes, laid out.
    public let bytesPerRow: Int
    /// Whether the picture is a palette's indices.
    public let isIndexed: Bool

    /// The chunks that may come before the pixels: they say what the pixels mean, never what they are.
    static let neutralChunks: Set<String> = [
        "IHDR", "PLTE", "iCCP", "sRGB", "cICP", "gAMA", "cHRM", "sBIT", "bKGD", "pHYs", "tEXt", "zTXt", "iTXt", "tIME", "eXIf",
    ]

    private enum Conversion { case copy, swap16, rgbx, unpack(scale: Int) }

    private let conversion: Conversion
    private let bitDepth: Int
    private let reader: PNGThumbnail.RowReader
    /// The row before and the row being unfiltered, as they are in the file (no filter byte).
    private var previous: UnsafeMutablePointer<UInt8>
    private var current: UnsafeMutablePointer<UInt8>
    private let rawBytes: Int
    private let filterUnit: Int
    /// The next row of the file to read.
    private var nextRow = 0
    /// The last `overlap` rows read, laid out, row `r` at `r % overlap`: a run may start among them.
    private let overlap: Int
    private let window: UnsafeMutablePointer<UInt8>

    /// The rows of the PNG in `data`, or nil when it is not a PNG of a kind read here. A run may start up to `overlap`
    /// rows before the furthest row read.
    public init?(data: Data, overlap: Int) {
        guard let header = PNGThumbnail.Header(data), header.width > 0, header.height > 0, !header.interlaced,
              header.methods == (0, 0), header.chunks.allSatisfy(Self.neutralChunks.contains)
        else { return nil }
        let depth = header.bitDepth
        let conversion: Conversion, layout: Layout
        let little = CGBitmapInfo.byteOrder16Little.rawValue
        switch (header.colorType, depth) {
        case (6, 8): (conversion, layout) = (.copy, Layout(bitsPerComponent: 8, bitsPerPixel: 32, alpha: .last))
        case (6, 16): (conversion, layout) = (.swap16, Layout(bitsPerComponent: 16, bitsPerPixel: 64, alpha: .last, order: little))
        case (2, 8): (conversion, layout) = (.rgbx, Layout(bitsPerComponent: 8, bitsPerPixel: 32, alpha: .noneSkipLast))
        case (2, 16): (conversion, layout) = (.swap16, Layout(bitsPerComponent: 16, bitsPerPixel: 48, alpha: .none, order: little))
        case (4, 8): (conversion, layout) = (.copy, Layout(bitsPerComponent: 8, bitsPerPixel: 16, alpha: .last))
        case (4, 16): (conversion, layout) = (.swap16, Layout(bitsPerComponent: 16, bitsPerPixel: 32, alpha: .last, order: little))
        case (0, 8), (3, 8): (conversion, layout) = (.copy, Layout(bitsPerComponent: 8, bitsPerPixel: 8, alpha: .none))
        case (0, 16): (conversion, layout) = (.swap16, Layout(bitsPerComponent: 16, bitsPerPixel: 16, alpha: .none, order: little))
        case (0, 1), (0, 2), (0, 4): (conversion, layout) = (.unpack(scale: 255 / ((1 << depth) - 1)), Layout(bitsPerComponent: 8, bitsPerPixel: 8, alpha: .none))
        case (3, 1), (3, 2), (3, 4): (conversion, layout) = (.unpack(scale: 1), Layout(bitsPerComponent: 8, bitsPerPixel: 8, alpha: .none))
        default: return nil
        }
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][header.colorType]!
        width = header.width
        height = header.height
        self.layout = layout
        self.conversion = conversion
        bitDepth = depth
        isIndexed = header.colorType == 3
        bytesPerRow = width * layout.bitsPerPixel / 8
        rawBytes = (width * channels * depth + 7) / 8
        filterUnit = max(1, channels * depth / 8)
        reader = PNGThumbnail.RowReader(header, rowBytes: 1 + rawBytes)
        previous = .allocate(capacity: rawBytes)
        current = .allocate(capacity: rawBytes)
        previous.initialize(repeating: 0, count: rawBytes)
        current.initialize(repeating: 0, count: rawBytes)
        self.overlap = max(overlap, 1)
        window = .allocate(capacity: self.overlap * bytesPerRow)
    }

    deinit {
        previous.deallocate()
        current.deallocate()
        window.deallocate()
    }

    /// The pixels of `rows`, laid out, `bytesPerRow` a row; nil when the file ends or is damaged before their end, or
    /// when they start further back than `overlap` rows before the furthest row read.
    public func rows(_ rows: Range<Int>) -> CGDataProvider? {
        guard !rows.isEmpty, rows.upperBound <= height, rows.lowerBound >= nextRow - min(overlap, nextRow) else { return nil }
        let size = rows.count * bytesPerRow
        // A CFData, which nothing autoreleases: an NSMutableData's `mutableBytes` comes with the data autoreleased, and a
        // task drains no pool until it ends.
        guard let data = CFDataCreateMutable(nil, size) else { return nil }
        CFDataSetLength(data, size)
        guard CFDataGetLength(data) == size, let bytes = CFDataGetMutableBytePtr(data) else { return nil }
        var row = rows.lowerBound
        // Rows read already, from the window.
        while row < min(nextRow, rows.upperBound) {
            (bytes + (row - rows.lowerBound) * bytesPerRow).update(from: window + row % overlap * bytesPerRow, count: bytesPerRow)
            row += 1
        }
        // Rows between, read and dropped.
        while nextRow < row {
            guard readRow() != nil else { return nil }
        }
        while row < rows.upperBound {
            guard let laid = readRow() else { return nil }
            (bytes + (row - rows.lowerBound) * bytesPerRow).update(from: laid, count: bytesPerRow)
            row += 1
        }
        return CGDataProvider(data: data)
    }

    /// Reads the next row of the file, lays it out into the window, and gives it there.
    private func readRow() -> UnsafePointer<UInt8>? {
        guard let raw = reader.next() else { return nil }
        PNGThumbnail.unfilter(raw, into: current, above: previous, length: rawBytes, bytesPerPixel: filterUnit)
        let laid = window + nextRow % overlap * bytesPerRow
        lay(current, into: laid)
        swap(&previous, &current)
        nextRow += 1
        return UnsafePointer(laid)
    }

    private func lay(_ row: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>) {
        switch conversion {
        case .copy:
            destination.update(from: row, count: rawBytes)
        case .swap16:
            for i in stride(from: 0, to: rawBytes, by: 2) {
                destination[i] = row[i + 1]
                destination[i + 1] = row[i]
            }
        case .rgbx:
            for x in 0 ..< width {
                let from = row + x * 3, to = destination + x * 4
                to[0] = from[0]; to[1] = from[1]; to[2] = from[2]; to[3] = 255
            }
        case .unpack(let scale):
            let perByte = 8 / bitDepth, mask = UInt8((1 << bitDepth) - 1)
            for x in 0 ..< width {
                let shift = 8 - bitDepth * (x % perByte + 1)
                destination[x] = (row[x / perByte] >> shift & mask) &* UInt8(scale)
            }
        }
    }
}

extension PNGBands.Layout {
    init(bitsPerComponent: Int, bitsPerPixel: Int, alpha: CGImageAlphaInfo, order: UInt32 = 0) {
        self.init(bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | order))
    }
}
