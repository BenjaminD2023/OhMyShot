import CoreGraphics
import Foundation
import OMSPixels

/// The geometry of PP-OCR's detection, as PaddleOCR's DBPostProcess and Tools/model-packs/ppocr_pack.py do it: the
/// bands a region is read in, each region's box (its minimum-area rectangle, grown by the unclip ratio), and the order
/// boxes are read in.
enum PPOCRGeometry {
    /// A band of a region `height` tall: its rows, and its core, the rows whose lines it keeps.
    struct Band: Equatable {
        var top: Int
        var bottom: Int
        var coreTop: Int
        var coreBottom: Int
    }

    /// Bands `band` tall, each reaching `overlap` into the next; the core of each ends halfway through the overlap
    /// it shares, so a line belongs to the one band whose core holds its center.
    static func bands(height: Int, band: Int, overlap: Int) -> [Band] {
        guard height > band else { return [Band(top: 0, bottom: height, coreTop: 0, coreBottom: height)] }
        var starts = Array(stride(from: 0, to: height - band, by: band - overlap))
        starts.append(height - band)
        return starts.enumerated().map { i, top in
            Band(
                top: top, bottom: top + band,
                coreTop: i == 0 ? 0 : (top + starts[i - 1] + band) / 2,
                coreBottom: i == starts.count - 1 ? height : (top + band + starts[i + 1]) / 2
            )
        }
    }

