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
/// Image, the OCR panel's second reading, Capture Formula), in a run of its own that exits once it has answered.
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
    ///   - formulas: the installed formula pack's folder, to put the formulas in the picture into the text as LaTeX
    ///     (Docs/ocr.md › Formulas among text).
    ///   - helper: the text reader.
    @concurrent
    public static func text(
        ofPictureAt url: URL, joinsWrappedLines: Bool, pack: URL? = nil, formulas: URL? = nil, helper: URL,
        priority: QualityOfService = .userInitiated, resources: ActiveResources = .shared
    ) async throws -> String {
        let job = Job(
            id: UUID().uuidString, path: url.path(percentEncoded: false), joinsWrappedLines: joinsWrappedLines, pack: pack?.path(percentEncoded: false),
            formulas: formulas?.path(percentEncoded: false)
        )
        let answer = try await run(job, helper: helper, priority: priority, resources: resources)
        if let text = answer.text { return text }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// A formula the formula pack found in a picture and read whole.
    public struct FoundFormula: Codable, Sendable, Equatable {
        /// "display", set apart on a line of its own, or "inline", within text.
        public var kind: String
        /// In the picture's pixels, top-left origin.
        public var box: CGRect
        public var latex: String

        public init(kind: String, box: CGRect, latex: String) {
            self.kind = kind
            self.box = box
            self.latex = latex
        }
    }

    /// The formulas the formula pack installed in `pack` finds in the picture at `url`, each read as LaTeX (Docs/ocr.md ›
    /// Formulas among text). `found` is told how many there are to read, before they are.
    @concurrent
    public static func formulas(
        ofPictureAt url: URL, pack: URL, helper: URL, found: (@Sendable (Int) -> Void)? = nil, priority: QualityOfService = .userInitiated,
        resources: ActiveResources = .shared
    ) async throws -> [FoundFormula] {
        let job = Job(id: UUID().uuidString, path: url.path(percentEncoded: false), formulas: pack.path(percentEncoded: false))
        let answer = try await run(job, helper: helper, priority: priority, resources: resources) { progress in
            if let count = progress.found { found?(count) }
        }
        if let formulas = answer.formulas { return formulas }
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

    /// What the formula pack read in a picture.
    public struct Formula: Sendable, Equatable {
        public var latex: String
        /// How the reading ended: "end" when the model finished the formula; "repeats", "cacheFull", or "deadline"
        /// when it was stopped.
        public var ending: String

        public init(latex: String, ending: String) {
            self.latex = latex
            self.ending = ending
        }

        /// Whether this is a formula to give the person: a whole reading with something in it.
        public var isFormula: Bool {
            ending == "end" && !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The formula the formula pack installed in `pack` reads in the picture at `url` (Capture Formula; Docs/ocr.md ›
    /// The formula pack). Without the spaces at its ends that upstream's tidying leaves where it unwraps `\text{}`.
    @concurrent
    public static func formula(
        ofPictureAt url: URL, pack: URL, helper: URL, priority: QualityOfService = .userInitiated, resources: ActiveResources = .shared
    ) async throws -> Formula {
        let job = Job(id: UUID().uuidString, path: url.path(percentEncoded: false), formula: pack.path(percentEncoded: false))
        let answer = try await run(job, helper: helper, priority: priority, resources: resources)
        if let latex = answer.latex, let ending = answer.ending {
            return Formula(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines), ending: ending)
        }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// Compiles the formula pack's models once, reading nothing, so the first Capture Formula doesn't wait on it.
    @concurrent
    public static func warm(formula pack: URL, helper: URL, priority: QualityOfService = .utility, resources: ActiveResources = .shared) async throws {
        let job = Job(id: UUID().uuidString, warm: true, formula: pack.path(percentEncoded: false))
        let answer = try await run(job, helper: helper, priority: priority, resources: resources)
        if let error = answer.error { throw Failure.unreadable(error) }
    }

    /// Removes what Core ML keeps in the reader's Caches folder of models that are gone (`CompiledModelCache`), after a
    /// pack was removed or replaced, reading nothing. Run in the reader, whose cache it is.
    /// - Returns: how many entries were removed.
    @concurrent
    @discardableResult
    public static func tidy(helper: URL, priority: QualityOfService = .utility, resources: ActiveResources = .shared) async throws -> Int {
        let job = Job(id: UUID().uuidString, tidy: true)
        let answer = try await run(job, helper: helper, priority: priority, resources: resources)
        if let removed = answer.removed { return removed }
        throw Failure.unreadable(answer.error ?? "")
    }

    /// Runs the reader on `job`. A line telling how far it got (`Answer.isProgress`) goes to `progress`; the answer is
    /// the last other line for the job.
    private static func run(
        _ job: Job, helper: URL, priority: QualityOfService, resources: ActiveResources, progress: (@Sendable (Answer) -> Void)? = nil
    ) async throws -> Answer {
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
                guard let decoded = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)), decoded.id == job.id else { continue }
                if decoded.isProgress { progress?(decoded) } else { answer = decoded }
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
        var formula: String?
        var formulas: String?
        var tidy: Bool?
    }

    private struct Answer: Decodable {
        let id: String
        let text: String?
        let lines: [Line]?
        let latex: String?
        let ending: String?
        let found: Int?
        let formulas: [FoundFormula]?
        let removed: Int?
        let error: String?

        /// How many formulas the reader found, said before it reads them.
        var isProgress: Bool {
            found != nil && text == nil && lines == nil && latex == nil && formulas == nil && removed == nil && error == nil
        }
    }
}
