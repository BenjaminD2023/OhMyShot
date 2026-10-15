import CoreGraphics
import Foundation
import ImageIO

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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw OCRError.unreadableImage }
        return try await read(image, pipeline: pipeline)
    }

    public static func read(_ image: CGImage, pipeline: VisionPipeline) async throws -> String {
        try await pipeline.recognize(image).text
    }

    /// The pieces a `width` × `height` picture is read in, row by row. Rows: bands `band` tall when the picture is
    /// more than a quarter taller than one; columns: as wide as the picture is tall (at least `band`) when it is
    /// more than 2.5 times wider than tall and over 4096 pixels wide. Each reaches `overlap` into the next.
    static func pieces(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let columns = width > 4096 && Double(width) > Double(height) * 2.5 ? spans(width, length: max(height, band)) : [0..<width]
        let rows = height > band + band / 4 ? spans(height, length: band) : [0..<height]
        return rows.flatMap { row in
            columns.map { column in CGRect(x: column.lowerBound, y: row.lowerBound, width: column.count, height: row.count) }
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