    /// The convex hull of `points`, counterclockwise in a y-up sense (Andrew's monotone chain).
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let unique: Set<SIMD2<Double>> = Set(points.map { SIMD2<Double>(Double($0.x), Double($0.y)) })
        let ordered: [SIMD2<Double>] = unique.sorted { (a: SIMD2<Double>, b: SIMD2<Double>) -> Bool in a.x != b.x ? a.x < b.x : a.y < b.y }
        let sorted: [CGPoint] = ordered.map { CGPoint(x: $0.x, y: $0.y) }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The smallest rectangle around `points`, as its four corners (in no particular order), and its two sides.
    static func minimumAreaRectangle(_ points: [CGPoint]) -> (corners: [CGPoint], width: CGFloat, height: CGFloat) {
        let hull = convexHull(points)
        guard hull.count > 2 else {
            // A point or a line: a rectangle of no width along it.
            let a = hull.first ?? .zero, b = hull.last ?? .zero
            return ([a, b, b, a], hypot(b.x - a.x, b.y - a.y), 0)
        }
        var best: (area: CGFloat, corners: [CGPoint], width: CGFloat, height: CGFloat)?
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            let u = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length), v = CGPoint(x: -u.y, y: u.x)
            var minU = CGFloat.infinity, maxU = -CGFloat.infinity, minV = CGFloat.infinity, maxV = -CGFloat.infinity
            for p in hull {
                let pu = (p.x - a.x) * u.x + (p.y - a.y) * u.y, pv = (p.x - a.x) * v.x + (p.y - a.y) * v.y
                minU = min(minU, pu); maxU = max(maxU, pu); minV = min(minV, pv); maxV = max(maxV, pv)
            }
            let area = (maxU - minU) * (maxV - minV)
            if best == nil || area < best!.area {
                func at(_ s: CGFloat, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + u.x * s + v.x * t, y: a.y + u.y * s + v.y * t) }
                best = (area, [at(minU, minV), at(maxU, minV), at(maxU, maxV), at(minU, maxV)], maxU - minU, maxV - minV)
            }
        }
        return best.map { ($0.corners, $0.width, $0.height) } ?? (hull, 0, 0)
    }

    /// The rectangle's corners in PaddleOCR's order (get_mini_boxes): the two leftmost, upper first, then the two
    /// rightmost, upper first, read around as top-left, top-right, bottom-right, bottom-left; and its shorter side.
    static func ordered(_ corners: [CGPoint], width: CGFloat, height: CGFloat) -> (box: [CGPoint], shorter: CGFloat) {
        let points = corners.sorted { $0.x < $1.x }
        let (topLeft, bottomLeft) = points[1].y > points[0].y ? (points[0], points[1]) : (points[1], points[0])
        let (topRight, bottomRight) = points[3].y > points[2].y ? (points[2], points[3]) : (points[3], points[2])
        return ([topLeft, topRight, bottomRight, bottomLeft], min(width, height))
    }

    /// `box` (a rectangle, corners in order around it) grown on every side by its area times `ratio` over its
    /// perimeter, as DBPostProcess's unclip does: offsetting a rectangle with round joins and taking the result's
    /// minimum-area rectangle gives the rectangle grown by the distance.
    static func unclipped(_ box: [CGPoint], ratio: Double) -> (corners: [CGPoint], width: CGFloat, height: CGFloat) {
        var area: CGFloat = 0, perimeter: CGFloat = 0
        for i in box.indices {
            let a = box[i], b = box[(i + 1) % box.count]
            area += a.x * b.y - b.x * a.y
            perimeter += hypot(b.x - a.x, b.y - a.y)
        }
        area = abs(area) / 2
        let distance = area * CGFloat(ratio) / max(perimeter, 1e-6)
        let width = hypot(box[1].x - box[0].x, box[1].y - box[0].y), height = hypot(box[3].x - box[0].x, box[3].y - box[0].y)
        guard width > 0, height > 0 else { return (box, width, height) }
        let u = CGPoint(x: (box[1].x - box[0].x) / width, y: (box[1].y - box[0].y) / width)
        let v = CGPoint(x: (box[3].x - box[0].x) / height, y: (box[3].y - box[0].y) / height)
        let center = CGPoint(x: box.map(\.x).reduce(0, +) / 4, y: box.map(\.y).reduce(0, +) / 4)
        let halfWidth = width / 2 + distance, halfHeight = height / 2 + distance
        func at(_ s: CGFloat, _ t: CGFloat) -> CGPoint { CGPoint(x: center.x + u.x * s + v.x * t, y: center.y + u.y * s + v.y * t) }
        return ([at(-halfWidth, -halfHeight), at(halfWidth, -halfHeight), at(halfWidth, halfHeight), at(-halfWidth, halfHeight)], halfWidth * 2, halfHeight * 2)
    }

    /// Boxes in reading order as PaddleOCR sorts them: by the top-left corner's height, then its left; a box whose
    /// top is within 10 pixels of the one before it and further left goes first.
    static func readingOrder(_ boxes: [[CGPoint]]) -> [[CGPoint]] {
        var sorted = boxes.sorted { $0[0].y != $1[0].y ? $0[0].y < $1[0].y : $0[0].x < $1[0].x }
        guard sorted.count > 1 else { return sorted }
        for i in 0..<(sorted.count - 1) {
            var j = i
            while j >= 0, abs(sorted[j + 1][0].y - sorted[j][0].y) < 10, sorted[j + 1][0].x < sorted[j][0].x {
                sorted.swapAt(j, j + 1)
                j -= 1
            }
        }
        return sorted
    }

    /// DBPostProcess over one band's probabilities (`width` × `height`, row by row): each region above the threshold
    /// whose rectangle is large enough and whose mean probability is high enough, grown by the unclip ratio, its
    /// corners rounded and kept inside the band.
    static func boxes(in probabilities: UnsafeBufferPointer<Float>, width: Int, height: Int, configuration: PPOCRConfiguration.Detection) -> [[CGPoint]] {
        let regions = BinaryComponents.components(of: probabilities, width: width, height: height, threshold: configuration.threshold, limit: configuration.maxCandidates)
        var boxes: [[CGPoint]] = []
        for region in regions {
            var points: [CGPoint] = []
            points.reserveCapacity(region.left.count * 2)
            for (i, left) in region.left.enumerated() where left >= 0 {
                let y = CGFloat(region.top + i)
                points.append(CGPoint(x: CGFloat(left), y: y))
                if region.right[i] != left { points.append(CGPoint(x: CGFloat(region.right[i]), y: y)) }
            }
            let rectangle = minimumAreaRectangle(points)
            let (box, shorter) = ordered(rectangle.corners, width: rectangle.width, height: rectangle.height)
            guard Double(shorter) >= configuration.minSize else { continue }
            let score = BinaryComponents.mean(of: probabilities, width: width, height: height, inside: box.map { (Double($0.x), Double($0.y)) })
            guard score >= configuration.boxThreshold else { continue }
            // As DBPostProcess hands the box to pyclipper: its corners cut to whole pixels first.
            let grown = unclipped(box.map { CGPoint(x: $0.x.rounded(.towardZero), y: $0.y.rounded(.towardZero)) }, ratio: configuration.unclipRatio)
            let (final, side) = ordered(grown.corners, width: grown.width, height: grown.height)
            guard Double(side) >= configuration.minSize + 2 else { continue }
            boxes.append(final.map { CGPoint(x: min(max($0.x.rounded(), 0), CGFloat(width)), y: min(max($0.y.rounded(), 0), CGFloat(height))) })
        }
        return boxes
    }
}
