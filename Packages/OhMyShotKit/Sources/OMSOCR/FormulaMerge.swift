import CoreGraphics
import Foundation

/// The formulas the formula pack read in a picture, put into the lines Vision read in it (Docs/ocr.md › Formulas among
/// text). Vision reads a formula as text of a sort ("-6土 v62- 4ac", "速度二时间"), so each formula takes the place of
/// what Vision made of it:
///
/// - A formula and the lines on its row that reach it (overlapping it, or within a line's height of it) become one line.
///   What those lines hold beside the formula is read again alone (`Plan.pieces`), since Vision's reading of the whole
///   line runs the formula's glyphs into its words, and the formula's LaTeX goes between, as `$…$`.
/// - A formula with no text beside it is a line of its own: `$$…$$` when the model found it set apart, else `$…$`.
/// - A reading with nothing of a formula in it (numbers, words set upright: LaTeX with no letter in italic and no command,
///   operator, script, or brace) leaves the text as Vision read it: "2.0" or "3.5 GB" need no `$`.
public enum FormulaMerge {
    /// A formula the formula pack read whole.
    public struct Formula: Sendable, Equatable {
        public var kind: LayoutFinder.Region.Kind
        /// In the picture's pixels, top-left origin.
        public var box: CGRect
        public var latex: String

        public init(kind: LayoutFinder.Region.Kind, box: CGRect, latex: String) {
            self.kind = kind
            self.box = box
            self.latex = latex
        }
    }

    /// A part of a line beside a formula, read again on its own.
    public struct Piece: Sendable, Equatable {
        /// In the picture's pixels: the line's height, between the formulas.
        public var box: CGRect
        /// The line it is part of, by index.
        var line: Int
        /// Whether a formula ends where it starts, and starts where it ends.
        var formulaBefore: Bool
        var formulaAfter: Bool
    }

    /// What to read again, and how to put the lines together once it is read.
    public struct Plan: Sendable, Equatable {
        /// The parts of lines beside formulas, to read again each on its own.
        public var pieces: [Piece]
        /// Whether the lines the pieces come from are all but free of CJK: the pieces then read best with the Latin model.
        public var latin: Bool
        /// The lines no formula touches, by index, kept as they are.
        var kept: [Int]
        var rows: [Row]

        /// Whether the formulas change anything.
        public var changes: Bool { !rows.isEmpty }
    }

    /// A line made of formulas and pieces of the lines beside them, left to right.
    struct Row: Sendable, Equatable {
        enum Part: Sendable, Equatable {
            case piece(Int)
            case formula(Int)
        }

        var parts: [Part]
        /// The lines it replaces, by index.
        var lines: [Int]
        var box: CGRect
    }

