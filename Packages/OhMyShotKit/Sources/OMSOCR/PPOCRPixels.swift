import Accelerate
import CoreGraphics
import CoreML
import Foundation
import OMSPixels

/// A picture as 8-bit RGBX pixels, top row first, for the reader's own pixel work (vImage). A class, so the pixels are
/// lent to vImage where they are rather than copied for every crop.
final class PPOCRPixels {
    let width: Int
    let height: Int
    /// `width * 4` bytes a row.
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// `image` drawn at `width` × `height` (its own size when nil). Its pixel values are kept as they are when it is RGB
    /// (as OpenCV reads a file, with no color matching), and converted to sRGB otherwise.
    convenience init?(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let width = width ?? image.width, height = height ?? image.height
        guard width > 0, height > 0 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytes: bytes)
    }

    /// The pixels of `rows` (all of them when nil) as a vImage buffer; vImage only reads them.
    func withBuffer<T>(rows: Range<Int>? = nil, _ body: (inout vImage_Buffer) throws -> T) rethrows -> T {
        let rows = rows ?? 0..<height
        return try bytes.withUnsafeMutableBytes { raw in
            var buffer = vImage_Buffer(
                data: raw.baseAddress!.advanced(by: rows.lowerBound * width * 4), height: vImagePixelCount(rows.count),
                width: vImagePixelCount(width), rowBytes: width * 4
            )
            return try body(&buffer)
        }
    }

    /// Scaled to `width` × `height` as `cv2.resize(…, INTER_LINEAR)` scales.
    func scaled(width: Int, height: Int) -> PPOCRPixels {
        let scaled = bytes.withUnsafeBufferPointer { Resample.bilinear($0, width: self.width, height: self.height, toWidth: width, toHeight: height) }
        return PPOCRPixels(width: width, height: height, bytes: scaled)
    }

    /// The part of the picture inside `quad` (top-left, top-right, bottom-right, bottom-left, in pixels), straightened to
    /// a rectangle as long and as tall as its longer sides, as PaddleOCR's get_rotate_crop_image does it (a perspective
    /// warp, cubic, edges extended); turned a quarter counterclockwise when `verticalRatio` times taller than wide, or more
    /// (vertical text, read as a line).
    func crop(_ quad: [CGPoint], verticalRatio: Double) -> PPOCRPixels? {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        let width = max(Int(max(distance(quad[0], quad[1]), distance(quad[2], quad[3]))), 1)
        let height = max(Int(max(distance(quad[0], quad[3]), distance(quad[1], quad[2]))), 1)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]
        guard let matrix = Self.homography(from: corners, to: quad) else { return nil }
        let warped = bytes.withUnsafeBufferPointer {
            Resample.warpCubic($0, width: self.width, height: self.height, matrix: matrix, toWidth: width, toHeight: height)
        }
        guard Double(height) / Double(width) >= verticalRatio else { return PPOCRPixels(width: width, height: height, bytes: warped) }
        let turned = warped.withUnsafeBufferPointer { Resample.turnedCounterclockwise($0, width: width, height: height) }
        return PPOCRPixels(width: height, height: width, bytes: turned)
    }

    /// The 3 × 3 perspective map (row-major) taking each of `from`'s four points to the same one of `to`'s, as
    /// `cv2.getPerspectiveTransform` solves it; nil when the points don't make one.
    static func homography(from: [CGPoint], to: [CGPoint]) -> [Double]? {
        // Eight equations in the map's eight unknowns (the ninth is 1), solved by elimination.
        var rows: [[Double]] = []
        for (p, q) in zip(from, to) {
            let x = Double(p.x), y = Double(p.y), u = Double(q.x), v = Double(q.y)
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        for column in 0..<8 {
            guard let pivot = (column..<8).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }), abs(rows[pivot][column]) > 1e-12 else { return nil }
            rows.swapAt(column, pivot)
            for row in 0..<8 where row != column {
                let factor = rows[row][column] / rows[column][column]
                guard factor != 0 else { continue }
                for k in column..<9 { rows[row][k] -= factor * rows[column][k] }
            }
        }
        return (0..<8).map { rows[$0][8] / rows[$0][$0] } + [1]
    }

    /// Writes `rows` of the picture into `array` (1 × 3 × H × W float32, already filled with the padding) from its top-left
    /// corner, channel by channel in BGR order, each value (v / 255 - mean) / std for that channel.
    func write(rows: Range<Int>, into array: MLMultiArray, mean: [Float], std: [Float]) {
        let planeHeight = array.shape[2].intValue, planeWidth = array.shape[3].intValue
        let height = min(rows.count, planeHeight), width = min(self.width, planeWidth)
        guard height > 0, width > 0 else { return }
        let floats = array.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = planeHeight * planeWidth
        // This picture's channels are R, G, B, X; the model's are B, G, R: R goes to plane 2, G to 1, B to 0.
        let model = [2, 1, 0]
        var maximum = [Float](repeating: 1, count: 4), minimum = [Float](repeating: 0, count: 4)
        for channel in 0..<3 {
            let c = model[channel]
            minimum[channel] = -mean[c] / std[c]
            maximum[channel] = (1 - mean[c]) / std[c]
        }
        var scratch = [Float](repeating: 0, count: width * height)
        withBuffer(rows: rows.lowerBound..<(rows.lowerBound + height)) { source in
            source.width = vImagePixelCount(width)
            func planeBuffer(_ index: Int) -> vImage_Buffer {
                vImage_Buffer(data: floats.advanced(by: index * plane), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: planeWidth * 4)
            }
            var red = planeBuffer(model[0]), green = planeBuffer(model[1]), blue = planeBuffer(model[2])
            scratch.withUnsafeMutableBytes { raw in
                var unused = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                _ = vImageConvert_ARGB8888toPlanarF(&source, &red, &green, &blue, &unused, maximum, minimum, vImage_Flags(kvImageNoFlags))
            }
        }
    }
}

