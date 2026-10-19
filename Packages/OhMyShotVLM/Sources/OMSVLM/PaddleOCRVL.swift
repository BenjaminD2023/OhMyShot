import Foundation
import MLX
import MLXNN

/// The model's two halves under the names its weights have.
final class PaddleOCRVLModel: Module {
    @ModuleInfo var visual: VisionModel
    @ModuleInfo(key: "language_model") var languageModel: LanguageModel

    init(_ configuration: PaddleOCRVLConfiguration) {
        _visual.wrappedValue = VisionModel(configuration.vision, output: configuration.hiddenSize)
        _languageModel.wrappedValue = LanguageModel(configuration)
    }
}

/// PaddleOCR-VL-1.6 on MLX: reads one picture (a block of text, a table, a formula, a chart) with the task's prompt,
/// greedily, one token at a time. Not thread-safe: one reading at a time.
public final class PaddleOCRVL {
    /// A task's prompt around the picture's tokens, tokenized when the pack was made: `<|begin_of_sentence|>User: `
    /// and `<|IMAGE_START|>` before, `<|IMAGE_END|>`, the task ("OCR:") and `\nAssistant:\n` after.
    public struct Prompt: Codable, Sendable {
        public var before: [Int]
        public var after: [Int]

        public init(before: [Int], after: [Int]) {
            self.before = before
            self.after = after
        }
    }

    public let configuration: PaddleOCRVLConfiguration
    let model: PaddleOCRVLModel

    init(configuration: PaddleOCRVLConfiguration, model: PaddleOCRVLModel) {
        self.configuration = configuration
        self.model = model
    }

    /// The model in `folder`: `config.json` and `model.safetensors` (mlx-vlm's conversion; the modules it quantized
    /// have `.scales` beside their weights).
    public static func load(from folder: URL) throws -> PaddleOCRVL {
        let configuration = try JSONDecoder().decode(
            PaddleOCRVLConfiguration.self, from: Data(contentsOf: folder.appending(path: "config.json")))
        let model = PaddleOCRVLModel(configuration)
        let weights = try loadArrays(url: folder.appending(path: "model.safetensors"))
        if let quantization = configuration.quantization {
            quantize(model: model) { path, _ in
                weights["\(path).scales"] == nil ? nil : (quantization.groupSize, quantization.bits, .affine)
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        return PaddleOCRVL(configuration: configuration, model: model)
    }

    /// The prompt's tokens with the picture's in their place.
    public func tokens(_ prompt: Prompt, picture: PaddleOCRVLPicture) -> [Int] {
        prompt.before + Array(repeating: configuration.imageToken, count: picture.tokens) + prompt.after
    }

    /// Each token's time, row, and column ([3][count]) and how far the positions after them run behind their count
    /// (mlx-vlm's `get_rope_index` for one picture): text counts on from the last position, the picture's tokens share
    /// its first position in time and take their row and column after it.
    public func positions(_ tokens: [Int], picture: PaddleOCRVLPicture) -> (positions: [[Int32]], delta: Int) {
        Self.positions(tokens, imageToken: configuration.imageToken, picture: picture)
    }

    /// The same for a model whose picture tokens are `imageToken`.
    static func positions(_ tokens: [Int], imageToken: Int, picture: PaddleOCRVLPicture) -> (positions: [[Int32]], delta: Int) {
        var positions: [[Int32]] = [[], [], []]
        guard let start = tokens.firstIndex(of: imageToken) else {
            let all = (0..<tokens.count).map(Int32.init)
            return ([all, all, all], 0)
        }
        for index in 0..<start {
            for axis in 0..<3 { positions[axis].append(Int32(index)) }
        }
        let columns = picture.width / PaddleOCRVLPicture.mergeSize
        for index in 0..<picture.tokens {
            positions[0].append(Int32(start))
            positions[1].append(Int32(start + index / columns))
            positions[2].append(Int32(start + index % columns))
        }
        var next = Int(positions.compactMap { $0.max() }.max() ?? -1) + 1
        for _ in (start + picture.tokens)..<tokens.count {
            for axis in 0..<3 { positions[axis].append(Int32(next)) }
            next += 1
        }
        return (positions, next - tokens.count)
    }

    /// The picture's embeddings, [tokens, dimensions].
    func seen(_ picture: PaddleOCRVLPicture) -> MLXArray {
        let type = model.visual.embeddings.patchEmbedding.weight.dtype
        let patch = PaddleOCRVLPicture.patchSize
        let values = MLXArray(picture.values, [picture.height * picture.width, 3, patch, patch]).asType(type)
        return model.visual(values, height: picture.height, width: picture.width)
    }

    /// Why a reading ended.
    public enum Ending: String, Sendable {
        /// The model said it was done.
        case end
        /// `maximum` tokens were read.
        case length
        /// `shouldStop` said so (a deadline, a cancelled reading).
        case stopped
    }

    /// The tokens the model reads from `picture` given `prompt`, greedily, up to its end token or `maximum` tokens;
    /// `shouldStop` is asked before each token.
    public func read(_ picture: PaddleOCRVLPicture, prompt: Prompt, maximum: Int = 2048,
                     shouldStop: () -> Bool = { false }) -> (tokens: [Int], ending: Ending) {
        let tokens = self.tokens(prompt, picture: picture)
        let (positions, delta) = self.positions(tokens, picture: picture)
        let language = model.languageModel
        let caches = language.model.layers.map { _ in KeyValueCache() }

        let embedded = language.model.embedTokens(MLXArray(tokens.map(Int32.init)).expandedDimensions(axis: 0))
        let start = prompt.before.count
        let features = seen(picture).asType(embedded.dtype).expandedDimensions(axis: 0)
        let merged = concatenated([embedded[0..., ..<start], features, embedded[0..., (start + picture.tokens)...]], axis: 1)
        let flat = positions.flatMap { $0 }
        var logits = language(merged, positions: MLXArray(flat, [3, tokens.count]), caches: caches)

        var read: [Int] = []
        var position = tokens.count + delta
        while true {
            let token = logits[0, -1].argMax().item(Int.self)
            if token == configuration.endToken { return (read, .end) }
            read.append(token)
            if read.count >= maximum { return (read, .length) }
            if shouldStop() { return (read, .stopped) }
            let next = language.model.embedTokens(MLXArray([Int32(token)]).expandedDimensions(axis: 0))
            let at = MLXArray([Int32](repeating: Int32(position), count: 3), [3, 1])
            logits = language(next, positions: at, caches: caches)
            position += 1
        }
    }
}
