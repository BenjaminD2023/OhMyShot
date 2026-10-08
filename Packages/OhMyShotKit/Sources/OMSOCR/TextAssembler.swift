import CoreGraphics
import Foundation

/// Turns recognized lines into the text a person would have typed: code with ASCII punctuation and its
/// indentation, punctuation in the width its language uses, no stray spaces inside Chinese or Japanese.
public enum TextAssembler {
    public struct Options: Sendable {
        /// Joins lines that wrap inside a paragraph, instead of keeping every line break.
        public var joinsWrappedLines: Bool

        public init(joinsWrappedLines: Bool = false) {
            self.joinsWrappedLines = joinsWrappedLines
        }
    }

    /// Assembled text, with where each line ended up in it.
    public struct Assembly: Sendable, Equatable {
        public var text: String
        /// Each line's range in `text`, in UTF-16 units, in the order the lines were given.
        public var lineRanges: [NSRange]
        /// The lines read as a code listing: kept line for line, never joined.
        public var isCode: Bool

        public init(text: String = "", lineRanges: [NSRange] = [], isCode: Bool = false) {
            self.text = text
            self.lineRanges = lineRanges
            self.isCode = isCode
        }
    }

    public static func assemble(_ lines: [OCRLine], options: Options = .init()) -> String {
        assembly(lines, options: options).text
    }

    /// The text, and each line's range in it, worked out while the text is built: the post-processing
    /// removes characters (spaces between CJK, a hyphen at a line break), so ranges cannot be found
    /// afterwards.
    public static func assembly(_ lines: [OCRLine], options: Options = .init()) -> Assembly {
        guard !lines.isEmpty else { return Assembly() }
        let isCode = isCodeListing(lines)
        let indents = isCode ? indentation(lines) : Array(repeating: 0, count: lines.count)
        let texts = zip(lines, indents).map { line, indent in
            let text = isCode || isCodeLike(line.text) ? asCode(line.text) : asProse(line.text)
            return String(repeating: " ", count: indent) + text
        }
        let wraps: [Bool] = if options.joinsWrappedLines, !isCode {
            zip(lines, inferredWraps(lines)).map { line, guess in line.wrapsToNextLine ?? guess }
        } else {
            texts.map { _ in false }
        }
        var assembly = build(texts, wraps: wraps)
        assembly.isCode = isCode
        return assembly
    }

    // MARK: Code

    /// A screenshot of code: most of its lines read as code.
    static func isCodeListing(_ lines: [OCRLine]) -> Bool {
        let codeLines = lines.filter { isCodeLike($0.text) }.count
        return lines.count >= 2 && Double(codeLines) >= Double(lines.count) * 0.4
    }

