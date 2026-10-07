import Foundation
import OMSOCR

/// How one engine did on one case.
struct Score: Codable, Sendable {
    /// Character error rate after the least normalization (NFC, trailing spaces, line endings): what the
    /// user would paste.
    var cerRaw: Double
    /// Character error rate with all whitespace removed, punctuation width folded, and emoji dropped: true
    /// misrecognition only. The gap to `cerRaw` is formatting work (spacing, punctuation width, line
    /// breaks) that post-processing can fix.
    var cerContent: Double
    /// Lines found and kept in order, from 0 to 1.
    var lineOrder: Double
    /// Code lines whose leading spaces match, from 0 to 1.
    var indentation: Double?
    /// Whether a table came back with the expected rows and columns.
    var tableShape: Bool?
    /// Table cells read exactly (content-normalized), from 0 to 1.
    var tableCells: Double?
}

enum Metrics {
    static func score(_ result: OCRResult, against truth: Truth, category: Category) -> Score {
        let truthLines = truth.lines
        let outputLines = result.text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var score = Score(
            cerRaw: errorRate(Normalize.raw(result.text), against: Normalize.raw(truth.text)),
            cerContent: errorRate(Normalize.content(result.text), against: Normalize.content(truth.text)),
            lineOrder: lineOrder(outputLines, against: truthLines)
        )
        if category == .code {
            score.indentation = indentation(outputLines, against: truthLines)
        }
        if let table = truth.table {
            if let found = result.tables.first {
                score.tableShape = found.rows.count == table.count && zip(found.rows, table).allSatisfy { $0.count == $1.count }
                score.tableCells = cellAccuracy(found.rows, against: table)
            } else {
                score.tableShape = false
                score.tableCells = 0
            }
        }
        return score
    }

    /// Edit distance over characters, divided by the truth's length.
    static func errorRate(_ output: [Character], against truth: [Character]) -> Double {
        guard !truth.isEmpty else { return output.isEmpty ? 0 : 1 }
        return Double(editDistance(output, truth)) / Double(truth.count)
    }

    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Each truth line is matched to the closest output line (content error rate at most 0.4); the score
    /// is the longest run of matches that keeps the truth's order, over the number of truth lines. Lost
    /// lines and shuffled lines both lower it.
    static func lineOrder(_ output: [String], against truth: [String]) -> Double {
        guard !truth.isEmpty else { return 1 }
        let candidates = output.map(Normalize.content)
        let matched: [Int] = truth.compactMap { line in
            let target = Normalize.content(line)
            let best = candidates.indices.min { errorRate(candidates[$0], against: target) < errorRate(candidates[$1], against: target) }
            guard let best, errorRate(candidates[best], against: target) <= 0.4 else { return nil }
            return best
        }
        return Double(longestIncreasingRun(matched)) / Double(truth.count)
    }

    /// The share of truth lines whose matched output line starts with the same number of spaces.
    static func indentation(_ output: [String], against truth: [String]) -> Double {
        guard !truth.isEmpty else { return 1 }
        let candidates = output.map(Normalize.content)
        let correct = truth.filter { line in
            let target = Normalize.content(line)
            guard let best = candidates.indices.min(by: { errorRate(candidates[$0], against: target) < errorRate(candidates[$1], against: target) }),
                  errorRate(candidates[best], against: target) <= 0.4
            else { return false }
            return leadingSpaces(output[best]) == leadingSpaces(line)
        }
        return Double(correct.count) / Double(truth.count)
    }

    static func cellAccuracy(_ output: [[String]], against truth: [[String]]) -> Double {
        let total = truth.map(\.count).reduce(0, +)
        guard total > 0 else { return 1 }
        var correct = 0
        for (row, cells) in truth.enumerated() {
            for (column, cell) in cells.enumerated() where output.indices.contains(row) && output[row].indices.contains(column) {
                if Normalize.content(output[row][column]) == Normalize.content(cell) { correct += 1 }
            }
        }
        return Double(correct) / Double(total)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// The length of the longest strictly increasing subsequence.
    static func longestIncreasingRun(_ values: [Int]) -> Int {
        var tails: [Int] = []
        for value in values {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if tails[middle] < value { low = middle + 1 } else { high = middle }
            }
            if low == tails.count { tails.append(value) } else { tails[low] = value }
        }
        return tails.count
    }
}

enum Normalize {
    /// NFC, Unix line endings, no trailing spaces, no blank lines at either end.
    static func raw(_ text: String) -> [Character] {
        let lines = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
        return Array(lines.joined(separator: "\n").trimmingCharacters(in: .newlines))
    }

    /// Text alone: no whitespace, punctuation folded to one width, no emoji.
    static func content(_ text: String) -> [Character] {
        var characters: [Character] = []
        for character in text.precomposedStringWithCanonicalMapping where !character.isWhitespace && !isEmoji(character) {
            characters.append(contentsOf: fold(character))
        }
        return characters
    }

    private static let punctuation: [Character: String] = [
        "，": ",", "、": ",", "。": ".", "：": ":", "；": ";", "！": "!", "？": "?",
        "（": "(", "）": ")", "【": "[", "】": "]", "「": "\"", "」": "\"", "『": "\"", "』": "\"",
        "“": "\"", "”": "\"", "‘": "'", "’": "'", "～": "~", "—": "-", "–": "-", "−": "-", "…": "...",
    ]

    private static func fold(_ character: Character) -> String {
        if let folded = punctuation[character] { return folded }
        // Full-width ASCII (U+FF01...U+FF5E) to its ASCII twin.
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
           (0xFF01...0xFF5E).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xFEE0) {
            return String(Character(ascii))
        }
        return String(character)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
            || character.unicodeScalars.contains { $0.value == 0xFE0F }
    }
}
