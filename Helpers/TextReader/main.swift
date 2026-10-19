// OhMyShot Text Reader: reads the text in pictures for Capture History's search, in a process of its own.
//
// Vision keeps its models and the memory a recognition used for as long as the process lives, and has no way
// to let them go (Docs/perf.md, M2). Reading every capture inside the app would keep a menu bar app that is
// otherwise 40 MB at 70 MB or more for good; this process takes that memory with it when it exits.
//
// The Shortcuts action Recognize Text in Image reads here too, for the same reason: the app then stays as small
// after it as before. So do Capture Formula and the formulas found among text: the formula pack's models take about
// 290 MB while they read.
//
// Input, on standard input: one JSON object per line, {"id": "…", "path": "/…/picture.png"}, and for a reading
// assembled as Capture Text assembles it, "joinsWrappedLines": true or false (without it, the text kept for the
// history's search). With "pack": "/…/Model Packs/<id>/<version>", a PP-OCR model pack reads beside Vision where the
// picture holds Chinese or Japanese (L2 beside L1, Docs/ocr.md › L2 beside L1); its models are loaded once a run, and
// a pack that won't load leaves Vision's reading alone. With "lines": true as well, the pack reads the picture alone
// and the answer holds its lines, for the app to put beside its own reading. With "warm": true and a pack (no path),
// the pack's models are loaded and nothing is read: their first load compiles them for the Neural Engine. With
// "formula": "/…/Model Packs/<id>/<version>" instead, the formula pack reads the picture as one formula (Capture Formula;
// Docs/ocr.md › The formula pack), and with "warm" its models are compiled. With "formulas": the formula pack's folder,
// the pack finds the formulas in the picture and reads each (Docs/ocr.md › Formulas among text): the answer holds them,
// after a line {"id": "…", "found": 3} saying how many there are to read; with "joinsWrappedLines" as well, the text is
// read as above and the formulas put into it, as LaTeX. With "tidy": true, nothing is read: what Core ML keeps in this
// process's Caches folder of models that are gone is removed (CompiledModelCache).
// Output, on standard output: one JSON object per line as each picture is read, in order,
// {"id": "…", "text": "…"}, {"id": "…", "lines": [{"text": "…", "box": [[x, y], [width, height]], "confidence": 0.9}]},
// {"id": "…", "latex": "…", "ending": "end"} (or "repeats", "cacheFull", "deadline": not a whole formula),
// {"id": "…", "formulas": [{"kind": "inline", "box": [[x, y], [width, height]], "latex": "…"}]},
// {"id": "…", "removed": 2}, or {"id": "…", "error": "…"}. The process exits once its input ends and every picture is
// read.

import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import OMSOCR

struct Job: Decodable {
    let id: String
    var path: String?
    var joinsWrappedLines: Bool?
    var pack: String?
    var lines: Bool?
    var warm: Bool?
    var formula: String?
    var formulas: String?
    var tidy: Bool?
}

struct Line: Encodable {
    let text: String
    let box: CGRect
    let confidence: Float
}

struct Formula: Encodable {
    let kind: String
    let box: CGRect
    let latex: String
}

struct Result: Encodable {
    let id: String
    var text: String?
    var lines: [Line]?
    var latex: String?
    var ending: String?
    var found: Int?
    var formulas: [Formula]?
    var removed: Int?
    var error: String?
}

let pipeline: VisionPipeline = {
    var options = VisionPipeline.Options.preferred()
    // A model's first use on this Mac can take seconds; nothing waits on this process.
    options.timeout = .seconds(60)
    return VisionPipeline(options: options)
}()

/// The packs' readers, loaded the first time a job names them.
var packReaders: [String: PPOCRReader] = [:]

func reader(for pack: String) async throws -> PPOCRReader {
    if let reader = packReaders[pack] { return reader }
    let reader = try await PPOCRReader.load(from: URL(filePath: pack, directoryHint: .isDirectory))
    packReaders[pack] = reader
    return reader
}

/// The formula packs' readers, loaded the first time a job names them.
var formulaReaders: [String: FormulaReader] = [:]

func formulaReader(for pack: String) async throws -> FormulaReader {
    if let reader = formulaReaders[pack] { return reader }
    let reader = try await FormulaReader.load(from: URL(filePath: pack, directoryHint: .isDirectory))
    formulaReaders[pack] = reader
    return reader
}

