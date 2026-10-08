import Foundation
import NaturalLanguage
// The framework predates strict concurrency: its sessions and availability checks carry no Sendable
// annotations, though they are meant to be awaited from anywhere.
@preconcurrency import Translation

/// Translates recognized text with the system's on-device models (the Translation framework). Each unit's
/// language is detected on its own, so on a page of Chinese and English with a Chinese target only the
/// English is translated. Simplified and Traditional Chinese, which the framework does not translate
/// between, are converted character by character (ICU's Hans–Hant transform).
///
/// An actor, because sessions are not safe to share and each language pair's first session loads a
/// model (about 0.8 s, measured): sessions are kept per pair for the life of the translator.
public actor Translator {
    public struct Outcome: Sendable, Equatable {
        /// The language translated into: the one asked for, or the one chosen for the page.
        public var target: Locale.Language
        /// Translated text by unit index, for the units that were translated.
        public var translations: [Int: String] = [:]
        /// The languages translated from.
        public var sources: [Locale.Language] = []
        /// Units already in the target language, left as they are.
        public var inTarget: [Int] = []
        /// Languages the system can translate once their model is downloaded.
        public var needsDownload: [Locale.Language] = []
        /// Languages the system cannot translate into the target at all.
        public var unsupported: [Locale.Language] = []
    }

    private var sessions: [String: TranslationSession] = [:]

    /// The text of `units` one to a line, translated where `outcome` translated it, as read elsewhere,
    /// with the ranges that were translated (UTF-16), so they can be marked as in the target language.
    public nonisolated static func text(of units: [TranslationUnit], _ outcome: Outcome) -> (text: String, translated: [NSRange]) {
        let output = NSMutableString()
        var translated: [NSRange] = []
        for index in units.indices {
            if index > 0 { output.append("\n") }
            let piece = outcome.translations[index] ?? units[index].text
            if outcome.translations[index] != nil { translated.append(NSRange(location: output.length, length: (piece as NSString).length)) }
            output.append(piece)
        }
        return (output as String, translated)
    }

    public init() {}

    /// The languages the system translates, for a target menu.
    @concurrent
    public static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    /// Translates every unit that is not skipped into `target`, or, when it is nil, into the first of
    /// `preferred` that most of the text is not already in: with English and Chinese preferred, an
    /// English page is translated into Chinese and a Chinese one into English.
    public func translate(
        _ units: [TranslationUnit], to target: Locale.Language?, preferred: [Locale.Language] = Translator.preferredLanguages()
    ) async throws -> Outcome {
        let candidates = units.indices.filter { units[$0].skip == nil }
        let readings = Self.languages(of: candidates.map { units[$0].text })
        let detected = readings.enumerated().map { (index: candidates[$0], language: $1.language) }
        let confident = Set(readings.indices.filter { readings[$0].confident }.map { candidates[$0] })
        let target = target ?? Self.automaticTarget(for: detected.map { (units[$0.index].text, $0.language) }, preferred: preferred)
        var outcome = Outcome(target: target)
        var groups: [Locale.Language: [Int]] = [:]
        var order: [Locale.Language] = []
        for (index, language) in detected {
            guard let source = language else { continue }
            if Self.isSame(source, target) || Self.isBilingual(units[index].text, in: target) {
                outcome.inTarget.append(index)
            } else if let transform = Self.chineseTransform(from: source, to: target) {
                outcome.translations[index] = units[index].text.applyingTransform(transform, reverse: false) ?? units[index].text
                if !outcome.sources.contains(source) { outcome.sources.append(source) }
            } else {
                if groups[source] == nil { order.append(source) }
                groups[source, default: []].append(index)
            }
        }
        let availability = LanguageAvailability()
        for source in order {
            guard let indices = groups[source] else { continue }
            let status = await availability.status(from: source, to: target)
            // A scrap in a language not downloaded (a misread icon, a status bar) is left as read rather
            // than worth a download: only a line's worth of text read with confidence asks for one.
            if status == .supported, indices.filter(confident.contains).reduce(0, { $0 + Self.weight(units[$1].text) }) < 16 { continue }
            switch status {
            case .installed:
                let session = session(from: source, to: target)
                let (batches, singles) = Self.batches(of: indices, in: units)
                var requests = singles.map { TranslationSession.Request(sourceText: units[$0].text, clientIdentifier: "u\($0)") }
                requests += batches.indices.map { batch in
                    TranslationSession.Request(sourceText: batches[batch].map { units[$0].text }.joined(separator: " | "), clientIdentifier: "b\(batch)")
                }
                var unsplit: [Int] = []
                for response in try await session.translations(from: requests) {
                    guard let identifier = response.clientIdentifier, let number = Int(identifier.dropFirst()) else { continue }
                    if identifier.hasPrefix("u") {
                        outcome.translations[number] = Self.tidied(response.targetText, into: target)
                        continue
                    }
                    let members = batches[number]
                    let pieces = response.targetText.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    guard pieces.count == members.count, !pieces.contains(where: \.isEmpty) else {
                        unsplit += members
                        continue
                    }
                    for (index, piece) in zip(members, pieces) { outcome.translations[index] = Self.tidied(piece, into: target) }
                }
                // A batch that came back with its pieces merged or split: one by one after all.
                if !unsplit.isEmpty {
                    let retries = unsplit.map { TranslationSession.Request(sourceText: units[$0].text, clientIdentifier: String($0)) }
                    for response in try await session.translations(from: retries) {
                        guard let identifier = response.clientIdentifier, let index = Int(identifier) else { continue }
                        outcome.translations[index] = Self.tidied(response.targetText, into: target)
                    }
                }
                outcome.sources.append(source)
            case .supported:
                outcome.needsDownload.append(source)
            case .unsupported:
                outcome.unsupported.append(source)
            @unknown default:
                outcome.unsupported.append(source)
            }
        }
        return outcome
    }

    /// Lets go of the sessions, and with them the system's loaded models, when no translation is near.
    public func releaseSessions() {
        sessions = [:]
    }

    private func session(from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        let key = "\(source.maximalIdentifier)>\(target.maximalIdentifier)"
        if let session = sessions[key] { return session }
        let session = TranslationSession(installedSource: source, target: target)
        sessions[key] = session
        return session
    }

    /// Short units (labels, cells, buttons) go together, " | " between them: alone, "Open" comes back
    /// as "户外" (outdoors) and "Free" as "未受困的" (not trapped); in a row with others, as "打开" and
    /// "免费", with every separator kept (measured on twelve lists of labels). Up to twenty to a batch,
    /// so a batch that comes back mangled costs little to redo.
    static func batches(of indices: [Int], in units: [TranslationUnit]) -> (batches: [[Int]], singles: [Int]) {
        let short = indices.filter { isShort(units[$0].text) }
        guard short.count >= 2 else { return ([], indices) }
        let batches = stride(from: 0, to: short.count, by: 20).map { Array(short[$0..<min($0 + 20, short.count)]) }
        return (batches, indices.filter { !short.contains($0) })
    }

    /// A label rather than a sentence: five words or fewer (a Han or kana character counted as half a
    /// word), no sentence ending inside it, and no bar to confuse the batch.
    static func isShort(_ text: String) -> Bool {
        guard text.count <= 40, !text.contains("|"), !text.contains("\n") else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let square = text.filter { Script.isCJK($0) && !Script.isHangul($0) }.count
        let inside = text.trimmingCharacters(in: .whitespaces).dropLast()
        let endsSentenceInside = inside.contains { "。！？".contains($0) } || text.range(of: #"[.!?]\s+\S"#, options: .regularExpression) != nil
        return Double(words) + Double(square) / 2 <= 5 && !endsSentenceInside
    }

    /// A bilingual label: one part in Latin and one in another script, side by side, one of them in the
    /// target language ("发布说明 Release Notes", "价格 Price" into Chinese or English); translated, it
    /// would only say the same thing twice. A word of one script inside a sentence of the other
    /// ("按住 Option 再松开鼠标", "Open the 设置 panel") makes three parts, and is translated as usual.
    /// The part's language is checked, not only its script: kanji are Chinese characters too.
    static func isBilingual(_ text: String, in target: Locale.Language) -> Bool {
        var parts: [(latin: Bool, text: String, weight: Int)] = []
        for character in text {
            guard character.isLetter else {
                if !parts.isEmpty { parts[parts.count - 1].text.append(character) }
                continue
            }
            let latin = character.unicodeScalars.allSatisfy { $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) }
            let weight = Script.isCJK(character) ? 2 : 1
            if let last = parts.last, last.latin == latin {
                parts[parts.count - 1].text.append(character)
                parts[parts.count - 1].weight += weight
            } else {
                parts.append((latin, String(character), weight))
            }
        }
        guard parts.count == 2 else { return false }
        let total = parts[0].weight + parts[1].weight
        // Each a fair share: not a lone letter beside a sentence.
        guard parts.allSatisfy({ Double($0.weight) >= Double(total) * 0.2 }) else { return false }
        return parts.contains { part in
            part.text.contains(where: { isWritten($0, in: target) }) && isPlausibly(part.text, in: target)
        }
    }

    /// Whether `text` may well be in `language`: a word or two ("Plan", "套餐") reads as several
    /// languages at once, so the question is whether it is one of them, not the likeliest.
    static func isPlausibly(_ text: String, in language: Locale.Language) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 5).contains { candidate, probability in
            probability >= 0.2 && isSame(Locale.Language(identifier: candidate.rawValue), language)
        }
    }

    /// Whether `character` is a letter of the script `language` is written in.
    private static func isWritten(_ character: Character, in language: Locale.Language) -> Bool {
        guard character.isLetter, let value = character.unicodeScalars.first?.value else { return false }
        let han = (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) || (0x20000...0x2FA1F).contains(value)
        switch language.languageCode {
        case .chinese: return han
        case .japanese: return han || (0x3040...0x30FF).contains(value)
        case .korean: return Script.isHangul(character)
        case .russian, .ukrainian: return (0x0400...0x04FF).contains(value)
        case .arabic: return (0x0600...0x06FF).contains(value)
        case .thai: return (0x0E00...0x0E7F).contains(value)
        case .hindi: return (0x0900...0x097F).contains(value)
        default: return value < 0x250 || (0x1E00...0x1EFF).contains(value)
        }
    }

    /// A translation into Chinese or Japanese without the spaces the model leaves between sentences
    /// ("即可。 捕获"): between two square characters, Han, kana, or full-width punctuation.
    static func tidied(_ text: String, into target: Locale.Language) -> String {
        guard target.languageCode == .chinese || target.languageCode == .japanese else { return text }
        func isSquare(_ character: Character) -> Bool {
            (Script.isCJK(character) && !Script.isHangul(character))
                || character.unicodeScalars.contains { (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
        }
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            if characters[index] == " ", let previous = output.last, isSquare(previous) {
                var end = index
                while end < characters.count, characters[end] == " " { end += 1 }
                if end < characters.count, isSquare(characters[end]) {
                    index = end
                    continue
                }
            }
            output.append(characters[index])
            index += 1
        }
        return output
    }

    // MARK: Languages

    /// The person's preferred languages, as translation targets.
    public static func preferredLanguages() -> [Locale.Language] {
        var languages: [Locale.Language] = []
        for identifier in Locale.preferredLanguages {
            let language = normalized(Locale.Language(identifier: identifier))
            if !languages.contains(where: { isSame($0, language) }) { languages.append(language) }
        }
        return languages
    }

    /// The languages to offer as targets, once each (one English, Simplified and Traditional Chinese
    /// apart), by name in `locale`.
    @concurrent
    public static func targets(in locale: Locale = .current) async -> [Locale.Language] {
        var languages: [Locale.Language] = []
        for language in await LanguageAvailability().supportedLanguages.map(normalized) where !languages.contains(where: { isSame($0, language) }) {
            languages.append(language)
        }
        return languages.sorted { name(of: $0, in: locale).localizedStandardCompare(name(of: $1, in: locale)) == .orderedAscending }
    }

    /// A language as it is stored and named: its code alone, with the script for Chinese ("zh-Hans",
    /// "zh-Hant"); the framework's own list has "zh" and "zh-TW", "en" and "en-GB".
    public static func normalized(_ language: Locale.Language) -> Locale.Language {
        guard let code = language.languageCode else { return language }
        guard code == .chinese else { return Locale.Language(languageCode: code) }
        return Locale.Language(languageCode: .chinese, script: chineseScript(language) ?? .hanSimplified)
    }

    /// The identifier a language is stored and named by: "en", "ja", "zh-Hans".
    public static func identifier(of language: Locale.Language) -> String {
        let normal = normalized(language)
        guard let code = normal.languageCode else { return language.minimalIdentifier }
        guard code == .chinese, let script = normal.script else { return code.identifier }
        return "\(code.identifier)-\(script.identifier)"
    }

    /// The language's name in `locale`: "简体中文", "English".
    public static func name(of language: Locale.Language, in locale: Locale = .current) -> String {
        let identifier = identifier(of: language)
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The first preferred language most of the text is not already in. Characters are counted, a Han
    /// or kana one as two letters (about a word, as in the assembler).
    static func automaticTarget(for texts: [(text: String, language: Locale.Language?)], preferred: [Locale.Language]) -> Locale.Language {
        let total = texts.reduce(0) { $0 + weight($1.text) }
        for language in preferred {
            let already = texts.filter { $0.language.map { isSame($0, language) } == true }.reduce(0) { $0 + weight($1.text) }
            if total == 0 || Double(already) < Double(total) * 0.5 { return language }
        }
        return preferred.first ?? Locale.Language(languageCode: .english)
    }

    /// The language of each text, as the page has it. A short text says little about its language
    /// ("dfanxu" reads as Polish, "Codex" as Spanish), so only a confident reading of a text long enough
    /// counts on its own; the others take the page's language in their script. A confident Japanese
    /// line on a Chinese page stays Japanese.
    static func languages(of texts: [String]) -> [(language: Locale.Language?, confident: Bool)] {
        let readings = texts.map { text -> (language: Locale.Language?, confident: Bool) in
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = constraints
            recognizer.processString(text)
            guard let (best, probability) = recognizer.languageHypotheses(withMaximum: 1).first else { return (nil, false) }
            let language = Locale.Language(identifier: best.rawValue)
            // Mostly in the language's own script: an icon read as kana among stray letters and figures
            // ("2っaくコiく") reads as Japanese with confidence, but it is not.
            let characters = text.filter { !$0.isWhitespace }
            let pure = Double(characters.filter { isWritten($0, in: language) }.count) >= Double(characters.count) * 0.7
            return (language, probability >= 0.75 && weight(text) >= 8 && pure)
        }
        // The page's languages: those of the confident readings, each with a fair share of the text.
        var shares: [(language: Locale.Language, weight: Int)] = []
        for (text, reading) in zip(texts, readings) where reading.confident {
            guard let language = reading.language else { continue }
            if let index = shares.firstIndex(where: { isSame($0.language, language) }) {
                shares[index].weight += weight(text)
            } else {
                shares.append((language, weight(text)))
            }
        }
        let total = shares.reduce(0) { $0 + $1.weight }
        var page = shares.filter { Double($0.weight) >= Double(total) * 0.15 }.sorted { $0.weight > $1.weight }.map(\.language)
        if page.isEmpty, let whole = language(of: texts.joined(separator: "\n"), hint: nil) { page = [whole] }
        return zip(texts, readings).map { text, reading in
            if reading.confident { return reading }
            if let language = reading.language, page.contains(where: { isSame($0, language) }) { return (language, false) }
            // The page's language that writes the most of this text's letters.
            let letters = text.filter(\.isLetter)
            let best = page.max { a, b in
                letters.filter { isWritten($0, in: a) }.count < letters.filter { isWritten($0, in: b) }.count
            }
            return (best.flatMap { language in letters.contains { isWritten($0, in: language) } ? language : nil }, false)
        }
    }

    /// Letters, a Han or kana character counted as two.
    private static func weight(_ text: String) -> Int {
        text.reduce(0) { $0 + (Script.isCJK($1) ? 2 : ($1.isLetter ? 1 : 0)) }
    }

    /// The dominant language of `text`, among the ones the system translates. `hint` tips short text
    /// toward the page's language.
    static func language(of text: String, hint: Locale.Language?) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        if let hint, let language = constraints.first(where: { isSame(Locale.Language(identifier: $0.rawValue), hint) }),
           text.filter(\.isLetter).count < 12 {
            recognizer.languageHints = [language: 0.6]
        }
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    /// What Natural Language may answer: languages the Translation framework works with.
    private static let constraints: [NLLanguage] = [
        .english, .simplifiedChinese, .traditionalChinese, .japanese, .korean, .french, .german, .spanish,
        .italian, .portuguese, .russian, .arabic, .dutch, .polish, .thai, .turkish, .ukrainian, .vietnamese,
        .indonesian, .hindi,
    ]

    /// Same language, and for Chinese the same script: Simplified is not Traditional.
    static func isSame(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard a.languageCode == b.languageCode else { return false }
        guard a.languageCode == .chinese else { return true }
        return chineseScript(a) == chineseScript(b)
    }

    private static func chineseScript(_ language: Locale.Language) -> Locale.Script? {
        if let script = language.script { return script }
        return Locale.Language(identifier: language.maximalIdentifier).script
    }

    /// Between Simplified and Traditional Chinese, the character conversion to use.
    static func chineseTransform(from source: Locale.Language, to target: Locale.Language) -> StringTransform? {
        guard source.languageCode == .chinese, target.languageCode == .chinese else { return nil }
        switch (chineseScript(source), chineseScript(target)) {
        case (.hanTraditional?, .hanSimplified?): return StringTransform("Hant-Hans")
        case (.hanSimplified?, .hanTraditional?): return StringTransform("Hans-Hant")
        default: return nil
        }
    }
}
