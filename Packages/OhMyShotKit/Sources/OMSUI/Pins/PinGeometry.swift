import CoreGraphics
import Foundation

/// Where a pin goes and how it grows and fades: the arithmetic, apart from the windows.
enum PinGeometry {
    static let zoomRange: ClosedRange<CGFloat> = 0.1...8
    static let opacityRange: ClosedRange<CGFloat> = 0.2...1
    /// The opacities the pin's menu offers.
    static let opacitySteps: [CGFloat] = [1, 0.8, 0.6, 0.4, 0.2]

    /// Where a pin of `size` points first appears, and at what zoom. Over `requested` (the screen area a
    /// capture came from) at 1:1, so nothing seems to move until it is dragged; centered on it when the
    /// picture is larger (a window's shadow). Without one, centered in `visible`, scaled down to fit
    /// 80 percent of it when larger.
    static func initialFrame(size: CGSize, requested: CGRect?, visible: CGRect) -> (frame: CGRect, zoom: CGFloat) {
        if let requested {
            if abs(size.width - requested.width) < 1, abs(size.height - requested.height) < 1 {
                return (requested, 1)
            }
            return (CGRect(x: requested.midX - size.width / 2, y: requested.midY - size.height / 2, width: size.width, height: size.height), 1)
        }
        let fit = min(1, 0.8 * visible.width / max(size.width, 1), 0.8 * visible.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * fit, height: size.height * fit)
        return (CGRect(x: visible.midX - fitted.width / 2, y: visible.midY - fitted.height / 2, width: fitted.width, height: fitted.height), fit)
    }

    /// `frame` grown or shrunk by `ratio`, keeping `anchor` (a point in the same space) where it is on
    /// screen: the pointer, or the pin's center.
    static func zoomed(_ frame: CGRect, by ratio: CGFloat, around anchor: CGPoint) -> CGRect {
        CGRect(
            x: anchor.x - (anchor.x - frame.minX) * ratio,
            y: anchor.y - (anchor.y - frame.minY) * ratio,
            width: frame.width * ratio,
            height: frame.height * ratio
        )
    }

    /// The zoom after scrolling up (positive) or down by `delta`: points from a trackpad, lines from a
    /// wheel, about 10 percent a line.
    static func zoom(_ zoom: CGFloat, scrolledBy delta: CGFloat, precise: Bool) -> CGFloat {
        clamp(zoom * exp(delta * (precise ? 0.005 : 0.1)), to: zoomRange)
    }

    /// The opacity after scrolling up (more opaque) or down by `delta`: 5 percent a wheel line.
    static func opacity(_ opacity: CGFloat, scrolledBy delta: CGFloat, precise: Bool) -> CGFloat {
        clamp(opacity + delta * (precise ? 0.005 : 0.05), to: opacityRange)
    }

    static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
