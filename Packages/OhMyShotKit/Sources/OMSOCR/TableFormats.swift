import Foundation

/// A recognized table written out for the places it gets pasted.
extension OCRTable {
    /// The cells with every row as long as the longest; merged cells leave rows short.
    var paddedRows: [[String]] {
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    /// A Markdown table with the first row as its header. Pipes in cells are escaped, line breaks
    /// become spaces.
    public var markdown: String {
        let rows = paddedRows.map { $0.map(Self.markdownCell) }
        guard let header = rows.first else { return "" }
        let lines = ["| " + header.joined(separator: " | ") + " |", "|" + header.map { _ in " --- " }.joined(separator: "|") + "|"]
            + rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n")
    }

    /// Comma-separated values per RFC 4180: a field with a comma, quote, or line break is quoted, and
    /// its quotes doubled.
    public var csv: String {
        paddedRows.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n")
    }

    /// Tab-separated values, as spreadsheets paste them; tabs and line breaks in cells become spaces.
    public var tsv: String {
        paddedRows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// An HTML table, which Numbers, Excel, and Pages paste as a table.
    public var html: String {
        let body = paddedRows.enumerated().map { index, row in
            let tag = index == 0 ? "th" : "td"
            return "<tr>" + row.map { "<\(tag)>\(Self.escapeHTML($0))</\(tag)>" }.joined() + "</tr>"
        }.joined()
        return "<table>\(body)</table>"
    }

    private static func markdownCell(_ cell: String) -> String {
        cell.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func csvField(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
