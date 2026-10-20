import Foundation

/// PaddleOCR-VL's numbers, read from the pack's `config.json` (mlx-vlm's conversion of the Hugging Face model: the text
/// model's keys at the top level, the vision tower's under `vision_config`).
public struct PaddleOCRVLConfiguration: Decodable, Sendable {
    public struct Vision: Decodable, Sendable {
        public var hiddenSize: Int
        public var intermediateSize: Int
        public var layers: Int
        public var heads: Int
        public var channels: Int
        public var imageSize: Int
        public var patchSize: Int
        public var layerNormEpsilon: Float
        public var mergeSize: Int

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case intermediateSize = "intermediate_size"
            case layers = "num_hidden_layers"
            case heads = "num_attention_heads"
            case channels = "num_channels"
            case imageSize = "image_size"
            case patchSize = "patch_size"
            case layerNormEpsilon = "layer_norm_eps"
            case mergeSize = "spatial_merge_size"
        }
    }

    public struct Quantization: Decodable, Sendable {
        public var groupSize: Int
        public var bits: Int

        enum CodingKeys: String, CodingKey {
            case groupSize = "group_size"
            case bits
        }
    }

    public struct RopeScaling: Decodable, Sendable {
        /// How the rotary frequencies are shared out among the time, height, and width positions.
        public var mropeSection: [Int]

        enum CodingKeys: String, CodingKey {
            case mropeSection = "mrope_section"
        }
    }

    public var hiddenSize: Int
    public var intermediateSize: Int
    public var layers: Int
    public var heads: Int
    public var keyValueHeads: Int
    public var headDimensions: Int
    public var rmsNormEpsilon: Float
    public var vocabularySize: Int
    public var ropeTheta: Float
    public var ropeScaling: RopeScaling
    public var imageToken: Int
    public var visionStartToken: Int
    public var endToken: Int
    public var quantization: Quantization?
    public var vision: Vision

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case layers = "num_hidden_layers"
        case heads = "num_attention_heads"
        case keyValueHeads = "num_key_value_heads"
        case headDimensions = "head_dim"
        case rmsNormEpsilon = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case ropeTheta = "rope_theta"
        case ropeScaling = "rope_scaling"
        case imageToken = "image_token_id"
        case visionStartToken = "vision_start_token_id"
        case endToken = "eos_token_id"
        case quantization
        case vision = "vision_config"
    }
}
