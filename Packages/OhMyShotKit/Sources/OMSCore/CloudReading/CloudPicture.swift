import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a picture goes to a cloud model: at its own pixels wherever the service takes them, never enlarged, and a
/// tall one cut into pieces top to bottom that overlap a little, all sent in one request. Small text is what the
/// cloud model is asked to read, so the picture is made smaller only where a service would make it smaller anyway
/// (wider than it reads), or where it needs more pieces than a request takes.
public enum CloudPicture {
    /// What one service reads of a picture.
    public struct Limits: Equatable, Sendable {
        /// The longest side a piece is read at; larger ones are made smaller by the service.
        public var longEdge: Int
        /// The most pixels a piece is read at.
        public var pixels: Int
        /// The most pieces sent in one request.
        public var pieces: Int
        /// The most bytes one piece may be, encoded.
        public var bytes: Int
        /// How far each piece reaches into the next, so no line is read only in halves.
        public var overlap: Int
        /// The most all the pieces may be together, base64-encoded as the request carries them.
        public var requestBytes: Int

        public init(longEdge: Int, pixels: Int, pieces: Int, bytes: Int, overlap: Int, requestBytes: Int) {
            self.longEdge = longEdge
            self.pixels = pixels
            self.pieces = pieces
            self.bytes = bytes
            self.overlap = overlap
            self.requestBytes = requestBytes
        }

        /// Claude 4.7 and later read 2576 pixels on the long edge and 4784 patches of 28 × 28; an image may be 10 MB
        /// base64-encoded (7.5 MB before), and over 20 images in a request each must be at most 2000 pixels a side
        /// (platform.claude.com/docs/en/build-with-claude/vision, 2026-10-18). Earlier models read less and make
        /// larger pieces smaller themselves. A request may be 32 MB: the pictures keep to 24, leaving room for the rest.
        public static let anthropic = Limits(longEdge: 2576, pixels: 4784 * 28 * 28, pieces: 20, bytes: 7_500_000, overlap: 64, requestBytes: 24_000_000)

        /// Services differ, and few say what they read: 2048 pixels and two megapixels a piece is a middle way, not
        /// measured, under what the documented ones take; and 16 MB for the request's pictures, a guess as well.
        public static let openAICompatible = Limits(longEdge: 2048, pixels: 2048 * 1024, pieces: 10, bytes: 7_500_000, overlap: 64, requestBytes: 16_000_000)

        public static func of(_ kind: CloudModel.Kind) -> Limits {
            kind == .anthropic ? .anthropic : .openAICompatible
        }
    }

    /// How a picture of a size is sent.
    public struct Plan: Equatable, Sendable {
        /// The size each piece is drawn at, 1 for the picture's own pixels.
        public var scale: Double
        /// Each piece's rows, in the picture's own pixels, top to bottom.
        public var pieces: [ClosedRange<Int>]

        /// The rows of each piece in the scaled picture's pixels.
        var scaledHeight: Int
    }

    /// The pieces a picture of `width` × `height` pixels is cut into, drawn at most at `maxScale`.
    public static func plan(width: Int, height: Int, limits: Limits, maxScale: Double = 1) -> Plan {
        guard width > 0, height > 0 else { return Plan(scale: 1, pieces: [], scaledHeight: 0) }
        var scale = min(maxScale, 1, Double(limits.longEdge) / Double(width))
        while true {
            let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
            let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
            let tallest = max(limits.overlap * 2 + 1, min(limits.longEdge, limits.pixels / scaledWidth))
            let count = scaledHeight <= tallest ? 1 : Int((Double(scaledHeight - limits.overlap) / Double(tallest - limits.overlap)).rounded(.up))
            if count <= limits.pieces || scale < 0.05 {
                return Plan(scale: scale, pieces: rows(scaledHeight: scaledHeight, count: count, overlap: limits.overlap, scale: scale, height: height), scaledHeight: scaledHeight)
            }
            scale *= 0.9
        }
    }

    /// `count` pieces of one height, each reaching `overlap` rows into the next, in the picture's own rows.
    private static func rows(scaledHeight: Int, count: Int, overlap: Int, scale: Double, height: Int) -> [ClosedRange<Int>] {
        guard count > 1 else { return [0...(height - 1)] }
        let pieceHeight = Int((Double(scaledHeight + (count - 1) * overlap) / Double(count)).rounded(.up))
        return (0..<count).map { index in
            let top = min(index * (pieceHeight - overlap), scaledHeight - pieceHeight)
            let first = Int((Double(top) / scale).rounded(.down))
            // The last piece reaches the bottom, whatever the rounding of the scaled height left.
            let last = index == count - 1 ? height - 1 : min(height - 1, Int((Double(top + pieceHeight) / scale).rounded(.up)) - 1)
            return first...last
        }
    }

    /// One piece, encoded.
    public struct Piece: Sendable {
        public var data: Data
        /// "image/png", or "image/jpeg" for a piece too large as PNG.
        public var mediaType: String
        public var width: Int
        public var height: Int
    }

    public enum PictureError: Error {
        case unencodable
    }

    /// The picture as it goes: its pieces and the size they were drawn at.
    public struct Prepared: Sendable {
        public var pieces: [Piece]
        public var scale: Double
    }

    /// The picture's pieces, drawn and encoded: PNG, which keeps small text sharp, or JPEG at high quality for a
    /// piece whose PNG is over the service's size. When all of them together are over what a request takes, every
    /// piece goes as JPEG, and then the picture is made smaller until they fit.
    public static func prepare(_ image: CGImage, limits: Limits) throws -> Prepared {
        var maxScale = 1.0
        var allJPEG = false
        for _ in 0..<8 {
            let plan = plan(width: image.width, height: image.height, limits: limits, maxScale: maxScale)
            let pieces = try plan.pieces.map { rows in try piece(of: image, rows: rows, scale: plan.scale, limits: limits, allJPEG: allJPEG) }
            let carried = pieces.reduce(0) { $0 + ($1.data.count + 2) / 3 * 4 }
            if carried <= limits.requestBytes { return Prepared(pieces: pieces, scale: plan.scale) }
            if allJPEG {
                maxScale = plan.scale * 0.8
            } else {
                allJPEG = true
            }
        }
        throw PictureError.unencodable
    }

    private static func piece(of image: CGImage, rows: ClosedRange<Int>, scale: Double, limits: Limits, allJPEG: Bool) throws -> Piece {
        let crop = CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)
        guard let cropped = image.cropping(to: crop) else { throw PictureError.unencodable }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(rows.count) * scale).rounded()))
        let drawn = scale >= 1 ? cropped : try scaled(cropped, width: width, height: height)
        if !allJPEG, let png = encode(drawn, as: .png, quality: nil), png.count <= limits.bytes {
            return Piece(data: png, mediaType: "image/png", width: drawn.width, height: drawn.height)
        }
        for quality in [0.92, 0.85, 0.75] {
            if let jpeg = encode(drawn, as: .jpeg, quality: quality), jpeg.count <= limits.bytes {
                return Piece(data: jpeg, mediaType: "image/jpeg", width: drawn.width, height: drawn.height)
            }
        }
        throw PictureError.unencodable
    }

    private static func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw PictureError.unencodable }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw PictureError.unencodable }
        return scaled
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
