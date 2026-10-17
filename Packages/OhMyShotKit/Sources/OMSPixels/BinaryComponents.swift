/// The connected regions of a probability map above a threshold, for reading text boxes out of a text detector's
/// output (PP-OCR's DB post-processing). Built with optimization always, as the rest of this module: a map is
/// millions of pixels, read once per detection.
public enum BinaryComponents {
    /// One region, 8-connected: for each row it spans, the leftmost and rightmost pixel in it, and its pixel count.
    public struct Component: Sendable, Equatable {
        public var top: Int
        /// `left[i]` and `right[i]` are the extremes of row `top + i`, over every run of the region in it (a U shape's
        /// arms put two runs in one row).
        public var left: [Int]
        public var right: [Int]
        public var count: Int

        public var bottom: Int { top + left.count - 1 }
    }

    /// The regions of `values` (row by row, `width` × `height`) greater than `threshold`, in the order their first
    /// pixel comes reading row by row; at most `limit` of them.
    public static func components(of values: UnsafeBufferPointer<Float>, width: Int, height: Int, threshold: Float, limit: Int) -> [Component] {
        precondition(values.count >= width * height)
        guard width > 0, height > 0 else { return [] }
        let count = width * height
        // 0: below the threshold; -1: above it, not yet labeled; > 0: the region's number.
        var labels = [Int32](repeating: 0, count: count)
        labels.withUnsafeMutableBufferPointer { labels in
            for index in 0..<count where values[index] > threshold { labels[index] = -1 }
        }
        // First, each region's number, and the rows it spans.
        var spans: [(top: Int, bottom: Int, count: Int)] = []
        var stack: [Int] = []
        stack.reserveCapacity(1024)
        labels.withUnsafeMutableBufferPointer { labels in
            for start in 0..<count where labels[start] == -1 {
                guard spans.count < limit else { break }
                let label = Int32(spans.count + 1)
                labels[start] = label
                stack.append(start)
                var top = start / width, bottom = top, pixels = 0
                while let index = stack.popLast() {
                    let row = index / width, column = index % width
                    top = min(top, row)
                    bottom = max(bottom, row)
                    pixels += 1
                    for dy in -1...1 {
                        let y = row + dy
                        guard y >= 0, y < height else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let x = column + dx
                            guard x >= 0, x < width else { continue }
                            let neighbor = y * width + x
                            if labels[neighbor] == -1 {
                                labels[neighbor] = label
                                stack.append(neighbor)
                            }
                        }
                    }
                }
                spans.append((top, bottom, pixels))
            }
        }
        // Then each row's extremes, region by region, in one pass. Pixels left unlabeled past `limit` stay -1.
        var components = spans.map { span in
            Component(top: span.top, left: Array(repeating: -1, count: span.bottom - span.top + 1),
                      right: Array(repeating: -1, count: span.bottom - span.top + 1), count: span.count)
        }
        labels.withUnsafeBufferPointer { labels in
            for row in 0..<height {
                for column in 0..<width {
                    let label = Int(labels[row * width + column])
                    guard label > 0 else { continue }
                    let i = row - components[label - 1].top
                    if components[label - 1].left[i] < 0 { components[label - 1].left[i] = column }
                    components[label - 1].right[i] = column
                }
            }
        }
        return components
    }

    /// The mean of `values` over the pixels whose centers lie inside the convex polygon `corners` (pixel coordinates,
    /// in order around it), and its edges' pixels, as OpenCV's fillPoly marks them; 0 when it covers none.
    public static func mean(of values: UnsafeBufferPointer<Float>, width: Int, height: Int, inside corners: [(x: Double, y: Double)]) -> Double {
        guard corners.count >= 3, width > 0, height > 0 else { return 0 }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = max(Int(xs.min()!.rounded(.down)), 0), maxX = min(Int(xs.max()!.rounded(.up)), width - 1)
        let minY = max(Int(ys.min()!.rounded(.down)), 0), maxY = min(Int(ys.max()!.rounded(.up)), height - 1)
        guard minX <= maxX, minY <= maxY else { return 0 }
        // Which side of every edge the inside is on, from the polygon's winding.
        var area = 0.0
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            area += a.x * b.y - b.x * a.y
        }
        let sign: Double = area >= 0 ? 1 : -1
        var sum = 0.0, covered = 0
        for y in minY...maxY {
            let py = Double(y)
            for x in minX...maxX {
                let px = Double(x)
                var inside = true
                for i in corners.indices {
                    let a = corners[i], b = corners[(i + 1) % corners.count]
                    // Half a pixel of slack: pixels the edge runs through count, as fillPoly's do.
                    let cross = ((b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)) * sign
                    let length = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
                    if cross < -0.5 * length {
                        inside = false
                        break
                    }
                }
                if inside {
                    sum += Double(values[y * width + x])
                    covered += 1
                }
            }
        }
        return covered > 0 ? sum / Double(covered) : 0
    }
}
