import Foundation

/// The tables in Markdown text, as GitHub reads pipe tables: a header row, a delimiter row of dashes, then rows until a
/// line without a pipe. A cloud model writes tables this way (Docs/ocr.md › Cloud models), and the OCR panel shows
/// and copies them as it does Vision's.
public enum MarkdownTables {
    public static func tables(in text: String) -> [OCRTable] {
        let lines = text.components(separatedBy: .newlines)
        var tables: [OCRTable] = []
        var fence: Substring?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.drop { $0 == " " }
            // Nothing inside a code block is a table.
            if let marker = fenceMarker(trimmed) {
                if let open = fence {
                    if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) { fence = nil }
                } else {
                    fence = marker
                }
                index += 1
                continue
            }
            guard fence == nil, index + 1 < lines.count, line.contains("|"), let columns = delimiterColumns(lines[index + 1]) else {
                index += 1
                continue
            }
            let header = cells(of: line)
            guard header.count == columns else {
                index += 1
                continue
            }
            var rows = [header]
            index += 2
            while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                var row = cells(of: lines[index])
                // As GitHub does: a short row is filled out, a long one cut to the header's width.
                if row.count < columns { row += Array(repeating: "", count: columns - row.count) }
                rows.append(Array(row.prefix(columns)))
                index += 1
            }
            tables.append(OCRTable(rows: rows))
        }
        return tables
    }

    /// "```" or "~~~" (three or more) opening or closing a fenced code block.
    private static func fenceMarker(_ line: Substring) -> Substring? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let marker = line.prefix { $0 == first }
        return marker.count >= 3 ? marker : nil
    }

    /// How many columns a delimiter row (`| --- | :--: |`) has, or nil when the line isn't one.
    private static func delimiterColumns(_ line: String) -> Int? {
        let parts = cells(of: line)
        guard !parts.isEmpty, parts.allSatisfy({ part in
            var core = Substring(part)
            if core.hasPrefix(":") { core = core.dropFirst() }
            if core.hasSuffix(":") { core = core.dropLast() }
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }) else { return nil }
        // One cell needs a pipe somewhere, or a lone "---" (a rule, or a heading's underline) would count.
        guard line.contains("|") else { return nil }
        return parts.count
    }

    /// A row's cells, trimmed, without the pipes at its ends. A pipe escaped (`\|`) or inside a code span is text.
    static func cells(of line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for character in row {
            if escaped {
                // "\|" is a pipe in the cell; any other escape stays as written.
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
