import Foundation

/// The text read in a capture, kept beside it (`HistoryStore.textURL(for:)`) so the history can be searched
/// by what the pictures show.
public struct HistoryText: Codable, Equatable, Sendable {
    /// Raised when the reading changes, so every capture is read again.
    public static let version = 1

    /// A file's size and when its content last changed: text read from a picture belongs to it while both
    /// are the same. Only ever compared for equality: putting a capture back as taken brings back an older date.
    public struct Stamp: Codable, Equatable, Sendable {
        public var size: Int
        public var modified: TimeInterval

        public init(size: Int, modified: TimeInterval) {
            self.size = size
            self.modified = modified
        }
    }

    public var version: Int
    public var stamp: Stamp
    public var text: String
    /// The model pack read beside Vision when the text was read (`TextReaderPack.reading`); nil when Vision read
    /// alone. Text read alone is read again once a pack is there, where it holds Chinese or Japanese.
    public var reading: String?

    public init(version: Int, stamp: Stamp, text: String, reading: String? = nil) {
        self.version = version
        self.stamp = stamp
        self.text = text
        self.reading = reading
    }

    /// Whether a pack could read `text` better: two or more of its characters are Han or kana, which L2 reads better
    /// than Vision (Docs/ocr.md › L2 beside L1). The same test as the text reader's, `SecondReading.wanted`.
    static func mayReadBetter(_ text: String) -> Bool {
        var count = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                count += 1
                if count >= 2 { return true }
            default:
                break
            }
        }
        return false
    }
}

/// Finding captures by the words in them, as people type them rather than as OCR spaced them.
///
/// Text and query are compared folded: case, width (full-width Latin and half-width kana), Latin diacritics,
/// and Traditional against Simplified Chinese count as the same, and spaces, line breaks, and punctuation are
/// left out of both. OCR spaces Chinese beside English one way on one line and another way on the next, breaks
/// a phrase across lines, and reads "›" as "，"; folded, "软件更新" finds "軟體 更新" read over a line break.
/// Each word typed must appear, in the capture's text or in the name of the app it was taken in.
public enum HistorySearch {
    /// A capture's text and app name, ready to be searched.
    public struct Entry: Sendable {
        let text: String
        let key: String
        /// Where in `text` each character of `key` came from.
        let origins: [String.Index]
        let appKey: String

        public init(text: String, appName: String?, folding: inout Folding) {
            self.text = text
            var key = "", origins: [String.Index] = []
            key.reserveCapacity(text.utf8.count)
            origins.reserveCapacity(text.count)
            var index = text.startIndex
            while index < text.endIndex {
                let folded = folding.fold(text[index])
                if !folded.isEmpty {
                    key += folded
                    origins.append(contentsOf: repeatElement(index, count: folded.count))
                }
                index = text.index(after: index)
            }
            self.key = key
            self.origins = origins
            appKey = folding.fold(appName ?? "")
        }
    }

    /// Where a search found a capture.
    public struct Match: Equatable, Sendable {
        /// The line of the capture's text around the first word found there; nil when every word was found in
        /// the app's name alone.
        public var excerpt: Excerpt?
    }

    /// A short run of a capture's text: what was found, with a little before and after it, on one line.
    public struct Excerpt: Equatable, Sendable {
        /// Whether the line goes on before `before`.
        public var continuesBefore: Bool
        public var before: String
        public var found: String
        public var after: String
    }

    /// The words in `query`, folded; empty when it holds nothing to look for.
    public static func terms(in query: String) -> [String] {
        var folding = Folding()
        return query.split(whereSeparator: \.isWhitespace).map { folding.fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// Where `entry` holds every one of `terms`, or nil when one is missing.
    public static func match(_ terms: [String], in entry: Entry) -> Match? {
        guard !terms.isEmpty else { return nil }
        var excerpt: Excerpt?
        for term in terms {
            if let found = entry.key.range(of: term) {
                if excerpt == nil { excerpt = Self.excerpt(of: found, in: entry) }
            } else if !entry.appKey.contains(term) {
                return nil
            }
        }
        return Match(excerpt: excerpt)
    }

    /// Columns kept before what was found, at most: a Chinese, Japanese, or Korean character takes two, as it is
    /// about twice as wide, so what was found starts on the card's first line in any language.
    static let before = 18
    /// Columns kept after it, at most; the card shows what fits.
    static let after = 90

    private static func excerpt(of found: Range<String.Index>, in entry: Entry) -> Excerpt? {
        let key = entry.key, origins = entry.origins, text = entry.text
        guard !origins.isEmpty else { return nil }
        let first = min(key.distance(from: key.startIndex, to: found.lowerBound), origins.count - 1)
        let last = min(first + max(key.distance(from: found.lowerBound, to: found.upperBound), 1) - 1, origins.count - 1)
        let start = origins[first], end = text.index(after: origins[last])
        // Back to the start of the line, or `before` columns, whichever comes first.
        var from = start, count = 0
        while from > text.startIndex {
            let previous = text.index(before: from)
            if text[previous].isNewline || count + columns(text[previous]) > before { break }
            from = previous
            count += columns(text[previous])
        }
        let continuesBefore = from > text.startIndex && !text[text.index(before: from)].isNewline
        var to = end
        count = 0
        while to < text.endIndex, !text[to].isNewline, count + columns(text[to]) <= after {
            count += columns(text[to])
            to = text.index(after: to)
        }
        func line(_ part: Substring) -> String {
            String(part.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        }
        return Excerpt(
            continuesBefore: continuesBefore,
            before: line(text[from..<start]).trimmingPrefixWhitespace(),
            found: line(text[start..<end]),
            after: line(text[end..<to])
        )
    }

    /// How many columns `character` takes: two for the wide characters of Chinese, Japanese, and Korean and for
    /// full-width forms, one for the rest.
    static func columns(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first, scalar.value >= 0x1100 else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Folds text for comparing, one character at a time. Holds what it folded before, so text that keeps to
    /// the same few thousand characters (any language) is folded quickly: fold a history's texts with one.
    public struct Folding: Sendable {
        private var folded: [Character: String] = [:]

        public init() {}

        /// `character` as it is compared: empty for spaces, line breaks, and punctuation.
        public mutating func fold(_ character: Character) -> String {
            if character.isASCII {
                if character.isWhitespace || character.isPunctuation { return "" }
                return character.isUppercase ? character.lowercased() : String(character)
            }
            if let known = folded[character] { return known }
            let result = Self.fold(nonASCII: character)
            folded[character] = result
            return result
        }

        public mutating func fold(_ text: String) -> String {
            var result = ""
            for character in text { result += fold(character) }
            return result
        }

        private static func fold(nonASCII character: Character) -> String {
            if character.isWhitespace || character.isPunctuation { return "" }
            guard let scalar = character.unicodeScalars.first else { return "" }
            var options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
            // Diacritics only in Latin, Greek, and Cyrillic: in kana the voicing marks are what tell が from か.
            if scalar.value < 0x0590 || (0x1E00...0x1FFF).contains(scalar.value) { options.insert(.diacriticInsensitive) }
            var text = String(character).folding(options: options, locale: nil)
            if isHan(scalar) {
                text = text.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? text
            }
            // Width folding turns full-width punctuation into ASCII punctuation, which is left out too.
            return String(text.filter { !$0.isWhitespace && !$0.isPunctuation })
        }

        private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: true
            default: false
            }
        }
    }
}

private extension String {
    func trimmingPrefixWhitespace() -> String {
        String(drop(while: \.isWhitespace))
    }
}
