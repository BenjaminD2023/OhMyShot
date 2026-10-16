import CoreGraphics
import Foundation

/// The shape the crop frame keeps while it is dragged: free, the picture's own, or a fixed ratio.
nonisolated public enum CropRatio: Hashable, Sendable {
    /// Any shape. Shift keeps the shape the frame has.
    case free
    /// The shape of the whole picture.
    case original
    /// Width to height, as "16:9".
    case fixed(Int, Int)

    /// What the crop menu offers, in order.
    public static let presets: [CropRatio] = [.free, .original, .fixed(1, 1), .fixed(4, 3), .fixed(3, 2), .fixed(16, 9), .fixed(9, 16)]

    /// Width divided by height for a picture of `picture` size; nil when free.
    public func value(forPicture picture: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: picture.width > 0 && picture.height > 0 ? picture.width / picture.height : nil
        case .fixed(let width, let height): width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : nil
        }
    }

    /// The largest rect of shape `ratio` (width over height) that fits in `rect`, centered in it.
    public static func fitted(_ ratio: CGFloat, in rect: CGRect) -> CGRect {
        let rect = rect.standardized
        guard ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        var size = rect.size
        if rect.width / rect.height > ratio {
            size.width = rect.height * ratio
        } else {
            size.height = rect.width / ratio
        }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `rect` with the side or corner under `handle` dragged to `point`, keeping shape `ratio` (width over
    /// height). A corner holds the opposite corner and grows along the longer of the two drags, so a frame
    /// started from a point (zero size) takes the ratio at once; a side moves alone, and the other
    /// dimension follows it about the middle of the frame.
    public static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint, ratio: CGFloat) -> CGRect {
        let rect = rect.standardized
        guard ratio > 0 else { return rect }
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            let anchor = CGPoint(
                x: handle == .topLeft || handle == .bottomLeft ? rect.maxX : rect.minX,
                y: handle == .topLeft || handle == .topRight ? rect.maxY : rect.minY
            )
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            var width = abs(dx)
            var height = abs(dy)
            if width / ratio >= height {
                height = width / ratio
            } else {
                width = height * ratio
            }
            // A drag that has not left the anchor goes the way the handle points.
            let right = dx == 0 ? handle == .topRight || handle == .bottomRight : dx > 0
            let down = dy == 0 ? handle == .bottomLeft || handle == .bottomRight : dy > 0
            return CGRect(x: anchor.x, y: anchor.y, width: right ? width : -width, height: down ? height : -height).standardized
        case .left, .right:
            let fixed = handle == .right ? rect.minX : rect.maxX
            let width = abs(point.x - fixed)
            let height = width / ratio
            return CGRect(x: min(fixed, point.x), y: rect.midY - height / 2, width: width, height: height)
        case .top, .bottom:
            let fixed = handle == .bottom ? rect.minY : rect.maxY
            let height = abs(point.y - fixed)
            let width = height * ratio
            return CGRect(x: rect.midX - width / 2, y: min(fixed, point.y), width: width, height: height)
        case .start, .end, .bend:
            return rect
        }
    }
}
