import CoreGraphics
import Foundation

/// What a capture's card shows of its picture: all of it, or for one far taller than wide (a scrolling capture)
/// its top, and for one far wider than tall its left end, as much as fills the card. Shown whole, either would
/// stand in the card as a thin strip.
public enum CardPicture {
    /// The card's width, in points, and the most its picture stands tall.
    public static let width: CGFloat = 220
    public static let tallest: CGFloat = 172

    /// The part of a picture `width` × `height` pixels the card shows, in its pixels from the top left.
    public static func shownRect(width: Int, height: Int) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0 else { return whole }
        let aspect = CGFloat(height) / CGFloat(width)
        if aspect > 2.5 {
            return CGRect(x: 0, y: 0, width: CGFloat(width), height: (CGFloat(width) * tallest / Self.width).rounded())
        }
        if aspect < 0.2 {
            return CGRect(x: 0, y: 0, width: (CGFloat(height) * Self.width / 100).rounded(), height: CGFloat(height))
        }
        return whole
    }

    /// The part of `image` the card shows.
    public static func shownPart(of image: CGImage) -> CGImage {
        let rect = shownRect(width: image.width, height: image.height)
        guard rect != CGRect(x: 0, y: 0, width: image.width, height: image.height) else { return image }
        return image.cropping(to: rect) ?? image
    }
}
