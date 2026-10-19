import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

// Spike: does the on-device system model read text in a picture, how well, how fast?
// fm_probe <dir> <variant: default|advanced> <id>...   (reads <dir>/<id>.png, writes <dir>/<id>.fm-<variant>.txt)
@main
struct Spike {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let directory = URL(filePath: arguments[0])
        let name = arguments[1]
        let model = SystemLanguageModel.default
        print("availability", model.availability)
        print("capabilities vision", model.capabilities.contains(.vision), "reasoning", model.capabilities.contains(.reasoning))
        print("variant", model.variant.displayName, "context", model.contextSize)
        print("languages", model.supportedLanguages.map(\.maximalIdentifier).sorted().joined(separator: " "))
        let instructions = "You transcribe the text in pictures exactly as it appears, keeping line breaks. You never translate, correct, summarize or explain."
        for id in arguments.dropFirst(2) {
            let url = directory.appending(path: "\(id).png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print(id, "no image"); continue }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let start = ContinuousClock.now
            do {
                let response = try await session.respond(options: GenerationOptions(samplingMode: .greedy, toolCallingMode: nil)) {
                    "Transcribe all the text in this picture, line by line, top to bottom. Output only the text."
                    Attachment(image)
                }
                let elapsed = ContinuousClock.now - start
                try response.content.write(to: directory.appending(path: "\(id).fm-\(name).txt"), atomically: true, encoding: .utf8)
                print(id, "\(image.width)x\(image.height)", elapsed)
            } catch {
                print(id, "error", error)
            }
        }
    }
}
