import CoreGraphics
import Foundation
import ImageIO
import OMSOCR
import UniformTypeIdentifiers

/// Scores OhMyShot's OCR engines on the synthetic corpus.
///
///     swift run -c release --package-path Tools/ocr-bench ocr-bench [options]
///
/// Options:
///   --engine NAME      run only this engine (repeatable), including the probes; see --list
///   --case PREFIX      run only cases whose id starts with PREFIX (repeatable)
///   --real DIR         add real screenshots: DIR/NAME.png with its truth in DIR/NAME.txt (keep these
///                      outside the repository)
///   --save DIR         write each case's image and every engine's output to DIR
///   --pack DIR         also run L2 ("l2") with the PP-OCR model pack in DIR (Tools/model-packs/ppocr_pack.py), and L1
///                      with L2 beside it ("l1+l2")
///   --json PATH        write every run, outputs included, as JSON
///   --write-baseline   record this run as the baseline for this major macOS version
///   --list             list engines and cases, then exit
///   --trace            print how long each step and Vision request of L1 took, on standard error
///
/// Engines run one request at a time: Vision can stall when several accurate requests overlap. (The
/// `text-zh-en+en` probe runs two on purpose, to measure how Vision runs two models side by side.)
@main
struct OCRBench {
    private static let zhHans = Locale.Language(identifier: "zh-Hans")
    private static let zhHant = Locale.Language(identifier: "zh-Hant")
    private static let en = Locale.Language(identifier: "en-US")
    private static let ja = Locale.Language(identifier: "ja-JP")
    private static let ko = Locale.Language(identifier: "ko-KR")

    static let engines: [any OCREngine] = [
        VisionTextEngine(name: "text-zh-en", configuration: .init(languages: [zhHans, en]), timeout: timeout),
        VisionTextEngine(name: "text-auto", configuration: .init(automaticallyDetectsLanguage: true), timeout: timeout),
        VisionDocumentEngine(name: "documents", timeout: timeout),
        VisionPipeline(name: "l1", options: .init(
            primaryLanguages: [zhHans, en],
            fallbackLanguages: [[ko, en], [en]],
            timeout: timeout
        )),
    ]

    /// Generous, so a model loading on first use reads as slow rather than as a hang.
    private static let timeout = Duration.seconds(30)

    /// Single-purpose engines for questions about Vision itself (for example, whether the first
    /// language picks the model). They run only when named with --engine.
    static let probes: [any OCREngine] = [
        // Recovery in a fresh helper process; use only languages the older accurate model supports.
        VisionPipeline(name: "l1-compatible", options: .init(
            primaryLanguages: [zhHans, en], fallbackLanguages: [[en]], timeout: timeout,
            prefersCompatibilityRecognition: true
        )),
        // Every language in one request: scores exactly like text-zh-en (one model per request).
        VisionTextEngine(name: "text-cjk", configuration: .init(languages: [zhHans, zhHant, en, ja, ko]), timeout: timeout),
        VisionDocumentEngine(name: "documents-cjk", languages: [zhHans, zhHant, en, ja, ko], timeout: timeout),
        VisionTextEngine(name: "text-ko-first", configuration: .init(languages: [ko, zhHans, en]), timeout: timeout),
        VisionTextEngine(name: "text-ja-first", configuration: .init(languages: [ja, zhHans, en]), timeout: timeout),
        VisionTextEngine(name: "text-hant-first", configuration: .init(languages: [zhHant, en]), timeout: timeout),
        VisionTextEngine(name: "text-en", configuration: .init(languages: [en]), timeout: timeout),
        // The Chinese and the Latin model on the same image at once: does Vision run them side by side?
        ConcurrentProbe(
            name: "text-zh-en+en",
            first: VisionTextEngine(name: "zh-en", configuration: .init(languages: [zhHans, en]), timeout: timeout),
            second: VisionTextEngine(name: "en", configuration: .init(languages: [en]), timeout: timeout)
        ),
    ]

    static func main() async throws {
        let options = Options(CommandLine.arguments.dropFirst())
        let real = try options.realDirectory.map(Corpus.real(in:)) ?? []
        let corpus = (Corpus.all + real).filter { item in options.cases.isEmpty || options.cases.contains { item.id.hasPrefix($0) } }
        // L2 from a model pack's folder (Docs/ocr.md › The L2 pack), named "l2", and L1 with L2 beside it, "l1+l2".
        var packs: [any OCREngine] = []
        if let folder = options.packDirectory {
            let reader = try await PPOCRReader.load(from: folder)
            packs.append(reader)
            if let l1 = engines.first(where: { $0.name == "l1" }) as? VisionPipeline {
                packs.append(PairedReading(first: l1, second: reader))
            }
        }
        var selected = options.engines.isEmpty ? engines + packs : (engines + probes + packs).filter { options.engines.contains($0.name) }
        if options.trace {
            // Each step and Vision request of L1, on standard error.
            selected = selected.map { engine in
                guard var pipeline = engine as? VisionPipeline else { return engine }
                pipeline.options.trace = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
                return pipeline
            }
        }

        if options.list {
            print("Engines: " + engines.map(\.name).joined(separator: ", "))
            print("Probes: " + probes.map(\.name).joined(separator: ", "))
            print("Cases: " + Corpus.all.map { "\($0.id) (\($0.category.rawValue))" }.joined(separator: ", "))
            return
        }
        guard !corpus.isEmpty, !selected.isEmpty else {
            FileHandle.standardError.write(Data("No engines or cases match.\n".utf8))
            exit(1)
        }

        let environment = Environment.current
        let images = Dictionary(uniqueKeysWithValues: corpus.map { ($0.id, $0.render()) })
        if let directory = options.saveDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for item in corpus {
                try write(images[item.id]!, to: directory.appending(path: "\(item.id).png"))
                try item.truth.text.write(to: directory.appending(path: "\(item.id).truth.txt"), atomically: true, encoding: .utf8)
            }
        }

