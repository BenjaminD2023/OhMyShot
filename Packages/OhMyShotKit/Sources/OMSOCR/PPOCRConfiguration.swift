import Foundation

/// How a PP-OCR model pack reads, from its `config.json` (Tools/model-packs/ppocr_pack.py writes it): every size,
/// threshold, and normalization the reader uses comes from here, so a pack with other shapes or bands needs no
/// change to the code.
public struct PPOCRConfiguration: Decodable, Sendable, Equatable {
    /// 1: the recognizer gives each class's probability at every step. 2: it gives its encoder's features, and the
    /// reader applies its last layer (`Recognition.head`) and the softmax (Docs/ocr.md › The recognizer's head on the CPU).
    public var format: Int
    public var model: String
    /// "cpuAndNeuralEngine" or "cpuOnly". Never the GPU, whose path fails on these models on macOS 27 beta.
    public var computeUnits: String
    public var detection: Detection
    public var recognition: Recognition

    public struct Detection: Decodable, Sendable, Equatable {
        public var file: String
        public var input: String
        public var output: String
        /// A region whose shorter side is shorter is scaled up to it first.
        public var shortestSide: Int
        /// A region wider (after that) is scaled down to it.
        public var maxWidth: Int
        /// Each side is then rounded to a multiple of this.
        public var multiple: Int
        /// The region is read in bands this tall, each reaching `overlap` into the next.
        public var band: Int
        public var overlap: Int
        /// The model's input sizes, height then width: a band is padded up to the smallest that holds it.
        public var shapes: [[Int]]
        /// "BGR": the model's channels in that order, each (value / 255 - mean) / std.
        public var channels: String
        public var mean: [Float]
        public var std: [Float]
        public var padding: Float
        public var threshold: Float
        public var boxThreshold: Double
        public var unclipRatio: Double
        public var minSize: Double
        public var maxCandidates: Int
    }

    public struct Recognition: Decodable, Sendable, Equatable {
        public var file: String
        public var input: String
        public var output: String
        public var height: Int
        /// The model's input widths: a line is padded up to the smallest that holds it, and narrowed to the last.
        public var widths: [Int]
        public var channels: String
        public var mean: [Float]
        public var std: [Float]
        public var padding: Float
        /// The pack's file of characters, one a line: class 1 is the first.
        public var characters: String
        public var blank: Int
        /// Whether the class after the last character is a space.
        public var spaceAfterCharacters: Bool
        /// A crop this many times taller than wide, or more, is vertical text, turned to lie as a line.
        public var verticalRatio: Double
        /// Format 2's last layer of the recognizer, which the model's output goes through to the classes.
        public var head: Head?
    }

    /// A linear map from `inputs` features at a step to the logits of `classes` classes: in `file`, the weights,
    /// `classes` × `inputs` row by row, then the `classes` biases, each a `type` ("float16": little-endian 16-bit floats).
    public struct Head: Decodable, Sendable, Equatable {
        public var file: String
        public var type: String
        public var inputs: Int
        public var classes: Int
    }

    /// The pack's configuration, refused when it is of a format this code doesn't know or makes no sense.
    public static func load(from folder: URL) throws -> PPOCRConfiguration {
        let configuration = try JSONDecoder().decode(PPOCRConfiguration.self, from: Data(contentsOf: folder.appending(path: "config.json")))
        if let problem = configuration.problem { throw PPOCRError.badPack(problem) }
        return configuration
    }

    var problem: String? {
        switch (format, recognition.head) {
        case (1, nil): break
        case (2, let head?):
            guard head.type == "float16", head.inputs > 0, head.classes > 0 else { return "a recognizer's head of no known kind" }
        case (1, _?): return "format 1 with a recognizer's head"
        case (2, nil): return "format 2 without a recognizer's head"
        default: return "format \(format) isn't known"
        }
        guard detection.channels == "BGR", recognition.channels == "BGR" else { return "only BGR channels are read" }
        guard detection.mean.count == 3, detection.std.count == 3, recognition.mean.count == 3, recognition.std.count == 3,
              (detection.std + recognition.std).allSatisfy({ $0 > 0 })
        else { return "normalization needs three means and three positive deviations" }
        guard !detection.shapes.isEmpty, detection.shapes.allSatisfy({ $0.count == 2 && $0[0] > 0 && $0[1] > 0 }) else { return "no detection shapes" }
        guard detection.multiple > 0, detection.band > detection.overlap, detection.overlap >= 0 else { return "bands don't fit" }
        // The largest band there can be, a band tall and maxWidth wide, needs a shape of its own.
        guard detection.shapes.contains(where: { $0[0] >= detection.band && $0[1] >= detection.maxWidth }) else {
            return "no shape holds a band \(detection.band) tall and \(detection.maxWidth) wide"
        }
        guard !recognition.widths.isEmpty, recognition.widths == recognition.widths.sorted(), recognition.height > 0 else { return "no recognition widths" }
        return nil
    }

    /// The characters of the pack's character file, class by class: the blank, the file's lines, and a space.
    public static func classes(in folder: URL, _ configuration: PPOCRConfiguration) throws -> [String] {
        let text = try String(contentsOf: folder.appending(path: configuration.recognition.characters), encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var classes = [""] + lines
        if configuration.recognition.spaceAfterCharacters { classes.append(" ") }
        return classes
    }
}

public enum PPOCRError: Error, Equatable {
    /// The pack's files can't be read as a PP-OCR pack.
    case badPack(String)
    /// The model gave an output of another shape or kind than the pack says.
    case unexpectedOutput(String)
}
