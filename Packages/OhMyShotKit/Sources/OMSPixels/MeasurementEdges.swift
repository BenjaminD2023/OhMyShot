/// Screen measurement on packed AARRGGBB pixels. Built optimized even in Debug: pointer scans must not
/// allocate a full-frame edge map. Area detection runs only inside the user's selection.
public enum MeasurementEdges {
    public struct Bounds: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    @inline(__always)
    private static func difference(_ a: UInt32, _ b: UInt32) -> Int {
        if a == b { return 0 }
        return max(abs(Int(a & 255) - Int(b & 255)),
            abs(Int((a >> 8) & 255) - Int((b >> 8) & 255)),
            abs(Int((a >> 16) & 255) - Int((b >> 16) & 255)))
    }

    private struct Detector {
        let pixels: [UInt32]
        let width: Int
        let height: Int
        let threshold: Int
        let radius: Int
        let weakThreshold: Int
        let prominenceThreshold: Int

        init(pixels: [UInt32], width: Int, height: Int, threshold: Int, radius: Int) {
            self.pixels = pixels
            self.width = width
            self.height = height
            self.threshold = threshold
            self.radius = radius
            weakThreshold = max(2, (threshold * 55 + 99) / 100)
            prominenceThreshold = max(2, threshold / 3)
        }

        @inline(__always)
        func sample(_ along: Int, _ across: Int, horizontal: Bool) -> UInt32 {
            pixels[horizontal ? across * width + along : along * width + across]
        }

        @inline(__always)
        func step(_ cut: Int, _ across: Int, horizontal: Bool) -> Int {
            difference(sample(cut - 1, across, horizontal: horizontal), sample(cut, across, horizontal: horizontal))
        }

        /// Remove the surrounding slope, cap by actual central contrast, and reject responses with an
        /// inverted sign. A linear background ramp cancels; a localized antialiased transition remains.
        func softScore(_ cut: Int, _ across: Int, horizontal: Bool) -> Double {
            let count = horizontal ? width : height
            let r = radius
            guard cut >= 3 * r, cut + 2 * r < count else { return 0 }
            let a = sample(cut - 3 * r, across, horizontal: horizontal)
            let b = sample(cut - 2 * r, across, horizontal: horizontal)
            let c = sample(cut + r, across, horizontal: horizontal)
            let d = sample(cut + 2 * r, across, horizontal: horizontal)
            var score = 0.0
            for shift: UInt32 in [0, 8, 16] {
                let av = Double((a >> shift) & 255), bv = Double((b >> shift) & 255)
                let cv = Double((c >> shift) & 255), dv = Double((d >> shift) & 255)
                let central = cv - bv
                let localized = central - 1.5 * ((bv - av) + (dv - cv))
                if central * localized > 0 { score = max(score, min(abs(central), abs(localized))) }
            }
            return score
        }

        /// 2 is an exact strong boundary; 1 needs spatial support; 0 is not a credible boundary.
        func kind(_ cut: Int, _ across: Int, horizontal: Bool) -> UInt8 {
            let delta = step(cut, across, horizontal: horizontal)
            guard delta > 0 else { return 0 }
            if delta > threshold { return 2 }
            guard threshold > 0 else { return 0 }
            let count = horizontal ? width : height
            let r = radius
            // Long faint edges count, but a sequence of equal gradient steps must remain one surface.
            if delta >= weakThreshold,
               cut - 2 * r >= 1, cut + 2 * r < count {
                let before = sample(cut - 1, across, horizontal: horizontal)
                let after = sample(cut, across, horizontal: horizontal)
                let farBefore = sample(cut - 2 * r - 1, across, horizontal: horizontal)
                let nearBefore = sample(cut - 2 * r, across, horizontal: horizontal)
                let nearAfter = sample(cut + 2 * r - 1, across, horizontal: horizontal)
                let farAfter = sample(cut + 2 * r, across, horizontal: horizontal)
                for shift: UInt32 in [0, 8, 16] {
                    let central = Int((after >> shift) & 255) - Int((before >> shift) & 255)
                    let leading = Int((nearBefore >> shift) & 255) - Int((farBefore >> shift) & 255)
                    let trailing = Int((farAfter >> shift) & 255) - Int((nearAfter >> shift) & 255)
                    // The opposite side of a thin rule has opposite polarity: it is not a background
                    // slope and must not suppress this edge when it lands exactly on a probe offset.
                    let surrounding = max(central * leading > 0 ? abs(leading) : 0, central * trailing > 0 ? abs(trailing) : 0)
                    if abs(central) >= weakThreshold, abs(central) - surrounding >= prominenceThreshold { return 1 }
                }
            }
            let score = softScore(cut, across, horizontal: horizontal)
            guard score > Double(threshold) else { return 0 }
            // Strong raw edges own their exact coordinates; broad probes must not ring before them.
            for neighbor in max(1, cut - 2 * r)...min(count - 1, cut + 2 * r) {
                if step(neighbor, across, horizontal: horizontal) > threshold { return 0 }
            }
            guard score >= softScore(cut - 1, across, horizontal: horizontal),
                  score > softScore(cut + 1, across, horizontal: horizontal) else { return 0 }
            return 1
        }

