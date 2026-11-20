import Foundation
import OMSOCR

/// Checks the scorer against the corpus before a run. A case's own truth must score full marks, and the same
/// truth with two lines swapped, its second half read first (as two columns read in the wrong order are), a
/// line lost, or a line repeated must not. A scorer that fails either way reports a regression that is not
/// there or hides one that is: line order once gave a perfect reading of code 0.90, because every closing
/// brace matched the first one.
enum SelfCheck {
    /// What the scorer gets wrong, a line for each; empty when it holds.
    static func failures(in corpus: [BenchCase]) -> [String] {
        corpus.flatMap { item -> [String] in
            let lines = item.truth.lines
            guard !lines.isEmpty else { return [] }
            let score = { (output: [String]) in
                Metrics.score(
                    OCRResult(lines: [], tables: item.truth.table.map { [OCRTable(rows: $0)] } ?? [], text: output.joined(separator: "\n"), duration: .zero),
                    against: item.truth, category: item.category, readsTables: true
                )
            }
            var failures: [String] = []
            let perfect = score(lines)
            if perfect.cerRaw != 0 || perfect.cerContent != 0 || perfect.lineOrder != 1 || perfect.indentation ?? 1 != 1
                || perfect.tableShape == false || perfect.tableCells ?? 1 != 1 {
                failures.append("\(item.id): its own truth scores \(perfect)")
            }

            let middle = lines.count / 2
            var disturbed: [(what: String, output: [String])] = [
                ("a line lost", Array(lines[..<middle] + lines[(middle + 1)...])),
                ("a line repeated", Array(lines[...middle] + lines[middle...])),
            ]
            // Lines alike but for spaces or emoji are one line to the scorer: swapping them changes nothing.
            let content = lines.map(Normalize.content)
            if let first = content.indices.dropLast().first(where: { content[$0] != content[$0 + 1] }) {
                var swapped = lines
                swapped.swapAt(first, first + 1)
                disturbed.append(("two lines swapped", swapped))
            }
            let halvesSwapped = Array(lines[middle...] + lines[..<middle])
            if halvesSwapped.map(Normalize.content) != content {
                disturbed.append(("its second half read first", halvesSwapped))
            }
            // Line order alone: `score` would also measure the edit distance of each whole text, twice, for nothing.
            for (what, output) in disturbed where Metrics.lineOrder(output, against: lines) >= 1 {
                failures.append("\(item.id): \(what) still scores line order 1")
            }

            if item.category == .code {
                var indented = lines
                indented[middle] = "  " + indented[middle]
                let (indentation, lineOrder) = (Metrics.indentation(indented, against: lines), Metrics.lineOrder(indented, against: lines))
                if indentation >= 1 || lineOrder != 1 {
                    failures.append("\(item.id): a line indented further scores indentation \(indentation), line order \(lineOrder)")
                }
            }
            return failures
        }
    }
}
