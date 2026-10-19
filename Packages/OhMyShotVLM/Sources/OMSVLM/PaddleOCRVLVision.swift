import MLX
import MLXNN

// PaddleOCR-VL's vision tower (a SigLIP encoder that takes pictures at their own size), as mlx-vlm 0.7.4 has it
// (models/paddleocr_vl/vision.py), for one picture: one segment, so its attention needs no mask. Weight names are
// mlx-vlm's, which its conversion wrote: query, key, and value in one `qkv`, the patch convolution channels last.

/// Each position's angle per frequency, in float32 as mlx-vlm computes it, then the query or key turned by it.
func rotated(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
    let half = x.dim(-1) / 2
    let turned = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
    return x * cos + turned * sin
}

final class VisionEmbeddings: Module {
    @ModuleInfo(key: "patch_embedding") var patchEmbedding: Conv2d
    @ModuleInfo(key: "position_embedding") var positionEmbedding: Embedding

    /// The side of the grid the position embeddings were learned on: 27 for 384-pixel pictures of 14-pixel patches.
    let side: Int

    init(_ configuration: PaddleOCRVLConfiguration.Vision) {
        side = configuration.imageSize / configuration.patchSize
        _patchEmbedding.wrappedValue = Conv2d(
            inputChannels: configuration.channels, outputChannels: configuration.hiddenSize,
            kernelSize: .init(configuration.patchSize), stride: .init(configuration.patchSize)
        )
        _positionEmbedding.wrappedValue = Embedding(embeddingCount: side * side, dimensions: configuration.hiddenSize)
    }

    /// `patches`: [count, channels, patch, patch] in the patch convolution's type, row by row of the grid.
    func callAsFunction(_ patches: MLXArray, height: Int, width: Int) -> MLXArray {
        let type = patchEmbedding.weight.dtype
        let embedded = patchEmbedding(patches.transposed(0, 2, 3, 1)).asType(type)
        return embedded.reshaped(patches.dim(0), -1) + positions(height: height, width: width)
    }

    /// The learned grid of position embeddings stretched to `height` × `width` patches (mlx-vlm's
    /// `bilinear_interpolate`, corners not aligned), in the order of the patches.
    func positions(height: Int, width: Int) -> MLXArray {
        let table = positionEmbedding(MLXArray.arange(side * side))
        let dimensions = table.dim(-1)
        func samples(_ count: Int) -> MLXArray {
            count == 1 ? MLXArray([Float(0)]) : (MLXArray.arange(count).asType(.float32) + 0.5) * Float(side) / Float(count) - 0.5
        }
        let rows = samples(height), columns = samples(width)
        let rowFloor = floor(rows).asType(.int32), columnFloor = floor(columns).asType(.int32)
        let top = clip(rowFloor, min: 0, max: side - 1), bottom = clip(rowFloor + 1, min: 0, max: side - 1)
        let left = clip(columnFloor, min: 0, max: side - 1), right = clip(columnFloor + 1, min: 0, max: side - 1)
        // From the clipped floors, as mlx-vlm has it: a sample before the first row weighs that row past one.
        let rowWeight = (rows - top).reshaped(height, 1, 1)
        let columnWeight = (columns - left).reshaped(1, width, 1)
        func gather(_ row: MLXArray, _ column: MLXArray) -> MLXArray {
            let index = row.reshaped(height, 1) * side + column.reshaped(1, width)
            return take(table, index.reshaped(-1), axis: 0).reshaped(height, width, dimensions)
        }
        let result = (1 - rowWeight) * (1 - columnWeight) * gather(top, left)
            + (1 - rowWeight) * columnWeight * gather(top, right)
            + rowWeight * (1 - columnWeight) * gather(bottom, left)
            + rowWeight * columnWeight * gather(bottom, right)
        return result.asType(table.dtype).reshaped(-1, dimensions)
    }
}

final class VisionAttention: Module {
    @ModuleInfo var qkv: Linear
    @ModuleInfo(key: "out_proj") var outProjection: Linear

    let heads: Int
    let scale: Float

    init(dimensions: Int, heads: Int) {
        self.heads = heads
        scale = 1 / Float(dimensions / heads).squareRoot()
        _qkv.wrappedValue = Linear(dimensions, dimensions * 3, bias: true)
        _outProjection.wrappedValue = Linear(dimensions, dimensions, bias: true)
    }

    /// `x`: [length, dimensions]; `cos`, `sin`: [1, length, 1, head dimensions] in float32.
    func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        let length = x.dim(0)
        let parts = qkv(x.expandedDimensions(axis: 0)).reshaped(1, length, 3, heads, -1).transposed(2, 0, 1, 3, 4)
        let type = parts.dtype
        let queries = rotated(parts[0], cos: cos, sin: sin).asType(type).transposed(0, 2, 1, 3)
        let keys = rotated(parts[1], cos: cos, sin: sin).asType(type).transposed(0, 2, 1, 3)
        let values = parts[2].transposed(0, 2, 1, 3)
        let output = MLXFast.scaledDotProductAttention(queries: queries, keys: keys, values: values, scale: scale, mask: .none)
        return outProjection(output.transposed(0, 2, 1, 3).reshaped(length, -1))
    }
}

