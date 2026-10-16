import CoreGraphics
import Foundation

/// A change to a screenshot's picture made from its Quick Access card: turned, flipped, or brought down to one
/// pixel per point. Turning and flipping move whole pixels and blend none, in the picture's own color space and
/// depth (8 or 16 bits to a channel), so a PNG keeps them exactly.
public enum PictureChange: Equatable, Sendable {
    case rotateLeft
    case rotateRight
    case flipHorizontal
    case flipVertical
    /// Scaled down by `pixelsPerPoint` (a Retina capture's 2), so one pixel is one point.
    case scaleToOneX(pixelsPerPoint: Double)

    /// The change to make now, for a capture that has `pixelsPerPoint` now: Scale to 1× starts from the capture's
    /// scale as it is, so one asked for twice in a row (the second while the first is still running) is nothing the
    /// second time. Nil when there is nothing to change.
    public func resolved(pixelsPerPoint: Double) -> PictureChange? {
        guard case .scaleToOneX = self else { return self }
        return pixelsPerPoint > 1 ? .scaleToOneX(pixelsPerPoint: pixelsPerPoint) : nil
    }

    /// The picture's size in pixels after the change.
    public func size(ofWidth width: Int, height: Int) -> (width: Int, height: Int) {
        switch self {
        case .rotateLeft, .rotateRight:
            (height, width)
        case .flipHorizontal, .flipVertical:
            (width, height)
        case .scaleToOneX(let scale):
            scale > 1 ? (max(Int((Double(width) / scale).rounded()), 1), max(Int((Double(height) / scale).rounded()), 1)) : (width, height)
        }
    }

    /// The picture after the change, in its own color space and with its transparency; nil when a bitmap of that
    /// size cannot be made.
    public func apply(to image: CGImage) -> CGImage? {
        let size = size(ofWidth: image.width, height: image.height)
        if case .scaleToOneX = self, size == (image.width, image.height) { return image }
        guard let context = Self.context(width: size.width, height: size.height, like: image) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // The context's space is y up; each change maps the picture's rectangle onto the context's.
        switch self {
        case .rotateRight:
            context.translateBy(x: 0, y: width)
            context.rotate(by: -.pi / 2)
        case .rotateLeft:
            context.translateBy(x: height, y: 0)
            context.rotate(by: .pi / 2)
        case .flipHorizontal:
            context.translateBy(x: width, y: 0)
            context.scaleBy(x: -1, y: 1)
        case .flipVertical:
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
        case .scaleToOneX:
            break
        }
        if case .scaleToOneX = self {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        } else {
            // Whole pixels onto whole pixels: nothing to blend.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()
    }

    /// A bitmap in `image`'s color space (a wide-gamut capture stays wide), opaque when the picture is, with 16 bits
    /// to a channel when the picture has them and 8 otherwise; sRGB when its own space is not one a bitmap can have.
    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let bitmapInfo = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        let depth = image.bitsPerComponent == 16 && !image.bitmapInfo.contains(.floatComponents) ? 16 : 8
        if let space = image.colorSpace, space.model == .rgb,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: depth, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) {
            return context
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: depth, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)
    }
}

/// Whether a capture's picture can be changed now.
public enum PictureChangeAvailability: Equatable, Sendable {
    case available
    /// The capture has been edited, or put on a background: its original and its marks are kept beside the
    /// picture, and a change would leave them as they were.
    case marked
    /// The editor has the capture open.
    case beingEdited
    /// A recording, or a picture that is not a PNG, as the app's captures are: a JPEG or HEIC file added to the
    /// history would lose some of itself being written again, and a photo's orientation is not in its pixels.
    case unsupported

    /// What a capture offers, from what is known of it.
    public static func of(isScreenshot: Bool, fileExtension: String, hasOriginal: Bool, isBeingEdited: Bool) -> Self {
        guard isScreenshot, fileExtension.lowercased() == ImageExporter.Format.png.fileExtension else { return .unsupported }
        if isBeingEdited { return .beingEdited }
        return hasOriginal ? .marked : .available
    }
}

/// What a card's menu is told about changing its picture.
public struct PictureChangeOffer: Equatable, Sendable {
    public var availability: PictureChangeAvailability
    /// The capture's pixels per point; Scale to 1× is offered above 1.
    public var pixelsPerPoint: Double

    public init(availability: PictureChangeAvailability, pixelsPerPoint: Double = 1) {
        self.availability = availability
        self.pixelsPerPoint = pixelsPerPoint
    }

    public static let unsupported = PictureChangeOffer(availability: .unsupported)
}