/// The formula packs' layout models, loaded the first time a job asks them to find formulas.
var layoutFinders: [String: LayoutFinder] = [:]

func layoutFinder(for pack: String) async throws -> LayoutFinder {
    if let finder = layoutFinders[pack] { return finder }
    let finder = try await LayoutFinder.load(from: URL(filePath: pack, directoryHint: .isDirectory))
    layoutFinders[pack] = finder
    return finder
}

/// The formulas the pack finds and reads in the picture in `file`, `found` told how many it found; none in a picture too
/// large to look in (`LayoutFinder.finds`), which isn't decoded for it.
func formulas(inPictureAt file: URL, pack: String, found: @escaping @Sendable (Int) -> Void) async throws -> (CGImage, [FormulaMerge.Formula])? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          LayoutFinder.finds(width: width, height: height)
    else {
        found(0)
        return nil
    }
    let image = try PictureText.image(at: file)
    let regions = try await layoutFinder(for: pack).regions(in: image)
    found(regions.count)
    // The formula models, 185 MB, are loaded only for a picture that holds a formula.
    guard !regions.isEmpty else { return (image, []) }
    return (image, try await formulaReader(for: pack).formulas(in: image, regions: regions))
}

/// L1, with the pack beside it when it loads.
func reading(with pack: String?) async -> any OCREngine {
    guard let pack else { return pipeline }
    do {
        return PairedReading(first: pipeline, second: try await reader(for: pack))
    } catch {
        FileHandle.standardError.write(Data("The pack at \(pack) didn't load: \(error)\n".utf8))
        return pipeline
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
let output = FileHandle.standardOutput

func send(_ result: Result) {
    guard var line = try? encoder.encode(result) else { return }
    line.append(0x0A)
    output.write(line)
}

for try await line in FileHandle.standardInput.bytes.lines {
    guard let job = try? JSONDecoder().decode(Job.self, from: Data(line.utf8)) else { continue }
    do {
        if job.tidy == true {
            // Core ML keeps its cache under the process's bundle identifier, which the Info.plist in this binary names.
            let removed = Bundle.main.bundleIdentifier.map { CompiledModelCache.removeStale(in: CompiledModelCache.folder(forBundleIdentifier: $0)) }
            send(Result(id: job.id, removed: removed?.count ?? 0))
            continue
        }
        if let pack = job.formula {
            let reader = try await formulaReader(for: pack)
            if job.warm == true {
                _ = try await layoutFinder(for: pack)
                send(Result(id: job.id, text: ""))
                continue
            }
            guard let path = job.path else { throw OCRError.unreadableImage }
            let reading = try await reader.read(fileAt: URL(filePath: path))
            send(Result(id: job.id, latex: reading.latex, ending: reading.ending.rawValue))
            continue
        }
        if job.warm == true, let pack = job.pack {
            _ = try await reader(for: pack)
            send(Result(id: job.id, text: ""))
            continue
        }
        guard let path = job.path else { throw OCRError.unreadableImage }
        let file = URL(filePath: path)
        if job.lines == true, let pack = job.pack {
            let lines = try await reader(for: pack).recognize(fileAt: file).lines
            send(Result(id: job.id, lines: lines.map { Line(text: $0.text, box: $0.box, confidence: $0.confidence) }))
            continue
        }
        if let pack = job.formulas, job.joinsWrappedLines == nil {
            let id = job.id
            let found = try await formulas(inPictureAt: file, pack: pack) { count in Task { @MainActor in send(Result(id: id, found: count)) } }
            send(Result(id: job.id, formulas: (found?.1 ?? []).map { Formula(kind: $0.kind.rawValue, box: $0.box, latex: $0.latex) }))
            continue
        }
        var result = try await reading(with: job.pack).recognize(fileAt: file)
        if let pack = job.formulas, let (image, found) = try await formulas(inPictureAt: file, pack: pack, found: { _ in }) {
            result.lines = await pipeline.lines(result.lines, with: found, in: image)
        }
        let text = job.joinsWrappedLines.map { TextAssembler.assemble(result.lines, options: .init(joinsWrappedLines: $0)) } ?? result.text
        send(Result(id: job.id, text: text))
    } catch {
        send(Result(id: job.id, error: String(describing: error)))
    }
}