final class VisionMLP: Module {
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear

    init(dimensions: Int, hidden: Int) {
        _fc1.wrappedValue = Linear(dimensions, hidden)
        _fc2.wrappedValue = Linear(hidden, dimensions)
    }

    /// GELU's tanh approximation (mlx-vlm's `approx="precise"`, the model's `gelu_pytorch_tanh`).
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        fc2(geluApproximate(fc1(x)))
    }
}

final class VisionLayer: Module {
    @ModuleInfo(key: "layer_norm1") var norm1: LayerNorm
    @ModuleInfo(key: "layer_norm2") var norm2: LayerNorm
    @ModuleInfo(key: "self_attn") var attention: VisionAttention
    @ModuleInfo var mlp: VisionMLP

    init(_ configuration: PaddleOCRVLConfiguration.Vision) {
        _norm1.wrappedValue = LayerNorm(dimensions: configuration.hiddenSize, eps: 1e-6)
        _norm2.wrappedValue = LayerNorm(dimensions: configuration.hiddenSize, eps: 1e-6)
        _attention.wrappedValue = VisionAttention(dimensions: configuration.hiddenSize, heads: configuration.heads)
        _mlp.wrappedValue = VisionMLP(dimensions: configuration.hiddenSize, hidden: configuration.intermediateSize)
    }

    func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        let h = x + attention(norm1(x), cos: cos, sin: sin)
        return h + mlp(norm2(h))
    }
}

/// Four neighboring patches (2 × 2) into one of the language model's embeddings.
final class VisionProjector: Module {
    @ModuleInfo(key: "pre_norm") var norm: LayerNorm
    @ModuleInfo(key: "linear_1") var linear1: Linear
    @ModuleInfo(key: "linear_2") var linear2: Linear

    let mergeSize: Int

    init(dimensions: Int, output: Int, mergeSize: Int) {
        self.mergeSize = mergeSize
        let merged = dimensions * mergeSize * mergeSize
        _norm.wrappedValue = LayerNorm(dimensions: dimensions, eps: 1e-6)
        _linear1.wrappedValue = Linear(merged, merged, bias: true)
        _linear2.wrappedValue = Linear(merged, output, bias: true)
    }

    func callAsFunction(_ x: MLXArray, height: Int, width: Int) -> MLXArray {
        let x = norm(x)
        let dimensions = x.dim(-1)
        let blocks = x.reshaped(1, height / mergeSize, mergeSize, width / mergeSize, mergeSize, dimensions)
            .transposed(0, 1, 3, 2, 4, 5)
            .reshaped((height / mergeSize) * (width / mergeSize), mergeSize * mergeSize * dimensions)
        return linear2(gelu(linear1(blocks)))
    }
}

final class VisionModel: Module {
    @ModuleInfo var embeddings: VisionEmbeddings
    let layers: [VisionLayer]
    @ModuleInfo(key: "post_layernorm") var postNorm: LayerNorm
    @ModuleInfo var projector: VisionProjector

    let headDimensions: Int

    init(_ configuration: PaddleOCRVLConfiguration.Vision, output: Int) {
        headDimensions = configuration.hiddenSize / configuration.heads
        _embeddings.wrappedValue = VisionEmbeddings(configuration)
        layers = (0..<configuration.layers).map { _ in VisionLayer(configuration) }
        _postNorm.wrappedValue = LayerNorm(dimensions: configuration.hiddenSize, eps: configuration.layerNormEpsilon)
        _projector.wrappedValue = VisionProjector(
            dimensions: configuration.hiddenSize, output: output, mergeSize: configuration.mergeSize)
    }

    /// The angles of each patch's row and column: half the head's frequencies turn with the row, half with the
    /// column ([count, head dimensions / 2], float32).
    func rotaryAngles(height: Int, width: Int) -> MLXArray {
        let dimensions = headDimensions / 2
        let inverse = 1 / pow(MLXArray(Float(10000)), MLXArray.arange(0, dimensions, step: 2, dtype: .float32) / Float(dimensions))
        let table = outer(MLXArray.arange(max(height, width)).asType(.float32), inverse)
        let index = MLXArray.arange(height * width)
        let rows = take(table, floorDivide(index, width), axis: 0)
        let columns = take(table, remainder(index, width), axis: 0)
        return concatenated([rows, columns], axis: -1)
    }

    /// The picture's embeddings for the language model, [(height / 2) × (width / 2), output].
    func callAsFunction(_ patches: MLXArray, height: Int, width: Int) -> MLXArray {
        var x = embeddings(patches, height: height, width: width)
        let angles = rotaryAngles(height: height, width: width)
        let cos = tiled(MLX.cos(angles).expandedDimensions(axis: 1), repetitions: [1, 1, 2]).expandedDimensions(axis: 0)
        let sin = tiled(MLX.sin(angles).expandedDimensions(axis: 1), repetitions: [1, 1, 2]).expandedDimensions(axis: 0)
        for layer in layers {
            x = layer(x, cos: cos, sin: sin)
        }
        return projector(postNorm(x), height: height, width: width)
    }
}
