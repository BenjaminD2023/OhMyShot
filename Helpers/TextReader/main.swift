// OhMyShot Text Reader: reads the text in pictures for Capture History's search, in a process of its own.
//
// Vision keeps its models and the memory a recognition used for as long as the process lives, and has no way
// to let them go (Docs/perf.md, M2). Reading every capture inside the app would keep a menu bar app that is
// otherwise 40 MB at 70 MB or more for good; this process takes that memory with it when it exits.
//
// Input, on standard input: one JSON object per line, {"id": "…", "path": "/…/picture.png"}.
// Output, on standard output: one JSON object per line as each picture is read, in order,
// {"id": "…", "text": "…"} or {"id": "…", "error": "…"}. The process exits once its input ends and every
// picture is read.

import Foundation
import OMSOCR

struct Job: Decodable {
    let id: String
    let path: String
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
        let text = try await PictureText.read(fileAt: URL(filePath: job.path), pipeline: pipeline)
        send(Result(id: job.id, text: text))
    } catch {
        send(Result(id: job.id, error: String(describing: error)))
    }
}
