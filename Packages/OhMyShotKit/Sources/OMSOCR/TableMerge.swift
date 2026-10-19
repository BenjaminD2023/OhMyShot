import CoreGraphics
import Foundation

/// The tables and charts the VLM pack read (Docs/ocr.md › The VLM pack), put in place of what Vision read there: each
/// row a line of its own, cells apart by tabs, as a spreadsheet pastes them. Vision's lines stay wherever the reading
/// doesn't bear itself out against them: a table or chart is taken only when its reading is whole, has two rows and two
/// columns at least, isn't over a code listing or the app's own characters, and holds mostly what Vision read there, the numbers above all, so that a
/// region the layout model took for a chart (a picture, an icon) can't put a made-up table into the text.
public enum TableMerge {
    /// A table or chart read: its region in the picture's pixels (top-left origin), its rows of cells.
    public struct Table: Sendable, Equatable {
        public enum Kind: String, Sendable, Codable {
            case table, chart
        }

        public var kind: Kind
        public var box: CGRect
        public var rows: [[String]]
        /// Whether the model said it was done, rather than stopping at its length or a deadline.
        public var isWhole: Bool

        public init(kind: Kind, box: CGRect, rows: [[String]], isWhole: Bool) {
            self.kind = kind
            self.box = box
            self.rows = rows
            self.isWhole = isWhole
        }
    }

    /// Why a table's reading was left out.
    public enum Refusal: String, Sendable {
        /// The reading stopped before the model said it was done.
        case cut
        /// Fewer than two rows or two columns.
        case small
        /// Vision read no line there to set it against.
        case unseen
        /// Vision's lines there read as code: a listing in columns stays as it is.
        case code
        /// Most of the lines there are the app's own characters (`AppTextMerge`), which a reading mustn't change.
        case appText
        /// Its numbers aren't those Vision read there.
        case numbers
        /// Its characters aren't those Vision read there.
        case characters
    }

    public struct Merged: Sendable {
        public var lines: [OCRLine]
        /// The tables taken, as tables, in the order given.
        public var tables: [OCRTable]
        /// Which of the tables given were taken, and why the others weren't.
        public var taken: [Int]
        public var refused: [(index: Int, refusal: Refusal)]
    }

    /// `lines` (in reading order) with each table that bears itself out in place of the lines inside its box.
    public static func merged(_ lines: [OCRLine], with tables: [Table]) -> Merged {
        var lines = lines
        var merged = Merged(lines: lines, tables: [], taken: [], refused: [])
        for (index, table) in tables.enumerated() {
            let inside = lines.indices.filter { isInside(lines[$0].box, table.box) }
            if let refusal = refusal(of: table, against: inside.map { lines[$0] }) {
                merged.refused.append((index, refusal))
                continue
            }
            let rows = table.rows.filter { row in row.contains { !$0.isEmpty } }
            let height = table.box.height / CGFloat(rows.count)
            let rowLines = rows.enumerated().map { row, cells in
                OCRLine(
                    text: cells.joined(separator: "\t"),
                    box: CGRect(x: table.box.minX, y: table.box.minY + CGFloat(row) * height, width: table.box.width, height: height),
                    confidence: 1, wrapsToNextLine: false, isExact: true, isTableRow: true
                )
            }
            let at = inside.first!
            for i in inside.reversed() { lines.remove(at: i) }
            lines.insert(contentsOf: rowLines, at: at)
            merged.tables.append(OCRTable(rows: rows))
            merged.taken.append(index)
        }
        merged.lines = lines
        return merged
    }

    /// `tables` (Vision's) without those lying where `merge` took a table of `read`, and with the tables taken after them.
    public static func tables(_ tables: [OCRTable], after merge: Merged, of read: [Table]) -> [OCRTable] {
        let regions = merge.taken.map { read[$0].box }
        let kept = tables.filter { table in
            let cells = table.cellBoxes.flatMap { $0 }.filter { !$0.isNull && $0.width > 0 }
            guard let first = cells.first else { return true }
            let box = cells.dropFirst().reduce(first) { $0.union($1) }
            return !regions.contains { isInside(box, $0) || isInside($0, box) }
        }
        return kept + merge.tables
    }

    /// Mostly (0.6 of it) inside `region`, grown a little: a line Vision boxed tight to the region's edge.
    static func isInside(_ box: CGRect, _ region: CGRect) -> Bool {
        let shared = box.intersection(region.insetBy(dx: -4, dy: -4))
        guard !shared.isNull, box.width > 0, box.height > 0 else { return false }
        return shared.width * shared.height >= box.width * box.height * 0.6
    }

