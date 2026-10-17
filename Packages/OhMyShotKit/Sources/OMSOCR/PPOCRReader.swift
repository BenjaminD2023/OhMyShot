import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// L2: PP-OCR's text detection and recognition from a model pack (Docs/ocr.md › The L2 pack), read as
/// Tools/model-packs/ppocr_pack.py checks it. Every size and threshold comes from the pack's `config.json`.
///
/// The region is scaled (its shorter side up to `shortestSide`, its width down to `maxWidth`, each side to a multiple of
/// 32) and read in bands; each band is padded up to one of the detector's shapes, and its probabilities become boxes
/// (DBPostProcess). A box belongs to the band whose core holds its center. Each box is cut out of the region as it was,
/// straightened, scaled to the recognizer's height, padded up to one of its widths, and decoded (CTC).
///
/// The models are compiled once into the pack's own folder (`Compiled/`), never to a temporary place: the Neural Engine
/// keeps what it compiles for a model by its path, so only the first load of a pack takes seconds.
public final class PPOCRReader: OCREngine, @unchecked Sendable {
    public let name = "l2"
    public let configuration: PPOCRConfiguration
    let classes: [String]
    // MLModel predictions may run from any thread; the reader asks one at a time.
    private let detector: MLModel
    private let recognizer: MLModel

    init(configuration: PPOCRConfiguration, classes: [String], detector: MLModel, recognizer: MLModel) {
        self.configuration = configuration
        self.classes = classes
        self.detector = detector
        self.recognizer = recognizer
    }

    /// The reader of the pack installed in `folder`, its models compiled into `folder/Compiled` the first time.
    public static func load(from folder: URL) async throws -> PPOCRReader {
        let configuration = try PPOCRConfiguration.load(from: folder)
        let classes = try PPOCRConfiguration.classes(in: folder, configuration)
        let units: MLComputeUnits = configuration.computeUnits == "cpuOnly" ? .cpuOnly : .cpuAndNeuralEngine
        async let detector = model(configuration.detection.file, in: folder, units: units)
        async let recognizer = model(configuration.recognition.file, in: folder, units: units)
        return try await PPOCRReader(configuration: configuration, classes: classes, detector: detector, recognizer: recognizer)
    }

    private static func model(_ file: String, in folder: URL, units: MLComputeUnits) async throws -> MLModel {
        let compiledFolder = folder.appending(path: "Compiled", directoryHint: .isDirectory)
        let compiled = compiledFolder.appending(path: (file as NSString).deletingPathExtension + ".mlmodelc", directoryHint: .isDirectory)
        let manager = FileManager.default
        if !manager.fileExists(atPath: compiled.path(percentEncoded: false)) {
            let made = try await MLModel.compileModel(at: folder.appending(path: file))
            try manager.createDirectory(at: compiledFolder, withIntermediateDirectories: true)
            do {
                try manager.moveItem(at: made, to: compiled)
            } catch where manager.fileExists(atPath: compiled.path(percentEncoded: false)) {
                // Compiled meanwhile by another reader: that one is kept.
                try? manager.removeItem(at: made)
            }
        }
        let options = MLModelConfiguration()
        options.computeUnits = units
        return try await MLModel.load(contentsOf: compiled, configuration: options)
    }

    // MARK: Reading

    public func recognize(_ image: CGImage) async throws -> OCRResult {
        let started = ContinuousClock.now
        guard let original = PPOCRPixels(image) else { throw OCRError.unreadableImage }
        var lines: [OCRLine] = []
        for box in try await detect(original) {
            try Task.checkCancellation()
            guard let crop = original.crop(box, verticalRatio: configuration.recognition.verticalRatio) else { continue }
            let (text, score) = try await read(crop)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let xs = box.map(\.x), ys = box.map(\.y)
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            lines.append(OCRLine(text: text, box: bounds, confidence: Float(score)))
        }
        return OCRResult(lines: lines, text: lines.map(\.text).joined(separator: "\n"), duration: ContinuousClock.now - started)
    }

