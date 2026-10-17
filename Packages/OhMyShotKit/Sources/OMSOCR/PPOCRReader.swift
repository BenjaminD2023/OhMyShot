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
/// straightened, scaled to the recognizer's height, padded up to one of its widths, and decoded (CTC): from the model's
/// probabilities in a pack of format 1, and from its features through the head (`PPOCRHead`) in one of format 2.
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
    private let head: PPOCRHead?

    init(configuration: PPOCRConfiguration, classes: [String], detector: MLModel, recognizer: MLModel, head: PPOCRHead? = nil) {
        self.configuration = configuration
        self.classes = classes
        self.detector = detector
        self.recognizer = recognizer
        self.head = head
    }

    /// The reader of the pack installed in `folder`, its models compiled into `folder/Compiled` the first time.
    public static func load(from folder: URL) async throws -> PPOCRReader {
        let configuration = try PPOCRConfiguration.load(from: folder)
        let classes = try PPOCRConfiguration.classes(in: folder, configuration)
        let head = try configuration.recognition.head.map { try PPOCRHead(contentsOf: folder.appending(path: $0.file), $0, classes: classes.count) }
        let units: MLComputeUnits = configuration.computeUnits == "cpuOnly" ? .cpuOnly : .cpuAndNeuralEngine
        async let detector = model(configuration.detection.file, in: folder, units: units)
        async let recognizer = model(configuration.recognition.file, in: folder, units: units)
        return try await PPOCRReader(configuration: configuration, classes: classes, detector: detector, recognizer: recognizer, head: head)
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

    /// A large picture is read in L1's pieces (`PictureText.pieces`), one at a time, and their lines put together as L1
    /// puts its own (`PieceMerge`): the pixels of a whole scrolling capture, 3346 × 47,000, would take 630 MB, and
    /// twice that scaled.
    public func recognize(_ image: CGImage) async throws -> OCRResult {
        try await recognize(width: image.width, height: image.height) { piece in PPOCRPixels(image, region: piece) }
    }

    /// The picture in the file at `url`: a tall PNG's pieces are read from the file a band at a time
    /// (`PictureText.Bands`), the picture never decoded whole; any other picture is decoded and read as above.
    public func recognize(fileAt url: URL) async throws -> OCRResult {
        if let bands = PictureText.Bands(fileAt: url) {
            do {
                return try await recognize(width: bands.width, height: bands.height) { piece in
                    try PPOCRPixels(width: Int(piece.width), height: Int(piece.height), space: bands.colorSpace) { context in
                        guard bands.draw(piece, into: context) else { throw PictureText.Bands.Ended() }
                    }
                }
            } catch is PictureText.Bands.Ended {
                // Decoded, the picture is read as far as ImageIO makes it out.
            }
        }
        return try await recognize(PictureText.image(at: url))
    }

    /// A `width` × `height` picture read in its pieces, `pixels` giving each piece's (in the piece's own coordinates).
    private func recognize(width: Int, height: Int, pixels: (CGRect) throws -> PPOCRPixels?) async throws -> OCRResult {
        let started = ContinuousClock.now
        let pieces = PictureText.pieces(width: width, height: height)
        guard pieces.count > 1 else {
            guard let original = try pixels(CGRect(x: 0, y: 0, width: width, height: height)) else { throw OCRError.unreadableImage }
            let lines = try await readPiece(original)
            return OCRResult(lines: lines, text: lines.map(\.text).joined(separator: "\n"), duration: ContinuousClock.now - started)
        }
        var readings: [[OCRLine]] = []
        for piece in pieces {
            try Task.checkCancellation()
            guard let original = try pixels(piece) else { throw OCRError.unreadableImage }
            readings.append(try await readPiece(original).map { $0.moved(by: piece.origin) })
        }
        let lines = ReadingOrder.sorted(PieceMerge.merged(readings, pieces: pieces, size: CGSize(width: width, height: height)))
        return OCRResult(lines: lines, text: lines.map(\.text).joined(separator: "\n"), duration: ContinuousClock.now - started)
    }

    /// Whether the reader reads a `width` × `height` picture as well as it reads at all: not when L1 would cut it
    /// across (`PictureText.isCutAcross`), which the reader would scale down to its widest instead, its text with it.
    public static func reads(width: Int, height: Int) -> Bool {
        !PictureText.isCutAcross(width: width, height: height)
    }

    /// The lines of one piece, in its pixels, in PaddleOCR's reading order.
    private func readPiece(_ original: PPOCRPixels) async throws -> [OCRLine] {
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
        return lines
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

        // The detector writes each band's map into an array of the reader's (Core ML's output backing), one for all the
        // piece's bands: given none, the footprint grew by about 40 MB with each prediction at 1280 × 4096, and came back
        // down only later (Docs/perf.md › M6 — The L2 reader on tall pictures).
        let mapType = detector.modelDescription.outputDescriptionsByName[detection.output]?.multiArrayConstraint?.dataType
        var backing: (shape: [Int], map: MLMultiArray)?
        var boxes: [[CGPoint]] = []
        for band in PPOCRGeometry.bands(height: scaledHeight, band: detection.band, overlap: detection.overlap) {
            try Task.checkCancellation()
            let bandHeight = band.bottom - band.top
            guard let shape = detection.shapes.filter({ $0[0] >= bandHeight && $0[1] >= scaledWidth }).min(by: { $0[0] * $0[1] < $1[0] * $1[1] }) else {
                throw PPOCRError.badPack("no detection shape holds \(bandHeight) × \(scaledWidth)")
            }
            let input = try MLMultiArray.planes(height: shape[0], width: shape[1], filledWith: detection.padding)
            scaled.write(rows: band.top..<band.bottom, into: input, mean: detection.mean, std: detection.std)
            let options = MLPredictionOptions()
            if let mapType, mapType == .float16 || mapType == .float32 {
                if backing?.shape != shape {
                    backing = (shape, try MLMultiArray(shape: [1, 1, NSNumber(value: shape[0]), NSNumber(value: shape[1])], dataType: mapType))
                }
                options.outputBackings = [detection.output: backing!.map]
            }
            let output = try await detector.prediction(from: MLDictionaryFeatureProvider(dictionary: [detection.input: MLFeatureValue(multiArray: input)]), options: options)
            guard let map = output.featureValue(for: detection.output)?.multiArrayValue, map.shape.count == 4,
                  map.shape[2].intValue == shape[0], map.shape[3].intValue == shape[1]
            else { throw PPOCRError.unexpectedOutput("detection output") }
            // The band's own part of the map, row by row.
            let part = try map.floats(rows: bandHeight, columns: scaledWidth)
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
        guard let values = output.featureValue(for: recognition.output)?.multiArrayValue, values.shape.count == 3 else {
            throw PPOCRError.unexpectedOutput("recognition output")
        }
        let steps = values.shape[1].intValue, count = values.shape[2].intValue
        if let head {
            guard count == head.inputs else { throw PPOCRError.unexpectedOutput("\(count) features for a head of \(head.inputs)") }
            return head.decode(try values.floats(), steps: steps, classes: classes, blank: recognition.blank)
        }
        guard count == classes.count else { throw PPOCRError.unexpectedOutput("\(count) classes for \(classes.count) characters") }
        return Self.decode(try values.floats(), steps: steps, classes: classes, blank: recognition.blank)
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
