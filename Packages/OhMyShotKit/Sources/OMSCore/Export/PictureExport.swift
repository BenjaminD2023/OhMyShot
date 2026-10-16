import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a screenshot into what leaves the app, as `ScreenshotOutput` says: scaled to 1×, converted to sRGB,
/// given a 1 px border, and encoded as PNG, JPEG, or HEIC. It is the one place that does it, for a file saved,
/// dragged out, or uploaded, a Shortcuts result, and the picture on the clipboard (which stays PNG).
///
/// The pixels are changed in one pass through one bitmap, whatever combination is asked for, and not at all
/// when none is: a PNG with nothing to do is written as it is.
public enum PictureExport {
    /// A picture as it will be written.
    public struct Prepared: Sendable {
        public let image: CGImage
        /// The extended-range picture beside `image` (same size, same changes), for a HEIC with an HDR gain map.
        public let hdr: CGImage?
        /// Pixels per point of `image` after any scaling; nil when it is not known.
        public let pixelsPerPoint: Double?
        /// Whether `image` differs from the picture that was given.
        public let isChanged: Bool
    }

    public struct Encoded: Sendable {
        public let data: Data
        public let format: ImageExporter.Format

        public var fileExtension: String { format.fileExtension }
    }

    /// The border's ink: black at this opacity, a hairline that shows on a light page and costs a dark picture
    /// next to nothing.
    public static let borderOpacity: CGFloat = 0.2

    // MARK: Pixels

    /// `image` as `output` has it. `pixelsPerPoint` is the picture's scale (2 for a Retina display's), which 1×
    /// needs: without it the picture's size is left alone. `hdr` is the extended-range copy of the same capture,
    /// used when the format is HEIC and the picture is not converted to sRGB.
    public static func prepare(_ image: CGImage, pixelsPerPoint: Double?, hdr: CGImage? = nil, output: ScreenshotOutput) -> Prepared {
        var width = image.width, height = image.height
        var scale = pixelsPerPoint
        if output.retinaAtOneX, let factor = pixelsPerPoint, factor > 1.01 {
            width = max(1, Int((Double(image.width) / factor).rounded()))
            height = max(1, Int((Double(image.height) / factor).rounded()))
            scale = 1
        }
        let resizes = width != image.width || height != image.height
        let converts = output.convertsToSRGB && image.colorSpace.map { !isSRGB($0) } == true
        // A picture with clear corners or a clear shadow has no edge to draw along.
        let borders = output.addsBorder && width > 2 && height > 2 && !hasTransparentEdge(image)
        let hdr = output.format == .heic && !output.convertsToSRGB && hdr?.width == image.width && hdr?.height == image.height ? hdr : nil
        guard resizes || converts || borders else {
            return Prepared(image: image, hdr: hdr, pixelsPerPoint: scale, isChanged: false)
        }
        guard let drawn = draw(image, width: width, height: height, toSRGB: output.convertsToSRGB, border: borders) else {
            return Prepared(image: image, hdr: hdr, pixelsPerPoint: pixelsPerPoint, isChanged: false)
        }
        let drawnHDR = hdr.flatMap { resizes || borders ? drawHDR($0, width: width, height: height, border: borders) : $0 }
        return Prepared(image: drawn, hdr: drawnHDR, pixelsPerPoint: scale, isChanged: true)
    }

