import CoreGraphics
import Foundation
import OMSPixels
import Testing
@testable import OMSOCR

/// L3's formula reading (FormulaReader): the picture's preparation, the tokens' text, and the tidying, against
/// transformers' PPFormulaNetProcessor and Tools/l3-spike/formula_picture.py; and with the corpus at hand, end to end:
/// OMS_FORMULA_CORPUS=<Tools/l3-spike's renders> with OMS_FORMULA_PIXELS=<formula_picture.py --dump's folder> compares
/// the prepared pictures, and with OMS_FORMULA_PACK=<an installed pack's folder> reads every picture, writing the LaTeX
/// to OMS_FORMULA_READINGS (a JSON file Tools/l3-spike/score.py scores) when it is set.
struct FormulaTests {
    // MARK: Tokens and text

    @Test func tokensAreByteLevelCharacters() {
        // "中" is E4 B8 AD: E4 and B8 stand for themselves, AD (not printable) for U+0143; "Ġ" is a space.
        let tokens = FormulaTokens(tokens: ["<s>", "<pad>", "</s>", "Ġx", "ä¸Ń", "Ġ="], special: 3)
        #expect(tokens.text(of: [0, 3, 5, 4, 2]) == " x =中")
        #expect(tokens.text(of: [4, 3]) == "中 x")
        // Bytes that make no character are U+FFFD, as the tokenizer's decoder gives them.
        #expect(FormulaTokens(tokens: ["<s>", "ä¸"], special: 1).text(of: [1]) == "\u{FFFD}")
    }

    @Test func everyByteHasACharacter() {
        #expect(FormulaTokens.byteOfScalar.count == 256)
        #expect(Set(FormulaTokens.byteOfScalar.values).count == 256)
        #expect(FormulaTokens.byteOfScalar["Ġ"] == 0x20 && FormulaTokens.byteOfScalar["Ċ"] == 0x0A && FormulaTokens.byteOfScalar["!"] == 0x21)
    }

    /// The pack's check's readings (formula-texts.json): the app's decoding and tidying give upstream's text for each.
    @Test func theCheckedReadingsDecodeAsUpstreamDecodesThem() throws {
        let url = try #require(Bundle.module.url(forResource: "Resources/formula-texts", withExtension: "json"))
        let fixture = try JSONDecoder().decode(TextFixture.self, from: Data(contentsOf: url))
        let top = try #require(fixture.tokens.keys.compactMap(Int.init).max())
        var tokens = [String](repeating: "", count: top + 1)
        for (id, token) in fixture.tokens { tokens[Int(id)!] = token }
        let decoder = FormulaTokens(tokens: tokens, special: fixture.special)
        #expect(fixture.cases.count == 200)
        for item in fixture.cases {
            #expect(FormulaText.tidy(decoder.text(of: item.ids)) == item.text, "\(item.case)")
        }
    }

    private struct TextFixture: Decodable {
        let special: Int
        let tokens: [String: String]
        let cases: [Case]

        struct Case: Decodable {
            let `case`: String
            let ids: [Int]
            let text: String
        }
    }

    /// Upstream's own results for these (PPFormulaNetProcessor.post_process_generation).
    @Test func tidyingTakesOutTheSpacesUpstreamTakesOut() {
        #expect(FormulaText.tidy("x ^ { 2 } + y ^ { 2 }") == "x^{2}+y^{2}")
        #expect(FormulaText.tidy(#"\text { 速 度 } = \frac { a } { b }"#) == #" 速 度 =\frac{a}{b}"#)
        #expect(FormulaText.tidy(#"\mathrm { d } x + "q""#) == #"\mathrm{d}x+q"#)
        #expect(FormulaText.tidy(#"\operatorname { s i n } \alpha x"#) == #"\operatorname{s i n}\alpha x"#)
        #expect(FormulaText.tidy(#"a \quad b"#) == #"a\quad b"#)
        #expect(FormulaText.tidy(#"\mathrm {\alpha x} y"#) == #"\mathrm{\alpha x}y"#)
    }

