import CoreGraphics
import Foundation
import Vision

/// Where the blocks of text on a screen lie: paragraphs, lists, code, tables. A selection dragged over a
/// frozen screen snaps to their edges. Only where text lies is found, never what it says, and quickly: the
/// system's text-rectangle detector places a box on each line (or part of a line) in a few tens of
/// milliseconds even on a large display, where reading the text takes seconds. All of it stays on this Mac.
///
/// Everything is in the picture's pixels with the origin at the top left, and sizes are judged against line
/// height, so the grouping does not depend on a display's scale.
public enum TextBlocks {
    /// The blocks of text in `image`, top to bottom. Empty when nothing is found, the detector fails, or the
    /// caller stops waiting: a selection that cannot snap is still a selection. A caller that has stopped
    /// before the detector starts never starts it; one already running is let finish, its answer dropped, since
    /// the system's request cannot be called back.
    @concurrent
    public static func find(in image: CGImage) async -> [CGRect] {
        guard !Task.isCancelled else { return [] }
        let size = CGSize(width: image.width, height: image.height)
        let request = DetectTextRectanglesRequest()
        guard let found = try? await withTimeout(.seconds(5), { try await request.perform(on: image) }),
              !Task.isCancelled else { return [] }
        return group(found.map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) })
    }

    // MARK: Tuning

    /// Boxes thinner than this are specks, not text.
    static let thinnest: CGFloat = 4
    /// The most boxes looked at: a screen holds a few hundred, more is noise, and grouping compares pairs.
    static let mostBoxes = 2_000
    /// Boxes on one row share this much of the shorter one's height.
    static let rowOverlap: CGFloat = 0.6
    /// Boxes and lines are of one size when the taller is at most this many times the shorter.
    static let sameSize: CGFloat = 1.6
    /// Boxes on one row are one line when at most this many line heights apart: the pieces a code line is
    /// detected in are about two apart, the columns of a table five or more.
    static let lineGap: CGFloat = 2.5
    /// Lines one above the other are one block when the space between them is at most this many line
    /// heights: the space inside a paragraph or a listing, not the one between paragraphs.
    static let tightGap: CGFloat = 1.1
    /// Lines set at an even, looser spacing (list items, the rows of a table) are one block up to this many
    /// line heights apart.
    static let looseGap: CGFloat = 2.5
    /// Two spacings are even when they differ by at most this share of the larger, or this many line heights.
    static let evenShare: CGFloat = 0.25
    static let evenSlack: CGFloat = 0.2
    /// Lines are in one column when they share this much of the narrower one's width, or start at most this
    /// many line heights from one another (an indent).
    static let columnOverlap: CGFloat = 0.25
    static let indent: CGFloat = 3
    /// A column of cells is at least this many lines, none wider than this many line heights.
    static let fewestRows = 3
    static let cellWidth: CGFloat = 12
    /// Columns of cells are one table when at most this many line heights apart and at least this share of
    /// the shorter column's rows line up with rows of the other.
    static let columnGap: CGFloat = 12
    static let rowsInCommon: CGFloat = 0.6
    /// A single line narrower than this many line heights is a label ("Save", "OK"), not a block of text.
    static let labelWidth: CGFloat = 5

    // MARK: Grouping

    /// A group of lines.
    struct Block {
        var lines: [CGRect]

        var rect: CGRect { lines.dropFirst().reduce(lines[0]) { $0.union($1) } }

        /// A short line on its own: a button's title, a menu item.
        var isLabel: Bool { lines.count == 1 && lines[0].width < TextBlocks.labelWidth * lines[0].height }

        /// A column of cells: several short lines.
        var isCells: Bool {
            lines.count >= TextBlocks.fewestRows && lines.allSatisfy { $0.width <= TextBlocks.cellWidth * $0.height }
        }
    }

    /// The blocks the detector's boxes make: boxes on one row are a line, lines one above the other a
    /// paragraph, a listing, or a list, and columns of cells with their rows lined up a table. Labels are
    /// left out, so a toolbar does not make a block of every button.
    static func group(_ boxes: [CGRect]) -> [CGRect] {
        let sound = boxes.map(\.standardized).filter {
            $0.width.isFinite && $0.height.isFinite && $0.minX.isFinite && $0.minY.isFinite && $0.width >= thinnest && $0.height >= thinnest
        }
        return blocks(of: lines(of: Array(sound.prefix(mostBoxes))))
            .filter { !$0.isLabel }
            .map(\.rect)
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The boxes on one row made one line each: the pieces a code line is detected in, a toolbar's titles.
    static func lines(of boxes: [CGRect]) -> [CGRect] {
        var sets = DisjointSets(count: boxes.count)
        for i in boxes.indices {
            for j in boxes.indices where j > i && sameRow(boxes[i], boxes[j]) { sets.join(i, j) }
        }
        return sets.groups.map { group in group.dropFirst().reduce(boxes[group[0]]) { $0.union(boxes[$1]) } }
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let shorter = min(a.height, b.height), taller = max(a.height, b.height)
        guard taller <= shorter * sameSize,
              min(a.maxY, b.maxY) - max(a.minY, b.minY) >= shorter * rowOverlap else { return false }
        return max(a.minX - b.maxX, b.minX - a.maxX) <= taller * lineGap
    }

    /// The lines made blocks by their spacing and alignment, and the columns of cells that stand side by side
    /// with their rows lined up made tables.
    static func blocks(of lines: [CGRect]) -> [Block] {
        let lines = lines.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        var sets = DisjointSets(count: lines.count)
        // For each line, the nearest line below it in its column and the nearest above, within the loose spacing,
        // and whether a line of the same paragraph is tight against it above or below.
        var below = [(line: Int, gap: CGFloat)?](repeating: nil, count: lines.count)
        var above = [(line: Int, gap: CGFloat)?](repeating: nil, count: lines.count)
        var tightAbove = [Bool](repeating: false, count: lines.count)
        var tightBelow = [Bool](repeating: false, count: lines.count)
        for i in lines.indices {
            for j in lines.indices where j > i {
                guard let gap = gap(from: lines[i], to: lines[j]) else { continue }
                let height = min(lines[i].height, lines[j].height)
                if gap <= tightGap * height {
                    sets.join(i, j)
                    tightBelow[i] = true
                    tightAbove[j] = true
                }
                guard gap <= looseGap * height else { continue }
                if gap < below[i]?.gap ?? .infinity { below[i] = (j, gap) }
                if gap < above[j]?.gap ?? .infinity { above[j] = (i, gap) }
            }
        }
        // Lines at an even spacing above and below one another are one block, however loose. Not across the end
        // or the start of a paragraph, though: a loose gap after a paragraph's last line, or before its first,
        // is the space between paragraphs, so a lone line between two paragraphs bridges neither.
        for j in lines.indices {
            guard let before = above[j], let after = below[j] else { continue }
            let difference = abs(before.gap - after.gap)
            if difference <= max(max(before.gap, after.gap) * evenShare, evenSlack * lines[j].height) {
                if !tightAbove[before.line] { sets.join(before.line, j) }
                if !tightBelow[after.line] { sets.join(j, after.line) }
            }
        }
        return tables(of: sets.groups.map { Block(lines: $0.map { lines[$0] }) })
    }

    /// The space between two lines of one column, `upper` above `lower`; nil when they are not one above the
    /// other in one column, of one size, and apart.
    private static func gap(from upper: CGRect, to lower: CGRect) -> CGFloat? {
        let shorter = min(upper.height, lower.height), taller = max(upper.height, lower.height)
        guard taller <= shorter * sameSize else { return nil }
        let shared = min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX)
        let alike = (shared > 0 && shared >= min(upper.width, lower.width) * columnOverlap) || abs(upper.minX - lower.minX) <= indent * shorter
        let space = lower.minY - upper.maxY
        // Lines that overlap a good deal are not stacked: one is beside the other.
        return alike && space > -0.5 * shorter ? space : nil
    }

    /// Columns of cells made one block when they stand side by side and their rows line up.
    private static func tables(of blocks: [Block]) -> [Block] {
        let columns = blocks.indices.filter { blocks[$0].isCells }
        guard columns.count > 1 else { return blocks }
        var sets = DisjointSets(count: blocks.count)
        for (position, i) in columns.enumerated() {
            for j in columns[(position + 1)...] where sideBySide(blocks[i], blocks[j]) { sets.join(i, j) }
        }
        return sets.groups.map { Block(lines: $0.flatMap { blocks[$0].lines }) }
    }

    private static func sideBySide(_ a: Block, _ b: Block) -> Bool {
        let (left, right) = (a.rect, b.rect)
        // The detector's boxes are as tall as the ink in them, so a line's height wobbles: judge by the mean.
        let heights = (a.lines + b.lines).map(\.height)
        let height = heights.reduce(0, +) / CGFloat(heights.count)
        guard max(left.minX - right.maxX, right.minX - left.maxX) <= columnGap * height else { return false }
        // Rows in common: lines of the shorter column that have a line of the other on their row.
        let (few, many) = a.lines.count <= b.lines.count ? (a, b) : (b, a)
        let shared = few.lines.filter { line in
            many.lines.contains { min($0.maxY, line.maxY) - max($0.minY, line.minY) >= min($0.height, line.height) * rowOverlap }
        }.count
        return shared >= fewestRows && CGFloat(shared) >= CGFloat(few.lines.count) * rowsInCommon
    }
}

/// Sets of indices that have been joined, by union-find.
private struct DisjointSets {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    private mutating func root(_ index: Int) -> Int {
        var index = index
        while parent[index] != index {
            parent[index] = parent[parent[index]]
            index = parent[index]
        }
        return index
    }

    mutating func join(_ a: Int, _ b: Int) {
        parent[root(b)] = root(a)
    }

    /// The sets, each its indices in order, the sets in the order of their first index.
    var groups: [[Int]] {
        var sets = self
        var members: [Int: [Int]] = [:]
        for index in parent.indices { members[sets.root(index), default: []].append(index) }
        return members.values.sorted { $0[0] < $1[0] }
    }
}
