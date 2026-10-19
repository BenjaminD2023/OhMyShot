import CoreGraphics
import Foundation
import OMSPixels

/// A picture as PaddleOCR-VL's processor gives it to the model (mlx-vlm's `ImageProcessor`, models/paddleocr_vl/
/// processing_paddleocr_vl.py): scaled with PIL's bicubic filter to whole 28-pixel blocks between `minimumPixels` and
/// `maximumPixels`, each value v made (v / 255 - 0.5) / 0.5, and cut into 14 × 14 patches row by row of the grid, each
/// patch's channels apart ([count, 3, 14, 14]).
public struct PaddleOCRVLPicture: Sendable {
    public static let patchSize = 14
    public static let mergeSize = 2
    /// The processor's bounds (preprocessor_config.json): 1280 and 144 blocks of 28 × 28 pixels.
    public static let minimumPixels = 112_896
    public static let maximumPixels = 1_003_520

    /// The grid's rows and columns of patches.
    public let height: Int
    public let width: Int
    /// The patches' values, [height × width, 3, 14, 14], in float32.
    public let values: [Float]

    /// How many embeddings the picture becomes: one for each 2 × 2 patches.
    public var tokens: Int { height * width / (Self.mergeSize * Self.mergeSize) }

    public enum Failure: Error {
        case undrawable
        /// One side more than 200 times the other, which the processor refuses.
        case tooNarrow
    }

    /// The size the processor scales a `height` × `width` picture to (its `smart_resize`, Python's rounding of halves
    /// to even included).
    public static func scaledSize(height: Int, width: Int, factor: Int = patchSize * mergeSize,
                                  minimumPixels: Int = minimumPixels, maximumPixels: Int = maximumPixels) throws -> (height: Int, width: Int) {
        var height = Double(height), width = Double(width)
        let factor = Double(factor)
        if height < factor {
            width = (width * factor / height).rounded(.toNearestOrEven)
            height = factor
        }
        if width < factor {
            height = (height * factor / width).rounded(.toNearestOrEven)
            width = factor
        }
        guard max(height, width) / min(height, width) <= 200 else { throw Failure.tooNarrow }
        var scaledHeight = (height / factor).rounded(.toNearestOrEven) * factor
        var scaledWidth = (width / factor).rounded(.toNearestOrEven) * factor
        if scaledHeight * scaledWidth > Double(maximumPixels) {
            let beta = (height * width / Double(maximumPixels)).squareRoot()
            scaledHeight = Foundation.floor(height / beta / factor) * factor
            scaledWidth = Foundation.floor(width / beta / factor) * factor
        } else if scaledHeight * scaledWidth < Double(minimumPixels) {
            let beta = (Double(minimumPixels) / (height * width)).squareRoot()
            scaledHeight = ceil(height * beta / factor) * factor
            scaledWidth = ceil(width * beta / factor) * factor
        }
        return (Int(scaledHeight), Int(scaledWidth))
    }

    /// The model's value for each 8-bit value, as NumPy computes it in 64-bit floats.
    static let normalized: [Float] = (0...255).map { Float((Double($0) / 255 - 0.5) / 0.5) }

    /// A picture already cut into patches, for tests.
    init(height: Int, width: Int, values: [Float]) {
        self.height = height
        self.width = width
        self.values = values
    }

    /// `bytes`: RGBX, `width * 4` a row, top row first.
    public init(bytes: [UInt8], width: Int, height: Int) throws {
        let size = try Self.scaledSize(height: height, width: width)
        let scaled = bytes.withUnsafeBufferPointer {
            Resample.antialiased($0, width: width, height: height, toWidth: size.width, toHeight: size.height, filter: .bicubic)
        }
        let patch = Self.patchSize
        let rows = size.height / patch, columns = size.width / patch
        var values = [Float](repeating: 0, count: rows * columns * 3 * patch * patch)
        values.withUnsafeMutableBufferPointer { out in
            var o = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    for channel in 0..<3 {
                        for y in 0..<patch {
                            let line = ((row * patch + y) * size.width + column * patch) * 4 + channel
                            for x in 0..<patch {
                                out[o] = Self.normalized[Int(scaled[line + x * 4])]
                                o += 1
                            }
                        }
                    }
                }
            }
        }
        self.height = rows
        self.width = columns
        self.values = values
    }

    /// The picture's pixels as they are when it is RGB (as PIL reads a file, with no color matching), in sRGB
    /// otherwise.
    public init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.undrawable }
        try self.init(bytes: bytes, width: width, height: height)
    }
}
