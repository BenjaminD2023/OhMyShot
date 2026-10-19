import CoreGraphics
import Foundation

/// What an app shows under one of Vision's lines, as it says through Accessibility (L0, Docs/ocr.md › Text from apps).
public struct AppTextLine: Sendable, Equatable {
    /// The box of the Vision line it was read for, in image pixels.
    public var box: CGRect
    /// The text of each place along the line, left to right: the app's line of text there, which may run on past the
    /// picture's edge, or the whole text of an element that has no lines (a label, a paragraph of a web page).
    public var pieces: [String]
    /// The app's name.
    public var app: String

    public init(box: CGRect, pieces: [String], app: String) {
        self.box = box
        self.pieces = pieces
        self.app = app
    }
}

/// L0 beside L1: Vision's lines, in Vision's order, each with the app's own characters where the app shows text that
/// reads like it in its place.
///
/// Vision decides which lines there are and where they are, from what the picture shows; the app says only which
/// characters they are. What the app shows under a line is found by asking it for the element at points along the
/// line, so it can hold more than the line: the rest of a paragraph, the part of a line the selection cut off. The part
/// that reads like Vision's line is taken (an alignment free to start and end anywhere in the app's text) when Vision's
/// line differs from it in at most a quarter of its characters, one in lines of four to seven, none in shorter ones;
/// spaces aside, widths and quotation marks folded, and a character Vision mistakes for another of its shape (l, I, 1,
/// and |; 0, O, and o; a letter of the other case) counted as a quarter of a difference: there, the app is right. The
/// app's text whole could hold what the screen doesn't show: the labels of icons, titles cut short with "…", rows
/// scrolled away, placeholders; and it can change between the moment the screen froze and the moment the app is asked.
/// A line that doesn't read alike keeps Vision's text, and so does one whose digits the app has otherwise: a digit for
/// another, or one more or fewer. Vision reads digits well, and a clock or a price that moved on since the picture
/// would otherwise be copied as a number the picture never showed.
public enum AppTextMerge {
    /// Vision's lines put together with what the apps said.
    public struct Merged: Sendable, Equatable {
        /// Vision's lines, with the app's characters in those it bears out, less the scraps beside them.
        public var lines: [OCRLine]
        /// The indexes in `lines` of the lines the app's text bears out, changed or not.
        public var taken: [Int]
        /// How many of those it changed.
        public var changed: Int
        /// How many scraps went.
        public var dropped: Int
        /// The app most of the text came from, when the lines it bears out hold half its characters or more: what
        /// Capture Text's card says the text is from. Nil when Vision read most of it.
        public var source: String?
    }

    /// `lines` (Vision's) with the app's characters in the lines `read` matches, by box. Formulas and vertical lines
    /// keep Vision's text.
    ///
    /// A line of Vision's the app doesn't bear out goes when it is a scrap of one the app does: nine tenths of it
    /// within that line's box, and less than three fifths its height. Vision makes such scraps of the strokes of
    /// Chinese ("TZHУ" under a line); the app's line holds what is there.
    public static func merged(_ lines: [OCRLine], with read: [AppTextLine]) -> Merged {
        guard !read.isEmpty else { return Merged(lines: lines, taken: [], changed: 0, dropped: 0) }
        var merged = lines
        var taken: [Int] = []
        var changed = 0
        for (index, line) in lines.enumerated() where line.math == nil && line.direction != .topToBottom {
            guard let shown = read.first(where: { $0.box == line.box }), let text = match(line.text, in: shown.pieces) else { continue }
            if text != line.text { changed += 1 }
            merged[index].text = text
            merged[index].confidence = 1
            merged[index].isExact = true
            taken.append(index)
        }
        let scraps = Set(lines.indices.filter { index in
            let box = lines[index].box
            guard !taken.contains(index), lines[index].math == nil, box.width > 0, box.height > 0 else { return false }
            return taken.contains { other in
                let holder = lines[other].box, common = box.intersection(holder)
                return !common.isNull && common.width * common.height >= box.width * box.height * 0.9 && box.height < holder.height * 0.6
            }
        })
        if !scraps.isEmpty {
            let kept = lines.indices.filter { !scraps.contains($0) }
            let place = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
            merged = kept.map { merged[$0] }
            taken = taken.compactMap { place[$0] }
        }
        return Merged(lines: merged, taken: taken, changed: changed, dropped: scraps.count, source: source(of: merged, taken: taken, read: read))
    }