    static func isCodeLike(_ text: String) -> Bool {
        let trimmed = String(text.trimmingCharacters(in: .whitespaces).map { Punctuation.halfWidth[$0] ?? $0 })
        guard !trimmed.isEmpty else { return false }
        // A lone bracket is a line of code; comment lines belong to their code, even in Chinese.
        if trimmed.count <= 2, trimmed.allSatisfy({ "{}[]()".contains($0) }) { return true }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") { return true }
        let ascii = Double(trimmed.filter(\.isASCII).count) / Double(trimmed.count)
        guard ascii > 0.8 else { return false }
        var score = ["{", "}", "[", "]", ";", "=", "->", "=>", "::", "()", "&&", "||", "</", "/>"].filter { trimmed.contains($0) }.count
        let patterns: [(String, Int)] = [
            (#"^(func|let|var|const|if|else|for|while|return|guard|def|class|struct|enum|import|from|public|private|static|switch|case|try|catch|fn|pub|package|#include)\b"#, 2),
            (#"\w\("#, 1),
            // key: value, as in YAML, when the key looks like code (lowercase, or with _ . -) or stands
            // alone; a capitalized label with a value ("Phone: +1 …") is as likely prose and counts half,
            // so a contact card is not a code listing, while "Type: AWS::S3::Bucket" still is.
            (#"^([a-z_][\w.-]*|[A-Za-z_]\w*[_.-][\w.-]*):(\s|$)"#, 2),
            (#"^[A-Za-z_][\w.-]*:$"#, 2),
            (#"^[A-Z]\w*:\s"#, 1),
            (#"^-\s+[A-Za-z_][\w.-]*:"#, 2), // - key: value
        ]
        for (pattern, weight) in patterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
            score += weight
        }
        return score >= 2
    }

    /// Code punctuation back to ASCII, except next to CJK, as in a Chinese comment.
    static func asCode(_ text: String) -> String {
        let characters = Array(text)
        return String(characters.indices.map { index -> Character in
            let character = characters[index]
            guard let ascii = Punctuation.halfWidth[character] else { return character }
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if previous.map(Script.isCJK) == true || next.map(Script.isCJK) == true { return character }
            return ascii
        })
    }

    /// Leading spaces for each line of a code listing, rebuilt from where each line starts and the width
    /// of a character, then snapped to steps of 4 or 2 when every line allows it.
    static func indentation(_ lines: [OCRLine]) -> [Int] {
        let widths = lines
            .filter { !Script.containsCJK($0.text) && $0.text.count >= 4 }
            .map { $0.box.width / CGFloat($0.text.count) }
            .sorted()
        guard !widths.isEmpty else { return Array(repeating: 0, count: lines.count) }
        let characterWidth = widths[widths.count / 2]
        let left = lines.map(\.box.minX).min() ?? 0
        let raw = lines.map { max(0, Int((($0.box.minX - left) / characterWidth).rounded())) }
        for step in [4, 2] where raw.allSatisfy({ abs($0 - Int((Double($0) / Double(step)).rounded()) * step) <= 1 }) {
            return raw.map { Int((Double($0) / Double(step)).rounded()) * step }
        }
        return raw
    }

    // MARK: Prose

    /// Punctuation in the width its language uses, and no spaces between Chinese or Japanese characters.
    ///
    /// A line that is mostly Latin (each CJK character counted as two letters, about a word) is written
    /// with half-width punctuation, except between two CJK characters: "Last file: 设计稿.png". In a
    /// mostly CJK line, half-width marks between two CJK characters become full-width, and full-width
    /// ones stay. "。" is never changed in a line with CJK: unlike a colon or a bracket, it looks nothing
    /// like its half-width twin, so Vision reports what the image shows. Korean keeps its spaces: it
    /// separates words with them.
    static func asProse(_ text: String) -> String {
        var characters = Array(text)
        let hasCJK = characters.contains(where: Script.isCJK)
        let mostlyLatin = characters.filter(Script.isLatinOrDigit).count > characters.filter(Script.isCJK).count * 2
        for index in characters.indices {
            let character = characters[index]
            let previous = neighbor(of: index, in: characters, step: -1)
            let next = neighbor(of: index, in: characters, step: 1)
            let betweenCJK = previous.map(isSquare) == true && next.map(isSquare) == true
            if mostlyLatin {
                if let half = Punctuation.halfWidth[character], !betweenCJK, !(character == "。" && hasCJK) {
                    characters[index] = half
                }
            } else if let full = Punctuation.fullWidth[character], betweenCJK {
                characters[index] = full
            }
        }
        var result: [Character] = []
        for (index, character) in characters.enumerated() {
            if character == " ", let last = result.last, isSquare(last), index + 1 < characters.count, isSquare(characters[index + 1]) {
                continue
            }
            result.append(character)
        }
        return String(result)
    }

    /// The nearest letter, digit, or CJK character before or after `index`, skipping spaces and other
    /// punctuation.
    private static func neighbor(of index: Int, in characters: [Character], step: Int) -> Character? {
        var cursor = index + step
        while characters.indices.contains(cursor) {
            let character = characters[cursor]
            if character.isLetter || character.isNumber { return character }
            cursor += step
        }
        return nil
    }

    /// Han or kana: the scripts written without spaces.
    private static func isSquare(_ character: Character) -> Bool {
        Script.isCJK(character) && !Script.isHangul(character)
    }

    // MARK: Paragraphs

    /// Whether each line runs on into the next, judged from the layout, for engines that do not say
    /// (Vision's line recognizer never does). A line wraps when it reaches across nearly its whole
    /// paragraph, does not end a sentence, and the next line starts at the same left edge without extra
    /// space between them; an indented next line starts a new paragraph.
    static func inferredWraps(_ lines: [OCRLine]) -> [Bool] {
        guard lines.count > 1 else { return lines.map { _ in false } }
        let heights = lines.map(\.box.height).sorted()
        let lineHeight = heights[heights.count / 2]
        let enders: Set<Character> = ["。", "！", "？", ".", "!", "?", "：", ":", "；", ";", "…"]
        let closers: Set<Character> = ["”", "」", "』", "\"", "'", ")", "）"]
        return lines.indices.map { index in
            guard index + 1 < lines.count else { return false }
            let line = lines[index]
            let next = lines[index + 1]
            let sameLeft = abs(next.box.minX - line.box.minX) < lineHeight * 0.8
            let gap = next.box.minY - line.box.maxY
            guard sameLeft, gap >= -lineHeight * 0.3, gap < lineHeight * 0.9 else { return false }
            // The paragraph's right edge: the widest of the neighboring lines that share this left edge.
            let neighbors = lines.indices
                .filter { abs($0 - index) <= 3 && abs(lines[$0].box.minX - line.box.minX) < lineHeight * 0.8 }
            let rightEdge = neighbors.map { lines[$0].box.maxX }.max() ?? line.box.maxX
            let width = rightEdge - line.box.minX
            guard width > 0, line.box.maxX - line.box.minX >= width * 0.85 else { return false }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            var last = trimmed.last
            if let character = last, closers.contains(character) { last = trimmed.dropLast().last }
            return !(last.map(enders.contains) ?? true)
        }
    }

    /// Joins each line that wraps onto the next: nothing between CJK, a space between words, and a word
    /// broken with a hyphen put back together.
    static func joinWrapped(_ texts: [String], wraps: [Bool]) -> String {
        build(texts, wraps: wraps).text
    }

    private static func build(_ texts: [String], wraps: [Bool]) -> Assembly {
        let output = NSMutableString()
        var ranges: [NSRange] = []
        for (index, text) in texts.enumerated() {
            ranges.append(NSRange(location: output.length, length: (text as NSString).length))
            output.append(text)
            guard index + 1 < texts.count else { break }
            guard wraps[index] else {
                output.append("\n")
                continue
            }
            let next = texts[index + 1]
            if output.hasSuffix("-"), let first = next.first, first.isLowercase {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
                ranges[index].length = max(0, ranges[index].length - 1)
            } else if let last = (output as String).last, let first = next.first, !(Script.isCJK(last) || Script.isCJK(first)) {
                output.append(" ")
            }
        }
        return Assembly(text: output as String, lineRanges: ranges)
    }
}