    @Test func aReadingThatRepeatsItselfIsCaught() {
        let run = [5, 6, 7]
        let looping = [1, 2] + Array(repeating: run, count: 8).flatMap { $0 }
        #expect(FormulaTokens.repeats(looping, times: 8, longest: 64))
        #expect(!FormulaTokens.repeats([1, 2] + Array(repeating: run, count: 7).flatMap { $0 }, times: 8, longest: 64))
        // A run longer than `longest` isn't looked for.
        let long = Array(28..<56)
        #expect(FormulaTokens.repeats(Array(repeating: long, count: 8).flatMap { $0 }, times: 8, longest: 64))
        #expect(!FormulaTokens.repeats(Array(repeating: long, count: 8).flatMap { $0 }, times: 8, longest: 24))
        // A formula's own repeats (x_{1}, x_{2}, ...) don't end in one run said over and over.
        #expect(!FormulaTokens.repeats([10, 11, 1, 12, 10, 11, 2, 12, 10, 11, 3, 12], times: 8, longest: 64))
        #expect(!FormulaTokens.repeats([], times: 8, longest: 64))
    }

    @Test func onlyAWholeReadingIsAFormula() {
        #expect(FormulaReading(latex: "x^{2}", ids: [1], ending: .end).isFormula)
        #expect(!FormulaReading(latex: " ", ids: [1], ending: .end).isFormula)
        #expect(!FormulaReading(latex: "x^{2}", ids: [1], ending: .repeats).isFormula)
        #expect(!FormulaReading(latex: "x^{2}", ids: [1], ending: .deadline).isFormula)
    }

    // MARK: The picture

