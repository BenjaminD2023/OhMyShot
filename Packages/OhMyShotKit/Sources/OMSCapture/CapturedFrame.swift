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
}

public enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    case emptyResult
}
