import CoreGraphics
import Foundation
import ImageIO
import OMSPixels

/// How a large picture is cut up to be read, and a picture's text read for finding it again later (Capture
/// History's search): every line the L1 pipeline reads, in reading order.
///
/// A large picture is read in overlapping pieces, which `VisionPipeline.recognize` does for every caller (Capture
/// Text, the OCR panel, Translate Area, this). One Vision request over a whole picture shrinks it to fit and
/// loses small text: over the history's own captures, bands 2048 pixels tall across the width read from 10% to
/// sixty times more of every tall capture's text, in a tenth of the time where the whole took 10 to 15 seconds
/// (Docs/ocr.md › Large pictures, in bands). Bands cut between lines; a very wide picture
/// (a sideways scrolling capture) is also cut across, through its lines. A line cut by a piece's edge is whole in the
/// next piece, as long as it is no taller than the overlap (`PieceMerge` keeps that reading and drops the cut one).
public enum PictureText {
    /// How tall a band is, in pixels.
    static let band = 2048
    /// How far each piece reaches into the next, in pixels: more than a large heading at 2x.
    static let overlap = 256

    /// The text of the picture in the file at `url`.
    public static func read(fileAt url: URL, pipeline: VisionPipeline) async throws -> String {
        try await pipeline.recognize(fileAt: url).text
    }

    /// The picture in the file at `url`, decoded. A tall PNG need not be: its pieces are read from the file a band at a
    /// time (`Bands`).
    public static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw OCRError.unreadableImage }
        return image
    }

    public static func read(_ image: CGImage, pipeline: VisionPipeline) async throws -> String {
        try await pipeline.recognize(image).text
    }

    /// The pieces a `width` × `height` picture is read in, row by row. Rows: bands `band` tall when the picture is
    /// more than a quarter taller than one; columns: as wide as the picture is tall (at least `band`) when it is
    /// more than 2.5 times wider than tall and over 4096 pixels wide. Each reaches `overlap` into the next.
    static func pieces(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let columns = isCutAcross(width: width, height: height) ? spans(width, length: max(height, band)) : [0..<width]
        let rows = height > band + band / 4 ? spans(height, length: band) : [0..<height]
        return rows.flatMap { row in
            columns.map { column in CGRect(x: column.lowerBound, y: row.lowerBound, width: column.count, height: row.count) }
        }
    }

    /// Whether a `width` × `height` picture is also cut across, through its lines: over 4096 pixels wide and more than
    /// 2.5 times wider than tall.
    static func isCutAcross(width: Int, height: Int) -> Bool {
        width > 4096 && Double(width) > Double(height) * 2.5
    }

    /// A PNG's pieces (`pieces`), each read from the file as a picture of its own rows alone, never the whole picture
    /// decoded: the decoded picture of a tall scrolling capture is counted in the reader's footprint again each time a
    /// piece of it is drawn, 215 MB for 3346 × 16811 (Docs/perf.md › M6 — Pieces of a tall PNG).
    ///
    /// A piece's rows are laid out as ImageIO decodes the whole picture (`PNGBands`) and made a picture in the same format
    /// and color space, so whatever draws or reads a piece gets what it got from the whole. Only a picture in more than
    /// one piece, every piece across its whole width (not cut across), of a kind read so (`PNGBands`) and laid out as
    /// ImageIO lays it out: nil for anything else, which is decoded whole as before (`image(at:)`).
    final class Bands {
        let width: Int
        let height: Int
        let pieces: [CGRect]
        private let png: PNGBands
        /// The picture as ImageIO makes it out, never decoded: its format and color space.
        private let template: CGImage

        /// The pieces' pictures have run out: the file's pixels end, or are damaged, before the picture does.
        struct Ended: Error {}

        init?(fileAt url: URL) {
            // Mapped, not read in: opening the tallest capture, a 13 MB file, this way added 1 MB to the footprint.
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                  let png = PNGBands(data: data, overlap: PictureText.overlap),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let template = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  template.width == png.width, template.height == png.height,
                  template.bitsPerComponent == png.layout.bitsPerComponent, template.bitsPerPixel == png.layout.bitsPerPixel,
                  template.bitmapInfo == png.layout.bitmapInfo, let space = template.colorSpace, (space.model == .indexed) == png.isIndexed
            else { return nil }
            let pieces = PictureText.pieces(width: png.width, height: png.height)
            guard pieces.count > 1, pieces.allSatisfy({ Int($0.width) == png.width }) else { return nil }
            width = png.width
            height = png.height
            self.pieces = pieces
            self.png = png
            self.template = template
        }

        /// The colors' space.
        var colorSpace: CGColorSpace? { template.colorSpace }

        /// The picture of `piece`'s rows, the pieces taken in order; nil when the file's pixels end before them.
        func image(of piece: CGRect) -> CGImage? {
            guard Int(piece.minX) == 0, Int(piece.width) == width else { return nil }
            return image(rows: Int(piece.minY) ..< Int(piece.maxY))
        }

        /// Draws `piece`'s rows into `context`, a bitmap of its size, a strip at a time (`stripBytes`), each a picture of
        /// its own drawn where it belongs; false when the file's pixels end before them.
        ///
        /// Drawn whole, a piece's picture left the reader's footprint 25 MB higher with each piece of a tall capture once
        /// Core ML's predictions had come between: freed blocks as large as a piece that malloc kept dirty, most likely
        /// CG's own for drawing it. In strips, no block is that large (Docs/perf.md › M6 — Pieces of a tall PNG).
        func draw(_ piece: CGRect, into context: CGContext, stripBytes: Int = Bands.stripBytes) -> Bool {
            guard Int(piece.minX) == 0, Int(piece.width) == width else { return false }
            let strip = max(1, stripBytes / max(png.bytesPerRow, width * 4))
            var top = Int(piece.minY)
            while top < Int(piece.maxY) {
                let bottom = min(top + strip, Int(piece.maxY))
                guard let image = image(rows: top ..< bottom) else { return false }
                context.draw(image, in: CGRect(x: 0, y: Int(piece.maxY) - bottom, width: width, height: bottom - top))
                top = bottom
            }
            return true
        }

        /// Bytes a strip holds at most, as read or as drawn (4 a pixel), whichever is more. On the tallest capture, strips
        /// of up to 7 MB kept the footprint flat from piece to piece, and strips of 13 MB grew it as whole pieces did.
        static let stripBytes = 4 << 20

        /// The picture of `rows` alone.
        private func image(rows: Range<Int>) -> CGImage? {
            guard let provider = png.rows(rows), let space = template.colorSpace else { return nil }
            return CGImage(
                width: width, height: rows.count, bitsPerComponent: template.bitsPerComponent, bitsPerPixel: template.bitsPerPixel,
                bytesPerRow: png.bytesPerRow, space: space, bitmapInfo: template.bitmapInfo, provider: provider,
                decode: template.decode, shouldInterpolate: template.shouldInterpolate, intent: template.renderingIntent
            )
        }
    }

    /// `0..<total` in pieces `length` long, each reaching `overlap` into the next.
    private static func spans(_ total: Int, length: Int) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var start = 0
        while true {
            let end = min(start + length, total)
            spans.append(start..<end)
            if end == total { return spans }
            start = end - overlap
        }
    }
}
