/// The formula pack's per-pixel work (OMSOCR's FormulaPicture holds the rules), here so it is fast in debug builds
/// too. Pixels are rows of `width * 4` bytes, RGBX, top row first.
public enum FormulaPixels {
    /// The pixels with their red, green, and blue inverted (255 - value), the fourth byte kept.
    public static func inverted(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        result.withUnsafeMutableBufferPointer { out in
            var i = 0
            while i + 2 < out.count {
                out[i] = 255 - out[i]; out[i + 1] = 255 - out[i + 1]; out[i + 2] = 255 - out[i + 2]
                i += 4
            }
        }
        return result
    }

    /// The box (x, y, width, height) of the pixels darker than `threshold` once their gray (torchvision's: 0.2989 R +
    /// 0.587 G + 0.114 B in 32-bit floats, truncated to 8 bits) is stretched to 0-255; nil when the picture is one shade.
    public static func inkBox(_ bytes: [UInt8], width: Int, height: Int, threshold: Float) -> (x: Int, y: Int, width: Int, height: Int)? {
        var grays = [Float](repeating: 0, count: width * height)
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        bytes.withUnsafeBufferPointer { source in
            grays.withUnsafeMutableBufferPointer { out in
                for i in 0..<(width * height) {
                    let r = Float(source[i * 4]), g = Float(source[i * 4 + 1]), b = Float(source[i * 4 + 2])
                    let gray = Float(UInt8(r * 0.2989 + g * 0.587 + b * 0.114))
                    out[i] = gray
                    low = min(low, gray); high = max(high, gray)
                }
            }
        }
        guard width > 0, height > 0, low != high else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        grays.withUnsafeBufferPointer { grays in
            for y in 0..<height {
                for x in 0..<width where (grays[y * width + x] - low) / (high - low) * 255 < threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// The pixels of the box at (x, y), `boxWidth` × `boxHeight`, of a picture `width` pixels wide.
    public static func cropped(_ bytes: [UInt8], width: Int, x: Int, y: Int, boxWidth: Int, boxHeight: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: boxWidth * boxHeight * 4)
        bytes.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { out in
                for row in 0..<boxHeight {
                    let from = ((y + row) * width + x) * 4, to = row * boxWidth * 4
                    for i in 0..<(boxWidth * 4) { out[to + i] = source[from + i] }
                }
            }
        }
        return result
    }

    /// Three planes (red, green, blue) of `size` × `size` values: the `width` × `height` pixels centered (their top-left
    /// at ((size - width) / 2, (size - height) / 2)), each (value / 255 - mean) / std for its channel, and around them
    /// the same of `padding`.
    public static func planes(_ bytes: [UInt8], width: Int, height: Int, size: Int, mean: [Float], std: [Float], padding: UInt8) -> [Float] {
        precondition(mean.count == 3 && std.count == 3 && width <= size && height <= size)
        let plane = size * size
        let top = (size - height) / 2, left = (size - width) / 2
        var values = [Float](repeating: 0, count: 3 * plane)
        bytes.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { out in
                for c in 0..<3 {
                    let m = mean[c], s = std[c]
                    let around = (Float(padding) / 255 - m) / s
                    for i in (c * plane)..<((c + 1) * plane) { out[i] = around }
                    for y in 0..<height {
                        let row = c * plane + (top + y) * size + left
                        for x in 0..<width { out[row + x] = (Float(source[(y * width + x) * 4 + c]) / 255 - m) / s }
                    }
                }
            }
        }
        return values
    }
}
