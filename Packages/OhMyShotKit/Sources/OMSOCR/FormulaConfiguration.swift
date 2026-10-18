import Foundation

/// How the formula pack reads, from its `config.json` (Tools/model-packs/formula_pack.py writes it): the picture's
/// preparation, the models' input and output names, and the tokens.
public struct FormulaConfiguration: Decodable, Sendable, Equatable {
    public var format: Int
    public var model: String
    /// "cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", or "all".
    public var computeUnits: String
    public var picture: Picture
    public var encoder: Encoder
    public var decoder: Decoder
    public var tokens: Tokens

    public struct Picture: Decodable, Sendable, Equatable {
        /// A picture whose border's mean gray (0-255) is below this is inverted first: the model reads dark ink on
        /// light paper.
        public var darkBorder: Int
        /// The margin cropped is what is lighter than this (0-255) once the gray is stretched to 0-255.
        public var cropGray: Float
        /// The model reads a `size` × `size` picture.
        public var size: Int
        /// The value of the pixels around the scaled picture, before normalization.
        public var padding: Int
        /// "RGB".
        public var channels: String
        public var mean: [Float]
        public var std: [Float]
    }

    public struct Encoder: Decodable, Sendable, Equatable {
        public var file: String
        public var input: String
        /// Each decoder layer's cross-attention keys and values.
        public var keys: String
        public var values: String
    }

    public struct Decoder: Decodable, Sendable, Equatable {
        public var file: String
        public var token: String
        public var position: String
        public var mask: String
        public var keys: String
        public var values: String
        /// The likeliest next token.
        public var next: String
        /// The decoder keeps the keys and values of this many steps: a reading ends within `cache` tokens.
        public var cache: Int
        public var start: Int
        public var end: Int
        public var repeats: Repeats
    }

    /// A reading ending in one run of at most `longest` tokens repeated `times` times over stops there: the model is
    /// reading something that isn't a formula.
    public struct Repeats: Decodable, Sendable, Equatable {
        public var times: Int
        public var longest: Int
    }

    public struct Tokens: Decodable, Sendable, Equatable {
        /// One token a line, in id order.
        public var file: String
        /// Ids below this are special tokens, left out of the text.
        public var special: Int
        /// "byteLevel": GPT-2's byte-level characters, each standing for a byte of the UTF-8 text.
        public var encoding: String
    }

    public static func load(from folder: URL) throws -> FormulaConfiguration {
        let configuration = try JSONDecoder().decode(FormulaConfiguration.self, from: Data(contentsOf: folder.appending(path: "config.json")))
        if let problem = configuration.problem { throw FormulaError.badPack(problem) }
        return configuration
    }

    /// Why the reader can't read with this configuration, or nil when it can.
    var problem: String? {
        guard format == 1 else { return "format \(format) is not 1" }
        guard picture.channels == "RGB", picture.mean.count == 3, picture.std.count == 3, picture.std.allSatisfy({ $0 > 0 }) else {
            return "the picture's normalization is not three RGB channels"
        }
        guard picture.size > 0, (0...255).contains(picture.padding) else { return "the picture's size or padding is out of range" }
        guard decoder.cache > 1, decoder.repeats.times > 1, decoder.repeats.longest > 0 else { return "the decoder's cache or repeats are out of range" }
        guard tokens.encoding == "byteLevel", tokens.special >= 0 else { return "tokens are not byte-level" }
        return nil
    }
}

public enum FormulaError: Error, Equatable {
    /// The pack's files can't be read as a formula pack.
    case badPack(String)
    /// A model gave an output of another shape or kind than the pack says.
    case unexpectedOutput(String)
}
