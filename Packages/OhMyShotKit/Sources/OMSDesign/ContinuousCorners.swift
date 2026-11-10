import CoreGraphics
import SwiftUI

public extension CGPath {
    /// A rounded rectangle with continuous (squircle) corners, as a layer draws with `cornerCurve = .continuous` and
    /// SwiftUI with `style: .continuous`. `NSBezierPath(roundedRect:)` and `CGPath(roundedRect:)` round with plain
    /// arcs, so a view that draws its own shape takes its path from here.
    static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        Path(roundedRect: rect, cornerRadius: max(0, min(radius, min(rect.width, rect.height) / 2)), style: .continuous).cgPath
    }
}