    /// Tools/l3-spike/formula_picture.py's `resample` of the same 6 × 4 picture.
    @Test func resamplingIsPILs() {
        var bytes: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<6 { bytes += [UInt8(x * 40 + y * 7), UInt8(255 - x * 30), UInt8((x * y * 23) % 256), 255] }
        }
        let up = bytes.withUnsafeBufferPointer { Resample.antialiased($0, width: 6, height: 4, toWidth: 9, toHeight: 5, filter: .bilinear) }
        let down = bytes.withUnsafeBufferPointer { Resample.antialiased($0, width: 6, height: 4, toWidth: 3, toHeight: 2, filter: .bicubic) }
        let rgb: ([UInt8]) -> [Int] = { pixels in stride(from: 0, to: pixels.count, by: 4).flatMap { pixels[$0..<($0 + 3)].map(Int.init) } }
        #expect(rgb(up) == [
            0, 255, 0, 20, 240, 0, 47, 220, 0, 73, 200, 0, 100, 180, 0, 127, 160, 0, 153, 140, 0, 180, 120, 0, 200, 105, 0,
            5, 255, 0, 25, 240, 8, 52, 220, 19, 78, 200, 29, 105, 180, 41, 132, 160, 51, 158, 140, 62, 185, 120, 73, 205, 105, 81,
            11, 255, 0, 31, 240, 18, 58, 220, 41, 84, 200, 63, 111, 180, 87, 138, 160, 110, 164, 140, 132, 191, 120, 156, 211, 105, 173,
            16, 255, 0, 36, 240, 27, 63, 220, 62, 89, 200, 97, 116, 180, 132, 143, 160, 155, 169, 140, 139, 196, 120, 161, 216, 105, 188,
            21, 255, 0, 41, 240, 35, 68, 220, 81, 94, 200, 126, 121, 180, 173, 148, 160, 176, 174, 140, 51, 201, 120, 55, 221, 105, 89,
        ])
        #expect(rgb(down) == [26, 239, 7, 104, 180, 35, 182, 121, 69, 39, 239, 32, 117, 180, 130, 195, 121, 138])
    }

    /// The sizes transformers' processor goes through: the shorter side to 768, then to fit 768 × 768.
    @Test func picturesAreScaledAsTheProcessorScalesThem() {
        func sizes(_ width: Int, _ height: Int) -> [[Int]] {
            FormulaPicture.scales(width: width, height: height, size: 768).map { [$0.1.width, $0.1.height] }
        }
        #expect(sizes(146, 50) == [[2242, 768], [768, 263]])
        #expect(sizes(50, 146) == [[768, 2242], [263, 768]])
        #expect(sizes(443, 110) == [[3092, 768], [768, 190]])
        #expect(sizes(300, 300) == [[768, 768]])
        #expect(sizes(768, 768) == [])
        // 16 times as wide as tall: straight to the processor's final size, not through a strip 12288 wide.
        #expect(sizes(1600, 100) == [[768, 48]])
        #expect(FormulaPicture.scales(width: 1600, height: 100, size: 768).map(\.0) == [.bicubic])
    }

    @Test func aDarkPictureIsInvertedAndItsInkBoxed() throws {
        // 12 × 8, dark gray, with a light 3 × 2 mark at (5, 4).
        var bytes = [UInt8](repeating: 0, count: 12 * 8 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = 30; bytes[i + 1] = 30; bytes[i + 2] = 30; bytes[i + 3] = 255 }
        for y in 4..<6 {
            for x in 5..<8 { let i = (y * 12 + x) * 4; bytes[i] = 230; bytes[i + 1] = 230; bytes[i + 2] = 230 }
        }
        #expect(FormulaPicture.isDark(bytes, width: 12, height: 8, below: 128))
        let inverted = FormulaPixels.inverted(bytes)
        #expect(!FormulaPicture.isDark(inverted, width: 12, height: 8, below: 128))
        #expect(inverted[3] == 255 && inverted[0] == 225)
        let box = try #require(FormulaPixels.inkBox(inverted, width: 12, height: 8, threshold: 200))
        #expect(box.x == 5 && box.y == 4 && box.width == 3 && box.height == 2)
        // One shade: nothing to crop.
        #expect(FormulaPixels.inkBox([UInt8](repeating: 200, count: 16), width: 2, height: 2, threshold: 200) == nil)
    }

    @Test func planesAreCenteredAndNormalized() {
        // 2 × 1 pixels, red then blue, in a 4 × 4 frame: at (1, 1) and (2, 1).
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let values = FormulaPixels.planes(bytes, width: 2, height: 1, size: 4, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5], padding: 0)
        #expect(values.count == 48)
        #expect(values[0] == -1)                  // padding: (0 - 0.5) / 0.5
        #expect(values[1 * 4 + 1] == 1)           // red plane, the red pixel
        #expect(values[1 * 4 + 2] == -1)          // red plane, the blue pixel
        #expect(values[32 + 1 * 4 + 2] == 1)      // blue plane, the blue pixel
    }

    @Test func theShippedConfigurationIsUsable() throws {
        let configuration = try Self.shippedConfiguration()
        #expect(configuration.problem == nil)
        #expect(configuration.picture.size == 768 && configuration.decoder.cache == 1024 && configuration.tokens.special == 23)
        #expect(configuration.layout.size == 800 && configuration.layout.classes == ["display": 5, "inline": 15])
        var other = configuration
        other.format = 1
        #expect(other.problem != nil)
        other = configuration
        other.tokens.encoding = "sentencepiece"
        #expect(other.problem != nil)
        other = configuration
        other.layout.classes = ["display": 5]
        #expect(other.problem != nil)
    }

    // MARK: End to end, with a pack

    @Test(.enabled(if: environment["OMS_FORMULA_PACK"] != nil))
    func formulasReadBack() async throws {
        let reader = try await FormulaReader.load(from: URL(filePath: Self.environment["OMS_FORMULA_PACK"]!, directoryHint: .isDirectory))
        // The pack's check read these so (formula-texts.json); the dark one is inverted first.
        let expected = [
            "f03_s2": #"x={\frac{-b\pm{\sqrt{b^{2}-4a c}}}{2a}}"#,
            "f31_s2": #" 速度 =\frac{ 路程 }{ 时间 }"#,
            "f23_d2": #" Attention(Q,K,V)=softmax\left(\frac{QK^T}{\sqrt{d_k}}\right)V"#,
        ]
        for (name, latex) in expected {
            let url = try #require(Bundle.module.url(forResource: "Resources/Formulas/\(name)", withExtension: "png"))
            let reading = try await reader.read(fileAt: url)
            #expect(reading.ending == .end, "\(name)")
            #expect(reading.latex == latex, "\(name)")
        }
    }

    @Test(.enabled(if: environment["OMS_FORMULA_PACK"] != nil))
    func aReadingStopsAtItsDeadline() async throws {
        let reader = try await FormulaReader.load(from: URL(filePath: Self.environment["OMS_FORMULA_PACK"]!, directoryHint: .isDirectory))
        let url = try #require(Bundle.module.url(forResource: "Resources/Formulas/f03_s2", withExtension: "png"))
        // Past the deadline once the encoder is done: the first token is the last.
        let reading = try await reader.read(fileAt: url, deadline: .milliseconds(1))
        #expect(reading.ending == .deadline)
        #expect(reading.ids.count == 1)
        #expect(!reading.isFormula)
    }

    // MARK: With the corpus

    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["OMS_FORMULA_CORPUS"] != nil && environment["OMS_FORMULA_PIXELS"] != nil))
    func picturesArePreparedAsTheSpikePreparesThem() throws {
        let corpus = URL(filePath: Self.environment["OMS_FORMULA_CORPUS"]!, directoryHint: .isDirectory)
        let dumps = URL(filePath: Self.environment["OMS_FORMULA_PIXELS"]!, directoryHint: .isDirectory)
        let picture = try Self.shippedConfiguration().picture
        let names = try FileManager.default.contentsOfDirectory(atPath: dumps.path()).filter { $0.hasSuffix(".f32") }.sorted()
        #expect(!names.isEmpty)
        var worst: Float = 0, differing = 0, total = 0
        for name in names {
            let stem = String(name.dropLast(4))
            let theirs = try Data(contentsOf: dumps.appending(path: name)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let image = try PictureText.image(at: corpus.appending(path: stem + ".png"))
            let mine = try #require(FormulaPicture.values(of: image, picture))
            #expect(mine.count == theirs.count, "\(stem)")
            for (a, b) in zip(mine, theirs) where a != b {
                worst = max(worst, abs(a - b))
                differing += 1
            }
            total += theirs.count
        }
        print("prepared pictures: \(names.count), \(differing) of \(total) values differ, by \(worst) at most")
        // One step of 8 bits (1/255/std = 0.0226) on a value now and then, from rounding the filters' weights.
        #expect(worst <= 0.0226 * 1.01)
        #expect(Double(differing) / Double(total) < 0.0001)
    }

    @Test(.enabled(if: environment["OMS_FORMULA_CORPUS"] != nil && environment["OMS_FORMULA_PACK"] != nil))
    func theCorpusReadsEndToEnd() async throws {
        let corpus = URL(filePath: Self.environment["OMS_FORMULA_CORPUS"]!, directoryHint: .isDirectory)
        let reader = try await FormulaReader.load(from: URL(filePath: Self.environment["OMS_FORMULA_PACK"]!, directoryHint: .isDirectory))
        let names = try FileManager.default.contentsOfDirectory(atPath: corpus.path()).filter { $0.wholeMatch(of: /f\d\d_[a-z]\d\.png/) != nil }.sorted()
        #expect(!names.isEmpty)
        var readings: [String: String] = [:], times: [Duration] = []
        for name in names {
            let started = ContinuousClock.now
            let reading = try await reader.read(fileAt: corpus.appending(path: name))
            times.append(ContinuousClock.now - started)
            #expect(reading.ending == .end, "\(name): \(reading.ending)")
            readings[String(name.dropLast(4))] = reading.latex
        }
        times.sort()
        print("read \(names.count) formulas: p50 \(times[times.count / 2]), p95 \(times[times.count * 95 / 100])")
        if let out = Self.environment["OMS_FORMULA_READINGS"] {
            try JSONSerialization.data(withJSONObject: readings, options: [.sortedKeys]).write(to: URL(filePath: out))
        }
    }

    static func shippedConfiguration() throws -> FormulaConfiguration {
        try JSONDecoder().decode(FormulaConfiguration.self, from: Data(shippedConfigurationJSON.utf8))
    }

    /// The pack's config.json, version 2.
    static let shippedConfigurationJSON = """
    {
      "format": 2, "model": "PP-FormulaNet_plus-L", "computeUnits": "cpuOnly",
      "picture": {"darkBorder": 128, "cropGray": 200, "size": 768, "padding": 0, "channels": "RGB",
                  "mean": [0.7931, 0.7931, 0.7931], "std": [0.1738, 0.1738, 0.1738]},
      "encoder": {"file": "encoder.mlpackage", "input": "pixel_values", "keys": "cross_k", "values": "cross_v"},
      "decoder": {"file": "decoder.mlpackage", "token": "ids", "position": "pos", "mask": "mask", "keys": "cross_k",
                  "values": "cross_v", "next": "next", "cache": 1024, "start": 2, "end": 2, "repeats": {"times": 8, "longest": 64}},
      "tokens": {"file": "tokens.txt", "special": 23, "encoding": "byteLevel"},
      "layout": {"file": "layout.mlpackage", "input": "pixel_values", "size": 800, "logits": "logits", "boxes": "boxes",
                 "classes": {"display": 5, "inline": 15}, "threshold": 0.5}
    }
    """
}