        var runs: [EngineRun] = []
        for engine in selected {
            FileHandle.standardError.write(Data("Running \(engine.name)…\n".utf8))
            // The first call loads models; it is timed apart so it does not skew the per-image numbers.
            let warmupStart = ContinuousClock.now
            _ = try? await engine.recognize(images[corpus[0].id]!)
            let warmup = ContinuousClock.now - warmupStart

            var cases: [CaseRun] = []
            for item in corpus {
                var run = CaseRun(id: item.id, category: item.category)
                var lineDetails: [String] = []
                if options.trace { FileHandle.standardError.write(Data("— \(item.id)\n".utf8)) }
                do {
                    let result = try await engine.recognize(images[item.id]!)
                    lineDetails = result.lines.map { line in
                        let box = line.box.integral
                        return "\(line.direction.map { "\($0)" } ?? "-")\t\(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))×\(Int(box.height))\t\(String(format: "%.2f", line.confidence))\t\(line.wrapsToNextLine.map { $0 ? "wraps" : "ends" } ?? "-")\t\(line.text)"
                    }
                    run.score = Metrics.score(result, against: item.truth, category: item.category)
                    run.milliseconds = result.duration.milliseconds
                    run.output = result.text
                    run.tables = result.tables.isEmpty ? nil : result.tables.map(\.rows)
                } catch {
                    run.error = String(describing: error)
                }
                if let directory = options.saveDirectory {
                    try (run.output ?? "error: \(run.error ?? "")").write(
                        to: directory.appending(path: "\(item.id).\(engine.name).txt"), atomically: true, encoding: .utf8)
                    try lineDetails.joined(separator: "\n").write(
                        to: directory.appending(path: "\(item.id).\(engine.name).lines.txt"), atomically: true, encoding: .utf8)
                }
                cases.append(run)
            }
            runs.append(EngineRun(engine: engine.name, warmupMilliseconds: warmup.milliseconds, cases: cases))
        }

        var regressions: [String] = []
        for run in runs {
            let url = baselineURL(engine: run.engine, major: environment.macOSMajor)
            if options.writeBaseline {
                let scores = Dictionary(uniqueKeysWithValues: run.cases.compactMap { item in item.score.map { (item.id, $0) } })
                let baseline = Baseline(macOS: environment.macOS, engine: run.engine, cases: scores)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(baseline).write(to: url)
            } else if let data = try? Data(contentsOf: url), let baseline = try? JSONDecoder().decode(Baseline.self, from: data) {
                regressions += Report.regressions(run, baseline: baseline)
            }
        }

        if let path = options.jsonPath {
            try encoder.encode(runs).write(to: path)
        }
        print(Report.markdown(runs: runs, corpus: corpus, environment: environment, regressions: regressions), terminator: "")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// `Tools/ocr-bench/baselines/<engine>-macos<major>.json`, next to this package.
    private static func baselineURL(engine: String, major: Int) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ocr-bench
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // package root
            .appending(path: "baselines/\(engine)-macos\(major).json")
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct Options {
    var engines: [String] = []
    var cases: [String] = []
    var saveDirectory: URL?
    var jsonPath: URL?
    var realDirectory: URL?
    /// An installed PP-OCR model pack, read as the "l2" engine.
    var packDirectory: URL?
    var writeBaseline = false
    var list = false
    /// Each step and Vision request of L1, on standard error.
    var trace = false

    init(_ arguments: ArraySlice<String>) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--engine": iterator.next().map { engines.append($0) }
            case "--case": iterator.next().map { cases.append($0) }
            case "--save": saveDirectory = iterator.next().map { URL(filePath: $0) }
            case "--json": jsonPath = iterator.next().map { URL(filePath: $0) }
            case "--real": realDirectory = iterator.next().map { URL(filePath: $0, directoryHint: .isDirectory) }
            case "--pack": packDirectory = iterator.next().map { URL(filePath: $0, directoryHint: .isDirectory) }
            case "--write-baseline": writeBaseline = true
            case "--list": list = true
            case "--trace": trace = true
            default: FileHandle.standardError.write(Data("Ignoring unknown option \(argument)\n".utf8))
            }
        }
    }
}

extension Environment {
    static var current: Environment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return Environment(
            date: formatter.string(from: .now),
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macOSMajor: version.majorVersion,
            textLanguages: VisionTextEngine.supportedLanguages.map(\.minimalIdentifier),
            documentLanguages: VisionDocumentEngine.supportedLanguages.map(\.minimalIdentifier)
        )
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}

/// Two engines on the same image at once; reports the first one's reading and the time both took.
struct ConcurrentProbe: OCREngine {
    let name: String
    let first: any OCREngine
    let second: any OCREngine

    @concurrent
    func recognize(_ image: CGImage) async throws -> OCRResult {
        let started = ContinuousClock.now
        async let a = first.recognize(image)
        async let b = second.recognize(image)
        let (result, _) = try await (a, b)
        return OCRResult(lines: result.lines, text: result.text, duration: ContinuousClock.now - started)
    }
}
