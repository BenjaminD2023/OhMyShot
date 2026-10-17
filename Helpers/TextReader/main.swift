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
// history's search). With "pack": "/…/Model Packs/<id>/<version>", the picture is read with that PP-OCR model pack
// (L2, Docs/ocr.md › The L2 pack) instead of Vision; its models are loaded once a run.
// Output, on standard output: one JSON object per line as each picture is read, in order,
// {"id": "…", "text": "…"} or {"id": "…", "error": "…"}. The process exits once its input ends and every
// picture is read.

import Foundation
import OMSOCR

struct Job: Decodable {
    let id: String
    let path: String
    var joinsWrappedLines: Bool?
    var pack: String?
}

struct Result: Encodable {
    let id: String
    var text: String?
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
        let url = URL(filePath: job.path)
        let text: String
        if let pack = job.pack {
            let lines = try await reader(for: pack).recognize(PictureText.image(at: url)).lines
            text = job.joinsWrappedLines.map { TextAssembler.assemble(lines, options: .init(joinsWrappedLines: $0)) } ?? lines.map(\.text).joined(separator: "\n")
        } else if let joins = job.joinsWrappedLines {
            let lines = try await pipeline.recognize(PictureText.image(at: url)).lines
            text = TextAssembler.assemble(lines, options: .init(joinsWrappedLines: joins))
        } else {
            text = try await PictureText.read(fileAt: url, pipeline: pipeline)
        }
        send(Result(id: job.id, text: text))
    } catch {
        send(Result(id: job.id, error: String(describing: error)))
    }
}
