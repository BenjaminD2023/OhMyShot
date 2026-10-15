import CoreGraphics

/// Lines cut out of an image and stacked one per row in an image of their own, so a model reads them with
/// nothing else in view. The Latin model's text detector misses whole lines when CJK is anywhere in the
/// image; in a strip of Latin lines alone it finds them all.
struct LineStrip {
    let image: CGImage
    /// Each row's span in `image`, in pixels from the top, in the order the crops were given.
    let rows: [Range<CGFloat>]

    private static let margin = 16

    /// Draws `crops` of `source` one under another, each on its own background (the median of its top and
    /// bottom pixel rows) carried into the gap around it, so light and dark rows can share a strip.
    init?(source: CGImage, crops: [CGRect]) {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let crops = crops.map { $0.integral.intersection(bounds) }
        guard !crops.isEmpty, crops.allSatisfy({ !$0.isNull && $0.width >= 2 && $0.height >= 2 }) else { return nil }
        let margin = Self.margin
        let sizes = crops.map { (width: Int($0.width), height: Int($0.height)) }
        // Rows at least 0.6 of their height apart, so the detector never merges two of them.
        let gaps = sizes.map { max(8, Int((Double($0.height) * 0.6).rounded())) }
        let width = (sizes.map(\.width).max() ?? 0) + margin * 2
        let height = margin * 2 + sizes.map(\.height).reduce(0, +) + gaps.dropLast().reduce(0, +)
        guard width * height <= 40_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // Core Graphics owns the pixels: an image made from a context over borrowed memory can keep
        // pointing at it after the memory is gone.
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let base = context.data else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var rows: [Range<CGFloat>] = []
        var top = margin
        for (index, crop) in crops.enumerated() {
            let (w, h) = sizes[index]
            guard let piece = source.cropping(to: crop) else { return nil }
            // Core Graphics counts y from the bottom; the buffer's first row is the image's top.
            context.draw(piece, in: CGRect(x: margin, y: height - top - h, width: w, height: h))
            let background = Self.medianColor(of: [top, top + h - 1], from: margin, to: margin + w, in: bytes, bytesPerRow: bytesPerRow)
            context.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: 1)
            // The band reaches halfway into the gaps (to the image's edge for the first and last row).
            let above = index == 0 ? top : gaps[index - 1] - gaps[index - 1] / 2
            let below = index == crops.count - 1 ? height - top - h : gaps[index] / 2
            let fills = [
                CGRect(x: 0, y: height - top, width: width, height: above),
                CGRect(x: 0, y: height - top - h - below, width: width, height: below),
                CGRect(x: 0, y: height - top - h, width: margin, height: h),
                CGRect(x: margin + w, y: height - top - h, width: width - margin - w, height: h),
            ]
            context.fill(fills.filter { $0.width > 0 && $0.height > 0 })
            rows.append(CGFloat(top)..<CGFloat(top + h))
            top += h + gaps[index]
        }
        guard let made = context.makeImage() else { return nil }
        image = made
        self.rows = rows
    }

    /// How to split `crops` over strips no taller than `height` pixels each, as ranges of the crops in order (a
    /// crop taller than that gets a strip of its own). Vision shrinks what it is given, so a strip of a few dozen
    /// long lines read in one request loses text the same way a large picture does.
    static func batches(of crops: [CGRect], height limit: CGFloat = 2048) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0
        var used = CGFloat(margin * 2)
        for (index, crop) in crops.enumerated() {
            let height = crop.integral.height + max(8, (crop.integral.height * 0.6).rounded())
            if index > start, used + height > limit {
                batches.append(start..<index)
                start = index
                used = CGFloat(margin * 2)
            }
            used += height
        }
        if start < crops.count { batches.append(start..<crops.count) }
        return batches
    }

    /// The row an observation in the strip belongs to: the one holding its vertical middle.
    func row(of box: CGRect) -> Int? {
        rows.firstIndex { $0.contains(box.midY) }
    }

    /// Where to cut each of `indices`' lines: the box padded a quarter of its height above and below and
    /// half of it to the sides, but never reaching into another line, so no neighbor's glyphs come along.
    static func crops(for indices: [Int], of lines: [OCRLine], in size: CGSize) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: size)
        return indices.map { index in
            let box = lines[index].box
            var top = box.minY - box.height * 0.25
            var bottom = box.maxY + box.height * 0.25
            var left = box.minX - box.height * 0.5
            var right = box.maxX + box.height * 0.5
            for (other, line) in lines.enumerated() where other != index {
                let neighbor = line.box
                let sideBySide = neighbor.minY < box.maxY && neighbor.maxY > box.minY
                if sideBySide {
                    if neighbor.maxX <= box.minX { left = max(left, neighbor.maxX) }
                    if neighbor.minX >= box.maxX { right = min(right, neighbor.minX) }
                } else if neighbor.maxX > left, neighbor.minX < right {
                    if neighbor.maxY <= box.minY { top = max(top, neighbor.maxY) }
                    if neighbor.minY >= box.maxY { bottom = min(bottom, neighbor.minY) }
                }
            }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top).intersection(bounds)
        }
    }

    private static func medianColor(
        of rowIndices: [Int], from start: Int, to end: Int, in bytes: UnsafeMutablePointer<UInt8>, bytesPerRow: Int
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var channels: [[UInt8]] = [[], [], []]
        for row in rowIndices {
            for x in start..<end {
                let offset = row * bytesPerRow + x * 4
                for channel in 0..<3 { channels[channel].append(bytes[offset + channel]) }
            }
        }
        let medians = channels.map { values -> CGFloat in
            let sorted = values.sorted()
            return sorted.isEmpty ? 1 : CGFloat(sorted[sorted.count / 2]) / 255
        }
        return (medians[0], medians[1], medians[2])
    }
}
