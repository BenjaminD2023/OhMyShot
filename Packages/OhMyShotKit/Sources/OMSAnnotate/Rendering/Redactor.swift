import Accelerate
import CoreGraphics
import Foundation

/// Blurs, pixelates, or erases part of a capture for a redaction. Only the capture is processed, never
/// other marks, and the result is the same every time for the same mark, so the screen and the export agree.
nonisolated enum Redactor {
    typealias Filter = (Redaction.Method, CGRect, CGImage, CGFloat, UUID) -> CGImage?

    struct Source {
        let bounds: CGRect
        let image: CGImage?

        var picture: (image: CGImage, origin: CGPoint)? {
            image.map { ($0, bounds.origin) }
        }

        init(base: CGImage) {
            self.init(bounds: CGRect(x: 0, y: 0, width: base.width, height: base.height), image: base)
        }

        init(bounds: CGRect, image: CGImage?) {
            self.bounds = bounds
            self.image = image
        }
    }

    enum Coverage {
        case filtered(CGImage, CGRect)
        case opaque(CGRect)
    }

    /// What to draw over the clipped rect in document pixels. A failed filter yields an opaque
    /// cover; nil means that there is no area to filter or that the mark itself draws a solid fill.
    /// The source retains its document bounds even if the combined image could not be made. `covered` is
    /// where the document's redactions lie, in document pixels (`AnnotationDocument.redactedRects`): an
    /// erasure reads none of it. `canvas` is what the picture keeps (a crop, or Annotate Area's selection): an
    /// erasure fills and reads only inside it, so it comes out the same once the picture is cut to it.
    static func coverage(
        for redaction: Redaction, id: UUID, source: Source, scale: CGFloat, covered: [CGRect] = [], canvas: CGRect? = nil,
        filter: Filter = apply
    ) -> Coverage? {
        guard redaction.method != .solid else { return nil }
        var rect = redaction.rect.standardized.integral.intersection(source.bounds)
        let kept = canvas?.standardized.integral
        if redaction.method == .erase, let kept { rect = rect.intersection(kept) }
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        // In the source's own pixels.
        let local = rect.offsetBy(dx: -source.bounds.minX, dy: -source.bounds.minY)
        guard let image = source.image else { return .opaque(rect) }
        let pixels = if redaction.method == .erase {
            erased(
                local, of: image, scale: scale, avoiding: covered.map { $0.offsetBy(dx: -source.bounds.minX, dy: -source.bounds.minY) },
                within: kept?.offsetBy(dx: -source.bounds.minX, dy: -source.bounds.minY)
            )
        } else {
            filter(redaction.method, local, image, scale, id)
        }
        guard let pixels else { return .opaque(rect) }
        return .filtered(pixels, rect)
    }

    static func apply(_ method: Redaction.Method, to rect: CGRect, of base: CGImage, scale: CGFloat, seed: UUID) -> CGImage? {
        switch method {
        case .blur: blurred(rect, of: base, scale: scale)
        case .pixelate: pixelated(rect, of: base, scale: scale, seed: seed)
        // A solid redaction draws itself, and an erasure is made by `coverage`, which knows what else is covered.
        case .solid, .erase: nil
        }
    }

    /// How far apart, in levels of 255 on any channel, the colors around an erasure may lie and still be
    /// taken for one color or one gradient.
    static let eraseTolerance = 4.0

    /// Fills `rect` from the picture around it, so it blends into the surface it lies on: one color when
    /// what borders it is one color, a gradient when that changes evenly, otherwise each side's colors carried
    /// in from that side, the nearer sides counting for more. Only a band of pixels just outside `rect` is
    /// read, never one inside it, so nothing it covers can be recovered from the fill; nor one in `avoiding`
    /// (where other redactions lie), so it never spreads what they hide; nor one outside `within`; nor one
    /// that is not opaque (a window's clear margin), so the fill is always opaque. A few stray pixels in the
    /// band (the edge of a word beside it) are outvoted. Nil when nothing around it can be read, which covers it
    /// opaquely.
    static func erased(_ rect: CGRect, of base: CGImage, scale: CGFloat, avoiding: [CGRect], within: CGRect? = nil) -> CGImage? {
        let band = max(2, Int((2 * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height).intersection(within ?? .infinite)
        let area = rect.insetBy(dx: -CGFloat(band), dy: -CGFloat(band)).intersection(bounds).integral
        guard !area.isNull, let around = Bitmap(base, crop: area) else { return nil }
        let inner = rect.offsetBy(dx: -area.minX, dy: -area.minY)
        let left = Int(inner.minX), top = Int(inner.minY), right = Int(inner.maxX), bottom = Int(inner.maxY)
        let width = right - left, height = bottom - top
        guard width > 0, height > 0 else { return nil }
        let avoided = avoiding.map { $0.standardized.integral.offsetBy(dx: -area.minX, dy: -area.minY) }

        func readable(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < around.width, y < around.height else { return false }
            if (left..<right).contains(x), (top..<bottom).contains(y) { return false }
            // The alpha comes first.
            guard around.bytes[y * around.rowBytes + x * 4] == 255 else { return false }
            let center = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            return !avoided.contains { $0.contains(center) }
        }
        func color(_ x: Int, _ y: Int) -> SIMD4<Double> {
            let index = y * around.rowBytes + x * 4
            return SIMD4(Double(around.bytes[index]), Double(around.bytes[index + 1]), Double(around.bytes[index + 2]), Double(around.bytes[index + 3]))
        }
        /// The mean of the readable pixels among `pixels`, or nil when none is.
        func mean(_ pixels: [(Int, Int)]) -> SIMD4<Double>? {
            let read = pixels.filter { readable($0.0, $0.1) }
            guard !read.isEmpty else { return nil }
            return read.reduce(SIMD4<Double>.zero) { $0 + color($1.0, $1.1) } / Double(read.count)
        }

        // Every readable pixel of the band, placed from the middle of `rect`.
        let middle = SIMD2(Double(left + right) / 2, Double(top + bottom) / 2)
        var samples: [(position: SIMD2<Double>, color: SIMD4<Double>)] = []
        for y in 0..<around.height {
            let columns = (top..<bottom).contains(y) ? [0..<left, right..<around.width] : [0..<around.width]
            for x in columns.joined() where readable(x, y) {
                samples.append((SIMD2(Double(x) + 0.5, Double(y) + 0.5) - middle, color(x, y)))
            }
        }
        guard !samples.isEmpty else { return nil }
        func distance(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> Double {
            let difference = a - b
            return max(max(abs(difference.x), abs(difference.y)), max(abs(difference.z), abs(difference.w)))
        }
        let enough = Double(samples.count) * 0.9

        var output = Bitmap(width: width, height: height, colorSpace: around.colorSpace)
        let rowBytes = output.rowBytes
        func fill(_ shade: (Int, Int) -> SIMD4<Double>) -> CGImage? {
            output.bytes.withUnsafeMutableBufferPointer { pixels in
                for j in 0..<height {
                    for i in 0..<width {
                        let value = shade(i, j)
                        let alpha = UInt8(clamping: Int(value[0].rounded()))
                        let index = j * rowBytes + i * 4
                        pixels[index] = alpha
                        // Premultiplied: no channel above the alpha.
                        for channel in 1..<4 { pixels[index + channel] = min(UInt8(clamping: Int(value[channel].rounded())), alpha) }
                    }
                }
            }
            return output.makeImage()
        }

        // One color: the median of each channel, then the mean of the pixels near it.
        let median = SIMD4((0..<4).map { channel in samples.map { $0.color[channel] }.sorted()[samples.count / 2] })
        let near = samples.filter { distance($0.color, median) <= eraseTolerance }
        if Double(near.count) >= enough {
            let flat = near.reduce(SIMD4<Double>.zero) { $0 + $1.color } / Double(near.count)
            return fill { _, _ in flat }
        }

        // A gradient: a plane through each channel, fitted again to the pixels that lie near it.
        func plane(_ points: [(position: SIMD2<Double>, color: SIMD4<Double>)]) -> ((SIMD2<Double>) -> SIMD4<Double>)? {
            var s1 = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0
            var sv = SIMD4<Double>.zero, sxv = SIMD4<Double>.zero, syv = SIMD4<Double>.zero
            for point in points {
                let (x, y) = (point.position.x, point.position.y)
                s1 += 1; sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y
                sv += point.color; sxv += point.color * x; syv += point.color * y
            }
            // The symmetric normal equations, solved by their cofactors.
            let c00 = sxx * syy - sxy * sxy, c01 = sxy * sy - sx * syy, c02 = sx * sxy - sxx * sy
            let c11 = s1 * syy - sy * sy, c12 = sx * sy - s1 * sxy, c22 = s1 * sxx - sx * sx
            let determinant = s1 * c00 + sx * c01 + sy * c02
            // Pixels along one line (a band one pixel deep on one side) fix no plane.
            guard determinant > 1e-9 * s1 * sxx * syy else { return nil }
            let a = (sv * c00 + sxv * c01 + syv * c02) / determinant
            let b = (sv * c01 + sxv * c11 + syv * c12) / determinant
            let c = (sv * c02 + sxv * c12 + syv * c22) / determinant
            return { a + b * $0.x + c * $0.y }
        }
        var gradient = plane(samples)
        for _ in 0..<2 {
            guard let fitted = gradient else { break }
            let close = samples.filter { distance(fitted($0.position), $0.color) <= 2 * eraseTolerance }
            gradient = close.count >= 3 ? plane(close) : nil
        }
        if let gradient, Double(samples.filter({ distance(gradient($0.position), $0.color) <= eraseTolerance }).count) >= enough {
            return fill { i, j in gradient(SIMD2(Double(left + i) + 0.5, Double(top + j) + 0.5) - middle) }
        }

        // Each side's colors, the band across it averaged, carried in from that side.
        func side(_ count: Int, _ pixels: (Int) -> [(Int, Int)]) -> [SIMD4<Double>]? {
            let read = (0..<count).map { mean(pixels($0)) }
            let known = read.indices.filter { read[$0] != nil }
            guard let first = known.first, let last = known.last else { return nil }
            var colors = read.map { $0 ?? .zero }
            for index in 0..<first { colors[index] = colors[first] }
            for index in (last + 1)..<count { colors[index] = colors[last] }
            for (start, end) in zip(known, known.dropFirst()) where end > start + 1 {
                for index in (start + 1)..<end {
                    let t = Double(index - start) / Double(end - start)
                    colors[index] = colors[start] * (1 - t) + colors[end] * t
                }
            }
            return colors
        }
        let above = side(width) { i in (top - band..<top).map { (left + i, $0) } }
        let below = side(width) { i in (bottom..<bottom + band).map { (left + i, $0) } }
        let before = side(height) { j in (left - band..<left).map { ($0, top + j) } }
        let after = side(height) { j in (right..<right + band).map { ($0, top + j) } }
        guard above != nil || below != nil || before != nil || after != nil else { return nil }
        return fill { i, j in
            var sum = SIMD4<Double>.zero
            var weight = 0.0
            if let above {
                let share = 1 / Double((j + 1) * (j + 1))
                sum += above[i] * share
                weight += share
            }
            if let below {
                let share = 1 / Double((height - j) * (height - j))
                sum += below[i] * share
                weight += share
            }
            if let before {
                let share = 1 / Double((i + 1) * (i + 1))
                sum += before[j] * share
                weight += share
            }
            if let after {
                let share = 1 / Double((width - i) * (width - i))
                sum += after[j] * share
                weight += share
            }
            return sum / weight
        }
    }

    /// The side of a pixelation block: never under 12 px, larger for large areas.
    static func blockSize(for rect: CGRect, scale: CGFloat) -> Int {
        max(12, Int(max(lineRadius(for: rect, scale: scale), max(rect.width, rect.height) / 28).rounded()))
    }

    /// Allow room around a line: keep the 6 pt UI radius for selections up to 24 pt high,
    /// then increase it by half a pixel for each extra pixel on the short side.
    private static func lineRadius(for rect: CGRect, scale: CGFloat) -> CGFloat {
        max(6 * scale, min(rect.width, rect.height) / 2 - 6 * scale)
    }

    /// Three box passes approximate a Gaussian. The short side estimates the height of a covered line;
    /// large selections get a proportionally wider blur on a smaller working bitmap.
    private static func blurred(_ rect: CGRect, of base: CGImage, scale: CGFloat) -> CGImage? {
        let sigma = lineRadius(for: rect, scale: scale)
        let stride = max(1, Int(sigma / 12))
        let box = Int(sigma * 2 / CGFloat(stride)) | 1
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let padding = CGFloat((box / 2) * 3 * stride)
        let source = rect.insetBy(dx: -padding, dy: -padding).intersection(bounds).integral
        guard var buffer = Bitmap(base, crop: source, downsampleBy: stride) else { return nil }
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
        let transform = CGAffineTransform(scaleX: CGFloat(buffer.width) / source.width, y: CGFloat(buffer.height) / source.height)
        return buffer.makeImage(interpolate: stride > 1)?.cropping(to: inner.applying(transform).integral)
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
    init?(_ image: CGImage, crop: CGRect, downsampleBy stride: Int = 1) {
        guard let cropped = image.cropping(to: crop) else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        self.init(width: (cropped.width - 1) / stride + 1, height: (cropped.height - 1) / stride + 1, colorSpace: space)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: colorSpace, bitmapInfo: Self.bitmapInfo
            ) else { return false }
            if stride > 1 { context.interpolationQuality = .high }
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

    func makeImage(interpolate: Bool = false) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider, decode: nil, shouldInterpolate: interpolate, intent: .defaultIntent
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
