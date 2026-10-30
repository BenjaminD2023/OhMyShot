import Foundation

/// Builds file names for captures from a pattern of tokens.
///
/// Tokens: `{date}` (2026-10-07), `{time}` (22.45.10, dots because macOS file names cannot hold
/// colons in Finder), `{app}` (the frontmost app), `{window}` (the captured window's title, or the front
/// window's for an area), `{counter}` (a running number). Anything else is kept as typed; slashes and colons
/// are replaced so the result is always a valid file name, and a name too long for the file system is cut.
public struct FilenameTemplate: Equatable, Sendable {
    public var pattern: String

    public static let standard = FilenameTemplate(pattern: "OhMyShot {date} at {time}")

    /// The words a pattern can hold between braces.
    public enum Token: String, CaseIterable, Sendable {
        case date
        case time
        case app
        case window
        case counter

        /// How the token is written in a pattern.
        public var placeholder: String { "{\(rawValue)}" }
    }

    /// A pattern as the bricks Settings lays it out in: tokens, words, and the separators between them. Each
    /// separator is a brick of its own, so a space can be dragged as easily as a word; joined, the pieces give
    /// the pattern back exactly.
    public enum Piece: Hashable, Sendable {
        case token(Token)
        case word(String)
        case separator(Character)

        /// The piece as it is written in a pattern.
        public var text: String {
            switch self {
            case .token(let token): token.placeholder
            case .word(let word): word
            case .separator(let character): String(character)
            }
        }
    }

    /// The characters that stand between words in a name, each a piece of its own.
    public static let separators: Set<Character> = [" ", "-", "_", ".", ",", "–", "—", "·", "+", "@", "(", ")", "[", "]"]

    /// The pattern cut into pieces. Braces that make no token (`{foo}`) are part of a word.
    public var pieces: [Piece] { Self.pieces(of: pattern) }

    /// The pattern the pieces make.
    public init(pieces: [Piece]) {
        self.pattern = pieces.map(\.text).joined()
    }

    /// `text` cut into pieces, as `pieces` cuts a pattern.
    public static func pieces(of text: String) -> [Piece] {
        var result: [Piece] = []
        var word = ""
        var rest = Substring(text)
        func endWord() {
            if !word.isEmpty { result.append(.word(word)) }
            word = ""
        }
        while let first = rest.first {
            if first == "{", let token = Token.allCases.first(where: { rest.hasPrefix($0.placeholder) }) {
                endWord()
                result.append(.token(token))
                rest = rest.dropFirst(token.placeholder.count)
            } else if separators.contains(first) {
                endWord()
                result.append(.separator(first))
                rest = rest.dropFirst()
            } else {
                word.append(first)
                rest = rest.dropFirst()
            }
        }
        endWord()
        return result
    }

    /// The most a name may take, in UTF-8 bytes: file systems allow 255 for the whole file name, and the
    /// extension and a " (12)" for a name already taken come after.
    public static let longestName = 200
    /// The most of a window's title a name takes, in characters: browser tabs are titled with whole sentences.
    static let longestWindowTitle = 80

    public init(pattern: String) {
        self.pattern = pattern
    }

    /// Whether names from this pattern change from one file to the next, so each saved file takes a number.
    public var usesCounter: Bool {
        pattern.contains(Token.counter.placeholder)
    }

    public func name(
        date: Date, appName: String? = nil, windowTitle: String? = nil, counter: Int = 1, timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateText = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let timeText = String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let title = Self.sanitized(windowTitle ?? "")
        let result = pattern
            .replacingOccurrences(of: Token.date.placeholder, with: dateText)
            .replacingOccurrences(of: Token.time.placeholder, with: timeText)
            .replacingOccurrences(of: Token.app.placeholder, with: appName ?? "")
            .replacingOccurrences(of: Token.window.placeholder, with: String(title.prefix(Self.longestWindowTitle)))
            .replacingOccurrences(of: Token.counter.placeholder, with: String(counter))
        let cleaned = Self.sanitized(result)
        return cleaned.isEmpty ? "OhMyShot" : Self.cut(cleaned, toBytes: Self.longestName)
    }

    /// Text as a file name: slashes and colons replaced, control characters (a title with a line break) and
    /// the dots that would hide the file taken away, ends trimmed. Empty when nothing is left.
    public static func sanitized(_ text: String) -> String {
        let replaced = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        let printable = String(String.UnicodeScalarView(replaced.unicodeScalars.filter { !$0.properties.generalCategory.isControl }))
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return String(trimmed.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
    }

    /// A name the person typed, as a file name: made valid, and without the extension of a picture if they typed one,
    /// since saving adds the right one. `fallback` when nothing usable is left.
    public static func typedName(_ text: String, fallback: String) -> String {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = typed.lastIndex(of: "."), ["png", "jpg", "jpeg", "heic", "heif"].contains(typed[typed.index(after: dot)...].lowercased()) {
            typed = String(typed[..<dot])
        }
        let name = cut(sanitized(typed), toBytes: longestName)
        return name.isEmpty ? fallback : name
    }

    /// `text` with whole characters taken off its end until it fits in `bytes` bytes of UTF-8.
    static func cut(_ text: String, toBytes bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var kept = text
        while kept.utf8.count > bytes { kept.removeLast() }
        return kept.trimmingCharacters(in: .whitespaces)
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool {
        switch self {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