        func supported(_ cut: Int, _ across: Int, horizontal: Bool) -> Bool {
            let primary = kind(cut, across, horizontal: horizontal)
            if primary == 2 { return true }
            guard primary == 1 else { return false }
            let perpendicularCount = horizontal ? height : width
            var votes = 0
            // Count unique scanlines; clamping five probes to a one-row image would invent support.
            for other in max(0, across - 2 * radius)...min(perpendicularCount - 1, across + 2 * radius) {
                if kind(cut, other, horizontal: horizontal) > 0 { votes += 1 }
                if votes >= 3 { return true }
            }
            return false
        }
    }

    public static func span(pixels: [UInt32], width: Int, height: Int, x: Int, y: Int, horizontal: Bool,
                            threshold: Int, pixelsPerPoint: Double) -> ClosedRange<Int> {
        let detector = Detector(pixels: pixels, width: width, height: height, threshold: threshold,
                                radius: max(1, min(3, Int(pixelsPerPoint.rounded()))))
        let start = horizontal ? x : y, across = horizontal ? y : x
        let count = horizontal ? width : height
        var low = start, high = start
        while low > 0, !detector.supported(low, across, horizontal: horizontal) { low -= 1 }
        while high + 1 < count, !detector.supported(high + 1, across, horizontal: horizontal) { high += 1 }
        return low...high
    }

