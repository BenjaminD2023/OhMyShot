import Foundation

/// The formula pack's tokens (`tokens.txt`) and the LaTeX of the ids the decoder gives, as transformers'
/// PPFormulaNetProcessor decodes and post-processes them (Tools/model-packs/formula_pack.py checks the two agree).
struct FormulaTokens: Sendable {
    /// Each token, in id order.
    let tokens: [String]
    /// Ids below this are special tokens.
    let special: Int

    init(tokens: [String], special: Int) {
        self.tokens = tokens
        self.special = special
    }

    static func load(from folder: URL, _ configuration: FormulaConfiguration) throws -> FormulaTokens {
        let text = try String(contentsOf: folder.appending(path: configuration.tokens.file), encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count > configuration.tokens.special, configuration.decoder.end < lines.count, configuration.decoder.start < lines.count else {
            throw FormulaError.badPack("\(configuration.tokens.file) holds \(lines.count) tokens")
        }
        return FormulaTokens(tokens: lines, special: configuration.tokens.special)
    }

    /// The text of `ids`: special tokens left out, the rest GPT-2's byte-level characters, each a byte of UTF-8 text
    /// (bytes that make no character become U+FFFD, as the tokenizer's decoder does).
    func text(of ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids where id >= special && id < tokens.count {
            for scalar in tokens[id].unicodeScalars {
                if let byte = Self.byteOfScalar[scalar] { bytes.append(byte) }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// GPT-2's byte-level alphabet, back to bytes: the printable bytes stand for themselves, and the others, in order,
    /// for the characters from U+0100 on.
    static let byteOfScalar: [Unicode.Scalar: UInt8] = {
        let printable = Array(33...126) + Array(161...172) + Array(174...255)
        var map: [Unicode.Scalar: UInt8] = [:]
        for byte in printable { map[Unicode.Scalar(UInt8(byte))] = UInt8(byte) }
        var next = 256
        for byte in 0...255 where !printable.contains(byte) {
            map[Unicode.Scalar(UInt32(next))!] = UInt8(byte)
            next += 1
        }
        return map
    }()

    /// Whether `ids` end in one run of at most `longest` tokens repeated `times` times over.
    static func repeats(_ ids: [Int], times: Int, longest: Int) -> Bool {
        for length in 1...max(longest, 1) {
            let span = length * times
            guard ids.count >= span else { break }
            let start = ids.count - span
            var same = true
            for i in length..<span where ids[start + i] != ids[start + i % length] {
                same = false
                break
            }
            if same { return true }
        }
        return false
    }
}

/// PPFormulaNetProcessor's `post_process_generation` (without ftfy, which changed nothing in the pack's check): Chinese
/// unwrapped from `\text{}`, quotes dropped, and the spaces between tokens taken out but for those a command needs.
enum FormulaText {
    static func tidy(_ text: String) -> String {
        var text = replacing(chineseText, in: text, with: "$1").replacingOccurrences(of: "\"", with: "")
        // Upstream's (PaddleX's) handling of a command inside \operatorname, \mathrm, \text, or \mathbf followed by a
        // space and a letter, kept as it is: the spaces go from the whole text, the command is marked, and each such
        // \operatorname{…} is replaced by the text as it then stood.
        var names: [String] = []
        for match in matches(textCommand, in: text) {
            for macro in captures(macro, in: match) where !protectedMacros.contains(macro) && !macro.trimmingCharacters(in: .whitespaces).isEmpty {
                text = text.replacingOccurrences(of: macro, with: macro + "XXXXXXX")
                text = text.replacingOccurrences(of: " ", with: "")
                names.append(text)
            }
        }
        if !names.isEmpty {
            let ns = text as NSString
            var result = ""
            var last = 0
            for found in textCommand.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: found.range.location - last))
                result += names.isEmpty ? "" : names.removeFirst()
                last = found.range.location + found.range.length
            }
            text = result + ns.substring(from: last)
        }
        while true {
            var next = replacing(noLetterNoLetter, in: text, with: "$1$2")
            next = replacing(noLetterLetter, in: next, with: "$1$2")
            next = replacing(letterNoLetter, in: next, with: "$1$2")
            if next == text { break }
            text = next
        }
        return text.replacingOccurrences(of: "XXXXXXX", with: " ")
    }

    private static let textCommand = expression(#"(\\(operatorname|mathrm|text|mathbf)\s?\*? \{.*?\})"#)
    private static let macro = expression(#"(\\[a-zA-Z]+)\s(?=\w)|\\[a-zA-Z]+\s(?=\})"#)
    private static let protectedMacros: Set = [#"\operatorname"#, #"\mathrm"#, #"\text"#, #"\mathbf"#]
    private static let noLetterNoLetter = expression(#"(?!\\ )([\W_^\d])\s+?([\W_^\d])"#)
    private static let noLetterLetter = expression(#"(?!\\ )([\W_^\d])\s+?([a-zA-Z])"#)
    private static let letterNoLetter = expression(#"([a-zA-Z])\s+?([\W_^\d])"#)
    private static let chineseText = expression(#"\\text\s*\{([^{}]*[\u4e00-\u9fff]+[^{}]*)\}"#)

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static func replacing(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// The whole of each match.
    private static func matches(_ expression: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Each match's first group, or "" where it took no part, as Python's `findall` gives them.
    private static func captures(_ expression: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }
}
