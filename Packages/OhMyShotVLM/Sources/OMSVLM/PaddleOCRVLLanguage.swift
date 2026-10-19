import MLX
import MLXNN

// PaddleOCR-VL's language model (ERNIE-4.5-0.3B: grouped-query attention, SwiGLU, RMS norms) with the rotary
// positions of Qwen2-VL's kind, as mlx-vlm 0.7.4 has it (models/paddleocr_vl/language.py): each position has a time,
// a row, and a column, and the head's frequencies are shared out among the three (16, 24, 24 of 64). Text has the
// same number in all three; the picture's embeddings have their row and column.

/// The keys and values every step so far, grown 256 positions at a time, as MLX's own cache is.
final class KeyValueCache {
    private var keys: MLXArray?
    private var values: MLXArray?
    private(set) var offset = 0
    private let step = 256

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let count = newKeys.dim(2)
        if keys == nil || offset + count > keys!.dim(2) {
            let grown = ((offset + count + step - 1) / step) * step
            func larger(_ old: MLXArray?, like new: MLXArray) -> MLXArray {
                let shape = [new.dim(0), new.dim(1), grown, new.dim(3)]
                let fresh = MLXArray.zeros(shape, dtype: new.dtype)
                guard let old else { return fresh }
                fresh[0..., 0..., ..<offset, 0...] = old[0..., 0..., ..<offset, 0...]
                return fresh
            }
            keys = larger(keys, like: newKeys)
            values = larger(values, like: newValues)
        }
        keys![0..., 0..., offset..<(offset + count), 0...] = newKeys
        values![0..., 0..., offset..<(offset + count), 0...] = newValues
        offset += count
        return (keys![0..., 0..., ..<offset, 0...], values![0..., 0..., ..<offset, 0...])
    }
}

final class TextAttention: Module {
    @ModuleInfo(key: "q_proj") var queryProjection: Linear
    @ModuleInfo(key: "k_proj") var keyProjection: Linear
    @ModuleInfo(key: "v_proj") var valueProjection: Linear
    @ModuleInfo(key: "o_proj") var outProjection: Linear

    let heads: Int
    let keyValueHeads: Int
    let headDimensions: Int
    let scale: Float

    init(_ configuration: PaddleOCRVLConfiguration) {
        heads = configuration.heads
        keyValueHeads = configuration.keyValueHeads
        headDimensions = configuration.headDimensions
        scale = 1 / Float(headDimensions).squareRoot()
        let dimensions = configuration.hiddenSize
        _queryProjection.wrappedValue = Linear(dimensions, heads * headDimensions, bias: false)
        _keyProjection.wrappedValue = Linear(dimensions, keyValueHeads * headDimensions, bias: false)
        _valueProjection.wrappedValue = Linear(dimensions, keyValueHeads * headDimensions, bias: false)
        _outProjection.wrappedValue = Linear(heads * headDimensions, dimensions, bias: false)
    }

    /// `cos`, `sin`: [1, 1, length, head dimensions] in the model's type.
    func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray, cache: KeyValueCache) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        var queries = queryProjection(x).reshaped(batch, length, heads, headDimensions).transposed(0, 2, 1, 3)
        var keys = keyProjection(x).reshaped(batch, length, keyValueHeads, headDimensions).transposed(0, 2, 1, 3)
        let values = valueProjection(x).reshaped(batch, length, keyValueHeads, headDimensions).transposed(0, 2, 1, 3)
        queries = rotated(queries, cos: cos, sin: sin)
        keys = rotated(keys, cos: cos, sin: sin)
        let (allKeys, allValues) = cache.update(keys: keys, values: values)
        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: allKeys, values: allValues, scale: scale, mask: length > 1 ? .causal : .none)
        return outProjection(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
    }
}

final class TextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    init(dimensions: Int, hidden: Int) {
        _gate.wrappedValue = Linear(dimensions, hidden, bias: false)
        _up.wrappedValue = Linear(dimensions, hidden, bias: false)
        _down.wrappedValue = Linear(hidden, dimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

final class TextLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: TextAttention
    @ModuleInfo var mlp: TextMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm

    init(_ configuration: PaddleOCRVLConfiguration) {
        _attention.wrappedValue = TextAttention(configuration)
        _mlp.wrappedValue = TextMLP(dimensions: configuration.hiddenSize, hidden: configuration.intermediateSize)
        _inputNorm.wrappedValue = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEpsilon)
        _postAttentionNorm.wrappedValue = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEpsilon)
    }

    func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray, cache: KeyValueCache) -> MLXArray {
        let h = x + attention(inputNorm(x), cos: cos, sin: sin, cache: cache)
        return h + mlp(postAttentionNorm(h))
    }
}

final class TextModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    let layers: [TextLayer]
    @ModuleInfo var norm: RMSNorm

    init(_ configuration: PaddleOCRVLConfiguration) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: configuration.vocabularySize, dimensions: configuration.hiddenSize)
        layers = (0..<configuration.layers).map { _ in TextLayer(configuration) }
        _norm.wrappedValue = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEpsilon)
    }
}

final class LanguageModel: Module {
    @ModuleInfo var model: TextModel
    @ModuleInfo(key: "lm_head") var head: Linear

    /// The head's frequencies, float32 (a leading underscore: not a weight).
    let _inverseFrequencies: MLXArray
    /// Of the frequencies, how many follow the time, the row, and the column, in that order.
    let sections: [Int]

    init(_ configuration: PaddleOCRVLConfiguration) {
        _model.wrappedValue = TextModel(configuration)
        _head.wrappedValue = Linear(configuration.hiddenSize, configuration.vocabularySize, bias: false)
        let dimensions = configuration.headDimensions
        _inverseFrequencies = 1 / pow(
            MLXArray(configuration.ropeTheta), MLXArray.arange(0, dimensions, step: 2).asType(.float32) / Float(dimensions))
        sections = configuration.ropeScaling.mropeSection
    }

    /// `positions`: [3, length] (time, row, column), the same in all three for text. The cos and sin of each
    /// position's angles, [1, 1, length, head dimensions], in `type`.
    func rotary(_ positions: MLXArray, type: DType) -> (MLXArray, MLXArray) {
        let angles = positions.asType(.float32).expandedDimensions(axis: -1) * _inverseFrequencies
        var start = 0
        var parts: [MLXArray] = []
        for (axis, count) in sections.enumerated() {
            parts.append(angles[axis, 0..., start..<(start + count)])
            start += count
        }
        let shared = concatenated(parts, axis: -1)
        let both = concatenated([shared, shared], axis: -1).expandedDimensions(axes: [0, 1])
        return (MLX.cos(both).asType(type), MLX.sin(both).asType(type))
    }

    /// The logits of the next token after each of `embeddings` ([1, length, dimensions]).
    func callAsFunction(_ embeddings: MLXArray, positions: MLXArray, caches: [KeyValueCache]) -> MLXArray {
        let (cos, sin) = rotary(positions, type: embeddings.dtype)
        var h = embeddings
        for (layer, cache) in zip(model.layers, caches) {
            h = layer(h, cos: cos, sin: sin, cache: cache)
        }
        return head(model.norm(h))
    }
}
