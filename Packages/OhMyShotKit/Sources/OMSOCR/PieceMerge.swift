import CoreGraphics
import Foundation

/// Puts the readings of a large picture's overlapping pieces (`PictureText.pieces`) together as one reading
/// of the picture, with every box where it lies in the whole.
///
/// Neighbouring pieces share `PictureText.overlap` pixels, so what lies in that strip is read twice, and what
/// a piece's edge cuts through is read badly in that piece and whole in the next. Each piece therefore
/// answers for its *core*: the piece less half the overlap on every side it shares with another piece. The
/// cores tile the picture, and anything no taller than the overlap that an edge cuts lies in the core of the
/// piece beside it, whole. A reading from a piece that does not own its spot is kept only if the owner found
/// nothing there, since a piece can miss a line its neighbour reads (a stray is then better than a gap).
enum PieceMerge {
    /// The part of each piece it answers for, in the same order as `pieces`.
    static func cores(of pieces: [CGRect], in size: CGSize) -> [CGRect] {
        let half = CGFloat(PictureText.overlap) / 2
        return pieces.map { piece in
            let left = piece.minX > 0 ? half : 0
            let top = piece.minY > 0 ? half : 0
            let right = piece.maxX < size.width ? half : 0
            let bottom = piece.maxY < size.height ? half : 0
            return CGRect(x: piece.minX + left, y: piece.minY + top, width: piece.width - left - right, height: piece.height - top - bottom)
        }
    }

    /// The readings of every piece as one, dropping what two pieces read of the same spot.
    ///
    /// - Parameter readings: the lines each piece read (same order as `pieces`), already in whole-picture
    ///   coordinates.
    static func merged(_ readings: [[OCRLine]], pieces: [CGRect], size: CGSize) -> [OCRLine] {
        let cores = cores(of: pieces, in: size)
        var owned = [[OCRLine]](repeating: [], count: readings.count)
        var strays: [(owner: Int, line: OCRLine)] = []
        for (piece, lines) in readings.enumerated() {
            for line in lines {
                let home = owner(of: CGPoint(x: line.box.midX, y: line.box.midY), cores: cores)
                if home == piece {
                    owned[piece].append(line)
                } else {
                    strays.append((home, line))
                }
            }
        }
        var kept = owned.flatMap { $0 }
        for (owner, line) in strays where !owned[owner].contains(where: { overlap($0.box, line.box) >= 0.3 }) {
            kept.append(line)
        }
        return withoutRepeats(kept)
    }

    /// The piece whose core holds `point`, or the nearest core to it (a point on the picture's far edge).
    static func owner(of point: CGPoint, cores: [CGRect]) -> Int {
        if let index = cores.firstIndex(where: { $0.contains(point) }) { return index }
        let distances = cores.map { core in
            let dx = max(core.minX - point.x, 0, point.x - core.maxX)
            let dy = max(core.minY - point.y, 0, point.y - core.maxY)
            return dx * dx + dy * dy
        }
        return distances.indices.min { distances[$0] < distances[$1] } ?? 0
    }

    /// The lines, once each: a later line that repeats an earlier one lying over it goes. (Two pieces that read
    /// one line a pixel apart can each own it, when their boxes' middles fall either side of a cut.) So does a
    /// fragment of a line that was read whole as well (`isFragment`), whichever of the two comes first.
    private static func withoutRepeats(_ lines: [OCRLine]) -> [OCRLine] {
        let order = lines.indices.sorted { lines[$0].box.minY < lines[$1].box.minY }
        var dropped = Set<Int>()
        var active: [Int] = []
        for index in order {
            let line = lines[index]
            active.removeAll { lines[$0].box.maxY <= line.box.minY }
            if active.contains(where: { overlap(lines[$0].box, line.box) > 0.5 && lines[$0].repeats(line) || isFragment(line, of: lines[$0]) }) {
                dropped.insert(index)
                continue
            }
            let fragments = active.filter { isFragment(lines[$0], of: line) }
            dropped.formUnion(fragments)
            active.removeAll(where: fragments.contains)
            active.append(index)
        }
        return lines.indices.filter { !dropped.contains($0) }.map { lines[$0] }
    }