    /// Where the formulas go among `lines`.
    public static func plan(_ lines: [OCRLine], formulas: [Formula]) -> Plan {
        let formulaIndices = formulas.indices.filter { !isPlain(formulas[$0].latex) }
        let lineIndices = lines.indices.filter { lines[$0].direction != .topToBottom && lines[$0].box.height > 0 }
        // Lines and formulas joined when on one row and near; each group of them is a row.
        var parent = Array(0..<(lines.count + formulas.count))
        func root(_ node: Int) -> Int {
            var node = node
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        for f in formulaIndices {
            for l in lineIndices where reaches(lines[l].box, formulas[f].box) {
                parent[root(lines.count + f)] = root(l)
            }
        }
        var groups: [Int: (lines: [Int], formulas: [Int])] = [:]
        for f in formulaIndices { groups[root(lines.count + f), default: ([], [])].formulas.append(f) }
        for l in lineIndices where groups[root(l)] != nil { groups[root(l)]!.lines.append(l) }

        var pieces: [Piece] = []
        var rows: [Row] = []
        var taken = Set<Int>()
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
            var parts: [(x: CGFloat, part: Row.Part)] = group.formulas.map { (formulas[$0].box.minX, .formula($0)) }
            var box = group.formulas.dropFirst().reduce(formulas[group.formulas[0]].box) { $0.union(formulas[$1].box) }
            let covers = group.formulas.map { formulas[$0].box.minX..<formulas[$0].box.maxX }
            for l in group.lines {
                let line = lines[l].box
                box = box.union(line)
                taken.insert(l)
                for span in uncovered(line.minX..<line.maxX, by: covers) where span.upperBound - span.lowerBound >= max(3, line.height * 0.15) {
                    parts.append((span.lowerBound, .piece(pieces.count)))
                    pieces.append(Piece(
                        box: CGRect(x: span.lowerBound, y: line.minY, width: span.upperBound - span.lowerBound, height: line.height), line: l,
                        formulaBefore: covers.contains { $0.contains(span.lowerBound - 0.5) },
                        formulaAfter: covers.contains { $0.contains(span.upperBound) }
                    ))
                }
            }
            rows.append(Row(parts: parts.sorted { $0.x < $1.x }.map(\.part), lines: group.lines.sorted(), box: box))
        }
        // Vision reads a formula's glyphs as the odd CJK character ("臺" for ½): only a tenth of the letters or more
        // makes the lines Chinese or Japanese.
        let text = Set(pieces.map(\.line)).flatMap { lines[$0].text.filter { !$0.isWhitespace } }
        let latin = Double(text.count { $0.isLetter && Script.isCJK($0) }) < Double(text.count) * 0.1
        return Plan(pieces: pieces, latin: latin, kept: lines.indices.filter { !taken.contains($0) }, rows: rows)
    }

