import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import OMSPixels

/// The small pictures of captures the history window, the Quick Access cards, and pins show, decoded without
/// loading the full image.
extension HistoryStore {
    /// A thumbnail at most `maxPixels` on its long side, decoded without loading the full image; for a
    /// recording, its first frame.
    @concurrent
    public static func thumbnail(of url: URL, maxPixels: Int) async -> CGImage? {
        if isMovie(url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return try? await generator.image(at: .zero).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(of: source, maxPixels: maxPixels)
    }

    /// The same, from encoded data already in memory.
    @concurrent
    public static func thumbnail(of data: Data, maxPixels: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(of: source, maxPixels: maxPixels)
    }

    /// The first image `source` holds, decoded at most `maxPixels` on its longer side and turned upright.
    private static func thumbnail(of source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// A card's thumbnail of a picture, at most `maxPixels` on its longer side: the part the card shows
    /// (`CardPicture`), drawn from the picture itself, so the top of a long scrolling capture stays sharp
    /// however long it is.
    @concurrent
    public static func cardThumbnail(of image: CGImage, maxPixels: Int) async -> CGImage? {
        scaled(CardPicture.shownPart(of: image), maxPixels: maxPixels)
    }

    /// The same, from a capture's file; a movie's first frame as `thumbnail(of:maxPixels:)` makes it.
    @concurrent
    public static func cardThumbnail(of url: URL, maxPixels: Int) async -> CGImage? {
        if isMovie(url) { return await thumbnail(of: url, maxPixels: maxPixels) }
        // The PNGs the app writes are read row by row, for what ImageIO leaves in the heap (see PNGThumbnail).
        if let data = try? Data(contentsOf: url, options: .alwaysMapped), let thumbnail = PNGThumbnail.make(from: data, maxPixels: maxPixels, part: CardPicture.shownRect) {
            return thumbnail
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return cardThumbnail(of: source, maxPixels: maxPixels)
    }

    /// The same, from encoded data already in memory.
    @concurrent
    public static func cardThumbnail(of data: Data, maxPixels: Int) async -> CGImage? {
        if let thumbnail = PNGThumbnail.make(from: data, maxPixels: maxPixels, part: CardPicture.shownRect) { return thumbnail }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return cardThumbnail(of: source, maxPixels: maxPixels)
    }

    /// The card's part of what `source` holds: decoded only as large as that part needs, then drawn on its own,
    /// so the larger decoding is let go.
    private static func cardThumbnail(of source: CGImageSource, maxPixels: Int) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return thumbnail(of: source, maxPixels: maxPixels) }
        let part = CardPicture.shownRect(width: width, height: height)
        guard part.width < CGFloat(width) || part.height < CGFloat(height) else { return thumbnail(of: source, maxPixels: maxPixels) }
        // The whole at the size that makes the part `maxPixels` on its longer side, but no more than about 64 MB of
        // pixels: a narrow picture tens of thousands of pixels long decodes long enough for a sharp part.
        let scale = Double(maxPixels) / Double(max(part.width, part.height))
        let longest = Int((16_777_216 * Double(max(width, height)) / Double(min(width, height))).squareRoot())
        let decoded = min(max(16_384, longest), Int((Double(max(width, height)) * scale).rounded(.up)))
        guard let whole = thumbnail(of: source, maxPixels: decoded) else { return nil }
        let across = Double(whole.width) / Double(width), along = Double(whole.height) / Double(height)
        let shown = CGRect(x: 0, y: 0, width: (part.width * across).rounded(), height: (part.height * along).rounded())
        return whole.cropping(to: shown).flatMap { scaled($0, maxPixels: maxPixels) }
    }

    /// `image` drawn at most `maxPixels` on its longer side, in a bitmap of its own.
    private static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
