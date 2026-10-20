import AppKit

/// Tab stops for a table's rows in the panel's text, where its cells are apart by tabs (the TSV a table read by Vision or
/// the Tables and Charts pack is copied as): each column as wide as its widest cell, so the rows line up as in the Table
/// pane, and columns of figures end at a right-aligned stop. On AppKit's default stops, one every 28 pt, a cell narrower
/// than that ran into the next ("East860") while a wider one jumped a column.
enum TableTabStops {
    /// Room between a column's widest cell and the next column.
    static let gap: CGFloat = 16

    struct Block: Equatable {
        /// The lines, through the last one's line break.
        var range: NSRange
        var stops: [NSTextTab]
    }

    /// Each run of lines that hold a tab after other text (a tab only at a line's start indents, as in code), with the
    /// stops its cells need in `font`.
    static func blocks(in text: String, font: NSFont) -> [Block] {
        let string = text as NSString
        var runs: [[(range: NSRange, cells: [String])]] = [[]]
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            let content = string.substring(with: line)
            if content.range(of: #"\S\t"#, options: .regularExpression) != nil {
                runs[runs.count - 1].append((enclosing, content.components(separatedBy: "\t")))
            } else if !runs[runs.count - 1].isEmpty {
                runs.append([])
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return runs.filter { !$0.isEmpty }.map { rows in
            let columns = rows.map(\.cells.count).max() ?? 0
            let widths = (0..<columns).map { column in
                rows.map { $0.cells.indices.contains(column) ? ceil(($0.cells[column] as NSString).size(withAttributes: attributes).width) : 0 }.max() ?? 0
            }
            var stops: [NSTextTab] = []
            var left: CGFloat = 0
            for column in 0..<columns {
                if column > 0 {
                    stops.append(holdsFigures(rows.map(\.cells), column: column)
                        ? NSTextTab(textAlignment: .right, location: left + widths[column])
                        : NSTextTab(textAlignment: .left, location: left))
                }
                left += widths[column] + gap
            }
            let first = rows[0].range
            let last = rows[rows.count - 1].range
            return Block(range: NSRange(location: first.location, length: NSMaxRange(last) - first.location), stops: stops)
        }
    }

    /// The paragraph style of a block's lines: `base` with the block's stops.
    static func style(_ base: NSParagraphStyle, stops: [NSTextTab]) -> NSParagraphStyle {
        guard let style = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        style.tabStops = stops
        return style
    }

    /// Sets `base` over the whole of `storage`, then each block's stops over its lines.
    static func apply(_ blocks: [Block], base: NSParagraphStyle, to storage: NSTextStorage) {
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: base, range: NSRange(location: 0, length: storage.length))
        for block in blocks where NSMaxRange(block.range) <= storage.length {
            storage.addAttribute(.paragraphStyle, value: style(base, stops: block.stops), range: block.range)
        }
        storage.endEditing()
    }

    /// A column of figures, here and in the Table pane: every cell under the first row starts with a digit, maybe after a
    /// sign or a currency symbol ("$20", "100 GB", "−3%").
    static func holdsFigures(_ rows: [[String]], column: Int) -> Bool {
        let cells = rows.dropFirst().compactMap { $0.indices.contains(column) ? $0[column] : nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^[\p{Sc}+\-−±]?\s?\d"#, options: .regularExpression) != nil }
    }
}
