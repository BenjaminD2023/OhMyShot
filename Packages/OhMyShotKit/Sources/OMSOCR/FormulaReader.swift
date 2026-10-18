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

    /// The decoder's mask, in half precision: −∞ for a position not reached yet, 0 for one it may look at. Written as
    /// bits: the package is built for Intel too in Release, where Swift has no `Float16`.
    private static let hidden: UInt16 = 0xFC00
    private static let shown: UInt16 = 0x0000

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
        mask.withUnsafeMutableBytes { bytes, _ in
            for position in 0..<d.cache { bytes.storeBytes(of: Self.hidden, toByteOffset: position * 2, as: UInt16.self) }
        }
        let inputs = try MLDictionaryFeatureProvider(dictionary: [d.token: token, d.position: position, d.mask: mask, d.keys: keys, d.values: crossValues])
        let state = decoder.makeState()

        var ids: [Int] = []
        var last = d.start
        var ending = FormulaReading.Ending.cacheFull
        for step in 0..<d.cache {
            try Task.checkCancellation()
            token[0] = NSNumber(value: Int32(last))
            position[0] = NSNumber(value: Int32(step))
            mask.withUnsafeMutableBytes { bytes, _ in bytes.storeBytes(of: Self.shown, toByteOffset: step * 2, as: UInt16.self) }
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

extension FormulaReader {
    /// The formulas `finder` finds in `image`, each read as LaTeX, top to bottom; those not read whole are left out, and
    /// so are those still waiting at `deadline` (their text then stays as Vision reads it). `found` is told how many
    /// there are to read before the first is.
    public func formulas(
        in image: CGImage, finder: FormulaFinder, deadline: Duration = .seconds(30), found: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [FormulaMerge.Formula] {
        let started = ContinuousClock.now
        let regions = try await finder.regions(in: image)
        found?(regions.count)
        return try await formulas(in: image, regions: regions, deadline: deadline - (ContinuousClock.now - started))
    }

    /// The formulas in `regions` of `image` (as `FormulaFinder` found them), each read as LaTeX, as above.
    public func formulas(in image: CGImage, regions: [FormulaFinder.Region], deadline: Duration = .seconds(30)) async throws -> [FormulaMerge.Formula] {
        let started = ContinuousClock.now
        let readings = try await withThrowingTaskGroup(of: (Int, FormulaReading?).self) { group in
            var next = 0
            func readNext() {
                guard next < regions.count else { return }
                let index = next
                next += 1
                group.addTask {
                    let left = deadline - (ContinuousClock.now - started)
                    guard left > .zero, let part = image.cropping(to: Self.crop(of: regions[index].box, in: image)) else { return (index, nil) }
                    return (index, try await self.read(part, deadline: min(Self.defaultDeadline, left)))
                }
            }
            for _ in 0..<Self.readsAtOnce { readNext() }
            var readings = [FormulaReading?](repeating: nil, count: regions.count)
            for try await (index, reading) in group {
                readings[index] = reading
                readNext()
            }
            return readings
        }
        return zip(regions, readings).compactMap { region, reading in
            guard let reading, reading.isFormula else { return nil }
            return FormulaMerge.Formula(kind: region.kind, box: region.box, latex: reading.latex)
        }
    }

    /// How many formulas are read side by side, each with a decoder state of its own. Core ML spreads one reading over
    /// the cores already: three at once read 8 formulas in 2.6 s rather than 4.1 s, for 20% more CPU time and 945 MB at
    /// the peak against 394 MB (Docs/perf.md › M6 — Formulas among text).
    static let readsAtOnce = 1

    /// What of the picture is read for a formula found in `box`: a little more above and below, where a box drawn
    /// close may cut an accent or a script, and barely more to the sides, where the words beside an inline formula are.
    /// The reader crops what it reads to its ink anyway.
    static func crop(of box: CGRect, in image: CGImage) -> CGRect {
        box.insetBy(dx: -2, dy: -max(2, box.height * 0.12)).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
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
