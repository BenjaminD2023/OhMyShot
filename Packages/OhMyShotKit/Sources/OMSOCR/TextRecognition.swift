import CoreGraphics
import Foundation
import Synchronization
import Vision

/// A picture read for its text, for everything that looks at it there: the redaction suggestions and the
/// lines the highlighter snaps to both need the picture read in Chinese, and through one recognition they
/// read it once. Each language model reads the picture the first time it is asked for, however many ask;
/// a reading that failed, or that everyone stopped waiting for, is made again the next time. All of it
/// stays on this Mac.
public final class TextRecognition: Sendable {
    /// The languages a reading is made in.
    enum Model: Hashable, Sendable {
        /// English alone, which reads email addresses, keys, and numbers most faithfully.
        case latin
        /// Simplified Chinese with English, which reads Chinese and places English as well.
        case chinese

        var languages: [Locale.Language] {
            switch self {
            case .latin: [Locale.Language(identifier: "en-US")]
            case .chinese: [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
            }
        }
    }

    /// The picture read.
    public let image: CGImage
    private let readings: SharedWork<Model, [RecognizedTextObservation]>
    private static let defaultLanguages = Mutex<[String]>([])

    /// Updates the default BCP-47 languages used when `TextRecognition(_:)` is initialized without explicit languages.
    public static func setDefaultLanguages(_ languages: [String]) {
        defaultLanguages.withLock { $0 = languages }
    }

    /// - Parameters:
    ///   - languages: explicit BCP-47 language identifiers; `nil` uses `setDefaultLanguages`, empty uses automatic default.
    ///   - timeout: how long one reading may take. A model's first use can take seconds.
    public convenience init(_ image: CGImage, languages: [String]? = nil, timeout: Duration = .seconds(20)) {
        let effective = languages ?? Self.defaultLanguages.withLock { $0 }
        let configured = Self.parsedLanguages(effective)
        self.init(image) { model in
            try await Self.recognize(image, by: model, configuredLanguages: configured, timeout: timeout)
        }
    }

    /// Reads with `read` in place of Vision alone (tests count the readings).
    init(_ image: CGImage, read: @escaping @Sendable (Model) async throws -> [RecognizedTextObservation]) {
        self.image = image
        readings = SharedWork(read)
    }

    /// The picture's lines of text as `model` reads them.
    func lines(by model: Model) async throws -> [RecognizedTextObservation] {
        try await readings.value(for: model)
    }

    static func recognize(_ image: CGImage, by model: Model, timeout: Duration) async throws -> [RecognizedTextObservation] {
        try await recognize(image, by: model, configuredLanguages: [], timeout: timeout)
    }

    static func recognize(
        _ image: CGImage,
        by model: Model,
        configuredLanguages: [Locale.Language],
        timeout: Duration
    ) async throws -> [RecognizedTextObservation] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Correction would "fix" keys and addresses into words, and changes nothing about where text lies.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = resolvedLanguages(for: model, configured: configuredLanguages)
        let configured = request
        return try await withTimeout(timeout) {
            try await RecognitionSlots.shared.run { try await configured.perform(on: image) }
        }
    }

    static func parsedLanguages(_ identifiers: [String]) -> [Locale.Language] {
        var seen = Set<String>()
        var result: [Locale.Language] = []
        for raw in identifiers {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let language = Locale.Language(identifier: trimmed)
            if seen.insert(language.minimalIdentifier.lowercased()).inserted {
                result.append(language)
            }
        }
        return result
    }

    static func resolvedLanguages(for model: Model, configured: [Locale.Language]) -> [Locale.Language] {
        switch model {
        case .latin:
            return model.languages
        case .chinese:
            return configured.isEmpty ? model.languages : configured
        }
    }
}
