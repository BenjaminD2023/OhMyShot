/// OpenCV's resampling of 8-bit 4-channel pixels, so a model reads what it read in the Python that checked it
/// (Tools/model-packs/ppocr_pack.py): `cv2.resize` with `INTER_LINEAR`, `cv2.warpPerspective` with `INTER_CUBIC` and
/// `BORDER_REPLICATE`, and `np.rot90`. Pixels are rows of `width * 4` bytes, top row first.
public enum Resample {
    /// `cv2.resize(…, INTER_LINEAR)`: each destination pixel's center mapped back into the source, the four nearest
    /// pixels weighed, columns and rows past the edge taken from the edge.
    public static func bilinear(_ source: UnsafeBufferPointer<UInt8>, width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        precondition(source.count >= width * height * 4)
        var result = [UInt8](repeating: 0, count: toWidth * toHeight * 4)
        guard width > 0, height > 0, toWidth > 0, toHeight > 0 else { return result }
        func taps(_ count: Int, _ to: Int) -> [(Int, Int, Double)] {
            let scale = Double(count) / Double(to)
            return (0..<to).map { d in
                var f = (Double(d) + 0.5) * scale - 0.5
                var s = Int(f.rounded(.down))
                f -= Double(s)
                if s < 0 { s = 0; f = 0 }
                if s >= count - 1 { s = count - 1; f = 0 }
                return (s, min(s + 1, count - 1), f)
            }
        }
        let xs = taps(width, toWidth), ys = taps(height, toHeight)
        result.withUnsafeMutableBufferPointer { out in
            for (dy, (y0, y1, fy)) in ys.enumerated() {
                let row0 = y0 * width * 4, row1 = y1 * width * 4
                for (dx, (x0, x1, fx)) in xs.enumerated() {
                    let a = (1 - fx) * (1 - fy), b = fx * (1 - fy), c = (1 - fx) * fy, d = fx * fy
                    let p00 = row0 + x0 * 4, p01 = row0 + x1 * 4, p10 = row1 + x0 * 4, p11 = row1 + x1 * 4
                    let o = (dy * toWidth + dx) * 4
                    for k in 0..<4 {
                        let v = a * Double(source[p00 + k]) + b * Double(source[p01 + k]) + c * Double(source[p10 + k]) + d * Double(source[p11 + k])
                        out[o + k] = UInt8(min(max(v.rounded(), 0), 255))
                    }
                }
            }
        }
        return result
    }

    /// `cv2.warpPerspective(…, INTER_CUBIC, BORDER_REPLICATE)`: each destination pixel (x, y) takes the source at
    /// `matrix · (x, y, 1)` (row-major 3 × 3, destination to source), weighed over 4 × 4 pixels with OpenCV's cubic
    /// (a = −0.75), pixels past the edge taken from the edge.
    public static func warpCubic(_ source: UnsafeBufferPointer<UInt8>, width: Int, height: Int, matrix: [Double], toWidth: Int, toHeight: Int) -> [UInt8] {
        precondition(source.count >= width * height * 4 && matrix.count == 9)
        var result = [UInt8](repeating: 0, count: toWidth * toHeight * 4)
        guard width > 0, height > 0, toWidth > 0, toHeight > 0 else { return result }
        func weights(_ x: Double) -> (Double, Double, Double, Double) {
            let a = -0.75
            let w0 = ((a * (x + 1) - 5 * a) * (x + 1) + 8 * a) * (x + 1) - 4 * a
            let w1 = ((a + 2) * x - (a + 3)) * x * x + 1
            let w2 = ((a + 2) * (1 - x) - (a + 3)) * (1 - x) * (1 - x) + 1
            return (w0, w1, w2, 1 - w0 - w1 - w2)
        }
        result.withUnsafeMutableBufferPointer { out in
            for dy in 0..<toHeight {
                for dx in 0..<toWidth {
                    let x = Double(dx), y = Double(dy)
                    let w = matrix[6] * x + matrix[7] * y + matrix[8]
                    let sx = (matrix[0] * x + matrix[1] * y + matrix[2]) / w, sy = (matrix[3] * x + matrix[4] * y + matrix[5]) / w
                    let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down))
                    let (wx0, wx1, wx2, wx3) = weights(sx - Double(ix)), (wy0, wy1, wy2, wy3) = weights(sy - Double(iy))
                    let wx = [wx0, wx1, wx2, wx3], wy = [wy0, wy1, wy2, wy3]
                    var sums = (0.0, 0.0, 0.0, 0.0)
                    for j in 0..<4 {
                        let row = min(max(iy - 1 + j, 0), height - 1) * width * 4
                        for i in 0..<4 {
                            let p = row + min(max(ix - 1 + i, 0), width - 1) * 4
                            let weight = wx[i] * wy[j]
                            sums.0 += weight * Double(source[p])
                            sums.1 += weight * Double(source[p + 1])
                            sums.2 += weight * Double(source[p + 2])
                            sums.3 += weight * Double(source[p + 3])
                        }
                    }
                    let o = (dy * toWidth + dx) * 4
                    out[o] = UInt8(min(max(sums.0.rounded(), 0), 255))
                    out[o + 1] = UInt8(min(max(sums.1.rounded(), 0), 255))
                    out[o + 2] = UInt8(min(max(sums.2.rounded(), 0), 255))
                    out[o + 3] = UInt8(min(max(sums.3.rounded(), 0), 255))
                }
            }
        }
        return result
    }

    /// `np.rot90`: turned a quarter counterclockwise, so the source's last column becomes the first row.
    public static func turnedCounterclockwise(_ source: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBufferPointer { out in
            // The result is `height` wide and `width` tall: its pixel (i, j) (row i, column j) is the source's (j, width - 1 - i).
            for i in 0..<width {
                for j in 0..<height {
                    let s = (j * width + (width - 1 - i)) * 4, o = (i * height + j) * 4
                    out[o] = source[s]; out[o + 1] = source[s + 1]; out[o + 2] = source[s + 2]; out[o + 3] = source[s + 3]
                }
            }
        }
        return result
    }
}
