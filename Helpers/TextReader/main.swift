// OhMyShot Text Reader: reads the text in pictures for Capture History's search, in a process of its own.
//
// Vision keeps its models and the memory a recognition used for as long as the process lives, and has no way
// to let them go (Docs/perf.md, M2). Reading every capture inside the app would keep a menu bar app that is
// otherwise 40 MB at 70 MB or more for good; this process takes that memory with it when it exits.
//
// The Shortcuts action Recognize Text in Image reads here too, for the same reason: the app then stays as small
// after it as before.
//
// Input, on standard input: one JSON object per line, {"id": "…", "path": "/…/picture.png"}, and for a reading
// assembled as Capture Text assembles it, "joinsWrappedLines": true or false (without it, the text kept for the
// history's search). With "pack": "/…/Model Packs/<id>/<version>", a PP-OCR model pack reads beside Vision where the
// picture holds Chinese or Japanese (L2 beside L1, Docs/ocr.md › L2 beside L1); its models are loaded once a run, and
// a pack that won't load leaves Vision's reading alone. With "lines": true as well, the pack reads the picture alone
// and the answer holds its lines, for the app to put beside its own reading. With "warm": true and a pack (no path),
// the pack's models are loaded and nothing is read: their first load compiles them for the Neural Engine.
// Output, on standard output: one JSON object per line as each picture is read, in order,
// {"id": "…", "text": "…"}, {"id": "…", "lines": [{"text": "…", "box": [[x, y], [width, height]], "confidence": 0.9}]},
// or {"id": "…", "error": "…"}. The process exits once its input ends and every picture is read.

import CoreGraphics
import Foundation
import OMSOCR

struct Job: Decodable {
    let id: String
    var path: String?
    var joinsWrappedLines: Bool?
    var pack: String?
    var lines: Bool?
    var warm: Bool?
}

struct Line: Encodable {
    let text: String
    let box: CGRect
    let confidence: Float
}

struct Result: Encodable {
    let id: String
    var text: String?
    var lines: [Line]?
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
        if job.warm == true, let pack = job.pack {
            _ = try await reader(for: pack)
            send(Result(id: job.id, text: ""))
            continue
        }
        guard let path = job.path else { throw OCRError.unreadableImage }
        let image = try PictureText.image(at: URL(filePath: path))
        if job.lines == true, let pack = job.pack {
            let lines = try await reader(for: pack).recognize(image).lines
            send(Result(id: job.id, lines: lines.map { Line(text: $0.text, box: $0.box, confidence: $0.confidence) }))
            continue
        }
        let result = try await reading(with: job.pack).recognize(image)
        let text = job.joinsWrappedLines.map { TextAssembler.assemble(result.lines, options: .init(joinsWrappedLines: $0)) } ?? result.text
        send(Result(id: job.id, text: text))
    } catch {
        send(Result(id: job.id, error: String(describing: error)))
    }
}