    /// The text boxes in `image`, in reading order, in its pixels.
    func detect(_ image: PPOCRPixels) async throws -> [[CGPoint]] {
        let detection = configuration.detection
        let width = image.width, height = image.height
        var scale = min(width, height) < detection.shortestSide ? Double(detection.shortestSide) / Double(min(width, height)) : 1
        scale = min(scale, Double(detection.maxWidth) / Double(width))
        func rounded(_ side: Int) -> Int {
            max(Int((Double(side) * scale / Double(detection.multiple)).rounded(.toNearestOrEven)) * detection.multiple, detection.multiple)
        }
        let scaledWidth = rounded(width), scaledHeight = rounded(height)
        let scaled = image.scaled(width: scaledWidth, height: scaledHeight)
        let sx = CGFloat(scaledWidth) / CGFloat(width), sy = CGFloat(scaledHeight) / CGFloat(height)

        var boxes: [[CGPoint]] = []
        for band in PPOCRGeometry.bands(height: scaledHeight, band: detection.band, overlap: detection.overlap) {
            try Task.checkCancellation()
            let bandHeight = band.bottom - band.top
            guard let shape = detection.shapes.filter({ $0[0] >= bandHeight && $0[1] >= scaledWidth }).min(by: { $0[0] * $0[1] < $1[0] * $1[1] }) else {
                throw PPOCRError.badPack("no detection shape holds \(bandHeight) × \(scaledWidth)")
            }
            let input = try MLMultiArray.planes(height: shape[0], width: shape[1], filledWith: detection.padding)
            scaled.write(rows: band.top..<band.bottom, into: input, mean: detection.mean, std: detection.std)
            let output = try await detector.prediction(from: MLDictionaryFeatureProvider(dictionary: [detection.input: MLFeatureValue(multiArray: input)]))
            guard let map = output.featureValue(for: detection.output)?.multiArrayValue, map.shape.count == 4,
                  map.shape[2].intValue == shape[0], map.shape[3].intValue == shape[1]
            else { throw PPOCRError.unexpectedOutput("detection output") }
            // The band's own part of the map, row by row.
            let full = try map.floats()
            var part = [Float](repeating: 0, count: bandHeight * scaledWidth)
            for row in 0..<bandHeight {
                part.replaceSubrange(row * scaledWidth..<(row + 1) * scaledWidth, with: full[(row * shape[1])..<(row * shape[1] + scaledWidth)])
            }
            let found = part.withUnsafeBufferPointer { PPOCRGeometry.boxes(in: $0, width: scaledWidth, height: bandHeight, configuration: detection) }
            for box in found {
                let center = box.map(\.y).reduce(0, +) / 4 + CGFloat(band.top)
                guard CGFloat(band.coreTop) <= center, center < CGFloat(band.coreBottom) else { continue }
                boxes.append(box.map { CGPoint(x: $0.x / sx, y: ($0.y + CGFloat(band.top)) / sy) })
            }
        }
        return PPOCRGeometry.readingOrder(boxes)
    }

    /// The text of one straightened line, and its mean probability.
    func read(_ crop: PPOCRPixels) async throws -> (String, Double) {
        let recognition = configuration.recognition
        let widest = recognition.widths.last!
        let width = min(Int((Double(recognition.height) * Double(crop.width) / Double(crop.height)).rounded(.up)), widest)
        let padded = recognition.widths.first { $0 >= width } ?? widest
        let line = crop.scaled(width: max(width, 1), height: recognition.height)
        let input = try MLMultiArray.planes(height: recognition.height, width: padded, filledWith: recognition.padding)
        line.write(rows: 0..<line.height, into: input, mean: recognition.mean, std: recognition.std)
        let output = try await recognizer.prediction(from: MLDictionaryFeatureProvider(dictionary: [recognition.input: MLFeatureValue(multiArray: input)]))
        guard let probabilities = output.featureValue(for: recognition.output)?.multiArrayValue, probabilities.shape.count == 3 else {
            throw PPOCRError.unexpectedOutput("recognition output")
        }
        let steps = probabilities.shape[1].intValue, count = probabilities.shape[2].intValue
        guard count == classes.count else { throw PPOCRError.unexpectedOutput("\(count) classes for \(classes.count) characters") }
        return Self.decode(try probabilities.floats(), steps: steps, classes: classes, blank: recognition.blank)
    }

    /// CTC's greedy decoding: each step's likeliest class, repeats of one class run together, blanks dropped; the mean of
    /// the kept steps' probabilities.
    static func decode(_ probabilities: [Float], steps: Int, classes: [String], blank: Int) -> (String, Double) {
        var text = "", total = 0.0, kept = 0, previous = -1
        probabilities.withUnsafeBufferPointer { values in
            for step in 0..<steps {
                var best: Float = 0
                var index: vDSP_Length = 0
                vDSP_maxvi(values.baseAddress! + step * classes.count, 1, &best, &index, vDSP_Length(classes.count))
                let class_ = Int(index)
                defer { previous = class_ }
                guard class_ != blank, class_ != previous, class_ < classes.count else { continue }
                text += classes[class_]
                total += Double(best)
                kept += 1
            }
        }
        return (text, kept > 0 ? total / Double(kept) : 0)
    }
}
