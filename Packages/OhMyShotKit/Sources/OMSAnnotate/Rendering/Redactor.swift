import Accelerate
import CoreGraphics
import Foundation

/// Blurs or pixelates part of a capture for a redaction. Only the capture is processed, never other
/// marks, and the result is the same every time for the same mark, so the screen and the export agree.
nonisolated enum Redactor {
    /// The redacted pixels for `rect` (in the document's pixels), the size of `rect` clipped to the
    /// picture under it, or nil when the rect misses it or the method draws no picture (solid).
    /// `base` is what lies under redactions: the capture, or the capture with images combined into it
    /// (`AnnotationRenderer.redactionSource`), whose top-left corner is at `origin` in the document.
    static func image(for redaction: Redaction, id: UUID, base: CGImage, origin: CGPoint = .zero, scale: CGFloat) -> (image: CGImage, rect: CGRect)? {
        let bounds = CGRect(x: origin.x, y: origin.y, width: CGFloat(base.width), height: CGFloat(base.height))
        let rect = redaction.rect.standardized.integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        // In the source's own pixels.
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        switch redaction.method {
        case .solid:
            return nil
        case .blur:
            return blurred(local, of: base, scale: scale).map { ($0, rect) }
        case .pixelate:
            return pixelated(local, of: base, scale: scale, seed: id).map { ($0, rect) }
        }
    }

    /// The side of a pixelation block: never under 12 px, larger for large areas.
    static func blockSize(for rect: CGRect, scale: CGFloat) -> Int {
        max(12, Int((6 * scale).rounded()), Int((max(rect.width, rect.height) / 28).rounded()))
    }

    /// A Gaussian-like blur (three box passes) strong enough that text under it cannot be read. Pixels
    /// around the rect take part, so its edges blend; at the capture's edges the last pixels repeat.
    private static func blurred(_ rect: CGRect, of base: CGImage, scale: CGFloat) -> CGImage? {
        let sigma = min(max(6 * scale, min(rect.width, rect.height) * 0.08), 48)
        let box = Int(sigma * 2) | 1
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let source = rect.insetBy(dx: -CGFloat(box * 2), dy: -CGFloat(box * 2)).intersection(bounds).integral
        guard var buffer = Bitmap(base, crop: source) else { return nil }
        var scratch = Bitmap(width: buffer.width, height: buffer.height, colorSpace: buffer.colorSpace)
        for _ in 0..<3 {
            let error = buffer.withBuffer { input in
                scratch.withBuffer { output in
                    vImageBoxConvolve_ARGB8888(&input, &output, nil, 0, 0, UInt32(box), UInt32(box), nil, vImage_Flags(kvImageEdgeExtend))
                }
            }
            guard error == kvImageNoError else { return nil }
            swap(&buffer, &scratch)
        }
        let inner = CGRect(x: rect.minX - source.minX, y: rect.minY - source.minY, width: rect.width, height: rect.height)
        return buffer.makeImage()?.cropping(to: inner)
    }

    /// Averages blocks anchored at the rect's corner, then moves each block's color by a little seeded
    /// noise: plain block averages of known type can be matched back to the text they came from.
    private static func pixelated(_ rect: CGRect, of base: CGImage, scale: CGFloat, seed: UUID) -> CGImage? {
        guard var bitmap = Bitmap(base, crop: rect) else { return nil }
        let block = blockSize(for: rect, scale: scale)
        var generator = SeededGenerator(seed: seed)
        let width = bitmap.width
        let height = bitmap.height
        let rowBytes = bitmap.rowBytes
        bitmap.bytes.withUnsafeMutableBufferPointer { pixels in
            var top = 0
            while top < height {
                let bottom = min(top + block, height)
                var left = 0
                while left < width {
                    let right = min(left + block, width)
                    var sums = (0, 0, 0, 0)
                    for y in top..<bottom {
                        var index = y * rowBytes + left * 4
                        for _ in left..<right {
                            sums.0 += Int(pixels[index])
                            sums.1 += Int(pixels[index + 1])
                            sums.2 += Int(pixels[index + 2])
                            sums.3 += Int(pixels[index + 3])
                            index += 4
                        }
                    }
                    let count = (bottom - top) * (right - left)
                    let alpha = sums.0 / count
                    // Shared brightness noise plus a little per channel, kept within the alpha
                    // (the bytes are premultiplied).
                    let shift = Int.random(in: -14...14, using: &generator)
                    func channel(_ sum: Int) -> UInt8 {
                        UInt8(clamping: min(sum / count + shift + Int.random(in: -5...5, using: &generator), alpha))
                    }
                    let color = (UInt8(clamping: alpha), channel(sums.1), channel(sums.2), channel(sums.3))
                    for y in top..<bottom {
                        var index = y * rowBytes + left * 4
                        for _ in left..<right {
                            pixels[index] = color.0
                            pixels[index + 1] = color.1
                            pixels[index + 2] = color.2
                            pixels[index + 3] = color.3
                            index += 4
                        }
                    }
                    left = right
                }
                top = bottom
            }
        }
        return bitmap.makeImage()
    }
}

/// Premultiplied ARGB, 8 bits per channel, in the capture's own color space.
nonisolated struct Bitmap {
    let width: Int
    let height: Int
    let rowBytes: Int
    let colorSpace: CGColorSpace
    var bytes: [UInt8]

    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    init(width: Int, height: Int, colorSpace: CGColorSpace) {
        self.width = width
        self.height = height
        rowBytes = width * 4
        self.colorSpace = colorSpace
        bytes = [UInt8](repeating: 0, count: rowBytes * height)
    }

    /// The `crop` of `image` (in its pixels, top-left origin).
    init?(_ image: CGImage, crop: CGRect) {
        guard let cropped = image.cropping(to: crop) else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        self.init(width: cropped.width, height: cropped.height, colorSpace: space)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: colorSpace, bitmapInfo: Self.bitmapInfo
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    mutating func withBuffer<Result>(_ body: (inout vImage_Buffer) -> Result) -> Result {
        let width = width
        let height = height
        let rowBytes = rowBytes
        return bytes.withUnsafeMutableBytes { raw in
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
            return body(&buffer)
        }
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// SplitMix64, seeded from a mark's identifier, so its noise is the same at every redraw.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UUID) {
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        state = bytes.enumerated().reduce(0x9E37_79B9_7F4A_7C15) { $0 ^ (UInt64($1.element) << (UInt64($1.offset % 8) * 8)) &* 0x100_0000_01B3 }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
