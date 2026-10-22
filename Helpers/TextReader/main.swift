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
// process's Caches folder of models that are gone is removed (CompiledModelCache). With "vlm": the VLM pack's folder,
// alone or beside "formulas", the tables and charts the layout model finds are read with the VLM too (Docs/ocr.md › The
// VLM pack), one layout run serving both packs: the answer holds them as rows of cells, and with "joinsWrappedLines"
// the text holds those that bear themselves out against Vision's reading, a row a line; "seconds" is how long the VLM
// may read before what is left stays as Vision read it. With the system's memory pressure past normal (or "pressure":
// "warning" or "critical" said for it), the VLM isn't loaded and the tables and charts stay as Vision read them, the
// answer saying how many with "tablesLeft". With "vlm" and "task": "ocr", "table", "formula", or "chart",
// the VLM reads the whole picture as that; with "warm" its model is loaded and nothing is read.
// Output, on standard output: one JSON object per line as each picture is read, in order,
// {"id": "…", "text": "…"}, {"id": "…", "lines": [{"text": "…", "box": [[x, y], [width, height]], "confidence": 0.9}]},
// {"id": "…", "latex": "…", "ending": "end"} (or "repeats", "cacheFull", "deadline": not a whole formula),
// {"id": "…", "found": 3, "foundTables": 1} first for those, {"id": "…", "formulas": [{"kind": "inline", "box": [[x, y], [width, height]], "latex": "…"}], "tables": [{"kind":
// "table", "box": …, "rows": [["…"]], "whole": true}], "tablesLeft": 1},
// {"id": "…", "removed": 2}, {"id": "…", "text": "…", "ending": "end"} (or "length", "stopped") for the VLM pack, or
// {"id": "…", "error": "…"}. The process exits once its input ends and every picture is
// read.
// With "visionCompatibility": true, the compatibility Vision pipeline reads the picture without any
// model packs. "visionLines" is the base64 JSON encoding of complete OMSOCR lines, retaining geometry,
// direction and wrapping metadata for the app's existing assembly and merge rules. "visionFormulas"
// optionally supplies already recognized formulas, merged with the same compatibility pipeline;
// "visionInputLines" may supply base64 JSON lines to preserve exact text already taken from apps.

import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import OMSOCR
import OMSVLM

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
    var vlm: String?
    var task: String?
    var seconds: Double?
    /// What to take the system's memory pressure to be, by name (`MemoryPressure`), rather than ask the kernel: for checking
    /// what happens when it is pressed.
    var pressure: String?
    var visionCompatibility: Bool?
    var visionFormulas: [TextReaderTool.FoundFormula]?
    var visionInputLines: Data?
}

nonisolated struct Line: Encodable {
    let text: String
    let box: CGRect
    let confidence: Float
}

nonisolated struct Formula: Encodable {
    let kind: String
    let box: CGRect
    let latex: String
}

nonisolated struct Table: Encodable {
    let kind: String
    let box: CGRect
    let rows: [[String]]
    let whole: Bool
}

