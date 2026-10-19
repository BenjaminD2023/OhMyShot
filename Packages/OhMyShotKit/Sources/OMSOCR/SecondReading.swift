import CoreGraphics
import Foundation

/// L2 read beside L1 (Docs/ocr.md › L2 beside L1): L1's lines, in L1's order, with L2's text in the lines that hold
/// Han or kana, and the Chinese and Japanese lines L1 missed.
///
/// Line for line on the benchmark and the real screenshots (`ocr-bench --pack`), L2 read 109 lines with Han or kana
/// better than L1 and 4 worse; on lines in Latin script alone it read 52 better and 43 worse, trading one kind of error
/// for another (`->` and `=>` read right, `|` read as `I` and `Oct` as `0ct`), so those keep L1's text. L2 reads no
/// Hangul, and its boxes leave out nothing L1's post-processing took away: L1 decides which lines there are (its
/// line numbers removed, its gaps filled) and their order, and L2 only rereads them. L1's confidence says nothing to
/// go by here: it comes in steps (0.3, 0.5, 1).
public enum SecondReading {
    /// Raised when these rules change, so text kept from an earlier merge is read again (`TextReaderPack.reading`).
    /// 1 kept Vision's Hangul over L2's Chinese.
    public static let revision = 2

    /// Whether a second reading can change `lines` (L1's): two or more of their characters are Han or kana.
    public static func wanted(_ lines: [OCRLine]) -> Bool {
        var count = 0
        for line in lines {
            count += line.text.count(where: isSquare)
            if count >= 2 { return true }
        }
        return false
    }

