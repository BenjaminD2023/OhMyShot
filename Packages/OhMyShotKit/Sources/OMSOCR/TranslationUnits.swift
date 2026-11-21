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
    /// Whether it holds a formula (`$…$`), whose LaTeX the translation keeps as it is.
    public var hasMath: Bool
    /// A list item whose bullet was read as text: taken off `text`, so the bullet is not translated, and drawn again in
    /// front of the translation (`Bullets.drawnMark`).
    public var bulleted: Bool

    public init(lines: [Int], text: String, box: CGRect, skip: Skip? = nil, hasMath: Bool = false, bulleted: Bool = false) {
        self.lines = lines
        self.text = text
        self.box = box
        self.skip = skip
        self.hasMath = hasMath
        self.bulleted = bulleted
    }
}

public enum TranslationUnits {
    /// Groups `lines` (in reading order) into units: lines that wrap into the next join it, as when
    /// assembling text with joined lines; every other line stands alone. A list item starts a unit of its own
    /// (`Bullets`), its bullet seen in `image`, the picture the lines were read from, when given.
    public static func group(_ lines: [OCRLine], image: CGImage? = nil) -> [TranslationUnit] {
        guard !lines.isEmpty else { return [] }
        let technical = isTechnical(lines.map(\.text))
        let items = image.flatMap { image in Pixels.reading(image) { Bullets.items(lines, in: $0) } } ?? Bullets.items(lines)
        let carries = zip(lines.indices, TextAssembler.inferredWraps(lines, items: items)).map { index, guess in
            // Whatever an engine says, a list item never carries on the line before it.
            index + 1 < lines.count && items[index + 1] ? false : lines[index].wrapsToNextLine ?? guess
        }
        let inCode = codeLines(lines, carries: carries)
        // Code keeps its lines.
        let wraps = lines.indices.map { carries[$0] && !inCode[$0] && !($0 + 1 < lines.count && inCode[$0 + 1]) }
        var units: [TranslationUnit] = []
        var current: [Int] = []
        for index in lines.indices {
            current.append(index)
            guard index == lines.count - 1 || !wraps[index] || isVertical(lines[index]) || isVertical(lines[index + 1])
                || lines[index].math == .display || lines[index + 1].math == .display || lines[index].isTableRow || lines[index + 1].isTableRow
            else { continue }
            let members = current.map { lines[$0] }
            var texts = members.map { line in
                line.math != nil ? TextAssembler.withMath(line.text) : TextAssembler.isCodeLike(line.text) ? TextAssembler.asCode(line.text) : TextAssembler.asProse(line.text)
            }
            // A bullet read as text is not translated: it is drawn again in front of the translation.
            let bulleted = !inCode[current[0]] && members[0].math == nil && Bullets.strippingMark(from: texts[0]) != nil
            if bulleted, let rest = Bullets.strippingMark(from: texts[0]) { texts[0] = rest }
            let text = TextAssembler.joinWrapped(texts, wraps: members.dropLast().map { _ in true } + [false])
            let box = members.dropFirst().reduce(members[0].box) { $0.union($1.box) }
            // A formula's LaTeX is neither code nor figures: what is around it decides.
            let hasMath = members.contains { $0.math != nil }
            let prose = hasMath ? text.replacing(TextAssembler.mathSpan, with: " ") : text
            units.append(TranslationUnit(
                lines: current, text: text, box: box, skip: skip(prose, members: members, isCode: inCode[current[0]], technical: technical),
                hasMath: hasMath,
                bulleted: bulleted
            ))
            current = []
        }
        return units
    }

    private static func skip(_ text: String, members: [OCRLine], isCode: Bool, technical: Bool) -> TranslationUnit.Skip? {
        // A formula set apart is left as it is on the image, as code is; so is a table's row (TableMerge), whose box spans
        // the table: redrawn, one run of text would cover its cells.
        if members.count == 1, members[0].math == .display || members[0].isTableRow { return .code }
        // A line of code among prose ("let x = 1" in a tutorial) is left as it is too.
        if isCode || members.count == 1 && TextAssembler.isCodeLike(TextAssembler.withoutMath(members[0])) { return .code }
        if members.contains(where: isVertical) { return .vertical }
        if isFigures(text) { return .figures }
        if isLinkAlone(text) { return .link }
        // Names of files, commands, and handles.
        if isCommandLike(text, technical: technical) { return .code }
        return nil
    }

    // MARK: Sentences in code listings

    /// Which of `lines` are code. None on a page that is no listing: there a line of code is told on its own (`skip`).
    /// On a listing (`TextAssembler.isCodeListing`, two lines in five that read as code), every line but its sentences and
    /// the lines they run on into (`carries`): a tutorial's two lines of `let` no longer leave the sentences explaining
    /// them untranslated, while what only the listing makes code (`break`, a string, a `#` comment) stays with it.
    static func codeLines(_ lines: [OCRLine], carries: [Bool]) -> [Bool] {
        guard TextAssembler.isCodeListing(lines) else { return lines.map { _ in false } }
        let texts = lines.map(TextAssembler.withoutMath)
        var isCode = texts.map { TextAssembler.isCodeLike($0) || !isSentence($0) }
        // The end of a sentence, on the line it wraps onto, is no sentence alone ("is missing.").
        for index in lines.indices.dropFirst() where !isCode[index - 1] && carries[index - 1] && !TextAssembler.isCodeLike(texts[index]) {
            isCode[index] = false
        }
        return isCode
    }