nonisolated struct Result: Encodable {
    let id: String
    var text: String?
    var lines: [Line]?
    var visionLines: Data?
    var latex: String?
    var ending: String?
    var found: Int?
    /// Of `found`, how many are tables and charts.
    var foundTables: Int?
    var formulas: [Formula]?
    var tables: [Table]?
    /// Tables and charts found but left to Vision, the system being short of memory for the VLM.
    var tablesLeft: Int?
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

/// The VLM packs' readers, loaded the first time a job names them.
var vlmReaders: [String: PaddleOCRVLReader] = [:]

func vlmReader(for pack: String) throws -> PaddleOCRVLReader {
    if let reader = vlmReaders[pack] { return reader }
    let reader = try PaddleOCRVLReader.load(from: URL(filePath: pack, directoryHint: .isDirectory))
    vlmReaders[pack] = reader
    return reader
}

/// The VLM pack's layout model: the formula pack's own (the same file) with its kinds, as `layout.json` says them.
struct VLMLayout: Decodable {
    let layout: FormulaConfiguration.Layout
    let computeUnits: String
}

/// The layout models, loaded the first time a job asks them to find what its packs read: one model, from the formula pack
/// when there is one, finding the formula pack's kinds and the VLM pack's both.
var layoutFinders: [String: LayoutFinder] = [:]

func layoutFinder(formulas: String?, vlm: String?) async throws -> LayoutFinder {
    let key = "\(formulas ?? "")\n\(vlm ?? "")"
    if let finder = layoutFinders[key] { return finder }
    var found: (folder: String, layout: FormulaConfiguration.Layout, units: String)?
    if let formulas {
        let configuration = try FormulaConfiguration.load(from: URL(filePath: formulas, directoryHint: .isDirectory))
        found = (formulas, configuration.layout, configuration.computeUnits)
    }
    if let vlm {
        let own = try JSONDecoder().decode(VLMLayout.self, from: Data(contentsOf: URL(filePath: vlm).appending(path: "layout.json")))
        if found == nil {
            found = (vlm, own.layout, own.computeUnits)
        } else {
            found!.layout.classes.merge(own.layout.classes) { formula, _ in formula }
        }
    }
    guard let (folder, layout, units) = found else { throw OCRError.unreadableImage }
    let finder = try await LayoutFinder.load(from: URL(filePath: folder, directoryHint: .isDirectory), layout: layout, units: units)
    layoutFinders[key] = finder
    return finder
}

/// The formulas the formula pack reads and the tables and charts the VLM pack reads in the picture in `file`, as one
/// layout run finds them, `found` told how many formulas and how many tables there are to read; none in a picture too large to look in
/// (`LayoutFinder.finds`), which isn't decoded for it. The VLM reads until `seconds` have gone, and tables and charts
/// still waiting then are left out; with the system's memory `pressure` past normal, the VLM isn't loaded at all and
/// every table and chart is left out (`left`).
func elements(
    inPictureAt file: URL, formulas formulaPack: String?, vlm vlmPack: String?, seconds: Double?, pressure: MemoryPressure,
    found: @escaping @Sendable (Int, Int) -> Void
) async throws -> (image: CGImage, formulas: [FormulaMerge.Formula], tables: [TableMerge.Table], left: Int)? {
    let started = ContinuousClock.now
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          LayoutFinder.finds(width: width, height: height)
    else {
        found(0, 0)
        return nil
    }
    let image = try PictureText.image(at: file)
    let regions = try await layoutFinder(formulas: formulaPack, vlm: vlmPack).regions(in: image)
    let formulaRegions = formulaPack == nil ? [] : regions.filter(\.kind.isFormula)
    var tableRegions = vlmPack == nil ? [] : regions.filter { !$0.kind.isFormula }
    // The VLM's 2.6 GB would push other apps' memory out to disk when the system is short of it already.
    let left = pressure > .normal ? tableRegions.count : 0
    if left > 0 { tableRegions = [] }
    found(formulaRegions.count, tableRegions.count)
    // The formula models, 185 MB, are loaded only for a picture that holds a formula; the VLM, 1.1 GB, for one that holds a
    // table or chart.
    var formulas: [FormulaMerge.Formula] = []
    if let formulaPack, !formulaRegions.isEmpty {
        formulas = try await formulaReader(for: formulaPack).formulas(in: image, regions: formulaRegions)
    }
    var tables: [TableMerge.Table] = []
    if let vlmPack, !tableRegions.isEmpty {
        let reader = try vlmReader(for: vlmPack)
        let deadline = seconds.map { started + .milliseconds(Int($0 * 1000)) }
        for region in tableRegions {
            if let deadline, ContinuousClock.now >= deadline { break }
            let chart = region.kind == .chart
            guard let reading = try reader.read(image, region: region.box, task: chart ? .chart : .table, deadline: deadline) else { continue }
            let rows = chart ? TableText.rows(chart: reading.text) : TableText.rows(otsl: reading.text)
            tables.append(TableMerge.Table(kind: chart ? .chart : .table, box: region.box, rows: rows, isWhole: reading.ending == .end))
        }
    }
    return (image, formulas, tables, left)
}

/// The system's memory pressure, or what the job says to take it to be.
func pressure(for job: Job) -> MemoryPressure {
    job.pressure.flatMap(MemoryPressure.init(name:)) ?? MemoryPressure.current()
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

/// A line written at once, from whatever is running: how many formulas and tables there are to read goes out before
/// they are read, while the VLM keeps this actor busy.
nonisolated func sendNow(_ result: Result) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard var line = try? encoder.encode(result) else { return }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

func send(_ result: Result) {
    guard var line = try? encoder.encode(result) else { return }
    line.append(0x0A)
    output.write(line)
}

for try await line in FileHandle.standardInput.bytes.lines {
    guard let job = try? JSONDecoder().decode(Job.self, from: Data(line.utf8)) else { continue }
    do {
        if job.visionCompatibility == true {
            guard let path = job.path else { throw OCRError.unreadableImage }
            var options = VisionPipeline.Options.preferred()
            options.timeout = .seconds(30)
            options.overallTimeout = .seconds(30)
            options.prefersCompatibilityRecognition = true
            let recovery = VisionPipeline(options: options)
            let lines: [OCRLine]
            if let formulas = job.visionFormulas, !formulas.isEmpty {
                let image = try PictureText.image(at: URL(filePath: path))
                let input: [OCRLine]
                if let encoded = job.visionInputLines {
                    input = try JSONDecoder().decode([OCRLine].self, from: encoded)
                } else {
                    input = try await recovery.recognize(image).lines
                }
                lines = await recovery.lines(input, with: formulas.map { formula in
                    FormulaMerge.Formula(kind: formula.kind == "display" ? .display : .inline, box: formula.box, latex: formula.latex)
                }, in: image)
            } else {
                lines = try await recovery.recognize(fileAt: URL(filePath: path)).lines
            }
            send(Result(id: job.id, visionLines: try JSONEncoder().encode(lines)))
            continue
        }
        if job.tidy == true {
            // Core ML keeps its cache under the process's bundle identifier, which the Info.plist in this binary names.
            let removed = Bundle.main.bundleIdentifier.map { CompiledModelCache.removeStale(in: CompiledModelCache.folder(forBundleIdentifier: $0)) }
            send(Result(id: job.id, removed: removed?.count ?? 0))
            continue
        }
        if let pack = job.vlm, job.task != nil || job.warm == true {
            let reader = try vlmReader(for: pack)
            if job.warm == true {
                send(Result(id: job.id, text: ""))
                continue
            }
            guard let path = job.path, let task = job.task.flatMap(PaddleOCRVLReader.Task.init(rawValue:)) else { throw OCRError.unreadableImage }
            let reading = try reader.read(fileAt: URL(filePath: path), task: task)
            send(Result(id: job.id, text: reading.text, ending: reading.ending.rawValue))
            continue
        }
        if let pack = job.formula {
            let reader = try await formulaReader(for: pack)
            if job.warm == true {
                _ = try await layoutFinder(formulas: pack, vlm: nil)
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
        if job.formulas != nil || job.vlm != nil, job.joinsWrappedLines == nil {
            let id = job.id
            let found = try await elements(
                inPictureAt: file, formulas: job.formulas, vlm: job.vlm, seconds: job.seconds, pressure: pressure(for: job)
            ) { formulas, tables in
                sendNow(Result(id: id, found: formulas + tables, foundTables: tables))
            }
            send(Result(
                id: job.id,
                formulas: (found?.formulas ?? []).map { Formula(kind: $0.kind.rawValue, box: $0.box, latex: $0.latex) },
                tables: (found?.tables ?? []).map { Table(kind: $0.kind.rawValue, box: $0.box, rows: $0.rows, whole: $0.isWhole) },
                tablesLeft: found.map { $0.left > 0 ? $0.left : nil } ?? nil
            ))
            continue
        }
        var result = try await reading(with: job.pack).recognize(fileAt: file)
        if job.formulas != nil || job.vlm != nil,
           let found = try await elements(
               inPictureAt: file, formulas: job.formulas, vlm: job.vlm, seconds: job.seconds, pressure: pressure(for: job), found: { _, _ in }
           ) {
            if !found.formulas.isEmpty { result.lines = await pipeline.lines(result.lines, with: found.formulas, in: found.image) }
            if !found.tables.isEmpty {
                let picture = CGRect(x: 0, y: 0, width: found.image.width, height: found.image.height)
                result.lines = TableMerge.merged(result.lines, with: found.tables, in: picture).lines
            }
        }
        let text = job.joinsWrappedLines.map { TextAssembler.assemble(result.lines, options: .init(joinsWrappedLines: $0)) } ?? result.text
        send(Result(id: job.id, text: text))
    } catch {
        send(Result(id: job.id, error: String(describing: error)))
    }
}
