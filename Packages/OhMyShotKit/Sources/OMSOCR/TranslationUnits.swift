import CoreGraphics
import Foundation

/// A piece of recognized text translated as one: a paragraph whose lines wrap into each other, or a line
/// on its own (a label, a title, a list item). Translating a paragraph whole reads better than line by
/// line, and the translation is laid out across the paragraph's box.
public struct TranslationUnit: Sendable, Equatable {
    /// Why a unit is left as read.
    public enum Skip: Sendable, Equatable {
        /// Figures, times, symbols, and figures with an abbreviation ("5 GB", "iOS 26"): nothing to
        /// translate, and a model asked anyway spells the abbreviation out ("5千兆字节").
        case figures
        /// A link or an email address alone.
        case link
        /// Code, a listing or a line of it: code is not translated.
        case code
        /// Vertical text, which the overlay cannot lay out.
        case vertical
    }

    /// The lines it is made of, as indices into the lines it was grouped from, in reading order.
    public var lines: [Int]
    public var text: String
    /// The union of its lines' boxes, in image pixels with a top-left origin.
    public var box: CGRect
    public var skip: Skip?

    public init(lines: [Int], text: String, box: CGRect, skip: Skip? = nil) {
        self.lines = lines
        self.text = text
        self.box = box
        self.skip = skip
    }
}

public enum TranslationUnits {
    /// Groups `lines` (in reading order) into units: lines that wrap into the next join it, as when
    /// assembling text with joined lines; every other line stands alone.
    public static func group(_ lines: [OCRLine]) -> [TranslationUnit] {
        guard !lines.isEmpty else { return [] }
        let isCode = TextAssembler.isCodeListing(lines)
        let technical = isTechnical(lines.map(\.text))
        let wraps = isCode ? lines.map { _ in false } : zip(lines, TextAssembler.inferredWraps(lines)).map { line, guess in
            line.wrapsToNextLine ?? guess
        }
        var units: [TranslationUnit] = []
        var current: [Int] = []
        for index in lines.indices {
            current.append(index)
            guard index == lines.count - 1 || !wraps[index] || isVertical(lines[index]) || isVertical(lines[index + 1]) else { continue }
            let members = current.map { lines[$0] }
            let texts = members.map { TextAssembler.isCodeLike($0.text) ? TextAssembler.asCode($0.text) : TextAssembler.asProse($0.text) }
            let text = TextAssembler.joinWrapped(texts, wraps: members.dropLast().map { _ in true } + [false])
            let box = members.dropFirst().reduce(members[0].box) { $0.union($1.box) }
            units.append(TranslationUnit(lines: current, text: text, box: box, skip: skip(text, members: members, isCode: isCode, technical: technical)))
            current = []
        }
        return units
    }

    private static func skip(_ text: String, members: [OCRLine], isCode: Bool, technical: Bool) -> TranslationUnit.Skip? {
        // A line of code among prose ("let x = 1" in a tutorial) is left as it is too.
        if isCode || members.count == 1 && TextAssembler.isCodeLike(members[0].text) { return .code }
        if members.contains(where: isVertical) { return .vertical }
        if isFigures(text) { return .figures }
        if isLinkAlone(text) { return .link }
        // Names of files, commands, and handles.
        if isCommandLike(text, technical: technical) { return .code }
        return nil
    }

    // MARK: Code outside code listings

    /// A token of code or the command line rather than a word: a file name, a path, a flag, a handle, an
    /// identifier ("package.json", "~/src", "--force", ".git", "@name", "camelCase", "ttys000").
    static func isIdentifier(_ token: Substring) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>,;:'\"“”‘’。，：；！？!?"))
        guard trimmed.count > 1, trimmed.allSatisfy(\.isASCII) else { return false }
        if let first = trimmed.first, "-./~$@#".contains(first), trimmed.contains(where: \.isLetter) { return true }
        if trimmed.dropFirst().dropLast().contains(where: { "._/\\@#~=|$%^&*<>".contains($0) }) { return true }
        if trimmed.contains(where: \.isLetter), trimmed.contains(where: \.isNumber) { return true }
        let characters = Array(trimmed)
        return characters.indices.dropFirst().contains { characters[$0].isUppercase && characters[$0 - 1].isLowercase }
    }

    /// A page of the command line or a code editor: a third of its words or more are identifiers or
    /// figures. There, a word on its own is a file name or a command, not a label.
    static func isTechnical(_ texts: [String]) -> Bool {
        let tokens = texts.filter { !Script.containsCJK($0) }.flatMap { $0.split(whereSeparator: \.isWhitespace) }
        guard tokens.count >= 20 else { return false }
        let technical = tokens.filter { isIdentifier($0) || !$0.contains(where: \.isLetter) }.count
        return Double(technical) >= Double(tokens.count) / 3
    }

    /// Names and commands rather than words: a lone identifier; more identifiers than words ("macOS
    /// 27.2 (26B5091g)"); and on a technical page, any lone word, or a line that is not mostly words
    /// ("drwxr-xr-x  -  me  6 Oct 23:53  .claude"), figures counted with the names. A label before a
    /// number ("Phone: +1 (555) 010-0199") and a sentence, such as an error message, are translated.
    static func isCommandLike(_ text: String, technical: Bool) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return false }
        // Chinese and Japanese are written without spaces: a line of them is one token, not a name.
        let hasCJK = Script.containsCJK(text)
        if tokens.count == 1 { return !hasCJK && (technical || isIdentifier(tokens[0])) }
        let identifiers = tokens.filter { isIdentifier($0) }.count
        let figures = tokens.filter { !$0.contains(where: \.isLetter) }.count
        if (technical ? identifiers + figures : identifiers) * 2 > tokens.count { return true }
        guard technical, !hasCJK else { return false }
        let words = tokens.filter { token in
            let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
            return !trimmed.isEmpty && trimmed.allSatisfy(\.isLetter)
        }.count
        return tokens.count < 4 || Double(words) < Double(tokens.count) * 0.6
    }

    /// No letters, or figures whose words are all abbreviations: three letters at most, or four capitals.
    static func isFigures(_ text: String) -> Bool {
        guard text.contains(where: \.isLetter) else { return true }
        guard text.contains(where: \.isNumber) else { return false }
        let words = text.split { !$0.isLetter }
        return words.allSatisfy { $0.count <= 3 || ($0.count == 4 && $0.allSatisfy(\.isUppercase)) }
    }

    private static func isVertical(_ line: OCRLine) -> Bool {
        line.direction == .topToBottom || line.box.height > line.box.width * 1.5
    }

    private static func isLinkAlone(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return detector.matches(in: trimmed, range: range).contains { $0.range.length >= range.length - 1 }
    }
}
