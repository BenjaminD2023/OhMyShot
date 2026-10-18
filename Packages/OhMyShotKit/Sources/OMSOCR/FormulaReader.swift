import CoreGraphics
import CoreML
import Foundation

/// L3: the formula in a picture read as LaTeX by the formula pack (PP-FormulaNet_plus-L; Docs/ocr.md › The formula
/// pack), as Tools/model-packs/formula_pack.py checks it: the picture prepared (`FormulaPicture`), the encoder read once,
/// then the decoder one token at a time, greedily, its keys and values kept in its Core ML state, from the start token
/// until it gives the end token. The ids' text is tidied as upstream tidies it (`FormulaText`).
///
/// A reading also stops when it repeats itself (the model reading something that isn't a formula runs on to the
/// cache's end, 8 s on the CPU), when the cache is full, or at a deadline; such a reading isn't taken for a formula.
public final class FormulaReader: @unchecked Sendable {
    public let configuration: FormulaConfiguration
    let tokens: FormulaTokens
    // MLModel predictions may run from any thread; the reader asks one at a time.
    private let encoder: MLModel
    private let decoder: MLModel

    init(configuration: FormulaConfiguration, tokens: FormulaTokens, encoder: MLModel, decoder: MLModel) {
        self.configuration = configuration
        self.tokens = tokens
        self.encoder = encoder
        self.decoder = decoder
    }

    /// The reader of the pack installed in `folder`, its models compiled into `folder/Compiled` the first time.
    public static func load(from folder: URL) async throws -> FormulaReader {
        let configuration = try FormulaConfiguration.load(from: folder)
        let tokens = try FormulaTokens.load(from: folder, configuration)
        let units = PackModel.units(configuration.computeUnits)
        async let encoder = PackModel.load(configuration.encoder.file, in: folder, units: units)
        async let decoder = PackModel.load(configuration.decoder.file, in: folder, units: units)
        return try await FormulaReader(configuration: configuration, tokens: tokens, encoder: encoder, decoder: decoder)
    }

    /// The formula in the picture in the file at `url`.
    public func read(fileAt url: URL, deadline: Duration = defaultDeadline) async throws -> FormulaReading {
        try await read(PictureText.image(at: url), deadline: deadline)
    }

    /// About 700 tokens on the CPU (the encoder 0.2 s, then 6.8 ms a token on an M3 Max): one-line formulas 18–21 times
    /// as wide as tall took 1.8–2.4 s, the corpus's longest reading 139 tokens. A reading gone astray in a way the repeat
    /// check misses ends here, where the cache alone would let it run 7 s.
    public static let defaultDeadline: Duration = .seconds(5)

    public func read(_ image: CGImage, deadline: Duration = defaultDeadline) async throws -> FormulaReading {
        let started = ContinuousClock.now
        let picture = configuration.picture
        guard let values = FormulaPicture.values(of: image, picture) else { throw OCRError.unreadableImage }
        let size = picture.size
        let pixels = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        pixels.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            _ = buffer.update(fromContentsOf: values)
        }
        let encoded = try await encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [configuration.encoder.input: pixels]))
        guard let keys = encoded.featureValue(for: configuration.encoder.keys)?.multiArrayValue,
              let crossValues = encoded.featureValue(for: configuration.encoder.values)?.multiArrayValue
        else { throw FormulaError.unexpectedOutput("the encoder gave no \(configuration.encoder.keys) or \(configuration.encoder.values)") }

        let d = configuration.decoder
        let token = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let position = try MLMultiArray(shape: [1], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: d.cache)], dataType: .float16)
        mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in buffer.initialize(repeating: -.infinity) }
        let inputs = try MLDictionaryFeatureProvider(dictionary: [d.token: token, d.position: position, d.mask: mask, d.keys: keys, d.values: crossValues])
        let state = decoder.makeState()

        var ids: [Int] = []
        var last = d.start
        var ending = FormulaReading.Ending.cacheFull
        for step in 0..<d.cache {
            try Task.checkCancellation()
            token[0] = NSNumber(value: Int32(last))
            position[0] = NSNumber(value: Int32(step))
            mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in buffer[step] = 0 }
            let output = try await decoder.prediction(from: inputs, using: state)
            guard let next = output.featureValue(for: d.next)?.multiArrayValue, next.count > 0 else {
                throw FormulaError.unexpectedOutput("the decoder gave no \(d.next)")
            }
            last = next[0].intValue
            if last == d.end {
                ending = .end
                break
            }
            ids.append(last)
            if FormulaTokens.repeats(ids, times: d.repeats.times, longest: d.repeats.longest) {
                ending = .repeats
                break
            }
            if ContinuousClock.now - started > deadline {
                ending = .deadline
                break
            }
        }
        return FormulaReading(latex: FormulaText.tidy(tokens.text(of: ids)), ids: ids, ending: ending)
    }
}

/// What the formula pack read in a picture.
public struct FormulaReading: Sendable, Equatable {
    public enum Ending: String, Sendable, Codable {
        /// The model gave its end token: the reading is whole.
        case end
        /// It repeated itself and was stopped.
        case repeats
        /// It filled the decoder's cache.
        case cacheFull
        /// It ran past the deadline.
        case deadline
    }

    public var latex: String
    public var ids: [Int]
    public var ending: Ending

    public init(latex: String, ids: [Int], ending: Ending) {
        self.latex = latex
        self.ids = ids
        self.ending = ending
    }

    /// Whether this is a formula to give the person: a whole reading with something in it.
    public var isFormula: Bool {
        ending == .end && !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
