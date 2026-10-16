import CoreGraphics
import Foundation

/// What a window screenshot is put on.
public enum WindowBackground: String, CaseIterable, Codable, Sendable {
    /// The background every new screenshot gets (Settings › General › Background), or none.
    case asScreenshots
    /// None: the window alone, its corners clear, with its shadow when that is captured.
    case transparent
    /// The desktop picture around the window, as it is on screen.
    case desktopWallpaper

    /// What one window screenshot gets: this choice, or with Shift held as the window was clicked the other way
    /// round: no background where there would be one, the desktop picture where there would be none.
    public func resolved(automaticPreset: Bool, shiftHeld: Bool) -> Resolved {
        let chosen: Resolved = switch self {
        case .asScreenshots: automaticPreset ? .preset : .none
        case .transparent: .none
        case .desktopWallpaper: .wallpaper
        }
        guard shiftHeld else { return chosen }
        return chosen == .none ? .wallpaper : .none
    }

    public enum Resolved: Equatable, Sendable {
        case none
        /// The automatic background preset.
        case preset
        case wallpaper
    }
}

/// The part of a display's desktop picture behind a window screenshot on the wallpaper: around the capture, as large
/// as the finished picture (the capture with its room all round), cut to the display.
public enum WallpaperCrop {
    /// In the desktop picture's pixels from the display's top-left corner. `picture` is where the capture lies on
    /// screen in global points (the window with its shadow: `pictureFrame`), `picturePixels` the capture's size,
    /// `padding` the background's room as a fraction of the capture's measure (the side of a square of its area).
    /// Nil when nothing of it is on the display.
    public static func region(
        around picture: CGRect, picturePixels: CGSize, padding: CGFloat, on display: DisplayInfo
    ) -> CGRect? {
        let scale = display.pixelsPerPoint
        let measure = (max(picturePixels.width, 1) * max(picturePixels.height, 1)).squareRoot()
        let room = padding * measure
        let size = CGSize(width: (picturePixels.width + 2 * room) / scale, height: (picturePixels.height + 2 * room) / scale)
        let around = CGRect(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2, width: size.width, height: size.height)
        let kept = around.intersection(display.frame)
        guard !kept.isNull, kept.width >= 1, kept.height >= 1 else { return nil }
        // Global points, y up, to the picture's pixels, y down.
        return CGRect(
            x: (kept.minX - display.frame.minX) * scale, y: (display.frame.maxY - kept.maxY) * scale,
            width: kept.width * scale, height: kept.height * scale
        ).integral
    }

    /// Where a window capture lies on screen, in global points, from the window's `frame`: the window with its
    /// shadow's room on each side, found where the window turns opaque along the capture's middle row and column.
    /// A shadow falls deeper below a window than above it, so the capture is not centered on the window. Without a
    /// shadow, or when the window cannot be found in it (clear in the middle), centered on the window.
    public static func pictureFrame(of image: CGImage, window frame: CGRect, pixelsPerPoint scale: CGFloat) -> CGRect {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let centered = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        guard size.width > frame.width + 1 || size.height > frame.height + 1,
              let across = opaqueSpan(of: image, column: false), let down = opaqueSpan(of: image, column: true),
              // The opaque part is the window, as wide and tall as its frame.
              abs(CGFloat(across.count) - frame.width * scale) <= 4, abs(CGFloat(down.count) - frame.height * scale) <= 4
        else { return centered }
        // From the capture's top-left, y down, to the screen, y up.
        let left = CGFloat(across.lowerBound) / scale, top = CGFloat(down.lowerBound) / scale
        return CGRect(x: frame.minX - left, y: frame.maxY + top - size.height, width: size.width, height: size.height)
    }

    /// The pixels from the first opaque one to the last along the capture's middle column (from the top) or row.
    private static func opaqueSpan(of image: CGImage, column: Bool) -> ClosedRange<Int>? {
        let strip = column
            ? CGRect(x: image.width / 2, y: 0, width: 1, height: image.height)
            : CGRect(x: 0, y: image.height / 2, width: image.width, height: 1)
        guard let line = image.cropping(to: strip) else { return nil }
        let count = line.width * line.height
        var pixels = [UInt8](repeating: 0, count: count * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: &pixels, width: line.width, height: line.height, bitsPerComponent: 8, bytesPerRow: line.width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // The context's first row is the strip's top.
        context.draw(line, in: CGRect(x: 0, y: 0, width: line.width, height: line.height))
        let opaque = { (index: Int) in pixels[index * 4 + 3] >= 250 }
        guard let first = (0..<count).first(where: opaque), let last = (0..<count).last(where: opaque) else { return nil }
        return first...last
    }
}
