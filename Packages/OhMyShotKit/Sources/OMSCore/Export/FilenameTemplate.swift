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
        let trimmedApp = (appName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = String(title.prefix(Self.longestWindowTitle)).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: [ResolvedPiece] = pieces.map { piece in
            switch piece {
            case .word(let word):
                return .text(word)
            case .separator(let character):
                return .separator(character)
            case .token(.date):
                return .text(dateText)
            case .token(.time):
                return .text(timeText)
            case .token(.counter):
                return .text(String(counter))
            case .token(.app):
                return trimmedApp.isEmpty ? .omitted : .text(appName ?? "")
            case .token(.window):
                return trimmedTitle.isEmpty ? .omitted : .text(String(title.prefix(Self.longestWindowTitle)))
            }
        }
        let result = Self.joined(resolved)
        let cleaned = Self.sanitized(result)
        return cleaned.isEmpty ? "OhMyShot" : Self.cut(cleaned, toBytes: Self.longestName)
    }

    private enum ResolvedPiece {
        case text(String)
        case separator(Character)
        case omitted

        var isOmitted: Bool {
            if case .omitted = self { return true }
            return false
        }

        var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    /// Joins resolved pieces, collapsing empty bracket groups and dangling separators left behind when
    /// optional tokens (`{app}`, `{window}`) are empty.
    private static func joined(_ input: [ResolvedPiece]) -> String {
        guard input.contains(where: \.isOmitted) else {
            return input.map { piece in
                switch piece {
                case .text(let s): s
                case .separator(let c): String(c)
                case .omitted: ""
                }
            }.joined()
        }

        // Collapse empty bracket pairs like `({window})` or `[{app}]` whose contents are all omitted/spaces.
        var items = input
        let bracketPairs: [(Character, Character)] = [("(", ")"), ("[", "]")]
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < items.count {
                if case .separator(let open) = items[index],
                   let close = bracketPairs.first(where: { $0.0 == open })?.1 {
                    var end = index + 1
                    var sawOmitted = false
                    var validEmpty = false
                    while end < items.count {
                        switch items[end] {
                        case .omitted:
                            sawOmitted = true
                            end += 1
                        case .separator(" "):
                            end += 1
                        case .separator(let c) where c == close:
                            validEmpty = sawOmitted
                            if validEmpty { end += 1 }
                            else { end = items.count }
                        default:
                            end = items.count
                        }
                        if validEmpty { break }
                    }
                    if validEmpty {
                        items.replaceSubrange(index..<end, with: [.omitted])
                        changed = true
                        continue
                    }
                }
                index += 1
            }
        }

        let openers: Set<Character> = ["(", "["]
        let closers: Set<Character> = [")", "]"]
        var output = ""
        var index = 0
        while index < items.count {
            if case .text(let text) = items[index] {
                output += text
                index += 1
                continue
            }
            let start = index
            while index < items.count, !items[index].isText { index += 1 }
            let run = Array(items[start..<index])
            let hasLeadingText = start > 0
            let hasTrailingText = index < items.count

            guard run.contains(where: \.isOmitted) else {
                for piece in run {
                    if case .separator(let c) = piece { output.append(c) }
                }
                continue
            }

            if !hasLeadingText && !hasTrailingText {
                continue
            } else if !hasLeadingText {
                // Keep only trailing opening brackets immediately preceding the next text piece.
                let trailingOpeners = run.reversed().prefix {
                    if case .separator(let c) = $0 { return openers.contains(c) }
                    return false
                }.reversed()
                for piece in trailingOpeners {
                    if case .separator(let c) = piece { output.append(c) }
                }
            } else if !hasTrailingText {
                // Keep only leading closing brackets immediately following the previous text piece.
                let leadingClosers = run.prefix {
                    if case .separator(let c) = $0 { return closers.contains(c) }
                    return false
                }
                for piece in leadingClosers {
                    if case .separator(let c) = piece { output.append(c) }
                }
            } else {
                let firstOmitted = run.firstIndex(where: \.isOmitted) ?? run.count
                let lastOmitted = run.lastIndex(where: \.isOmitted) ?? 0
                let left = Array(run[..<firstOmitted])
                let right = Array(run[(lastOmitted + 1)...])

                let leadingClosers = left.prefix {
                    if case .separator(let c) = $0 { return closers.contains(c) }
                    return false
                }
                let leftConnectors = left.dropFirst(leadingClosers.count)

                let trailingOpeners = Array(right.reversed().prefix {
                    if case .separator(let c) = $0 { return openers.contains(c) }
                    return false
                }.reversed())
                let rightConnectors = right.dropLast(trailingOpeners.count)

                let chosenConnectors: ArraySlice<ResolvedPiece>
                if !trailingOpeners.isEmpty, !rightConnectors.isEmpty {
                    chosenConnectors = rightConnectors
                } else if !leftConnectors.isEmpty {
                    chosenConnectors = leftConnectors
                } else {
                    chosenConnectors = rightConnectors
                }

                for piece in leadingClosers {
                    if case .separator(let c) = piece { output.append(c) }
                }
                for piece in chosenConnectors {
                    if case .separator(let c) = piece { output.append(c) }
                }
                for piece in trailingOpeners {
                    if case .separator(let c) = piece { output.append(c) }
                }
            }
        }
        return output
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
