import CoreGraphics
import Foundation
import OMSPixels

/// A picture of a formula as the formula pack's encoder reads it (config.json's "picture"), as transformers'
/// PPFormulaNetImageProcessor prepares it (Tools/l3-spike/formula_picture.py, which the app's preparation matches value
/// for value, gives the processor's within 2/255 on 0.03% of values): a dark picture inverted, its margin cropped,
/// scaled so its shorter side is `size` (bilinear), then to fit `size` × `size` (bicubic), centered, and normalized.
/// The pixel work is OMSPixels' (`FormulaPixels`, `Resample.antialiased`).
enum FormulaPicture {
    /// 3 planes of `size` × `size` values, red, green, blue; nil when the picture has no pixels to draw.
    static func values(of image: CGImage, _ picture: FormulaConfiguration.Picture) -> [Float]? {
        guard let pixels = PPOCRPixels(image) else { return nil }
        return values(of: pixels.bytes, width: pixels.width, height: pixels.height, picture)
    }

    /// The same, of RGBX bytes, top row first.
    static func values(of bytes: [UInt8], width: Int, height: Int, _ picture: FormulaConfiguration.Picture) -> [Float] {
        var (pixels, w, h) = (bytes, width, height)
        if isDark(pixels, width: w, height: h, below: picture.darkBorder) { pixels = FormulaPixels.inverted(pixels) }
        if let box = FormulaPixels.inkBox(pixels, width: w, height: h, threshold: picture.cropGray) {
            pixels = FormulaPixels.cropped(pixels, width: w, x: box.x, y: box.y, boxWidth: box.width, boxHeight: box.height)
            (w, h) = (box.width, box.height)
        }
        for (filter, to) in scales(width: w, height: h, size: picture.size) {
            pixels = pixels.withUnsafeBufferPointer { Resample.antialiased($0, width: w, height: h, toWidth: to.width, toHeight: to.height, filter: filter) }
            (w, h) = (to.width, to.height)
        }
        return FormulaPixels.planes(pixels, width: w, height: h, size: picture.size, mean: picture.mean, std: picture.std, padding: UInt8(picture.padding))
    }

    /// Whether the mean gray along the border, sampled at 32 or so places on each side, is below `threshold`.
    static func isDark(_ bytes: [UInt8], width: Int, height: Int, below threshold: Int) -> Bool {
        func gray(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return (Int(bytes[i]) * 299 + Int(bytes[i + 1]) * 587 + Int(bytes[i + 2]) * 114) / 1000
        }
        var total = 0, count = 0
        for x in stride(from: 0, to: width, by: max(1, width / 32)) {
            total += gray(x, 0) + gray(x, height - 1)
            count += 2
        }
        for y in stride(from: 0, to: height, by: max(1, height / 32)) {
            total += gray(0, y) + gray(width - 1, y)
            count += 2
        }
        return count > 0 && Double(total) / Double(count) < Double(threshold)
    }

    /// A picture this many times longer than tall (or taller than long), or more, is scaled to fit in one step rather
    /// than through its shorter side at `size`, which would draw a strip 16 × 768 wide and wider.
    static let longestRatio = 16

    /// The resizings that take a `width` × `height` picture to fit `size` × `size`: its shorter side to `size`, the
    /// longer in proportion (truncated), bilinear; then, when that is too large, to fit (bicubic), the shorter side in
    /// proportion, truncated.
    static func scales(width: Int, height: Int, size: Int) -> [(Resample.Filter, (width: Int, height: Int))] {
        let short = min(width, height), long = max(width, height)
        if long >= short * longestRatio {
            let fitted = max(1, Int(Double(short) * Double(size) / Double(long)))
            return [(.bicubic, width >= height ? (size, fitted) : (fitted, size))]
        }
        let longer = Int(Double(size) * Double(long) / Double(short))
        let (w, h) = width <= height ? (size, longer) : (longer, size)
        // A resizing to the same size changes nothing (the filters weigh only the pixel itself).
        var steps: [(Resample.Filter, (width: Int, height: Int))] = (w, h) == (width, height) ? [] : [(.bilinear, (w, h))]
        var (tw, th) = (min(w, size), min(h, size))
        if (tw, th) != (w, h) {
            if h > w {
                tw = Int(Double(w * th) / Double(h))
            } else if w > h {
                th = Int(Double(h * tw) / Double(w))
            }
            steps.append((.bicubic, (tw, th)))
        }
        return steps
    }
}
