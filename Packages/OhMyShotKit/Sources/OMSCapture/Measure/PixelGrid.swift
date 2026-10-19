import CoreGraphics
import OMSCore
import OMSPixels

/// A display's frozen frame as plain pixels, for measuring: where a run of one color ends, and where the
/// content in a box begins. Built once per display, the first time measuring needs it there.
nonisolated struct PixelGrid: Sendable {
    let width: Int
    let height: Int
    /// One 32-bit pixel each, rows from the top, in the frame's own color space: only differences matter.
    private let pixels: [UInt32]
    private let pixelsPerPoint: CGFloat

    init(width: Int, height: Int, pixels: [UInt32], pixelsPerPoint: CGFloat = 1) {
        precondition(width > 0 && height > 0)
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.pixelsPerPoint = pixelsPerPoint.isFinite && pixelsPerPoint > 0 ? pixelsPerPoint : 1
    }

    /// `image`'s pixels, as they are: drawn without color conversion when its space is RGB.
    init?(_ image: CGImage, pixelsPerPoint: CGFloat = 1) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, !Task.isCancelled else { return nil }
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
            // The destination is uninitialized: transparent source pixels must replace it, not blend.
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drawn = true
        }
        // CGContext.draw itself cannot be interrupted; discard a copy cancelled while drawing.
        guard drawn, !Task.isCancelled else { return nil }
        self.init(width: width, height: height, pixels: pixels, pixelsPerPoint: pixelsPerPoint)
    }

    func pixel(_ x: Int, _ y: Int) -> UInt32 {
        pixels[y * width + x]
    }

    static func matches(_ a: UInt32, _ b: UInt32, tolerance: MeasureTolerance = .medium) -> Bool {
        guard a != b else { return true }
        // These words are AARRGGBB. Measure compares color, with alpha irrelevant on a frozen screen.
        for shift in stride(from: 0, to: 24, by: 8) {
            let difference = abs(Int((a >> UInt32(shift)) & 0xFF) - Int((b >> UInt32(shift)) & 0xFF))
            if difference > tolerance.threshold { return false }
        }
        return true
    }

    /// Strong neighboring edges retain exact coordinates; faint/soft transitions also need support
    /// from nearby scanlines. Gradients remain one surface. Both endpoints belong to the measured span.
    func span(throughX x: Int, y: Int, horizontal: Bool, tolerance: MeasureTolerance = .medium) -> ClosedRange<Int> {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        return MeasurementEdges.span(pixels: pixels, width: width, height: height, x: x, y: y,
                                     horizontal: horizontal, threshold: tolerance.threshold, pixelsPerPoint: Double(pixelsPerPoint))
    }

    /// Bounds of supported pixel-edge contours, clipped to the original selection. Continuous faint
    /// outlines count; a confident strong outline can reject isolated far-away specks. Nil abstains.
    func contentBounds(in rect: CGRect, tolerance: MeasureTolerance = .medium) -> CGRect? {
        let box = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        guard let bounds = MeasurementEdges.bounds(pixels: pixels, width: width, height: height,
            x: Int(box.minX), y: Int(box.minY), boxWidth: Int(box.width), boxHeight: Int(box.height),
            threshold: tolerance.threshold, pixelsPerPoint: Double(pixelsPerPoint)) else { return nil }
        return CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }
}
