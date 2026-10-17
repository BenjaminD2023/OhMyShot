import CoreGraphics
import CoreML
import CoreText
import Foundation
import ImageIO
import OMSPixels
import Testing
import UniformTypeIdentifiers
@testable import OMSOCR

/// L2's reading (PPOCRReader): its geometry, decoding, and pixel work against what PaddleOCR and OpenCV do, and, with
/// a pack at hand (OMS_L2_PACK=<an installed pack's folder>), a page read end to end.
struct PPOCRTests {
    // MARK: Bands

    @Test func aRegionNoTallerThanABandIsOneBand() {
        #expect(PPOCRGeometry.bands(height: 1000, band: 1280, overlap: 256) == [.init(top: 0, bottom: 1000, coreTop: 0, coreBottom: 1000)])
    }

    @Test func bandsOverlapAndTheirCoresMeetHalfwayThroughEachOverlap() {
        let bands = PPOCRGeometry.bands(height: 3000, band: 1280, overlap: 256)
        #expect(bands.map(\.top) == [0, 1024, 1720])
        #expect(bands.allSatisfy { $0.bottom - $0.top == 1280 })
        #expect(bands.first?.coreTop == 0 && bands.last?.coreBottom == 3000)
        for (a, b) in zip(bands, bands.dropFirst()) {
            #expect(a.coreBottom == b.coreTop)
            #expect(a.coreBottom > b.top && a.coreBottom < a.bottom)
        }
    }

    // MARK: Rectangles

    @Test func theSmallestRectangleOfATurnedRectangleIsItself() {
        let angle = 30.0 * .pi / 180, center = CGPoint(x: 200, y: 100)
        let points = [(-50.0, -10.0), (50, -10), (50, 10), (-50, 10)].map { x, y in
            CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
        let rectangle = PPOCRGeometry.minimumAreaRectangle(points)
        #expect(abs(max(rectangle.width, rectangle.height) - 100) < 1e-6)
        #expect(abs(min(rectangle.width, rectangle.height) - 20) < 1e-6)
    }

    @Test func cornersComeTopLeftTopRightBottomRightBottomLeft() {
        let (box, shorter) = PPOCRGeometry.ordered([CGPoint(x: 100, y: 20), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20), CGPoint(x: 100, y: 0)], width: 100, height: 20)
        #expect(box == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 20), CGPoint(x: 0, y: 20)])
        #expect(shorter == 20)
    }