    /// `first` (L1's lines, in reading order) with `second`'s (L2's) text where L2 reads better, and the lines only L2
    /// found, in reading order.
    ///
    /// Each L2 line belongs to the L1 line that holds half its area or more, unless it also holds half of another L1
    /// line: L2 reads a name and the time beside it as one line where L1 reads two, and either reading would then show
    /// both. An L1 line with Han or kana and no Hangul takes the text of the L2 lines it holds, side by side, when they
    /// read at least four fifths as many characters (fewer, and L2 missed part of the line), written as L1 writes what
    /// both read alike (`dressed`); so does a line of Chinese L1 read as Hangul (`isMisreadAsHangul`), as L2 read it.
    /// Its box, direction, and wrapping stay L1's. An L2 line that no L1 line holds, and
    /// that no L1 line covers a quarter of, is added when it reads two Han or kana characters or more with a confidence
    /// of 0.9 or more: below that, L2's readings of icons ("凶" for a muted bell).
    public static func merged(_ first: [OCRLine], with second: [OCRLine]) -> [OCRLine] {
        var held = [[OCRLine]](repeating: [], count: first.count)
        var alone: [OCRLine] = []
        for line in second {
            let area = line.box.width * line.box.height
            guard area > 0 else { continue }
            let shares = first.map { shared($0.box, line.box) }
            let covered = first.indices.filter { shares[$0] >= first[$0].box.width * first[$0].box.height / 2 }
            if let best = shares.indices.max(by: { shares[$0] < shares[$1] }), shares[best] >= area / 2 {
                if covered.allSatisfy({ $0 == best }) { held[best].append(line) }
            } else if shares.allSatisfy({ $0 < area / 4 }) {
                alone.append(line)
            }
        }

        var lines = first
        for (index, line) in first.enumerated() where !held[index].isEmpty {
            let vertical = ReadingOrder.isVertical(line)
            let parts = held[index].sorted { vertical ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
            let text = joined(parts.map(\.text))
            let misread = isMisreadAsHangul(line.text, second: text, confidence: parts.map(\.confidence).min() ?? 0)
            guard takesSecond(line.text) || misread, characters(in: text) * 5 >= characters(in: line.text) * 4 else { continue }
            // A misread line's characters are not the same text, so nothing of its form goes over.
            lines[index].text = misread ? text : dressed(text, like: line.text)
            lines[index].confidence = parts.map(\.confidence).min() ?? line.confidence
        }

        let found = alone.filter { $0.confidence >= 0.9 && $0.text.count(where: isSquare) >= 2 }
        return found.isEmpty ? lines : ReadingOrder.sorted(lines + found)
    }

    /// Whether a line L1 read as `text` takes L2's reading: it holds Han or kana and no Hangul.
    static func takesSecond(_ text: String) -> Bool {
        text.contains(where: isSquare) && !text.contains(where: Script.isHangul)
    }

    /// Whether L1 read Chinese or Japanese as Hangul: its line holds Hangul where L2 read two Han or kana characters or
    /// more, none of them Hangul, with a confidence of 0.9 or more. L1 reads the regions its first pass left empty again
    /// with the Korean model, which makes Hangul and stray marks of small gray Chinese type. In a tall chat capture L2
    /// read Chinese in 22 of 28 such lines; on the benchmark's Korean it read nothing at all.
    static func isMisreadAsHangul(_ text: String, second: String, confidence: Float) -> Bool {
        text.contains(where: Script.isHangul) && !second.contains(where: Script.isHangul) && confidence >= 0.9
            && second.count(where: isSquare) >= 2
    }

    /// Han or kana: what L2 reads better than L1.
    private static func isSquare(_ character: Character) -> Bool {
        Script.isCJK(character) && !Script.isHangul(character)
    }

    /// The area two boxes share.
    private static func shared(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let common = a.intersection(b)
        return common.isNull ? 0 : common.width * common.height
    }

    private static func characters(in text: String) -> Int {
        text.count { !$0.isWhitespace }
    }

    /// Pieces of one line, side by side: run together beside Han or kana, a space between other words.
    static func joined(_ texts: [String]) -> String {
        texts.reduce("") { text, next in
            guard let last = text.last, let first = next.first else { return text + next }
            return text + (Script.isCJK(last) || Script.isCJK(first) ? "" : " ") + next
        }
    }

    /// `text` (L2's reading of a line) written as `reference` (L1's) writes what both read alike.
    ///
    /// L2 reads the characters better, Vision their form: L2 writes "(", ")", and "?" half-width at times in Chinese
    /// ("多余的空格?") and digits full-width in Japanese ("午後２時"), where Vision reads the width the picture shows; and L2
    /// leaves out most spaces beside Han ("降到了10 ms以内"), which L1 measures in the ink. So the two readings are
    /// aligned character by character (spaces aside, widths folded); a character both read alike takes L1's form. Two
    /// characters both read side by side are spaced as L1 spaces them where Han meets a Latin letter or a digit and L1
    /// measured that (`Spacing.restored`: "打开App Store" has none, though L2 puts one), and where either reading
    /// spaces them elsewhere ("- 已全额" has a space L1 lost). Where L2 reads a mark twice and L1 once ("px: ："), the
    /// extra one goes. L2's "..." is L1's "…" when L1 reads that.
    static func dressed(_ text: String, like reference: String) -> String {
        let (a, aSpaced) = spaced(reference)
        let ellipsis = a.first { $0 == "…" || $0 == "⋯" }
        let (b, bSpaced) = spaced(ellipsis.map { text.replacingOccurrences(of: "...", with: String($0)) } ?? text)
        guard !a.isEmpty, !b.isEmpty else { return text }
        let fa = a.map(folded), fb = b.map(folded)

        // Edit distance with its path: `pair[j]` is the character of `a` that `b[j]` stands for, nil where L2 read one
        // more.
        var cost = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { cost[i][0] = i }
        for j in 0...b.count { cost[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1, cost[i - 1][j - 1] + (fa[i - 1] == fb[j - 1] ? 0 : 1))
            }
        }
        var pair = [Int?](repeating: nil, count: b.count)
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if cost[i][j] == cost[i - 1][j - 1] + (fa[i - 1] == fb[j - 1] ? 0 : 1) {
                pair[j - 1] = i - 1
                i -= 1
                j -= 1
            } else if cost[i][j] == cost[i][j - 1] + 1 {
                j -= 1
            } else {
                i -= 1
            }
        }

        // An icon before Chinese or Japanese text, which the two read as different symbols ("$ 开发调优", "<>开发调优"):
        // neither reading of it is text.
        var icon = 0
        while icon < b.count, b[icon].isSymbol, pair[icon].map({ fa[$0] != fb[icon] }) ?? true { icon += 1 }
        if icon == 0 || icon == b.count || !isSquare(b[icon]) || !(pair[icon].map { $0 > 0 && a[..<$0].allSatisfy(\.isSymbol) } ?? false) {
            icon = 0
        }

