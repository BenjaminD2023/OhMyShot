import CoreGraphics
import OMSCore

/// One captured image and where on screen it came from.
public struct CapturedFrame: Sendable {
    /// The image in the display's SDR color space. Clipboard, OCR, and the color picker always use this.
    public let image: CGImage
    /// The same capture in extended sRGB, when HDR was requested and the display could show it.
    public let hdrImage: CGImage?
    public let displayID: CGDirectDisplayID
    /// The captured area in AppKit's global space, in points.
    public let frame: CGRect

    public init(image: CGImage, hdrImage: CGImage?, displayID: CGDirectDisplayID, frame: CGRect) {
        self.image = image
        self.hdrImage = hdrImage
        self.displayID = displayID
        self.frame = frame
    }

    /// Image pixels per point of screen.
    public var pixelsPerPoint: CGFloat {
        frame.width > 0 ? CGFloat(image.width) / frame.width : 1
    }

    /// The part of this capture under `rect` (AppKit's global space), in whole pixels: what a capture of
    /// that area would have given when this one was taken. The pixels are copied out, so the whole
    /// capture can be let go. Nil when `rect` misses it.
    public func cropped(to rect: CGRect) -> CapturedFrame? {
        let scale = pixelsPerPoint
        let area = rect.standardized.intersection(frame)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        // Global space is y up; the image is y down from the capture's top-left corner.
        let minX = ((area.minX - frame.minX) * scale).rounded()
        let maxX = ((area.maxX - frame.minX) * scale).rounded()
        let minY = ((frame.maxY - area.maxY) * scale).rounded()
        let maxY = ((frame.maxY - area.minY) * scale).rounded()
        let pixels = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, let part = image.cropping(to: pixels) else { return nil }
        // Drawn into a bitmap of its own in the capture's color space, so the pixels stay as they were.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(part, in: CGRect(origin: .zero, size: pixels.size))
        guard let copy = context.makeImage() else { return nil }
        return CapturedFrame(image: copy, hdrImage: nil, displayID: displayID, frame: CGRect(
            x: frame.minX + pixels.minX / scale, y: frame.maxY - pixels.maxY / scale,
            width: pixels.width / scale, height: pixels.height / scale
        ))
    }

    /// The captures of an area's parts on several displays, put together as one capture of `area`: at
    /// `pixelsPerPoint` (the sharpest display's), in the parts' color space when they share one and in
    /// Display P3 when they do not, and clear where no display reaches. It belongs to the display that
    /// holds most of it. Nil without parts.
    public static func stitched(_ parts: [CapturedFrame], covering area: CGRect, pixelsPerPoint scale: CGFloat) -> CapturedFrame? {
        let width = Int((area.width * scale).rounded())
        let height = Int((area.height * scale).rounded())
        guard let largest = parts.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              width > 0, height > 0 else { return nil }
        let spaces = parts.map { $0.image.colorSpace }
        let shared = spaces.allSatisfy { $0 == spaces[0] } ? spaces[0].flatMap { $0.model == .rgb ? $0 : nil } : nil
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: shared ?? CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        for part in parts {
            // Both are y up: each part goes where it lies within the area.
            let rect = CGRect(
                x: (part.frame.minX - area.minX) * scale, y: (part.frame.minY - area.minY) * scale,
                width: part.frame.width * scale, height: part.frame.height * scale
            )
            context.interpolationQuality = abs(part.pixelsPerPoint - scale) < 0.001 ? .none : .high
            context.draw(part.image, in: rect)
        }
        guard let image = context.makeImage() else { return nil }
        return CapturedFrame(image: image, hdrImage: nil, displayID: largest.displayID, frame: area)
    }
}

public enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    case emptyResult
}
