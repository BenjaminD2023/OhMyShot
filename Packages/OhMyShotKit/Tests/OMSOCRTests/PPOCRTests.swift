import CoreGraphics
import CoreText
import Foundation
import OMSPixels
import Testing
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
        wrong.format = 2
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