    /// `lines` with the formulas in them, as `plan` has it, `pieces` the text read again in its pieces; not in reading
    /// order. A piece's text is the line's own where it matches (`aligned`).
    public static func lines(_ lines: [OCRLine], formulas: [Formula], plan: Plan, pieces read: [String]) -> [OCRLine] {
        var cursors: [Int: Int] = [:]
        let pieces = plan.pieces.indices.map { index -> String in
            let piece = plan.pieces[index]
            let again = read.indices.contains(index) ? read[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let line = Array(lines[piece.line].text), cursor = cursors[piece.line] ?? 0
            guard let match = aligned(again, in: String(line), from: cursor) else {
                // Read alone, a piece that starts on a comma lost the space after it.
                return again.replacingOccurrences(of: #"^([,;:])(?=\p{L})"#, with: "$1 ", options: .regularExpression)
            }
            cursors[piece.line] = match.end
            var text = withEnds(of: again, on: match.text)
            // The period after a formula, cut off with the formula's edge, is still in the line's own reading.
            if piece.formulaBefore, let first = text.first, !enders.contains(first),
               let mark = line[cursor..<match.start].lastIndex(where: { !$0.isWhitespace }), enders.contains(line[mark]) {
                text = String(line[mark..<match.start]) + text
            }
            return text
        }
        var merged = plan.kept.map { lines[$0] }
        for row in plan.rows {
            let hasText = row.parts.contains { if case .piece(let p) = $0 { !text(of: p, in: pieces).isEmpty } else { false } }
            let alone = !hasText && row.parts.count { if case .formula = $0 { true } else { false } } == 1
            let parts: [(text: String, isFormula: Bool)] = row.parts.map { part in
                switch part {
                case .piece(let p): (text(of: p, in: pieces), false)
                case .formula(let f): (wrapped(formulas[f], display: alone), true)
                }
            }
            let members = row.lines.map { lines[$0] }
            let last = members.max { $0.box.maxX < $1.box.maxX }
            let display = alone && row.parts.contains { if case .formula(let f) = $0 { formulas[f].kind == .display } else { false } }
            var text = joined(parts)
            // A period or comma right after a formula ending the line is too narrow a piece to read; the line had it.
            if !display, parts.last(where: { !$0.text.isEmpty })?.isFormula == true,
               let end = last?.text.trimmingCharacters(in: .whitespaces).last, enders.contains(end), let final = text.last, !enders.contains(final) {
                text.append(end)
            }
            merged.append(OCRLine(
                text: text,
                box: row.box,
                confidence: members.map(\.confidence).min() ?? 1,
                direction: .leftToRight,
                wrapsToNextLine: hasText ? last?.wrapsToNextLine : false,
                math: display ? .display : .inline
            ))
        }
        return merged
    }

    /// The punctuation that ends a clause or a sentence.
    static let enders: Set<Character> = [".", ",", ";", ":", "!", "?", "。", "，", "；", "：", "！", "？"]

    /// `text`, the line's own reading of a piece, with the punctuation the piece read alone has at its ends and the line
    /// doesn't there: the line's reading may run a formula's garble into the period after it.
    static func withEnds(of piece: String, on text: String) -> String {
        let normal = { (character: Character?) in character.map { Punctuation.halfWidth[$0] ?? $0 } }
        var text = text
        if let first = piece.first, enders.contains(first), normal(text.first) != normal(first) {
            text = String(first) + (piece.dropFirst().first?.isWhitespace == true ? " " : "") + text
        }
        if let last = piece.last, enders.contains(last), normal(text.last) != normal(last) {
            text.append(last)
        }
        return text
    }

    private static func text(of piece: Int, in pieces: [String]) -> String {
        pieces.indices.contains(piece) ? pieces[piece].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// `$$…$$` for a formula set apart on a line of its own, else `$…$`, with the punctuation a formula within text ends
    /// on (its box takes in the comma after it) put after it, as prose has it.
    static func wrapped(_ formula: Formula, display: Bool) -> String {
        let latex = formula.latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if display && formula.kind == .display { return "$$\(latex)$$" }
        guard let last = latex.last, ".,;:".contains(last), latex.count > 1, latex.dropLast().last != "\\" else { return "$\(latex)$" }
        return "$\(latex.dropLast())$\(last)"
    }

    // MARK: Geometry

    /// Where to cut each piece out to read it, in the picture's pixels, or nil for one too narrow to hold anything:
    /// - beside a formula, at the blank columns nearest the formula's edge (within a third of the line's height): a box
    ///   drawn close leaves a sliver of the formula's ink by it ("loss." for "loss", "lis" for "is"), and one drawn wide
    ///   would cut the comma after it;
    /// - a little past the line's own ends;
    /// - a quarter of the line's height above and below, but not into a line or formula above or below: a line holding a
    ///   fraction is tall, and its padding reached the subscripts of the line above.
    ///
    /// `ink` gives the columns holding ink in a part of the picture.
    static func crops(_ plan: Plan, lines: [OCRLine], formulas: [Formula], size: CGSize, ink: (CGRect) -> InkProfile?) -> [CGRect?] {
        let bounds = CGRect(origin: .zero, size: size)
        return plan.pieces.map { piece in
            let box = piece.box, height = box.height
            var top = box.minY - height * 0.25, bottom = box.maxY + height * 0.25
            let others = lines.indices.filter { $0 != piece.line }.map { lines[$0].box } + formulas.map(\.box)
            for other in others where other.minX < box.maxX && other.maxX > box.minX {
                let shared = min(other.maxY, box.maxY) - max(other.minY, box.minY)
                guard shared < min(other.height, height) * 0.5 else { continue }
                if other.midY < box.midY { top = max(top, other.maxY) } else { bottom = min(bottom, other.minY) }
            }
            guard bottom - top >= 2 else { return nil }
            let reach = height / 3
            // The gap on the text's side of the formula's edge first: a box drawn close ends where the formula's ink
            // does, and the period after it may sit a pixel or two away.
            func blankNear(_ x: CGFloat, textAfter: Bool) -> Range<Int>? {
                guard let profile = ink(CGRect(x: x - reach, y: top, width: reach * 2, height: bottom - top)) else { return nil }
                let runs = blanks(in: profile)
                let onTextSide = runs.filter { textAfter ? CGFloat($0.upperBound) > x : CGFloat($0.lowerBound) < x }
                return (onTextSide.isEmpty ? runs : onTextSide).min { distance($0, x) < distance($1, x) }
            }
            var left = box.minX - min(height * 0.15, 4), right = box.maxX + min(height * 0.15, 4)
            if piece.formulaBefore {
                left = blankNear(box.minX, textAfter: true).map { CGFloat(max($0.lowerBound, $0.upperBound - 2)) } ?? box.minX
            }
            if piece.formulaAfter {
                right = blankNear(box.maxX, textAfter: false).map { CGFloat(min($0.upperBound, $0.lowerBound + 2)) } ?? box.maxX
            }
            guard right - left >= max(3, height * 0.15) else { return nil }
            let crop = CGRect(x: left, y: top, width: right - left, height: bottom - top).integral.intersection(bounds)
            return crop.isNull || crop.width < 2 || crop.height < 2 ? nil : crop
        }
    }

    /// The runs of columns without ink, in the picture's x.
    static func blanks(in profile: InkProfile) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (column, hasInk) in profile.ink.enumerated() {
            if !hasInk, start == nil { start = column }
            if hasInk, let first = start {
                runs.append((profile.originX + first)..<(profile.originX + column))
                start = nil
            }
        }
        if let first = start { runs.append((profile.originX + first)..<(profile.originX + profile.ink.count)) }
        return runs
    }

    private static func distance(_ run: Range<Int>, _ x: CGFloat) -> CGFloat {
        if CGFloat(run.lowerBound) <= x, x <= CGFloat(run.upperBound) { return 0 }
        return min(abs(CGFloat(run.lowerBound) - x), abs(CGFloat(run.upperBound) - x))
    }

    /// Whether a line and a formula are on one row (they share half the height of the shorter at least) and near (they
    /// overlap, or the gap between them is no wider than the line is tall).
    static func reaches(_ line: CGRect, _ formula: CGRect) -> Bool {
        let shared = min(line.maxY, formula.maxY) - max(line.minY, formula.minY)
        guard shared >= min(line.height, formula.height) * 0.5 else { return false }
        let gap = max(line.minX, formula.minX) - min(line.maxX, formula.maxX)
        return gap <= line.height
    }

    /// The parts of `span` none of `covers` covers, left to right.
    static func uncovered(_ span: Range<CGFloat>, by covers: [Range<CGFloat>]) -> [Range<CGFloat>] {
        var spans: [Range<CGFloat>] = []
        var start = span.lowerBound
        for cover in covers.sorted(by: { $0.lowerBound < $1.lowerBound }) where cover.upperBound > start && cover.lowerBound < span.upperBound {
            if cover.lowerBound > start { spans.append(start..<cover.lowerBound) }
            start = max(start, cover.upperBound)
        }
        if start < span.upperBound { spans.append(start..<span.upperBound) }
        return spans
    }

    // MARK: Text

    /// LaTeX with nothing of a formula in it: numbers, and words set upright (`\mathrm{}`, `\text{}`), with the
    /// punctuation of prose and spacing commands between. A letter set in italic is a variable: "n" or "L(x)" is math.
    static func isPlain(_ latex: String) -> Bool {
        let upright = #"\\(?:mathrm|text|textrm|operatorname)\s*\{([^{}]*)\}"#
        let spacing = #"\\[,;:! ]|~"#
        let unwrapped = latex.replacingOccurrences(of: upright, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: spacing, with: " ", options: .regularExpression)
        let italic = latex.replacingOccurrences(of: upright, with: " ", options: .regularExpression)
            .replacingOccurrences(of: spacing, with: " ", options: .regularExpression)
        let prose = CharacterSet.letters.union(.decimalDigits).union(.whitespaces).union(CharacterSet(charactersIn: ".,:;!?'\"()%-/"))
        return !unwrapped.trimmingCharacters(in: .whitespaces).isEmpty && unwrapped.unicodeScalars.allSatisfy { prose.contains($0) }
            && !italic.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// The part of `line` (the text read with the whole line in view, by Vision or the L2 pack beside it) that a piece of
    /// it read again alone (`read`) matches, from the character offset `start`, and where that part ends. Its own
    /// characters and spaces are kept: read alone, without the rest of the line, a piece reads no better ("由此" came
    /// back as "田此"), and Vision drops a space after a comma it starts on. Nil when nothing in the line is that close
    /// (an edit distance of a third of the piece's length at most, spaces and the width of punctuation aside, exact for
    /// one or two characters).
    static func aligned(_ read: String, in line: String, from start: Int) -> (text: String, start: Int, end: Int)? {
        let normal = { (character: Character) in Punctuation.halfWidth[character] ?? character }
        let piece = read.filter { !$0.isWhitespace }.map(normal)
        let characters = Array(line)
        let text = characters.indices.filter { $0 >= start && !characters[$0].isWhitespace }
        let (m, n) = (piece.count, text.count)
        guard m > 0, n > 0 else { return nil }
        // Edit distance with the match free to start and end anywhere in the line; `from` keeps where each match starts.
        var distance = Array(0...m).map { [Int](repeating: $0, count: n + 1) }
        var from = [[Int]](repeating: Array(0...n), count: m + 1)
        distance[0] = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            for j in 1...n {
                let substitute = distance[i - 1][j - 1] + (piece[i - 1] == normal(characters[text[j - 1]]) ? 0 : 1)
                let skipPiece = distance[i - 1][j] + 1, skipLine = distance[i][j - 1] + 1
                if substitute <= skipPiece, substitute <= skipLine {
                    (distance[i][j], from[i][j]) = (substitute, from[i - 1][j - 1])
                } else if skipPiece <= skipLine {
                    (distance[i][j], from[i][j]) = (skipPiece, from[i - 1][j])
                } else {
                    (distance[i][j], from[i][j]) = (skipLine, from[i][j - 1])
                }
            }
        }
        guard let end = (1...n).min(by: { distance[m][$0] < distance[m][$1] }), distance[m][end] <= m / 3, from[m][end] < end else { return nil }
        let first = text[from[m][end]], last = text[end - 1]
        return (String(characters[first...last]), first, last + 1)
    }

    /// The parts of a line joined: a space between text and a formula, but not inside brackets or before the
    /// punctuation that follows a word; between two pieces of text, one unless both sides are CJK. Punctuation a formula
    /// ended on (`wrapped`), before Chinese or Japanese, is theirs: "$c$，则有".
    static func joined(_ parts: [(text: String, isFormula: Bool)]) -> String {
        let fullWidth: [Character: Character] = [",": "，", ";": "；", ":": "：", ".": "。"]
        var out = ""
        var lastIsFormula = false
        for part in parts where !part.text.isEmpty {
            // The formula's box took in the comma the text beside it has too: the text's stands.
            if lastIsFormula, !part.isFormula, let first = part.text.first, enders.contains(first),
               let mark = out.last, enders.contains(mark), out.dropLast().last == "$" {
                out.removeLast()
            }
            if lastIsFormula, !part.isFormula, let first = part.text.first, Script.isCJK(first),
               let mark = out.last, let wide = fullWidth[mark], out.dropLast().last == "$" {
                out.removeLast()
                out += String(wide) + part.text
                lastIsFormula = false
                continue
            }
            if let last = out.last, let first = part.text.first {
                let opens = "([{（【「『“‘".contains(last)
                let closes = ",.;:!?)]}，。；：！？、）】」』”’%".contains(first)
                let bothCJK = !part.isFormula && !lastIsFormula && Script.isCJK(last) && Script.isCJK(first)
                if !opens, !closes, !bothCJK, !last.isWhitespace, !first.isWhitespace { out += " " }
            }
            out += part.text
            lastIsFormula = part.isFormula
        }
        return out
    }
}