        let measured = Spacing.mayNeedSpaces(reference[...])
        var result = ""
        var last: Int?
        // The space before a mark that was left out, which goes before the next character instead of its own.
        var carried: Bool?
        for j in b.indices where j >= icon {
            // A mark L2 read once more beside itself.
            if pair[j] == nil, b[j].isPunctuation, (j > 0 && fb[j - 1] == fb[j]) || (j + 1 < b.count && fb[j + 1] == fb[j]) {
                carried = carried ?? bSpaced[j]
                continue
            }
            if let previous = last {
                var space = carried ?? bSpaced[j]
                if let p = pair[previous], let q = pair[j], q == p + 1 {
                    space = measured && Spacing.isBoundary(a[p], a[q]) ? aSpaced[q] : space || aSpaced[q]
                }
                if space { result.append(" ") }
            }
            carried = nil
            result.append(pair[j].map { fa[$0] == fb[j] } == true ? a[pair[j]!] : b[j])
            last = j
        }
        return result
    }

    /// The characters of `text` other than spaces, each with whether a space comes before it.
    private static func spaced(_ text: String) -> (characters: [Character], spacedBefore: [Bool]) {
        var characters: [Character] = [], spaced: [Bool] = []
        var space = false
        for character in text {
            if character.isWhitespace {
                space = !characters.isEmpty
                continue
            }
            characters.append(character)
            spaced.append(space)
            space = false
        }
        return (characters, spaced)
    }

    /// A character with its width folded: full-width forms and the punctuation Chinese writes full-width as their
    /// half-width twins. Marks that differ in shape ("「" and "“") stay apart.
    static func folded(_ character: Character) -> Character {
        if character == "⋯" { return "…" }
        if let half = Punctuation.halfWidth[character] { return half }
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
           (0xFF01...0xFF5E).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xFEE0) {
            return Character(ascii)
        }
        return character
    }
}

extension TextAnalysis {
    /// The analysis with L2's reading of the same picture put beside L1's (`SecondReading`): its lines, its text
    /// assembled as `assembly` says, and its tables' cells taken from the lines again.
    public func withSecondReading(_ second: [OCRLine], assembly: TextAssembler.Options) -> TextAnalysis {
        let lines = SecondReading.merged(result.lines, with: second)
        var analysis = self
        analysis.result.lines = lines
        analysis.result.text = TextAssembler.assemble(lines, options: assembly)
        analysis.tables = tables.map { $0.filled(from: lines) }
        return analysis
    }
}

/// L1, with L2 reading beside it (`SecondReading`) when the picture holds Chinese or Japanese: the text reader's
/// reading when a PP-OCR model pack is installed. When L2 fails, L1's reading stands.
public struct PairedReading: OCREngine {
    public let name: String
    public let first: VisionPipeline
    public let second: PPOCRReader

    public init(name: String = "l1+l2", first: VisionPipeline, second: PPOCRReader) {
        self.name = name
        self.first = first
        self.second = second
    }

    @concurrent
    public func recognize(_ image: CGImage) async throws -> OCRResult {
        try await recognize(width: image.width, height: image.height, first: { try await first.recognize(image) }, second: { try await second.recognize(image) })
    }

    /// The picture in the file at `url`, each reading taking it from the file (`VisionPipeline.recognize(fileAt:)`,
    /// `PPOCRReader.recognize(fileAt:)`) when it is a tall PNG read a band at a time; otherwise decoded once for both.
    @concurrent
    public func recognize(fileAt url: URL) async throws -> OCRResult {
        guard let bands = PictureText.Bands(fileAt: url) else { return try await recognize(PictureText.image(at: url)) }
        return try await recognize(
            width: bands.width, height: bands.height,
            first: { try await first.recognize(fileAt: url) }, second: { try await second.recognize(fileAt: url) }
        )
    }

    private func recognize(
        width: Int, height: Int, first: () async throws -> OCRResult, second: () async throws -> OCRResult
    ) async throws -> OCRResult {
        let started = ContinuousClock.now
        let result = try await first()
        guard SecondReading.wanted(result.lines), PPOCRReader.reads(width: width, height: height) else { return result }
        let read: [OCRLine]
        do {
            read = try await second().lines
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return result
        }
        let lines = SecondReading.merged(result.lines, with: read)
        let text = TextAssembler.assemble(lines, options: self.first.options.assembly)
        return OCRResult(lines: lines, tables: result.tables, text: text, duration: ContinuousClock.now - started)
    }
}