    @Test func unclippingGrowsEverySideByAreaTimesRatioOverPerimeter() {
        let box = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 20), CGPoint(x: 0, y: 20)]
        let grown = PPOCRGeometry.unclipped(box, ratio: 1.4)
        let distance = 2000 * 1.4 / 240
        #expect(abs(grown.width - (100 + 2 * distance)) < 1e-9)
        #expect(abs(grown.height - (20 + 2 * distance)) < 1e-9)
        #expect(abs(grown.corners[0].x + distance) < 1e-9 && abs(grown.corners[0].y + distance) < 1e-9)
    }

    @Test func boxesAreReadTopDownAndLeftFirstWithinTenPixels() {
        func box(_ x: CGFloat, _ y: CGFloat) -> [CGPoint] { [CGPoint(x: x, y: y), CGPoint(x: x + 50, y: y), CGPoint(x: x + 50, y: y + 20), CGPoint(x: x, y: y + 20)] }
        #expect(PPOCRGeometry.readingOrder([box(300, 100), box(10, 105)]).map { $0[0].x } == [10, 300])
        #expect(PPOCRGeometry.readingOrder([box(300, 100), box(10, 115)]).map { $0[0].x } == [300, 10])
    }

    // MARK: Finding boxes

    private let detection = PPOCRConfiguration.Detection(
        file: "det.mlpackage", input: "x", output: "prob", shortestSide: 736, maxWidth: 4096, multiple: 32, band: 1280, overlap: 256,
        shapes: [[640, 640]], channels: "BGR", mean: [0.485, 0.456, 0.406], std: [0.229, 0.224, 0.225], padding: 0,
        threshold: 0.2, boxThreshold: 0.45, unclipRatio: 1.4, minSize: 3, maxCandidates: 3000
    )

    @Test func aRegionOfTextBecomesItsGrownRectangleAndNoiseAndFaintRegionsDont() {
        let width = 200, height = 120
        var map = [Float](repeating: 0, count: width * height)
        func fill(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>, _ value: Float) {
            for y in ys { for x in xs { map[y * width + x] = value } }
        }
        fill(40...139, 30...49, 0.9)   // a line of text
        fill(5...6, 5...6, 0.9)        // a speck, too small
        fill(40...139, 80...99, 0.3)   // above the threshold, too faint
        let boxes = map.withUnsafeBufferPointer { PPOCRGeometry.boxes(in: $0, width: width, height: height, configuration: detection) }
        #expect(boxes.count == 1)
        // The pixels 40...139 × 30...49 (99 × 19 between centers), grown by 99 · 19 · 1.4 / 236 on every side.
        let grow = 99.0 * 19 * 1.4 / 236
        let expected = [(40 - grow, 30 - grow), (139 + grow, 30 - grow), (139 + grow, 49 + grow), (40 - grow, 49 + grow)].map { CGPoint(x: $0.0.rounded(), y: $0.1.rounded()) }
        #expect(boxes.first == expected)
    }

    @Test func aRowOfAUShapeSpansBothArms() {
        // Two arms joined at the bottom row.
        let width = 10, height = 4
        var map = [Float](repeating: 0, count: width * height)
        for y in 0..<4 { map[y * width + 1] = 1; map[y * width + 7] = 1 }
        for x in 1...7 { map[3 * width + x] = 1 }
        let regions = map.withUnsafeBufferPointer { BinaryComponents.components(of: $0, width: width, height: height, threshold: 0.5, limit: 10) }
        #expect(regions.count == 1)
        #expect(regions.first?.left == [1, 1, 1, 1] && regions.first?.right == [7, 7, 7, 7])
        #expect(regions.first?.count == 13)
    }

    @Test func theMeanInsideABoxCountsThePixelsItCovers() {
        let width = 20, height = 10
        var map = [Float](repeating: 0, count: width * height)
        for y in 2...5 { for x in 4...9 { map[y * width + x] = 1 } }
        let inside = map.withUnsafeBufferPointer { BinaryComponents.mean(of: $0, width: width, height: height, inside: [(4, 2), (9, 2), (9, 5), (4, 5)]) }
        #expect(inside == 1)
        let half = map.withUnsafeBufferPointer { BinaryComponents.mean(of: $0, width: width, height: height, inside: [(4, 2), (15, 2), (15, 5), (4, 5)]) }
        #expect(abs(half - 6.0 / 12) < 1e-9)
    }

    // MARK: Decoding

    @Test func ctcRunsRepeatsTogetherAndDropsBlanks() {
        let classes = ["", "a", "b", " "]
        // Steps' likeliest classes: a a blank b b space a.
        let likeliest = [1, 1, 0, 2, 2, 3, 1]
        var probabilities = [Float](repeating: 0.01, count: likeliest.count * classes.count)
        for (step, index) in likeliest.enumerated() { probabilities[step * classes.count + index] = 0.9 }
        let (text, score) = PPOCRReader.decode(probabilities, steps: likeliest.count, classes: classes, blank: 0)
        #expect(text == "ab a")
        #expect(abs(score - 0.9) < 1e-6)
    }

    @Test func theHeadDecodesAsTheProbabilitiesOfItsSoftmaxDo() {
        // A head of 3 inputs and 4 classes, over more steps than it multiplies at once.
        let classes = ["", "a", "b", " "], inputs = 3, steps = PPOCRHead.chunk * 2 + 7
        var state: UInt64 = 7
        func random() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24) * 4 - 2
        }
        let weights = (0..<classes.count * inputs).map { _ in random() }, biases = (0..<classes.count).map { _ in random() }
        let features = (0..<steps * inputs).map { _ in random() }
        var probabilities: [Float] = []
        for step in 0..<steps {
            let logits = (0..<classes.count).map { c in
                biases[c] + (0..<inputs).reduce(Float(0)) { $0 + weights[c * inputs + $1] * features[step * inputs + $1] }
            }
            let exps = logits.map { exp($0 - logits.max()!) }
            probabilities += exps.map { $0 / exps.reduce(0, +) }
        }
        let expected = PPOCRReader.decode(probabilities, steps: steps, classes: classes, blank: 0)
        let head = PPOCRHead(weights: weights, biases: biases, inputs: inputs)
        let (text, score) = head.decode(features, steps: steps, classes: classes, blank: 0)
        #expect(!expected.0.isEmpty)
        #expect(text == expected.0)
        #expect(abs(score - expected.1) < 1e-6)
        #expect(head.decode([], steps: 0, classes: classes, blank: 0) == ("", 0))
    }

    @Test func aHeadFileHoldsItsWeightsThenItsBiasesAsHalfFloats() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSPPOCRTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 2 classes of 2 inputs: weights [[1, 0], [0, 1]], biases [0.5, -0.5].
        let values: [Float16] = [1, 0, 0, 1, 0.5, -0.5]
        let file = folder.appending(path: "head.bin")
        try values.withUnsafeBytes { Data($0) }.write(to: file)
        let configuration = PPOCRConfiguration.Head(file: "head.bin", type: "float16", inputs: 2, classes: 2)
        let head = try PPOCRHead(contentsOf: file, configuration, classes: 2)
        // Features (3, 1): logits 3.5 and 0.5, so class 0 at 1 / (1 + e^-3).
        let (text, score) = head.decode([3, 1], steps: 1, classes: ["x", "y"], blank: 1)
        #expect(text == "x")
        #expect(abs(score - 1 / (1 + exp(-3))) < 1e-6)
        #expect(throws: PPOCRError.self) { try PPOCRHead(contentsOf: file, configuration, classes: 3) }
        var longer = configuration
        longer.inputs = 3
        #expect(throws: PPOCRError.self) { try PPOCRHead(contentsOf: file, longer, classes: 2) }
    }

    // MARK: Pixels, as OpenCV makes them

    @Test func bilinearScalingWeighsAsOpenCVDoes() {
        // One row, 0 and 100, doubled: OpenCV gives 0, 25, 75, 100.
        let source: [UInt8] = [0, 0, 0, 255, 100, 100, 100, 255]
        let scaled = source.withUnsafeBufferPointer { Resample.bilinear($0, width: 2, height: 1, toWidth: 4, toHeight: 1) }
        #expect(stride(from: 0, to: 16, by: 4).map { scaled[$0] } == [0, 25, 75, 100])
        let same = source.withUnsafeBufferPointer { Resample.bilinear($0, width: 2, height: 1, toWidth: 2, toHeight: 1) }
        #expect(same == source)
    }

    @Test func aQuarterTurnIsNumPysRot90() {
        // [[1, 2, 3], [4, 5, 6]] turned is [[3, 6], [2, 5], [1, 4]].
        let source: [UInt8] = [1, 2, 3, 4, 5, 6].flatMap { (value: UInt8) -> [UInt8] in [value, 0, 0, 255] }
        let turned = source.withUnsafeBufferPointer { Resample.turnedCounterclockwise($0, width: 3, height: 2) }
        #expect(stride(from: 0, to: 24, by: 4).map { turned[$0] } == [3, 6, 2, 5, 1, 4])
    }

    @Test func aCubicWarpByTheIdentityGivesThePictureBack() {
        var source: [UInt8] = []
        for i in 0..<(6 * 5) {
            source += [UInt8(i * 7 % 256), UInt8(i * 3 % 256), UInt8(i % 256), 255]
        }
        let warped = source.withUnsafeBufferPointer { Resample.warpCubic($0, width: 6, height: 5, matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1], toWidth: 6, toHeight: 5) }
        #expect(warped == source)
    }

    @Test func theHomographyTakesEachCornerToItsMatch() throws {
        let from = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 30), CGPoint(x: 0, y: 30)]
        let to = [CGPoint(x: 12, y: 40), CGPoint(x: 113, y: 44), CGPoint(x: 111, y: 75), CGPoint(x: 10, y: 71)]
        let m = try #require(PPOCRPixels.homography(from: from, to: to))
        for (p, q) in zip(from, to) {
            let w = m[6] * p.x + m[7] * p.y + m[8]
            #expect(abs((m[0] * p.x + m[1] * p.y + m[2]) / w - q.x) < 1e-6)
            #expect(abs((m[3] * p.x + m[4] * p.y + m[5]) / w - q.y) < 1e-6)
        }
    }

    @Test func aCropStraightensTheQuadAndKeepsItsTopUp() throws {
        // A picture 40 wide, 20 tall: the top half dark, the bottom light. Its left half cropped keeps dark on top.
        var bytes = [UInt8](repeating: 0, count: 40 * 20 * 4)
        for y in 0..<20 { for x in 0..<40 { let v: UInt8 = y < 10 ? 20 : 230; let o = (y * 40 + x) * 4; bytes[o] = v; bytes[o + 1] = v; bytes[o + 2] = v; bytes[o + 3] = 255 } }
        let picture = PPOCRPixels(width: 40, height: 20, bytes: bytes)
        let crop = try #require(picture.crop([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 20), CGPoint(x: 0, y: 20)], verticalRatio: 1.5))
        #expect(crop.width == 20 && crop.height == 20)
        #expect(crop.bytes[(2 * 20 + 10) * 4] < 60)
        #expect(crop.bytes[(17 * 20 + 10) * 4] > 200)
    }

    @Test func aRegionIsDrawnAsItsCropWouldBe() throws {
        // Pieces of a busy picture, drawn from the whole picture moved, byte for byte as from image.cropping(to:), in a
        // few of the formats a capture or a file can come in.
        let formats: [(CGColorSpace, UInt32, Int)] = [
            (CGColorSpace(name: CGColorSpace.displayP3)!, CGImageAlphaInfo.noneSkipLast.rawValue, 4),
            (CGColorSpace(name: CGColorSpace.sRGB)!, CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue, 4),
            (CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, CGImageAlphaInfo.none.rawValue, 1),
        ]
        let width = 300, height = 700
        for (space, info, components) in formats {
            var bytes = [UInt8](repeating: 0, count: width * height * components)
            var seed: UInt32 = 12345
            for i in bytes.indices {
                seed = seed &* 1_103_515_245 &+ 12345
                bytes[i] = UInt8(truncatingIfNeeded: seed >> 16)
            }
            if info & CGImageAlphaInfo.premultipliedFirst.rawValue != 0 {
                // Premultiplied: no channel above its pixel's alpha (the first byte in memory here is blue, the last alpha).
                for o in stride(from: 0, to: bytes.count, by: 4) { for k in 0..<3 { bytes[o + k] = min(bytes[o + k], bytes[o + 3]) } }
            }
            let image = try #require(bytes.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * components, space: space, bitmapInfo: info)?.makeImage()
            })
            for region in [CGRect(x: 0, y: 0, width: 300, height: 256), CGRect(x: 0, y: 200, width: 300, height: 500), CGRect(x: 40, y: 333, width: 170, height: 101)] {
                let drawn = try #require(PPOCRPixels(image, region: region))
                let crop = try #require(image.cropping(to: region))
                let cropped = try #require(PPOCRPixels(crop))
                #expect(drawn.width == cropped.width && drawn.height == cropped.height)
                #expect(drawn.bytes == cropped.bytes, "\(space.name.map { $0 as String } ?? "?") \(region)")
            }
        }
    }

    @Test func aMapsRowsAreReadWhereTheyAreInHalfAndSingleFloats() throws {
        // A 1 × 1 × 4 × 6 map whose rows lie 8 values apart; rows 0–2, columns 0–3 of it, as float32.
        let expected: [Float] = (0..<3).flatMap { row in (0..<4).map { Float(row * 10 + $0) } }
        for type in [MLMultiArrayDataType.float16, .float32] {
            let size = type == .float16 ? 2 : 4
            let memory = UnsafeMutableRawPointer.allocate(byteCount: 4 * 8 * size, alignment: 16)
            for row in 0..<4 {
                for column in 0..<8 {
                    let value = Float(row * 10 + column)
                    if type == .float16 { memory.storeBytes(of: Float16(value), toByteOffset: (row * 8 + column) * 2, as: Float16.self) } else {
                        memory.storeBytes(of: value, toByteOffset: (row * 8 + column) * 4, as: Float.self)
                    }
                }
            }
            let map = try MLMultiArray(dataPointer: memory, shape: [1, 1, 4, 6], dataType: type, strides: [32, 32, 8, 1]) { $0.deallocate() }
            #expect(try map.floats(rows: 3, columns: 4) == expected)
            #expect(throws: PPOCRError.self) { try map.floats(rows: 5, columns: 4) }
        }
    }

    // MARK: The pack's configuration

    private static let config = """
    {"format": 1, "model": "PP-OCRv6 small", "computeUnits": "cpuAndNeuralEngine",
     "detection": {"file": "det.mlpackage", "input": "x", "output": "prob", "shortestSide": 736, "maxWidth": 4096, "multiple": 32,
       "band": 1280, "overlap": 256, "shapes": [[640, 640], [640, 1280], [640, 2560], [640, 4096], [1280, 640], [1280, 1280], [1280, 2560], [1280, 4096]],
       "channels": "BGR", "mean": [0.485, 0.456, 0.406], "std": [0.229, 0.224, 0.225], "padding": 0,
       "threshold": 0.2, "boxThreshold": 0.45, "unclipRatio": 1.4, "minSize": 3, "maxCandidates": 3000},
     "recognition": {"file": "rec.mlpackage", "input": "x", "output": "probs", "height": 48,
       "widths": [160, 320, 480, 640, 800, 960, 1280, 1600, 2000, 2400, 3200, 4000], "channels": "BGR", "mean": [0.5, 0.5, 0.5], "std": [0.5, 0.5, 0.5],
       "padding": 0, "characters": "characters.txt", "blank": 0, "spaceAfterCharacters": true, "verticalRatio": 1.5}}
    """

    @Test func thePacksConfigurationReadsAndMakesSense() throws {
        let configuration = try JSONDecoder().decode(PPOCRConfiguration.self, from: Data(Self.config.utf8))
        #expect(configuration.problem == nil)
        #expect(configuration.detection.shapes.count == 8)
        var wrong = configuration
        wrong.detection.band = 2048
        #expect(wrong.problem != nil)
        wrong = configuration
        wrong.format = 3
        #expect(wrong.problem != nil)
        // Format 2: the recognizer ends at its features, and the pack has its head.
        let head = PPOCRConfiguration.Head(file: "head.bin", type: "float16", inputs: 120, classes: 18710)
        var second = configuration
        second.format = 2
        #expect(second.problem != nil)
        second.recognition.head = head
        #expect(second.problem == nil)
        second.recognition.head?.type = "float32"
        #expect(second.problem != nil)
        wrong = configuration
        wrong.recognition.head = head
        #expect(wrong.problem != nil)
        // The tallest and the widest shapes are different ones: a full band has no shape.
        wrong = configuration
        wrong.detection.shapes = [[1280, 640], [640, 4096]]
        #expect(wrong.problem != nil)
    }

    @Test func theClassesAreTheBlankTheCharactersAndASpace() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSPPOCRTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "a\nb\n字\n".write(to: folder.appending(path: "characters.txt"), atomically: true, encoding: .utf8)
        let configuration = try JSONDecoder().decode(PPOCRConfiguration.self, from: Data(Self.config.utf8))
        #expect(try PPOCRConfiguration.classes(in: folder, configuration) == ["", "a", "b", "字", " "])
    }

    // MARK: End to end, with a pack

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_L2_PACK"] != nil))
    func aDrawnPageReadsBack() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["OMS_L2_PACK"]!, directoryHint: .isDirectory)
        let reader = try await PPOCRReader.load(from: folder)
        let page = try #require(Self.page(["Model packs read text", "模型包在本机读字"]))
        let result = try await reader.recognize(page)
        let text = result.lines.map(\.text).joined(separator: "\n")
        #expect(result.lines.count == 2)
        #expect(text.replacingOccurrences(of: " ", with: "").contains("Modelpacksreadtext"))
        #expect(text.contains("模型包在本机读字"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_L2_PACK"] != nil))
    func aTallPNGReadsFromItsFileAsFromItsPicture() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["OMS_L2_PACK"]!, directoryHint: .isDirectory)
        let reader = try await PPOCRReader.load(from: folder)
        // 20 lines, 2860 pixels tall: two pieces, read from the file a band at a time (`PictureText.Bands`).
        let page = try #require(Self.page((1...20).map { "第\($0)行 模型包在本机读字 line \($0)" }))
        let url = FileManager.default.temporaryDirectory.appending(path: "l2-tall-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, page, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(PictureText.Bands(fileAt: url) != nil)

        let fromFile = try await reader.recognize(fileAt: url)
        let decoded = try await reader.recognize(PictureText.image(at: url))
        #expect(fromFile.lines.count == 20)
        #expect(fromFile.lines.map(\.text) == decoded.lines.map(\.text))
        #expect(fromFile.lines.map(\.box) == decoded.lines.map(\.box))
        #expect(fromFile.lines.map(\.confidence) == decoded.lines.map(\.confidence))
    }

    private static func page(_ lines: [String]) -> CGImage? {
        let width = 1200, height = 140 * lines.count + 60
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 56, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 60, y: CGFloat(height - 110 - index * 140))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()
    }
}
