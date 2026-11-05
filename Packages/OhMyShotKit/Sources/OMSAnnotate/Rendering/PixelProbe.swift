import CoreGraphics
import Foundation

/// Single pixels read from a picture: the eyedropper's color, and whether a capture's corners are see-through.
nonisolated enum PixelProbe {
    /// The color of the pixel at `point` (pixels from the picture's top-left corner), opaque; nil off the picture.
    static func color(at point: CGPoint, in image: CGImage) -> RGBA? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let bitmap = Bitmap(image, crop: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        let pixel = bitmap.pixel(0, 0)
        return RGBA(red: Double(pixel.red) / 255, green: Double(pixel.green) / 255, blue: Double(pixel.blue) / 255, alpha: 1)
    }

    /// Whether the picture's four corners are opaque: false for a window captured with its shadow.
    static func hasOpaqueCorners(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: break
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: image.width - 1, y: 0), CGPoint(x: 0, y: image.height - 1), CGPoint(x: image.width - 1, y: image.height - 1)]
        return corners.allSatisfy { corner in
            guard let crop = image.cropping(to: CGRect(origin: corner, size: CGSize(width: 1, height: 1))) else { return false }
            return pixel.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return raw[3] == 255
            }
        }
    }
}