extension MLMultiArray {
    /// A 1 × 3 × `height` × `width` float32 array filled with `value`.
    static func planes(height: Int, width: Int, filledWith value: Float) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        var fill = value
        vDSP_vfill(&fill, array.dataPointer.assumingMemoryBound(to: Float.self), 1, vDSP_Length(3 * height * width))
        return array
    }

    /// The array's values as float32, row-major over its shape whatever its strides and its type (float32 or float16).
    func floats() throws -> [Float] {
        let count = shape.reduce(1) { $0 * $1.intValue }
        var result = [Float](repeating: 0, count: count)
        let dims = shape.map(\.intValue), steps = strides.map(\.intValue)
        // Row by row along the last dimension, which these models keep contiguous.
        guard steps.last == 1 else { throw PPOCRError.unexpectedOutput("a last dimension that isn't contiguous") }
        let rowLength = dims.last ?? 1, rows = count / max(rowLength, 1)
        func offset(ofRow row: Int) -> Int {
            var remainder = row, offset = 0
            for axis in stride(from: dims.count - 2, through: 0, by: -1) {
                offset += (remainder % dims[axis]) * steps[axis]
                remainder /= dims[axis]
            }
            return offset
        }
        switch dataType {
        case .float32:
            let source = dataPointer.assumingMemoryBound(to: Float.self)
            result.withUnsafeMutableBufferPointer { destination in
                for row in 0..<rows {
                    (destination.baseAddress! + row * rowLength).update(from: source + offset(ofRow: row), count: rowLength)
                }
            }
        case .float16:
            let source = dataPointer.assumingMemoryBound(to: UInt16.self)
            result.withUnsafeMutableBufferPointer { destination in
                for row in 0..<rows {
                    var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source + offset(ofRow: row)), height: 1, width: vImagePixelCount(rowLength), rowBytes: rowLength * 2)
                    var output = vImage_Buffer(data: destination.baseAddress! + row * rowLength, height: 1, width: vImagePixelCount(rowLength), rowBytes: rowLength * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageNoFlags))
                }
            }
        default:
            throw PPOCRError.unexpectedOutput("values of type \(dataType.rawValue)")
        }
        return result
    }
}
