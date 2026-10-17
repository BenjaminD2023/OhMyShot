import Foundation
import OSLog

/// One picture read by the text reader for someone waiting on the answer (the Shortcuts action Recognize Text in
/// Image), in a run of its own that exits once it has answered.
///
/// Vision keeps what a recognition used for as long as its process lives (Docs/perf.md, M2 and M5 — power gate:
/// the action read in the app left it 56 MB larger for good); read in the text reader, the app stays as it was.
/// The run holds an `ActiveResources` lease while it lasts, and cancelling the task that awaits it ends it.
public enum TextReaderTool {
    public enum Failure: Error, Equatable {
        /// The reader didn't start.
        case unavailable(String)
        /// The reader answered that it couldn't read the picture.
        case unreadable(String)
        /// The reader ended without answering.
        case noAnswer(status: Int32)
    }

    /// The text in the picture at `url`, assembled as Capture Text assembles it.
    ///
    /// - Parameters:
    ///   - joinsWrappedLines: whether lines a paragraph wraps onto are joined into one.
    ///   - pack: an installed PP-OCR model pack's folder, to read with it (L2) instead of Vision.
    ///   - helper: the text reader.
    @concurrent
    public static func text(
        ofPictureAt url: URL, joinsWrappedLines: Bool, pack: URL? = nil, helper: URL, priority: QualityOfService = .userInitiated,
        resources: ActiveResources = .shared
    ) async throws -> String {
        let process = Process()
        process.executableURL = helper
        process.qualityOfService = priority
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let (exited, exiting) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { process in
            exiting.yield(process.terminationStatus)
            exiting.finish()
        }
        do {
            try process.run()
        } catch {
            throw Failure.unavailable(error.localizedDescription)
        }
        let lease = resources.acquire(.helperProcess)
        defer { lease.end() }

        let id = UUID().uuidString
        var job = try JSONEncoder().encode(Job(id: id, path: url.path(percentEncoded: false), joinsWrappedLines: joinsWrappedLines, pack: pack?.path(percentEncoded: false)))
        job.append(0x0A)
        let writer = input.fileHandleForWriting
        // A reader that stops early closes the pipe: writing then fails, rather than the signal ending the app.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? writer.write(contentsOf: job)
        try? writer.close()

        return try await withTaskCancellationHandler {
            var answer: Answer?
            for try await line in output.fileHandleForReading.bytes.lines {
                if let decoded = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)), decoded.id == id { answer = decoded }
            }
            var status: Int32 = -1
            for await code in exited { status = code }
            try Task.checkCancellation()
            guard let answer else { throw Failure.noAnswer(status: status) }
            if let text = answer.text { return text }
            throw Failure.unreadable(answer.error ?? "")
        } onCancel: {
            process.terminate()
        }
    }

    private struct Job: Encodable {
        let id: String
        let path: String
        let joinsWrappedLines: Bool
        let pack: String?
    }

    private struct Answer: Decodable {
        let id: String
        let text: String?
        let error: String?
    }
}
