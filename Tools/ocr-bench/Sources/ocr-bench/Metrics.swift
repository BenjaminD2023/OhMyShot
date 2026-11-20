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
    /// Lines found once and kept in order, from 0 to 1.
    var lineOrder: Double
    /// Code lines whose leading spaces match, from 0 to 1.
    var indentation: Double?
    /// Whether a table came back with the expected rows and columns. Nil for an engine that reads no tables.
    var tableShape: Bool?
    /// Table cells read exactly (content-normalized), from 0 to 1. Nil for an engine that reads no tables.
    var tableCells: Double?
}

enum Metrics {
    /// `readsTables` is false for an engine whose results never carry tables: it is not scored on them, where
    /// an engine that reads tables and found none scores zero.
    static func score(_ result: OCRResult, against truth: Truth, category: Category, readsTables: Bool) -> Score {
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
        if readsTables, let table = truth.table {
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

    /// Truth lines are paired with output lines one to one (`pairs`); the score is the longest run of pairs
    /// that keeps the truth's order, over the lines of the longer text. Lost, repeated, and shuffled lines
    /// all lower it.
    static func lineOrder(_ output: [String], against truth: [String]) -> Double {
        guard !truth.isEmpty else { return output.isEmpty ? 1 : 0 }
        let kept = longestIncreasingRun(pairs(output, against: truth).map(\.output))
        return Double(kept) / Double(max(truth.count, output.count))
    }

    /// The share of truth lines whose paired output line starts with the same number of spaces.
    static func indentation(_ output: [String], against truth: [String]) -> Double {
        guard !truth.isEmpty else { return 1 }
        let correct = pairs(output, against: truth).filter { leadingSpaces(output[$0.output]) == leadingSpaces(truth[$0.truth]) }
        return Double(correct.count) / Double(truth.count)
    }

    /// Each truth line with the output line that reads it, in the truth's order: the closest pairs first
    /// (content error rate at most 0.4), equally close ones by how near their places in the two texts are,
    /// and no line in two pairs. So a line the truth repeats (a closing brace, a row of a template) pairs
    /// with its own copy: matching every truth line to its closest output line on its own gave them all the
    /// first copy, and a perfect reading of code then scored as lines lost.
    ///
    /// The pairs are free to cross, and the order is scored afterwards. Pairs kept in order from the start
    /// (an alignment) could not tell a page read right column first from one read well: where the lines are
    /// alike, as a template's are, it pairs each with its neighbour's copy and finds nothing out of order.
    static func pairs(_ output: [String], against truth: [String]) -> [(truth: Int, output: Int)] {
        let candidates = output.map(Normalize.content)
        let targets = truth.map(Normalize.content)
        var close: [(cost: Double, apart: Double, truth: Int, output: Int)] = []
        for (row, target) in targets.enumerated() {
            for (column, candidate) in candidates.enumerated() {
                let cost = errorRate(candidate, against: target)
                guard cost <= 0.4 else { continue }
                let apart = abs(Double(row) / Double(targets.count) - Double(column) / Double(candidates.count))
                close.append((cost, apart, row, column))
            }
        }
        close.sort { ($0.cost, $0.apart, $0.truth, $0.output) < ($1.cost, $1.apart, $1.truth, $1.output) }
        var pairedTruth: Set<Int> = []
        var pairedOutput: Set<Int> = []
        var pairs: [(truth: Int, output: Int)] = []
        for pair in close where !pairedTruth.contains(pair.truth) && !pairedOutput.contains(pair.output) {
            pairedTruth.insert(pair.truth)
            pairedOutput.insert(pair.output)
            pairs.append((pair.truth, pair.output))
        }
        return pairs.sorted { $0.truth < $1.truth }
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