    /// A sentence rather than a line of code: it starts on a word (no quote before it), none of its tokens is an operator
    /// ("=", "->"), and it holds five characters of Chinese or Japanese, or four words that are three in four of its
    /// tokens. A statement can be all that: `echo Welcome to your home directory`, `raise ValueError("This option is
    /// not available")`. So in a script that has capitals:
    ///
    /// - It starts as a sentence does, on a capital ("The") or on a name with one inside ("macOS", "iPhone"), or it
    ///   ends as one does, on a period or a mark like it ("the cache is cleared when the app restarts."): a command
    ///   rarely ends so.
    /// - Its first word is no keyword in capitals ("SELECT") and no cmdlet ("Write-Host", `isCmdlet`).
    /// - It calls nothing ("name(").
    static func isSentence(_ text: String) -> Bool {
        let marks = CharacterSet(charactersIn: ".,:;!?…'\"“”‘’，。：；！？、")
        let isWord = { (token: Substring) in
            let word = token.trimmingCharacters(in: marks)
            return !word.isEmpty && word.allSatisfy { $0.isLetter || "'’-".contains($0) }
        }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first, let initial = first.first, initial.isLetter, isWord(first),
              tokens.allSatisfy({ token in token.contains { $0.isLetter || $0.isNumber } || token.allSatisfy { "-–—&".contains($0) } })
        else { return false }
        if initial.isCased {
            let word = first.trimmingCharacters(in: marks)
            let startsAsOne = initial.isUppercase || word.dropFirst().contains(where: \.isUppercase)
            let endsAsOne = tokens.last?.last.map(sentenceEnds.contains) ?? false
            guard startsAsOne || endsAsOne, word.count == 1 || word.contains(where: \.isLowercase), !isCmdlet(word, in: tokens),
                  text.range(of: #"\w\("#, options: .regularExpression) == nil else { return false }
        }
        if text.count(where: Script.isCJK) >= 5 { return true }
        let words = tokens.count(where: isWord)
        return words >= 4 && words * 4 >= tokens.count * 3
    }

    /// PowerShell's approved verbs (what `Get-Verb` lists), and the four its own cmdlets start on besides (`ForEach-Object`,
    /// `Sort-Object`, `Tee-Object`, `Where-Object`): a cmdlet is named verb-noun ("Write-Host", "Format-Table").
    private static let cmdletVerbs: Set<Substring> = [
        "Add", "Approve", "Assert", "Backup", "Block", "Build", "Checkpoint", "Clear", "Close", "Compare", "Complete", "Compress", "Confirm",
        "Connect", "Convert", "ConvertFrom", "ConvertTo", "Copy", "Debug", "Deny", "Deploy", "Disable", "Disconnect", "Dismount", "Edit", "Enable",
        "Enter", "Exit", "Expand", "Export", "Find", "ForEach", "Format", "Get", "Grant", "Group", "Hide", "Import", "Initialize", "Install",
        "Invoke", "Join", "Limit", "Lock", "Measure", "Merge", "Mount", "Move", "New", "Open", "Optimize", "Out", "Ping", "Pop", "Protect",
        "Publish", "Push", "Read", "Receive", "Redo", "Register", "Remove", "Rename", "Repair", "Request", "Reset", "Resize", "Resolve", "Restart",
        "Restore", "Resume", "Revoke", "Save", "Search", "Select", "Send", "Set", "Show", "Skip", "Sort", "Split", "Start", "Step", "Stop",
        "Submit", "Suspend", "Switch", "Sync", "Tee", "Test", "Trace", "Unblock", "Undo", "Uninstall", "Unlock", "Unprotect", "Unpublish",
        "Unregister", "Update", "Use", "Wait", "Watch", "Where", "Write",
    ]

    /// What a sentence ends on.
    private static let sentenceEnds = ".!?。！？"

    /// Whether the first word of a line is a cmdlet: a verb, a hyphen, and one word that starts on a capital
    /// ("Step-By-Step" is none). That is not enough, a name is written so too ("Wi-Fi is required to pair the
    /// device."): the line is a command besides. It holds a parameter ("-Path"), a quote, or a variable ("$name"); or
    /// the verb is one of PowerShell's and the line ends as no sentence does. Those verbs are English words, and
    /// "Open-Source libraries are listed in the appendix." is prose, where `Format-Table Name, Length, Mode` ends on
    /// no period.
    static func isCmdlet(_ word: String, in tokens: [Substring]) -> Bool {
        guard word.range(of: #"^[^-]+-\p{Lu}[^-]*$"#, options: .regularExpression) != nil else { return false }
        let holdsArguments = tokens.dropFirst().contains { token in
            guard let first = token.first else { return false }
            return "\"'".contains(first) || first == "-" && token.dropFirst().first?.isLetter == true
                || token.range(of: #"\$[\p{L}_{(]"#, options: .regularExpression) != nil
        }
        let endsAsSentence = tokens.last?.last.map(sentenceEnds.contains) ?? false
        return holdsArguments || cmdletVerbs.contains(word.prefix { $0 != "-" }) && !endsAsSentence
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