    /// The app most of `lines` (merged) came from, when the lines `taken` from apps hold half their characters or
    /// more.
    static func source(of lines: [OCRLine], taken: [Int], read: [AppTextLine]) -> String? {
        let all = lines.reduce(0) { $0 + characters(in: $1.text) }
        var byApp: [String: Int] = [:]
        for index in taken {
            guard let app = read.first(where: { $0.box == lines[index].box })?.app, !app.isEmpty else { continue }
            byApp[app, default: 0] += characters(in: lines[index].text)
        }
        guard all > 0, byApp.values.reduce(0, +) * 2 >= all else { return nil }
        return byApp.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    private static func characters(in text: String) -> Int {
        text.count { !$0.isWhitespace }
    }

    /// The longest text of the app's taken into account; past it, a piece is likely a whole document.
    static let longest = 8000

    /// The part of `pieces` (the app's text along a line, left to right) that reads like `seen` (Vision's reading of
    /// the line), written with the app's characters, or nil when no part does.
    ///
    /// Between two characters of one piece go the spaces the app has there; between two pieces, a space where Vision
    /// read one between the characters each stands for, else where neither side is Han, kana, or Hangul. A line break
    /// within the part becomes a space.
    static func match(_ seen: String, in pieces: [String]) -> String? {
        let (s, sSpaced) = marks(of: seen)
        guard !s.isEmpty else { return nil }
        let shown = Shown(pieces)
        guard !shown.marks.isEmpty, shown.marks.count <= longest else { return nil }
        let a = shown.marks.map(\.key)
        // In quarters of an edit.
        let allowed = s.count < 4 ? 0 : s.count < 8 ? 4 : s.count
        guard a.count * 4 + allowed >= s.count * 4, let found = bestPart(of: a, for: s), found.cost <= allowed else { return nil }

        let part = Array(a[found.start..<found.end])
        let pair = alignment(s, part)
        guard sameDigits(s, part, pair) else { return nil }
        var text = ""
        for k in part.indices {
            let mark = shown.marks[found.start + k]
            if k > 0 {
                if let space = mark.spaceBefore {
                    text += space.contains(where: \.isNewline) ? " " : space
                } else if let p = pair[k - 1], let q = pair[k], q == p + 1 {
                    if sSpaced[q] { text += " " }
                } else if !Script.isCJK(shown.marks[found.start + k - 1].character), !Script.isCJK(mark.character) {
                    text += " "
                }
            }
            text.append(mark.character)
        }
        return text
    }

    /// The app's pieces as characters other than spaces, each with the spaces before it in its piece ("" for none),
    /// or nil where it starts a piece after the first.
    private struct Shown {
        struct Mark {
            let character: Character
            let key: Character
            let spaceBefore: String?
        }

        var marks: [Mark] = []

        init(_ pieces: [String]) {
            for piece in pieces {
                var space = ""
                var starts = true
                for character in piece {
                    if character.isWhitespace {
                        if !starts { space.append(character) }
                        continue
                    }
                    marks.append(Mark(character: character, key: AppTextMerge.key(character), spaceBefore: starts ? (marks.isEmpty ? "" : nil) : space))
                    space = ""
                    starts = false
                }
            }
        }
    }

    /// Whether `part` (the app's) holds the digits `s` (Vision's) does, where the alignment `pair` puts them: none read as
    /// another digit, none the app has more, none it has fewer (nor any Vision read beyond the part).
    private static func sameDigits(_ s: [Character], _ part: [Character], _ pair: [Int?]) -> Bool {
        var paired = Set<Int>()
        for (k, character) in part.enumerated() {
            guard let q = pair[k] else {
                if isDigit(character) { return false }
                continue
            }
            paired.insert(q)
            if isDigit(character), isDigit(s[q]), character != s[q] { return false }
        }
        // A digit Vision read past either end of the app's part too: a count beside a button is on screen.
        return !s.indices.contains { isDigit(s[$0]) && !paired.contains($0) }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Vision's characters other than spaces, folded, each with whether a space comes before it.
    private static func marks(of text: String) -> (keys: [Character], spacedBefore: [Bool]) {
        var keys: [Character] = [], spaced: [Bool] = []
        var space = false
        for character in text {
            if character.isWhitespace {
                space = !keys.isEmpty
                continue
            }
            keys.append(key(character))
            spaced.append(space)
            space = false
        }
        return (keys, spaced)
    }

    /// A character as the two readings are compared: widths folded (`SecondReading.folded`), curly quotation marks
    /// straight.
    static func key(_ character: Character) -> Character {
        switch character {
        case "‘", "’", "‚", "‛", "′": "'"
        case "“", "”", "„", "‟", "″": "\""
        default: SecondReading.folded(character)
        }
    }

    /// What reading `a` for `b` costs, in quarters of an edit: nothing for the same character, a quarter for one
    /// Vision mistakes for the other, a whole edit else (as for one left out or one more).
    static func substitution(_ a: Character, _ b: Character) -> Int {
        if a == b { return 0 }
        if let shape = shapes[a], shape == shapes[b] { return 1 }
        return a.lowercased() == b.lowercased() ? 1 : 4
    }

    /// Characters of one shape, as Vision reads them for each other.
    private static let shapes: [Character: Int] = {
        var shapes: [Character: Int] = [:]
        for (index, group) in ["lI1|!", "0Oo", "5S", "2Z", "8B", "-–—‐−", "[「", "]」"].enumerated() {
            for character in group { shapes[character] = index }
        }
        return shapes
    }()

    /// Where in `a` (the app's characters) `s` (Vision's) reads with the fewest edits, free to start and end anywhere:
    /// the first such part, as a range of `a`, and its cost in quarters of an edit.
    private static func bestPart(of a: [Character], for s: [Character]) -> (cost: Int, start: Int, end: Int)? {
        let m = s.count
        // Column by column through `a`: `cost[i]` is the least cost that reads `s[..<i]` as a part of `a` ending here,
        // and `start[i]` where that part starts.
        var cost = (0...m).map { $0 * 4 }, start = [Int](repeating: 0, count: m + 1)
        var next = cost, nextStart = start
        var best: (cost: Int, start: Int, end: Int)?
        for j in 1...a.count {
            next[0] = 0
            nextStart[0] = j
            for i in 1...m {
                let same = cost[i - 1] + substitution(s[i - 1], a[j - 1])
                let left = next[i - 1] + 4
                let extra = cost[i] + 4
                if same <= left, same <= extra {
                    next[i] = same
                    nextStart[i] = start[i - 1]
                } else if left <= extra {
                    next[i] = left
                    nextStart[i] = nextStart[i - 1]
                } else {
                    next[i] = extra
                    nextStart[i] = start[i]
                }
            }
            // As few edits as can be, and of those the longest part from where it starts: "Cance1" reads "Cancel", not
            // "Cance" with the 1 left out.
            if nextStart[m] < j, next[m] < best?.cost ?? m * 4 || (next[m] == best?.cost && nextStart[m] == best?.start) {
                best = (next[m], nextStart[m], j)
            }
            swap(&cost, &next)
            swap(&start, &nextStart)
        }
        return best
    }

    /// For each character of `b`, the character of `a` it stands for in an alignment of least cost, nil where `b` holds
    /// one more.
    private static func alignment(_ a: [Character], _ b: [Character]) -> [Int?] {
        guard !a.isEmpty, !b.isEmpty else { return [Int?](repeating: nil, count: b.count) }
        var cost = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { cost[i][0] = i * 4 }
        for j in 0...b.count { cost[0][j] = j * 4 }
        for i in 1...a.count {
            for j in 1...b.count {
                cost[i][j] = min(cost[i - 1][j] + 4, cost[i][j - 1] + 4, cost[i - 1][j - 1] + substitution(a[i - 1], b[j - 1]))
            }
        }
        var pair = [Int?](repeating: nil, count: b.count)
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if cost[i][j] == cost[i - 1][j - 1] + substitution(a[i - 1], b[j - 1]) {
                pair[j - 1] = i - 1
                i -= 1
                j -= 1
            } else if cost[i][j] == cost[i][j - 1] + 4 {
                j -= 1
            } else {
                i -= 1
            }
        }
        return pair
    }
}

extension TextAnalysis {
    /// The analysis with the app's characters in the lines it shows alike (`AppTextMerge`): its text assembled again as
    /// `assembly` says, its tables' cells taken from the lines again; and what the merge did.
    public func withAppText(_ read: [AppTextLine], assembly: TextAssembler.Options) -> (analysis: TextAnalysis, merge: AppTextMerge.Merged) {
        let merge = AppTextMerge.merged(result.lines, with: read)
        guard !merge.taken.isEmpty else { return (self, merge) }
        var analysis = self
        analysis.result.lines = merge.lines
        analysis.result.text = TextAssembler.assemble(merge.lines, options: assembly)
        analysis.tables = tables.map { $0.filled(from: merge.lines) }
        return (analysis, merge)
    }
}
