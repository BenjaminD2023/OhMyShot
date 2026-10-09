import CoreGraphics

/// A display's frozen frame as plain pixels, for measuring: where a run of one color ends, and where the
/// content in a box begins. Built once per display, the first time measuring needs it there.
nonisolated struct PixelGrid: Sendable {
    let width: Int
    let height: Int
    /// One 32-bit pixel each, rows from the top, in the frame's own color space: only differences matter.
    private let pixels: [UInt32]

    /// Two pixels differ when a channel differs by more than this, out of 255: past dithering in a soft
    /// shadow, short of a light hairline on white.
    static let tolerance = 8

    init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// `image`'s pixels, as they are: drawn without color conversion when its space is RGB.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var drawn = false
        let pixels = [UInt32](unsafeUninitializedCapacity: width * height) { buffer, count in
            count = width * height
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                buffer.initialize(repeating: 0)
                return
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drawn = true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    func pixel(_ x: Int, _ y: Int) -> UInt32 {
        pixels[y * width + x]
    }

    static func matches(_ a: UInt32, _ b: UInt32) -> Bool {
        guard a != b else { return true }
        for shift in stride(from: 0, to: 32, by: 8) {
            let difference = abs(Int((a >> UInt32(shift)) & 0xFF) - Int((b >> UInt32(shift)) & 0xFF))
            if difference > tolerance { return false }
        }
        return true
    }

    /// The run of pixels through (`x`, `y`) along a row (or a column) that match its color: from it out to
    /// the last pixel before another color, each way, or to the frame's edge.
    func span(throughX x: Int, y: Int, horizontal: Bool) -> ClosedRange<Int> {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        let start = pixel(x, y)
        if horizontal {
            var low = x, high = x
            while low > 0, Self.matches(pixel(low - 1, y), start) { low -= 1 }
            while high < width - 1, Self.matches(pixel(high + 1, y), start) { high += 1 }
            return low...high
        } else {
            var low = y, high = y
            while low > 0, Self.matches(pixel(x, low - 1), start) { low -= 1 }
            while high < height - 1, Self.matches(pixel(x, high + 1), start) { high += 1 }
            return low...high
        }
    }

    /// What `rect` (pixels from the top left) holds besides its background, as a box: `rect` shrunk until
    /// each side touches content, the background being the color most of its corners share. Nil when it
    /// holds nothing but background.
    func contentBounds(in rect: CGRect) -> CGRect? {
        let box = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        var minX = Int(box.minX), maxX = Int(box.maxX) - 1
        var minY = Int(box.minY), maxY = Int(box.maxY) - 1
        let corners = [pixel(minX, minY), pixel(maxX, minY), pixel(minX, maxY), pixel(maxX, maxY)]
        let background = corners.max { a, b in
            corners.count { Self.matches($0, a) } < corners.count { Self.matches($0, b) }
        } ?? corners[0]
        func rowIsBackground(_ y: Int) -> Bool { (minX...maxX).allSatisfy { Self.matches(pixel($0, y), background) } }
        func columnIsBackground(_ x: Int) -> Bool { (minY...maxY).allSatisfy { Self.matches(pixel(x, $0), background) } }
        while minY <= maxY, rowIsBackground(minY) { minY += 1 }
        guard minY <= maxY else { return nil }
        while rowIsBackground(maxY) { maxY -= 1 }
        while columnIsBackground(minX) { minX += 1 }
        while columnIsBackground(maxX) { maxX -= 1 }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
