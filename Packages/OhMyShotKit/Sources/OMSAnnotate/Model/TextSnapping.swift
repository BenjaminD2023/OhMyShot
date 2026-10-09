import CoreGraphics
import Foundation

/// A line of text in the capture, as the highlighter snaps to it.
nonisolated public struct TextLine: Sendable, Equatable {
    /// From the line's first glyph to its last, and as tall as its paragraph's letters reach, ascenders
    /// and descenders included; in pixels.
    public var rect: CGRect
    /// Each word's glyphs along x, left to right, in pixels. Each Chinese, Japanese, or Korean character
    /// is a word.
    public var words: [ClosedRange<CGFloat>]

    public init(rect: CGRect, words: [ClosedRange<CGFloat>]) {
        self.rect = rect
        self.words = words
    }

    /// The line moved by `delta` pixels.
    func offsetBy(dx: CGFloat, dy: CGFloat) -> TextLine {
        TextLine(rect: rect.offsetBy(dx: dx, dy: dy), words: words.map { ($0.lowerBound + dx)...($0.upperBound + dx) })
    }
}

/// How a highlighter drag lies over text, as a text selection does: started on a word, it highlights from
/// there to the word under the pointer, so dragging down from the end of a line carries on along the next
/// one: the rest of the first line, every line between whole, and the last line up to the pointer. Whole
/// words only, each band the height of its line, within the column of lines it started in.
nonisolated struct TextSnapping {
    let lines: [TextLine]
    /// The lines the drag can reach, top to bottom: those of the column it started in.
    let column: [Int]
    /// Where the drag started: a place in `column`, and a word's place on that line.
    let anchor: (line: Int, word: Int)
    /// Where the pointer is, the same way.
    private(set) var current: (line: Int, word: Int)

    /// Starts a drag at `point`, or nil when no line is there to snap to.
    init?(at point: CGPoint, lines: [TextLine]) {
        guard let start = Self.line(at: point, in: lines) else { return nil }
        self.lines = lines
        column = Self.column(of: start, in: lines)
        anchor = (column.firstIndex(of: start) ?? 0, Self.word(nearest: point.x, in: lines[start]))
        current = anchor
    }

    /// The line a drag starting at `point` snaps to: the one under it, give or take 35% of the line's
    /// height above and below and half of it past its ends; the nearest when two are.
    static func line(at point: CGPoint, in lines: [TextLine]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, line) in lines.enumerated() where !line.words.isEmpty && startZone(of: line).contains(point) {
            let distance = abs(point.y - line.rect.midY)
            if best.map({ distance < $0.distance }) ?? true { best = (index, distance) }
        }
        return best?.index
    }

    private static func startZone(of line: TextLine) -> CGRect {
        line.rect.insetBy(dx: -line.rect.height * 0.5, dy: -line.rect.height * 0.35)
    }

    /// The lines of the column `start` is in, top to bottom: lines above and below one another, overlapping
    /// side to side, of about one size, and less than one and a half lines apart, so a paragraph and the
    /// paragraphs right after it are one column and the column beside it is another.
    static func column(of start: Int, in lines: [TextLine]) -> [Int] {
        var members: Set<Int> = [start]
        var waiting = [start]
        while let index = waiting.popLast() {
            let a = lines[index].rect
            for (other, line) in lines.enumerated() where !members.contains(other) && !line.words.isEmpty {
                let b = line.rect
                guard min(a.maxX, b.maxX) > max(a.minX, b.minX),
                      max(a.height, b.height) < min(a.height, b.height) * 1.6,
                      max(b.minY - a.maxY, a.minY - b.maxY) < max(a.height, b.height) * 1.5
                else { continue }
                members.insert(other)
                waiting.append(other)
            }
        }
        return members.sorted { (lines[$0].rect.midY, lines[$0].rect.minX) < (lines[$1].rect.midY, lines[$1].rect.minX) }
    }

    /// Follows the drag to `point`: to the column's line nearest it (above or below, the one whose text is
    /// closest, so the turn to the next line comes halfway between the two, as in a text selection; side
    /// by side, the nearer one) and the word on it nearest the pointer.
    mutating func extend(to point: CGPoint) {
        var best = current.line
        var nearest = (CGFloat.infinity, CGFloat.infinity)
        for (place, index) in column.enumerated() {
            let rect = lines[index].rect
            let distance = (max(rect.minY - point.y, point.y - rect.maxY, 0), max(rect.minX - point.x, point.x - rect.maxX, 0))
            if distance < nearest {
                best = place
                nearest = distance
            }
        }
        current = (best, Self.word(nearest: point.x, in: lines[column[best]]))
    }

    /// The word under `x`, or the nearest one.
    static func word(nearest x: CGFloat, in line: TextLine) -> Int {
        var best = 0
        var bestDistance = CGFloat.infinity
        for (index, word) in line.words.enumerated() {
            let distance = x < word.lowerBound ? word.lowerBound - x : x > word.upperBound ? x - word.upperBound : 0
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// The bands, top to bottom: from the word the drag started on to the word under the pointer, whichever
    /// comes first.
    var rects: [CGRect] {
        let forward = (anchor.line, anchor.word) <= (current.line, current.word)
        let first = forward ? anchor : current, last = forward ? current : anchor
        return (first.line...last.line).map { place in
            let index = column[place]
            let from = place == first.line ? first.word : 0
            let to = place == last.line ? last.word : lines[index].words.count - 1
            return Self.band(over: from...max(from, to), of: index, in: lines)
        }
    }

    /// A band over `words` of line `index`: a little taller than the text and past its ends by a little
    /// more, but never past halfway to the next word, nor to the line above or below, so it stops cleanly
    /// between two and the bands of neighboring lines meet without overlapping.
    static func band(over words: ClosedRange<Int>, of index: Int, in lines: [TextLine]) -> CGRect {
        let line = lines[index]
        let height = line.rect.height
        let padding = (height * 0.1).rounded()
        let reach = (height * 0.2).rounded()
        let first = line.words[words.lowerBound], last = line.words[words.upperBound]
        var minX = first.lowerBound - reach
        var maxX = last.upperBound + reach
        if words.lowerBound > 0 { minX = max(minX, ((line.words[words.lowerBound - 1].upperBound + first.lowerBound) / 2).rounded()) }
        if words.upperBound < line.words.count - 1 { maxX = min(maxX, ((last.upperBound + line.words[words.upperBound + 1].lowerBound) / 2).rounded()) }
        var minY = line.rect.minY - padding
        var maxY = line.rect.maxY + padding
        for (other, neighbor) in lines.enumerated() where other != index && neighbor.rect.minX < maxX && neighbor.rect.maxX > minX {
            let middle = ((neighbor.rect.midY < line.rect.midY ? neighbor.rect.maxY + line.rect.minY : line.rect.maxY + neighbor.rect.minY) / 2).rounded()
            // The padding gives way; the line's own text never does.
            if neighbor.rect.midY < line.rect.midY {
                minY = max(minY, min(middle, line.rect.minY))
            } else {
                maxY = min(maxY, max(middle, line.rect.maxY))
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

nonisolated extension TextHighlight {
    /// Whether two bands lie on one line: they share most of their height.
    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) * 0.5
    }

    /// Whether two bands on one line overlap or touch.
    private static func meet(_ a: CGRect, _ b: CGRect) -> Bool {
        sameLine(a, b) && a.minX <= b.maxX + 0.5 && b.minX <= a.maxX + 0.5
    }

    /// Whether a band of this highlight meets one of `other`'s on a line.
    func meets(_ other: TextHighlight) -> Bool {
        rects.contains { band in other.rects.contains { Self.meet(band, $0) } }
    }

    /// The bands of both, those that meet on a line made one, top to bottom.
    func merged(with other: TextHighlight) -> TextHighlight {
        var bands: [CGRect] = []
        for rect in rects + other.rects {
            var band = rect
            while let index = bands.firstIndex(where: { Self.meet($0, band) }) {
                band = band.union(bands.remove(at: index))
            }
            bands.append(band)
        }
        return TextHighlight(rects: bands.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) })
    }
}
