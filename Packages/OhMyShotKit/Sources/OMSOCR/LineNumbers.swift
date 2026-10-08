import CoreGraphics
import Foundation

/// An editor's line numbers are not part of the code. Vision reads them as lines of their own, and with
/// them in place a listing no longer reads as code, so it also loses its indentation. A gutter is a column
/// of at least three lines of digits alone, aligned, left of every other line, counting up from top to
/// bottom; short readings inside the same column ("S5" for 55) and numbers Vision read together are part
/// of it. It goes
/// only when what remains is a code listing, so a numbered list or `cat -n` output keeps its numbers.
enum LineNumbers {
    static func removed(from lines: [OCRLine]) -> [OCRLine] {
        let numbers = lines.filter { isNumber($0.text) }.sorted { $0.box.midY < $1.box.midY }
        guard numbers.count >= 3 else { return lines }
        let height = numbers.map(\.box.height).sorted()[numbers.count / 2]
        let rightEdges = numbers.map(\.box.maxX).sorted()
        let leftEdges = numbers.map(\.box.minX).sorted()
        let right = rightEdges[rightEdges.count / 2]
        let left = leftEdges[0]
        let aligned = rightEdges.filter { abs($0 - right) <= height / 2 }.count * 4 >= numbers.count * 3
            || leftEdges.filter { abs($0 - left) <= height / 2 }.count * 4 >= numbers.count * 3
        let values = numbers.compactMap { Int($0.text.trimmingCharacters(in: .whitespaces)) }
        let rising = zip(values, values.dropFirst()).filter { $0 < $1 }.count
        guard aligned, rising * 4 >= (values.count - 1) * 3 else { return lines }

        // Misread numbers ("S5"), and numbers read together across rows ("757677"), are in it too.
        let inColumn = { (line: OCRLine) in
            let characters = line.text.filter { !$0.isWhitespace }
            return line.box.maxX <= right + height / 2 && (characters.count <= 5 || characters.allSatisfy { $0.isASCII && $0.isNumber })
        }
        let remaining = lines.filter { !inColumn($0) }
        guard let textStart = remaining.map(\.box.minX).min(), right <= textStart + height / 4,
              TextAssembler.isCodeListing(ReadingOrder.sorted(remaining)) else { return lines }
        return remaining
    }

    static func isNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (1...5).contains(trimmed.count) && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
