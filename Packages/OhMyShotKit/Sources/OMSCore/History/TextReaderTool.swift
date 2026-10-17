import CoreGraphics
import Foundation
import OSLog

/// A PP-OCR model pack the text reader reads with beside Vision (L2 beside L1, Docs/ocr.md › L2 beside L1).
public struct TextReaderPack: Sendable, Equatable {
    /// The installed pack's folder.
    public var folder: URL
    /// What a reading with it is called where its text is kept: "<id>/<version>/merge-<revision>", the revision of the
    /// rules that put its reading beside Vision's (`SecondReading.revision`).
    public var reading: String

    public init(folder: URL, reading: String) {
        self.folder = folder
        self.reading = reading
    }
}

/// One picture read by the text reader for someone waiting on the answer (the Shortcuts action Recognize Text in
/// Image, the OCR panel's second reading), in a run of its own that exits once it has answered.
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

    /// A line a model pack read, in the picture's pixels with a top-left origin.
    public struct Line: Codable, Sendable, Equatable {
        public var text: String
        public var box: CGRect
        public var confidence: Float

        public init(text: String, box: CGRect, confidence: Float) {
            self.text = text
            self.box = box
            self.confidence = confidence
        }
    }

    /// The text in the picture at `url`, assembled as Capture Text assembles it.
    ///
    /// - Parameters:
    ///   - joinsWrappedLines: whether lines a paragraph wraps onto are joined into one.
    ///   - pack: an installed PP-OCR model pack's folder, to read with it beside Vision (L2 beside L1).
    ///   - helper: the text reader.
    @concurrent
    public static func text(
        ofPictureAt url: URL, joinsWrappedLines: Bool, pack: URL? = nil, helper: URL, priority: QualityOfService = .userInitiated,
        resources: ActiveResources = .shared
    ) async throws -> String {
        let job = Job(id: UUID().uuidString, path: url.path(percentEncoded: false), joinsWrappedLines: joinsWrappedLines, pack: pack?.path(percentEncoded: false))
        let answer = try await run(job, helper: helper, priority: priority, resources: resources)
        if let text = answer.text { return text }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// The lines the pack in `pack` reads in the picture at `url`, alone, for the app to put beside its own reading.
    @concurrent
    public static func lines(
        ofPictureAt url: URL, pack: URL, helper: URL, priority: QualityOfService = .userInitiated, resources: ActiveResources = .shared
    ) async throws -> [Line] {
        let job = Job(id: UUID().uuidString, path: url.path(percentEncoded: false), pack: pack.path(percentEncoded: false), lines: true)
        let answer = try await run(job, helper: helper, priority: priority, resources: resources)
        if let lines = answer.lines { return lines }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// Loads the pack in `pack` once, reading nothing: its first load compiles its models for the Neural Engine, which
    /// takes seconds, and later loads, in any run, find that done (Docs/ocr.md › The L2 pack).
    @concurrent
    public static func warm(pack: URL, helper: URL, priority: QualityOfService = .utility, resources: ActiveResources = .shared) async throws {
        let job = Job(id: UUID().uuidString, pack: pack.path(percentEncoded: false), warm: true)
        let answer = try await run(job, helper: helper, priority: priority, resources: resources)
        if let error = answer.error { throw Failure.unreadable(error) }
    }

    private static func run(_ job: Job, helper: URL, priority: QualityOfService, resources: ActiveResources) async throws -> Answer {
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

        var line = try JSONEncoder().encode(job)
        line.append(0x0A)
        let writer = input.fileHandleForWriting
        // A reader that stops early closes the pipe: writing then fails, rather than the signal ending the app.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? writer.write(contentsOf: line)
        try? writer.close()

        return try await withTaskCancellationHandler {
            var answer: Answer?
            for try await line in output.fileHandleForReading.bytes.lines {
                if let decoded = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)), decoded.id == job.id { answer = decoded }
            }
            var status: Int32 = -1
            for await code in exited { status = code }
            try Task.checkCancellation()
            guard let answer else { throw Failure.noAnswer(status: status) }
            return answer
        } onCancel: {
            process.terminate()
        }
    }

    private struct Job: Encodable {
        let id: String
        var path: String?
        var joinsWrappedLines: Bool?
        var pack: String?
        var lines: Bool?
        var warm: Bool?
    }

    private struct Answer: Decodable {
        let id: String
        let text: String?
        let lines: [Line]?
        let error: String?
    }
}
