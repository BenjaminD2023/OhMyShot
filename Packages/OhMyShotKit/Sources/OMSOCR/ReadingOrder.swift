import CoreGraphics
import Foundation

/// Puts lines in the order a person reads them: rows from top to bottom, left to right within a row;
/// vertical columns from right to left.
public enum ReadingOrder {
    public static func sorted(_ lines: [OCRLine]) -> [OCRLine] {
        let vertical = lines.filter(isVertical)
        let horizontal = lines.filter { !isVertical($0) }

        // A line joins the current row when it overlaps the row's first line by more than half of the
        // shorter height, so a slightly lower baseline still reads as the same row.
        var rows: [[OCRLine]] = []
        for line in horizontal.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = rows.indices.last, let anchor = rows[last].first, verticalOverlap(anchor.box, line.box) > 0.5 {
                rows[last].append(line)
            } else {
                rows.append([line])
            }
        }
        let orderedRows = rows.flatMap { row in row.sorted { $0.box.minX < $1.box.minX } }
        let orderedColumns = vertical.sorted { $0.box.midX > $1.box.midX }
        return orderedRows + orderedColumns
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