    /// One pass: `image` at its new size in sRGB (or the color space it has), with the border over its outer ring.
    private static func draw(_ image: CGImage, width: Int, height: Int, toSRGB: Bool, border: Bool) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let info = (image.hasAlpha ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // A color space a bitmap cannot be made in (an extended one) is drawn in sRGB.
        guard let context = [toSRGB ? srgb : own ?? srgb, srgb].lazy.compactMap({
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: $0, bitmapInfo: info)
        }).first else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if border { drawBorder(in: context, width: width, height: height) }
        return context.makeImage()
    }

    private static func drawHDR(_ image: CGImage, width: Int, height: Int, border: Bool) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space, bitmapInfo: info) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if border { drawBorder(in: context, width: width, height: height) }
        return context.makeImage()
    }

    /// The picture's outermost ring of pixels, darkened a little. Each corner is drawn once.
    private static func drawBorder(in context: CGContext, width: Int, height: Int) {
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: borderOpacity))
        context.fill([
            CGRect(x: 0, y: 0, width: width, height: 1),
            CGRect(x: 0, y: height - 1, width: width, height: 1),
            CGRect(x: 0, y: 1, width: 1, height: height - 2),
            CGRect(x: width - 1, y: 1, width: 1, height: height - 2),
        ])
    }

    private static func isSRGB(_ space: CGColorSpace) -> Bool {
        space.name == CGColorSpace.sRGB
    }

    /// Whether any pixel of the picture's outermost ring is not opaque: a window with its shadow, or with the
    /// rounded corners of one without.
    static func hasTransparentEdge(_ image: CGImage) -> Bool {
        guard image.hasAlpha else { return false }
        let strips = [
            CGRect(x: 0, y: 0, width: image.width, height: 1), CGRect(x: 0, y: image.height - 1, width: image.width, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: image.height), CGRect(x: image.width - 1, y: 0, width: 1, height: image.height),
        ]
        return strips.contains { rect in
            guard let strip = image.cropping(to: rect) else { return true }
            return !isOpaque(strip)
        }
    }

    private static func isOpaque(_ strip: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: strip.width * strip.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: buffer.baseAddress, width: strip.width, height: strip.height, bitsPerComponent: 8, bytesPerRow: strip.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] >= 250 }
    }

    // MARK: Encoding

    /// Encodes a prepared picture. With an HDR copy it is a HEIC with an ISO gain map, the SDR picture ImageIO
    /// makes of it as the base; should that fail, the SDR picture alone is written. A picture with transparency
    /// goes to JPEG on white.
    public static func encode(_ prepared: Prepared, output: ScreenshotOutput) throws -> Encoded {
        if let hdr = prepared.hdr, output.format == .heic,
           let data = try? write(hdr, properties: properties(for: prepared, output: output, gainMap: true), output: output) {
            return Encoded(data: data, format: .heic)
        }
        return Encoded(
            data: try write(prepared.image, properties: properties(for: prepared, output: output, gainMap: false), output: output),
            format: output.format
        )
    }

    public static func encode(_ image: CGImage, pixelsPerPoint: Double?, hdr: CGImage? = nil, output: ScreenshotOutput) throws -> Encoded {
        try encode(prepare(image, pixelsPerPoint: pixelsPerPoint, hdr: hdr, output: output), output: output)
    }

    /// A capture's file, read and encoded; its scale is `pixelsPerPoint`, else the resolution the file states.
    public static func encode(fileAt url: URL, pixelsPerPoint: Double?, output: ScreenshotOutput) throws -> Encoded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ImageExporter.ExportError.cannotRead }
        return try encode(image, pixelsPerPoint: pixelsPerPoint ?? resolution(of: source), output: output)
    }

    /// Encoding takes tens of milliseconds to seconds for a large capture, so these run off the main actor.
    @concurrent
    public static func encoded(_ image: CGImage, pixelsPerPoint: Double?, hdr: CGImage? = nil, output: ScreenshotOutput) async throws -> Encoded {
        try encode(image, pixelsPerPoint: pixelsPerPoint, hdr: hdr, output: output)
    }

    @concurrent
    public static func encoded(fileAt url: URL, pixelsPerPoint: Double?, output: ScreenshotOutput) async throws -> Encoded {
        try encode(fileAt: url, pixelsPerPoint: pixelsPerPoint, output: output)
    }

    /// The picture as the clipboard has it: scaled, converted, and given its border as `output` says, and PNG
    /// whatever its format. Nil when it cannot be encoded.
    @concurrent
    public static func clipboardPicture(_ image: CGImage, pixelsPerPoint: Double?, output: ScreenshotOutput) async -> (image: CGImage, png: Data)? {
        let prepared = prepare(image, pixelsPerPoint: pixelsPerPoint, output: output.with(format: .png))
        guard let png = try? await ImageExporter.encode(prepared.image, as: .png) else { return nil }
        return (prepared.image, png)
    }

    /// The scale a picture file states: 144 dpi is 2 pixels per point. Nil when it states none (72 dpi is every
    /// file's way of saying so).
    static func resolution(of source: CGImageSource) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 72.5 else { return nil }
        // PNG stores resolution per meter, so 144 dpi reads back as 143.99: snapped to quarter steps.
        return (dpi / 72 * 4).rounded() / 4
    }

    private static func properties(for prepared: Prepared, output: ScreenshotOutput, gainMap: Bool) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if output.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = output.quality }
        if output.format == .jpeg { properties[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1) }
        // The resolution says how large the picture is meant to be: a 2× picture is 144 dpi, as macOS's are.
        if let scale = prepared.pixelsPerPoint {
            properties[kCGImagePropertyDPIWidth] = 72 * scale
            properties[kCGImagePropertyDPIHeight] = 72 * scale
        }
        if gainMap { properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap }
        return properties
    }

    private static func write(_ image: CGImage, properties: [CFString: Any], output: ScreenshotOutput) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, output.format.type.identifier as CFString, 1, nil) else {
            throw ImageExporter.ExportError.cannotEncode
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageExporter.ExportError.cannotEncode }
        return data as Data
    }
}

extension CGImage {
    /// Whether the image has an alpha channel, opaque or not.
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
