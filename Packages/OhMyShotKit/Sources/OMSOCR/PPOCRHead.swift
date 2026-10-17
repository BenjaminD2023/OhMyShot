import Accelerate
import Foundation

/// The recognizer's last layer, applied on the CPU for a pack of format 2 (Docs/ocr.md › The recognizer's head on the
/// CPU): a linear map from each step's features to the classes' logits, then CTC over their softmax.
///
/// On the Neural Engine this layer's output, a probability for each of 18,710 classes at every step, crossed to the CPU
/// for the softmax, and Core ML kept that crossing's memory for every width a reader used: about 760 MB over the
/// twelve. Here it costs the weights, 9 MB, and a few megabytes while a line is read.
struct PPOCRHead: Sendable {
    let inputs: Int
    let classes: Int
    /// `inputs` × `classes`, row by row: the pack's weights turned, so steps × features times these are the logits.
    private let weights: [Float]
    private let biases: [Float]
    /// Steps multiplied at once.
    static let chunk = 32

    /// `weights` as the pack keeps them, `classes` × `inputs` row by row.
    init(weights: [Float], biases: [Float], inputs: Int) {
        precondition(inputs > 0 && weights.count == biases.count * inputs)
        self.inputs = inputs
        classes = biases.count
        var turned = [Float](repeating: 0, count: weights.count)
        vDSP_mtrans(weights, 1, &turned, 1, vDSP_Length(inputs), vDSP_Length(classes))
        self.weights = turned
        self.biases = biases
    }

    /// The head in the pack's `file`, refused unless it holds exactly the weights and biases `head` says, for as many
    /// classes as the pack has characters.
    init(contentsOf file: URL, _ head: PPOCRConfiguration.Head, classes: Int) throws {
        guard head.classes == classes else { throw PPOCRError.badPack("a head of \(head.classes) classes for \(classes) characters") }
        let data = try Data(contentsOf: file)
        let count = head.classes * head.inputs + head.classes
        guard data.count == count * 2 else { throw PPOCRError.badPack("\(head.file) holds \(data.count) bytes, not \(count * 2)") }
        var values = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            values.withUnsafeMutableBufferPointer { floats in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var to = vImage_Buffer(data: floats.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        let weightCount = head.classes * head.inputs
        self.init(weights: Array(values[..<weightCount]), biases: Array(values[weightCount...]), inputs: head.inputs)
    }

    /// CTC's greedy decoding of `steps` rows of `inputs` features, as `PPOCRReader.decode` over the head's softmax:
    /// each step's likeliest class is its largest logit, and its probability, worked out only at the steps kept, is
    /// 1 / Σ exp(logit − the largest).
    func decode(_ features: [Float], steps: Int, classes names: [String], blank: Int) -> (String, Double) {
        precondition(features.count >= steps * inputs)
        var text = "", total = 0.0, kept = 0, previous = -1
        let logits = UnsafeMutablePointer<Float>.allocate(capacity: min(Self.chunk, steps) * classes)
        defer { logits.deallocate() }
        features.withUnsafeBufferPointer { features in
            weights.withUnsafeBufferPointer { weights in
                var start = 0
                while start < steps {
                    let rows = min(Self.chunk, steps - start)
                    vDSP_mmul(features.baseAddress! + start * inputs, 1, weights.baseAddress!, 1, logits, 1,
                              vDSP_Length(rows), vDSP_Length(classes), vDSP_Length(inputs))
                    for row in 0..<rows {
                        let line = logits + row * classes
                        vDSP_vadd(line, 1, biases, 1, line, 1, vDSP_Length(classes))
                        var largest: Float = 0
                        var index: vDSP_Length = 0
                        vDSP_maxvi(line, 1, &largest, &index, vDSP_Length(classes))
                        let class_ = Int(index)
                        defer { previous = class_ }
                        guard class_ != blank, class_ != previous, class_ < names.count else { continue }
                        var shift = -largest
                        vDSP_vsadd(line, 1, &shift, line, 1, vDSP_Length(classes))
                        var count = Int32(classes)
                        vvexpf(line, line, &count)
                        var sum: Float = 0
                        vDSP_sve(line, 1, &sum, vDSP_Length(classes))
                        text += names[class_]
                        total += Double(1 / sum)
                        kept += 1
                    }
                    start += rows
                }
            }
        }
        return (text, kept > 0 ? total / Double(kept) : 0)
    }
}