    /// Why `table` shouldn't stand for Vision's `lines` inside it, or nil when it should.
    static func refusal(of table: Table, against lines: [OCRLine]) -> Refusal? {
        guard table.isWhole else { return .cut }
        let rows = table.rows.filter { row in row.contains { !$0.isEmpty } }
        guard rows.count >= 2, rows.contains(where: { $0.count >= 2 }) else { return .small }
        guard !lines.isEmpty else { return .unseen }
        guard !TextAssembler.isCodeListing(lines) else { return .code }
        guard lines.count { $0.isExact } * 2 < lines.count else { return .appText }
        let seen = lines.map(\.text).joined(separator: " ")
        let read = rows.flatMap { $0 }.joined(separator: " ")
        // A chart's data holds what its labels say, while Vision also read its axis's steps; a table holds what Vision
        // read and no more.
        let seenNumbers = numbers(in: seen), readNumbers = numbers(in: read)
        if !readNumbers.isEmpty, share(of: readNumbers, in: seenNumbers) < 0.8 { return .numbers }
        if table.kind == .table, !seenNumbers.isEmpty, share(of: seenNumbers, in: readNumbers) < 0.8 { return .numbers }
        let seenCharacters = characters(of: seen), readCharacters = characters(of: read)
        if share(of: readCharacters, in: seenCharacters) < 0.75 { return .characters }
        if table.kind == .table, share(of: seenCharacters, in: readCharacters) < 0.75 { return .characters }
        return nil
    }

    /// The runs of digits in `text`: "1,240.5" is 1, 240, and 5, as Vision may read the separators otherwise.
    static func numbers(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).map(String.init)
    }

    /// The characters of `text` but spaces, widths and case folded.
    static func characters(of text: String) -> [Character] {
        text.compactMap { character in
            character.isWhitespace ? nil : Character(SecondReading.folded(character).lowercased())
        }
    }

    /// How much of `items` (counted with repeats) `other` holds too, from 0 to 1; 1 when there are none.
    static func share<T: Hashable>(of items: [T], in other: [T]) -> Double {
        guard !items.isEmpty else { return 1 }
        var counts: [T: Int] = [:]
        for item in other { counts[item, default: 0] += 1 }
        var found = 0
        for item in items where counts[item, default: 0] > 0 {
            counts[item]! -= 1
            found += 1
        }
        return Double(found) / Double(items.count)
    }
}

/// The VLM's own ways of writing a table and a chart, as rows of cells.
public enum TableText {
    /// OTSL, as PaddleOCR-VL writes a table: `<fcel>` before a cell's text, `<ecel>` an empty cell, `<lcel>`, `<ucel>`,
    /// and `<xcel>` a cell merged with the one to its left, above, or both (empty here: a merged cell appears once, at its
    /// first row and column), `<nl>` the end of a row. Rows are padded to the widest.
    public static func rows(otsl text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let tag = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            let content = rest.prefix { $0 != "<" }
            switch tag {
            case "fcel":
                row.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
                rest = rest.dropFirst(content.count)
            case "ecel", "lcel", "ucel", "xcel":
                row.append("")
            case "nl":
                rows.append(row)
                row = []
            default:
                // Markup inside a cell (a line break): the text goes on in the cell.
                if !row.isEmpty {
                    let more = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !more.isEmpty { row[row.count - 1] += row[row.count - 1].isEmpty ? more : " " + more }
                    rest = rest.dropFirst(content.count)
                }
            }
        }
        if !row.isEmpty { rows.append(row) }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    /// A chart's data as PaddleOCR-VL writes it: a line a row, cells apart by " | " (a Markdown table's outer bars and
    /// rule line allowed). Rows are padded to the widest.
    public static func rows(chart text: String) -> [[String]] {
        let rows = text.split(whereSeparator: \.isNewline).compactMap { line -> [String]? in
            var line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("|") { line.removeFirst() }
            if line.hasSuffix("|") { line.removeLast() }
            let cells = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !cells.allSatisfy({ $0.isEmpty || $0.allSatisfy { "-:".contains($0) } }) else { return nil }
            return cells
        }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
}

extension TextAnalysis {
    /// The analysis with the tables and charts that bear themselves out in place of Vision's lines there (`TableMerge`):
    /// its text assembled again as `assembly` says, and the tables Vision found where they lie replaced by those read
    /// (a chart's data is a table too); and what the merge did.
    public func withTables(_ read: [TableMerge.Table], assembly: TextAssembler.Options) -> (analysis: TextAnalysis, merge: TableMerge.Merged) {
        let merge = TableMerge.merged(result.lines, with: read)
        guard !merge.taken.isEmpty else { return (self, merge) }
        var analysis = self
        analysis.result.lines = merge.lines
        analysis.result.text = TextAssembler.assemble(merge.lines, options: assembly)
        analysis.tables = TableMerge.tables(tables, after: merge, of: read)
        return (analysis, merge)
    }
}
