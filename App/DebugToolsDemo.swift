#if DEBUG
import AppKit
import OMSCore

/// A display drawn for scripted checks of Pick Color and Measure, so they never read the real screen:
/// white, with things of known size and color at known places, in the display's points from its top-left
/// corner, drawn in Display P3.
enum DebugToolsDemo {
    /// A blue button, 120 × 36 pt, in sRGB's #007AFF.
    static let button = CGRect(x: 200, y: 200, width: 120, height: 36)
    /// A square of Display P3's own red, which sRGB cannot hold, 48 × 48 pt.
    static let square = CGRect(x: 400, y: 194, width: 48, height: 48)
    /// A light gray hairline under them, 1 pt tall.
    static let hairline = CGRect(x: 200, y: 280, width: 248, height: 1)

    static func screen(for display: DisplayInfo) -> CGImage? {
        let scale = display.pixelsPerPoint
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let context = CGContext(
            data: nil, width: Int(display.pixelSize.width), height: Int(display.pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Core Graphics is y up; the rects are from the top-left corner.
        func fill(_ rect: CGRect, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: rect.minX * scale, y: (display.frame.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale))
        }
        fill(CGRect(origin: .zero, size: display.frame.size), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        fill(button, CGColor(srgbRed: 0, green: 122.0 / 255, blue: 1, alpha: 1))
        fill(square, CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        fill(hairline, CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        return context.makeImage()
    }

    /// `point`, from the top-left corner of `display`, in global space.
    static func global(_ point: CGPoint, on display: DisplayInfo) -> CGPoint {
        CGPoint(x: display.frame.minX + point.x, y: display.frame.maxY - point.y)
    }

    /// `rect`, from the top-left corner of `display`, in global space.
    static func global(_ rect: CGRect, on display: DisplayInfo) -> CGRect {
        CGRect(x: display.frame.minX + rect.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
#endif