    /// Whether `fragment` is a part of `line` read a second time, as the passes over a dense piece can leave one
    /// ("21. The quiet l" over "21. The quiet harbor crosses …"): on the line's row, nearly all of it within the
    /// line's width, and less than half as long.
    static func isFragment(_ fragment: OCRLine, of line: OCRLine) -> Bool {
        func count(_ text: String) -> Int { text.filter { !$0.isWhitespace }.count }
        let shared = min(fragment.box.maxX, line.box.maxX) - max(fragment.box.minX, line.box.minX)
        return count(fragment.text) * 2 < count(line.text) && shared > fragment.box.width * 0.7
            && ReadingOrder.verticalOverlap(fragment.box, line.box) > 0.5
    }

    /// The lines that are pieces of one line a column cut went through, each group left to right.
    ///
    /// A line that runs across a whole column overlap is cut in both columns: the left column's reading ends at
    /// its edge, the right column's begins at its own, and the two overlap by the strip they share. (A line that
    /// fits one column whole is the owner's, and needs nothing.) So: two lines on one row, the first reaching
    /// the left column's right edge, the second starting at the right column's left edge, over each other.
    static func crossings(in lines: [OCRLine], pieces: [CGRect]) -> [[Int]] {
        var joined: [Int: Int] = [:]
        func root(_ index: Int) -> Int {
            var index = index
            while let parent = joined[index] { index = parent }
            return index
        }
        var involved = Set<Int>()
        for left in pieces {
            for right in pieces where right.minY == left.minY && right.height == left.height
                && right.minX == left.maxX - CGFloat(PictureText.overlap) {
                let rightEdge = left.maxX
                let leftEdge = right.minX
                let candidates = lines.indices.filter { lines[$0].box.midY >= left.minY && lines[$0].box.midY < left.maxY }
                for first in candidates {
                    let a = lines[first].box
                    let slack = max(8, a.height / 4)
                    guard a.maxX >= rightEdge - slack, a.maxX <= rightEdge + 1 else { continue }
                    for second in candidates where second != first {
                        let b = lines[second].box
                        guard b.minX <= leftEdge + slack, b.minX >= leftEdge - 1, a.minX < b.minX, a.maxX > b.minX,
                              ReadingOrder.verticalOverlap(a, b) > 0.5 else { continue }
                        let (x, y) = (root(first), root(second))
                        if x != y { joined[y] = x }
                        involved.formUnion([first, second])
                    }
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in involved { groups[root(index), default: []].append(index) }
        return groups.values
            .map { $0.sorted { lines[$0].box.minX < lines[$1].box.minX } }
            .sorted { $0[0] < $1[0] }
    }

    /// The lines a column cut went through that the column beyond it read no part of: `crossings` pairs the two
    /// pieces of a cut line, and such a line has one. Each comes with the stretch of its row to read again: the line
    /// and what lies past the cut, up to the next line on the row or that column's far edge, and no wider than a
    /// column in all, which is what Vision reads without shrinking it; and with where it was cut, `before` its start
    /// or `after` its end.
    static func loneCuts(in lines: [OCRLine], pieces: [CGRect]) -> [(line: Int, stretch: CGRect, before: CGFloat?, after: CGFloat?)] {
        let paired = Set(crossings(in: lines, pieces: pieces).joined())
        var stretches: [Int: CGRect] = [:]
        var cuts: [Int: (before: CGFloat?, after: CGFloat?)] = [:]
        for left in pieces {
            for right in pieces where right.minY == left.minY && right.height == left.height
                && right.minX == left.maxX - CGFloat(PictureText.overlap) {
                for index in lines.indices where !paired.contains(index) && lines[index].box.midY >= left.minY && lines[index].box.midY < left.maxY {
                    let box = lines[index].box
                    let slack = max(8, box.height / 4)
                    let others = lines.indices.filter { $0 != index && ReadingOrder.verticalOverlap(lines[$0].box, box) > 0.5 }.map { lines[$0].box }
                    var (start, end) = (stretches[index]?.minX ?? box.minX, stretches[index]?.maxX ?? box.maxX)
                    if box.maxX >= left.maxX - slack, box.maxX <= left.maxX + 1 {
                        end = min(others.filter { $0.minX >= box.maxX }.map(\.minX).min() ?? right.maxX, right.maxX, start + left.width)
                        cuts[index, default: (nil, nil)].after = left.maxX
                    }
                    if box.minX <= right.minX + slack, box.minX >= right.minX - 1 {
                        start = max(others.filter { $0.maxX <= box.minX }.map(\.maxX).max() ?? left.minX, left.minX, end - left.width)
                        cuts[index, default: (nil, nil)].before = right.minX
                    }
                    // Compared end with end: `end - start > box.width` holds by rounding for a line no cut is near.
                    if start < box.minX || end > box.maxX { stretches[index] = CGRect(x: start, y: box.minY, width: end - start, height: box.height) }
                }
            }
        }
        return stretches.sorted { $0.key < $1.key }.map { ($0.key, $0.value, cuts[$0.key]?.before, cuts[$0.key]?.after) }
    }

    /// Whether what was read in a lone cut's stretch (`text`, in `box`) is `line` read on past a cut it stopped at
    /// (`before` its start, `after` its end). It reaches a quarter of the line's height past the cut: a letter or two
    /// may be all that lay there, so the line's own box is no measure. It is longer. And the line's own reading is a
    /// part of it, but for the two characters the cut went through and one in ten besides: two readings of one line
    /// differ by a letter here and there ("moring" for "morning"), and a line left cut for that loses all that lay
    /// past the cut. Not at the end no cut touched: the three characters there are in the other reading as they are,
    /// or what it added past the cut would be paid for with what it lost at the other end (a line's number).
    static func completes(_ line: OCRLine, text: String, box: CGRect, before: CGFloat?, after: CGFloat?) -> Bool {
        let reach = line.box.height / 4
        guard before.map({ box.minX <= $0 - reach }) ?? false || after.map({ box.maxX >= $0 + reach }) ?? false else { return false }
        var (read, own) = (Array(text.filter { !$0.isWhitespace }), Array(line.text.filter { !$0.isWhitespace }))
        guard read.count > own.count else { return false }
        // Both from the end no cut touched: for a line cut at its start, that is its last character.
        if after == nil { (read, own) = (read.reversed(), own.reversed()) }
        let whole = before == nil || after == nil ? min(3, max(0, own.count - 2)) : 0
        // The fewest edits that make the line's reading a part of the other: for each character of `read`, the fewest
        // for a part that ends on it. None is allowed in the first `whole` characters.
        let never = read.count + own.count
        var edits = [Int](repeating: 0, count: read.count + 1)
        for (row, character) in own.enumerated() {
            var diagonal = edits[0]
            edits[0] = whole > 0 ? never : row + 1
            for column in 1...read.count {
                let above = edits[column]
                let isSame = read[column - 1] == character
                edits[column] = row < whole ? (isSame ? diagonal : never) : min(diagonal + (isSame ? 0 : 1), above + 1, edits[column - 1] + 1)
                diagonal = above
            }
        }
        return (edits.min() ?? 0) <= 2 + own.count / 10
    }

    /// Whether `text` reads as the whole of the line that `parts` (left to right, each over the next) are cut
    /// pieces of: as long as they are together, less the characters that lie in their overlaps.
    static func isWhole(_ text: String, of parts: [OCRLine]) -> Bool {
        func count(_ string: String) -> Int { string.filter { !$0.isWhitespace }.count }
        var expected = Double(parts.reduce(0) { $0 + count($1.text) })
        for (a, b) in zip(parts, parts.dropFirst()) where b.box.width > 0 {
            let shared = min(max(0, a.box.maxX - b.box.minX), b.box.width)
            expected -= Double(count(b.text)) * Double(shared / b.box.width)
        }
        let read = Double(count(text))
        return expected > 0 && read >= expected * 0.75 && read <= expected * 1.25
    }

    /// How much of the smaller of two boxes the other covers, from 0 to 1.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        let smaller = min(a.width * a.height, b.width * b.height)
        guard !shared.isNull, smaller > 0 else { return 0 }
        return shared.width * shared.height / smaller
    }
}

extension OCRLine {
    /// The same line with its box moved by `offset`: a piece's reading placed in the whole picture.
    func moved(by offset: CGPoint) -> OCRLine {
        var line = self
        line.box = box.offsetBy(dx: offset.x, dy: offset.y)
        return line
    }

    /// Whether `other` is this line's text again: the same characters, spaces aside.
    func repeats(_ other: OCRLine) -> Bool {
        text.filter { !$0.isWhitespace } == other.text.filter { !$0.isWhitespace }
    }
}
