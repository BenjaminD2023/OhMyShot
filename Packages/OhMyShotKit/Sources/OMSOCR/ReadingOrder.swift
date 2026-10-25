import CoreGraphics
import Foundation

/// Puts lines in reading order. Sustained, separate text columns read one at a time; shared headings
/// divide the page into bands. Sparse UI labels, alternating chat messages and code keep their rows.
public enum ReadingOrder {
    public enum Layout: Equatable, Sendable {
        case automatic
        /// A caller already knows the content is a cell or a row-oriented structure.
        case rows
    }

    public static func sorted(_ lines: [OCRLine], layout: Layout = .automatic) -> [OCRLine] {
        let vertical = lines.filter(isVertical)
        let horizontal = lines.filter { !isVertical($0) }
        let orderedRows = layout == .automatic ? documentOrder(horizontal, depth: 0) : rowOrder(horizontal)
        let orderedColumns = vertical.sorted { $0.box.midX == $1.box.midX ? breaksTie($0, $1) : $0.box.midX > $1.box.midX }
        return orderedRows + orderedColumns
    }

    private static func rowGroups(_ lines: [OCRLine]) -> [[OCRLine]] {
        // A line joins the current row when it overlaps the row's first line by more than half of the
        // shorter height, so a slightly lower baseline still reads as the same row.
        var rows: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.box.midY == $1.box.midY ? breaksTie($0, $1) : $0.box.midY < $1.box.midY }) {
            if let last = rows.indices.last, let anchor = rows[last].first, verticalOverlap(anchor.box, line.box) > 0.5 {
                rows[last].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
    }

    private static func rowOrder(_ lines: [OCRLine]) -> [OCRLine] {
        rowGroups(lines).flatMap { row in
            let rtl = rightToLeft(row)
            return row.sorted {
                if $0.box.minX == $1.box.minX { return breaksTie($0, $1) }
                return rtl ? $0.box.minX > $1.box.minX : $0.box.minX < $1.box.minX
            }
        }
    }

    /// Explicit script direction is authoritative; unlabelled text does not vote against it. Latin
    /// numerals within an Arabic/Hebrew row do not reverse the row's flow.
    private static func rightToLeft(_ lines: [OCRLine]) -> Bool {
        var right = 0, left = 0
        for line in lines {
            let letters = line.text.filter(\.isLetter).count
            if line.direction == .rightToLeft { right += max(letters, 1) }
            if line.direction == .leftToRight { left += letters }
        }
        return right > left
    }

    private struct Gutter {
        let x: CGFloat
        let width: CGFloat
        let support: Int
    }

    /// A few stable left/right text edges propose gutters. A single wide title cannot bridge a column's
    /// median right edge; right-aligned paragraphs can supply the same evidence through their right edges.
    private static func gutters(_ lines: [OCRLine], height: CGFloat) -> [Gutter] {
        var candidates: [Gutter] = []
        for useRight in [false, true] {
            func edge(_ line: OCRLine) -> CGFloat { useRight ? line.box.maxX : line.box.minX }
            var groups: [[OCRLine]] = []
            for line in lines.sorted(by: { edge($0) == edge($1) ? breaksTie($0, $1) : edge($0) < edge($1) }) {
                if let last = groups.indices.last, abs(edge(line) - edge(groups[last][0])) <= height * 0.75 {
                    groups[last].append(line)
                } else { groups.append([line]) }
            }
            for (left, right) in zip(groups, groups.dropFirst()) {
                guard min(left.count, right.count) >= 1, max(left.count, right.count) >= 3 else { continue }
                let minimum = height * 1.5
                let a: [OCRLine], b: [OCRLine]
                if useRight {
                    let edge = median(left.map(\.box.maxX))
                    b = right.filter { $0.box.minX >= edge + minimum }
                    guard !b.isEmpty else { continue }
                    let opposite = median(b.map(\.box.minX))
                    a = left.filter { $0.box.maxX <= opposite - minimum }
                } else {
                    let edge = median(right.map(\.box.minX))
                    a = left.filter { $0.box.maxX <= edge - minimum }
                    guard !a.isEmpty else { continue }
                    let opposite = median(a.map(\.box.maxX))
                    b = right.filter { $0.box.minX >= opposite + minimum }
                }
                guard !a.isEmpty, !b.isEmpty else { continue }
                let from = median(a.map(\.box.maxX)), to = median(b.map(\.box.minX))
                candidates.append(Gutter(x: (from + to) / 2, width: to - from, support: min(a.count, b.count)))
            }
        }
        let sorted = candidates.sorted {
            if $0.support != $1.support { return $0.support > $1.support }
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.x < $1.x
        }
        var unique: [Gutter] = []
        for candidate in sorted where !unique.contains(where: { abs($0.x - candidate.x) < height * 0.5 }) {
            unique.append(candidate)
            if unique.count == 8 { break }
        }
        return unique
    }

    private static func documentOrder(_ lines: [OCRLine], depth: Int) -> [OCRLine] {
        guard lines.count >= 5, depth < 8,
              lines.allSatisfy({ $0.box.width > 0 && $0.box.height > 0 && $0.box.minX.isFinite && $0.box.maxX.isFinite && $0.box.minY.isFinite && $0.box.maxY.isFinite })
        else { return rowOrder(lines) }
        let height = median(lines.map(\.box.height))
        let candidates = gutters(lines, height: height)
        guard !candidates.isEmpty, !TextAssembler.isCodeListing(lines) else { return rowOrder(lines) }
        for gutter in candidates {
            let left = lines.filter { !$0.isTableRow && $0.box.maxX <= gutter.x }
            let right = lines.filter { !$0.isTableRow && $0.box.minX >= gutter.x }
            guard separatesColumns(left, right, height: height) else { continue }
            let shared = lines.filter { $0.isTableRow || ($0.box.minX < gutter.x && $0.box.maxX > gutter.x) }
            let separators = rowGroups(shared)
            let body = (left + right).sorted { $0.box.midY == $1.box.midY ? breaksTie($0, $1) : $0.box.midY < $1.box.midY }
            var result: [OCRLine] = []
            var index = 0
            func appendBand(_ band: [OCRLine]) {
                let a = band.filter { $0.box.maxX <= gutter.x }, b = band.filter { $0.box.minX >= gutter.x }
                guard separatesColumns(a, b, height: height) else { return result += rowOrder(band) }
                let ordered = rightToLeft(band) ? [b, a] : [a, b]
                for column in ordered { result += documentOrder(column, depth: depth + 1) }
            }
            for separator in separators {
                let boundary = separator.map(\.box.midY).min() ?? 0
                let start = index
                while index < body.count, body[index].box.midY < boundary { index += 1 }
                appendBand(Array(body[start..<index]))
                result += rowOrder(separator)
            }
            appendBand(Array(body[index...]))
            return result
        }
        return rowOrder(lines)
    }

    /// Columns must coexist vertically and contain paragraph-shaped text. Left/right chat bubbles at
    /// different heights, short table cells and a line-number gutter therefore do not become columns.
    private static func separatesColumns(_ left: [OCRLine], _ right: [OCRLine], height: CGFloat) -> Bool {
        guard !left.isEmpty, !right.isEmpty, max(left.count, right.count) >= 3 else { return false }
        let widths = [median(left.map(\.box.width)), median(right.map(\.box.width))]
        guard max(widths[0], widths[1]) >= height * 6, min(widths[0], widths[1]) >= height * 2.5 else { return false }
        let main = left.count > right.count ? left : right
        func proseCount(_ column: [OCRLine]) -> Int {
            column.filter { line in
                line.wrapsToNextLine == true || line.text.split(whereSeparator: \.isWhitespace).count >= 3
                    || (Script.containsCJK(line.text) && line.text.count >= 8)
            }.count
        }
        guard max(proseCount(left), proseCount(right)) >= 2 else { return false }
        let a = coverage(left), b = coverage(right)
        var first = 0, second = 0, shared: CGFloat = 0
        while first < a.count, second < b.count {
            shared += max(0, min(a[first].upperBound, b[second].upperBound) - max(a[first].lowerBound, b[second].lowerBound))
            if a[first].upperBound < b[second].upperBound { first += 1 } else { second += 1 }
        }
        let shorter = min(a.reduce(0) { $0 + $1.upperBound - $1.lowerBound }, b.reduce(0) { $0 + $1.upperBound - $1.lowerBound })
        guard shared >= shorter * 0.5 else { return false }
        if min(left.count, right.count) == 1 {
            let note = left.count == 1 ? left[0] : right[0]
            return main.count >= 4 && note.box.height < median(main.map(\.box.height)) * 0.85
                && note.box.width < median(main.map(\.box.width)) * 0.6 && shared >= note.box.height * 0.5
        }
        return shared >= height
    }

    private static func coverage(_ lines: [OCRLine]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for box in lines.map(\.box).sorted(by: { $0.minY < $1.minY }) {
            if let last = result.last, box.minY <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, box.maxY)
            } else { result.append(box.minY...box.maxY) }
        }
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        values.sorted()[values.count / 2]
    }

    /// Recognition can return the same boxes in a different order. Equal centers must pick the same
    /// row anchor, and equal edges read topmost first, then by their remaining geometry and text.
    private static func breaksTie(_ a: OCRLine, _ b: OCRLine) -> Bool {
        if a.box.minY != b.box.minY { return a.box.minY < b.box.minY }
        if a.box.minX != b.box.minX { return a.box.minX < b.box.minX }
        if a.box.height != b.box.height { return a.box.height < b.box.height }
        if a.box.width != b.box.width { return a.box.width < b.box.width }
        return a.text < b.text
    }

    /// Vision does not always report a direction for vertical text, so a tall, narrow line of several
    /// characters counts as vertical too. (A single tall glyph, such as a closing brace, does not.)
    static func isVertical(_ line: OCRLine) -> Bool {
        if let direction = line.direction { return direction == .topToBottom }
        return line.text.count >= 2 && line.box.height >= line.box.width * 2
    }

    /// The vertical overlap of two boxes as a fraction of the shorter one's height.
    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let shorter = min(a.height, b.height)
        guard shorter > 0 else { return 0 }
        return max(0, overlap) / shorter
    }
}