    private struct Contour {
        var left: Int
        var right: Int
        var top: Int
        var bottom: Int
        var count = 0
        var strong = 0
        var open = false
        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    /// Edges live on pixel boundaries, so a 40-pixel rectangle returns width 40 without expanding by a
    /// halo pixel. Weak contours need sustained support; truly isolated outliers are ignored only when
    /// a substantial closed strong outline establishes the intended object.
    public static func bounds(pixels: [UInt32], width: Int, height: Int, x: Int, y: Int,
                              boxWidth: Int, boxHeight: Int, threshold: Int, pixelsPerPoint: Double) -> Bounds? {
        guard boxWidth > 0, boxHeight > 0, !Task.isCancelled else { return nil }
        let scale = max(1, min(3, Int(pixelsPerPoint.rounded())))
        let detector = Detector(pixels: pixels, width: width, height: height, threshold: threshold, radius: scale)
        if boxWidth == 1 || boxHeight == 1 {
            let horizontal = boxHeight == 1, length = horizontal ? boxWidth : boxHeight
            let start = horizontal ? x : y, across = horizontal ? y : x
            var first: Int?, last: Int?
            for cut in 1..<length where detector.step(start + cut, across, horizontal: horizontal) > threshold {
                if first == nil { first = cut }
                last = cut
            }
            guard let first, let last, last > first else { return nil }
            return Bounds(x: x + (horizontal ? first : 0), y: y + (horizontal ? 0 : first),
                          width: horizontal ? last - first : 1, height: horizontal ? 1 : last - first)
        }
        let stride = boxWidth + 1
        // Low four bits are graph directions; bit 4 marks strong evidence; bit 5 marks visited nodes.
        var nodes = [UInt8](repeating: 0, count: stride * (boxHeight + 1))
        for row in 0..<boxHeight {
            guard !Task.isCancelled else { return nil }
            for column in 0..<boxWidth {
                let node = row * stride + column
                if column > 0 {
                    let kind = detector.kind(x + column, y + row, horizontal: true)
                    if kind > 0 {
                        let strong: UInt8 = kind == 2 ? 16 : 0
                        nodes[node] |= 2 | strong
                        nodes[node + stride] |= 1 | strong
                    }
                }
                if row > 0 {
                    let kind = detector.kind(y + row, x + column, horizontal: false)
                    if kind > 0 {
                        let strong: UInt8 = kind == 2 ? 16 : 0
                        nodes[node] |= 8 | strong
                        nodes[node + 1] |= 4 | strong
                    }
                }
            }
        }
        var contours: [Contour] = []
        var horizontalCuts: [Contour] = []
        var verticalCuts: [Contour] = []
        var stack: [Int] = []
        for start in nodes.indices {
            if start & 4095 == 0, Task.isCancelled { return nil }
            guard nodes[start] & 15 != 0, nodes[start] & 32 == 0 else { continue }
            let startX = start % stride, startY = start / stride
            var contour = Contour(left: startX, right: startX, top: startY, bottom: startY)
            nodes[start] |= 32
            stack.append(start)
            while let node = stack.popLast() {
                if contour.count & 4095 == 0, Task.isCancelled { return nil }
                let flags = nodes[node], column = node % stride, row = node / stride
                contour.left = min(contour.left, column)
                contour.right = max(contour.right, column)
                contour.top = min(contour.top, row)
                contour.bottom = max(contour.bottom, row)
                contour.count += 1
                if flags & 16 != 0 { contour.strong += 1 }
                if (flags & 15).nonzeroBitCount == 1 { contour.open = true }
                for (bit, offset) in [(UInt8(1), -stride), (2, stride), (4, -1), (8, 1)] where flags & bit != 0 {
                    let next = node + offset
                    if nodes[next] & 32 == 0 {
                        nodes[next] |= 32
                        stack.append(next)
                    }
                }
            }
            // A band can extend beyond both sides of the user's crop. Its two open boundaries still
            // enclose content within that crop; one transition alone remains ambiguous.
            if contour.height == 0, contour.width == boxWidth {
                horizontalCuts.append(contour)
                continue
            }
            if contour.width == 0, contour.height == boxHeight {
                verticalCuts.append(contour)
                continue
            }
            guard contour.width > 0, contour.height > 0 else { continue }
            if contour.strong > 0 || (!contour.open && contour.count >= 16 * scale) {
                contours.append(contour)
            }
        }
        if horizontalCuts.count >= 2, let top = horizontalCuts.map(\.top).min(), let bottom = horizontalCuts.map(\.bottom).max() {
            contours.append(Contour(left: 0, right: boxWidth, top: top, bottom: bottom, open: true))
        }
        if verticalCuts.count >= 2, let left = verticalCuts.map(\.left).min(), let right = verticalCuts.map(\.right).max() {
            contours.append(Contour(left: left, right: right, top: 0, bottom: boxHeight, open: true))
        }
        let outlines = contours.filter {
            !$0.open && $0.width >= 8 * scale && $0.height >= 8 * scale &&
                $0.strong >= ($0.width + $0.height) && $0.count >= ($0.width + $0.height)
        }
        if threshold > 0, !outlines.isEmpty {
            contours.removeAll { contour in
                guard contour.width <= scale, contour.height <= scale else { return false }
                // Nearby punctuation and disconnected image detail stay with the object.
                return outlines.allSatisfy { outline in
                    let dx = max(outline.left - contour.right, contour.left - outline.right, 0)
                    let dy = max(outline.top - contour.bottom, contour.top - outline.bottom, 0)
                    return max(dx, dy) > 8 * scale
                }
            }
        }
        guard let first = contours.first else { return nil }
        let left = contours.reduce(first.left) { min($0, $1.left) }
        let right = contours.reduce(first.right) { max($0, $1.right) }
        let top = contours.reduce(first.top) { min($0, $1.top) }
        let bottom = contours.reduce(first.bottom) { max($0, $1.bottom) }
        return Bounds(x: x + left, y: y + top, width: right - left, height: bottom - top)
    }
}
