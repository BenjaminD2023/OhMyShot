import Darwin
import Foundation
import Synchronization

/// A short-lived, reusable text reader for interactive captures. Keeping its models loaded between
/// nearby selections avoids paying process and model startup for every few words. Each job still has
/// its own complete deadline; cancelled or stalled native work is discarded with its whole process.
public actor TextReaderWorker {
    private let helper: URL
    private let resources: ActiveResources
    private let idleTimeout: Duration?
    private var session: Session?
    private var events: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var active: Request?
    private var waiting: [Request] = []
    private var buffered = Data()
    private var ended = false
    private var status: Int32?

    /// `idleTimeout` releases model memory after inactivity. Nil retains it until `stop()` or the
    /// worker's owner goes away, for shortcuts that must stay ready after a long pause.
    public init(helper: URL, resources: ActiveResources = .shared, idleTimeout: Duration? = .seconds(120)) {
        self.helper = helper
        self.resources = resources
        self.idleTimeout = idleTimeout
    }

    deinit {
        idle?.cancel()
        writer?.cancel()
        events?.cancel()
        session?.stop()
    }

    /// The full OCR-line payload, with the requested native backend. A false compatibility flag
    /// keeps modern Vision's usual recognition; true selects the isolated recovery backend.
    public func visionLines(
        ofPictureAt url: URL, compatibility: Bool = true, formulas: [TextReaderTool.FoundFormula]? = nil, inputLines: Data? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        let job = Job(
            id: UUID().uuidString, path: url.path(percentEncoded: false), visionCompatibility: compatibility,
            visionFormulas: formulas, visionInputLines: inputLines
        )
        let answer = try await run(job, timeout: timeout)
        guard let lines = answer.visionLines else { throw TextReaderTool.Failure.unreadable(answer.error ?? "") }
        return lines
    }

    public func elements(
        ofPictureAt url: URL, formulas: URL? = nil, vlm: URL? = nil, seconds: Double? = nil, pressure: MemoryPressure? = nil,
        found: (@Sendable (TextReaderTool.Found) -> Void)? = nil, timeout: Duration = .seconds(30)
    ) async throws -> (formulas: [TextReaderTool.FoundFormula], tables: [TextReaderTool.FoundTable], tablesLeft: Int) {
        let job = Job(
            id: UUID().uuidString, path: url.path(percentEncoded: false), formulas: formulas?.path(percentEncoded: false),
            vlm: vlm?.path(percentEncoded: false), seconds: seconds, pressure: pressure?.name
        )
        let answer = try await run(job, timeout: timeout, found: found)
        guard let formulas = answer.formulas else { throw TextReaderTool.Failure.unreadable(answer.error ?? "") }
        return (formulas, answer.tables ?? [], answer.tablesLeft ?? 0)
    }

    /// Ends idle models too. Waiting calls are cancelled, and actual helper accounting ends only once
    /// the process dies. A subsequent request may start a new worker.
    public func stop() {
        let requests = waiting
        waiting.removeAll()
        if let request = active {
            active = nil
            request.timer.cancel()
            request.result.resume(throwing: CancellationError())
        }
        for request in requests {
            request.timer.cancel()
            request.result.resume(throwing: CancellationError())
        }
        discardSession()
    }

    private func run(
        _ job: Job, timeout: Duration, found: (@Sendable (TextReaderTool.Found) -> Void)? = nil
    ) async throws -> Answer {
        try Task.checkCancellation()
        var line = try JSONEncoder().encode(job)
        line.append(0x0A)
        let answer: Answer = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Answer, any Error>) in
                guard !Task.isCancelled else { return result.resume(throwing: CancellationError()) }
                let timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        await self?.expire(job.id)
                    } catch {}
                }
                waiting.append(Request(id: job.id, line: line, result: result, timer: timer, found: found))
                startNext()
            }
        } onCancel: {
            Task { await self.cancel(job.id) }
        }
        try Task.checkCancellation()
        return answer
    }

    private func startNext() {
        guard active == nil else { return }
        idle?.cancel()
        idle = nil
        guard !waiting.isEmpty else {
            guard let session, let idleTimeout else { return }
            let id = session.id
            idle = Task { [weak self] in
                do {
                    try await Task.sleep(for: idleTimeout)
                    await self?.retire(id)
                } catch {}
            }
            return
        }
        let request = waiting.removeFirst()
        active = request
        do {
            if session == nil {
                let next = try Session(helper: helper, resources: resources)
                session = next
                buffered.removeAll(keepingCapacity: true)
                ended = false
                status = nil
                events = Task { [weak self] in
                    for await event in next.events {
                        guard !Task.isCancelled else { return }
                        await self?.receive(event, from: next.id)
                    }
                }
            }
            guard let session else { return }
            writer = Task.detached(priority: .userInitiated) { await session.write(request.line) }
        } catch {
            finish(.failure(error))
        }
    }

    private func receive(_ event: Event, from id: UUID) {
        guard session?.id == id else { return }
        switch event {
        case .bytes(let bytes):
            buffered.append(bytes)
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                guard let answer = try? JSONDecoder().decode(Answer.self, from: line), let active, answer.id == active.id else { continue }
                if answer.isProgress {
                    active.found?(.init(formulas: (answer.found ?? 0) - (answer.foundTables ?? 0), tables: answer.foundTables ?? 0))
                } else {
                    // A prediction can load a much larger model than the small detector we keep
                    // ready. The helper retires after that answer; queued work starts a fresh one.
                    // A failed native prediction may also poison its process, so never reuse it.
                    if answer.retire == true || answer.error != nil { discardSession() }
                    finish(.success(answer))
                }
            }
            // A corrupt worker cannot accumulate unlimited output while it waits on its deadline.
            if buffered.count > 16 * 1024 * 1024 {
                discardSession()
                finish(.failure(TextReaderTool.Failure.unreadable("Reader output is too large")))
            }
        case .eof: ended = true
        case .exited(let code): status = code
        case .writeFailed:
            discardSession()
            finish(.failure(TextReaderTool.Failure.unreadable("Reader input closed")))
        }
        if ended, let status {
            discardSession()
            finish(.failure(TextReaderTool.Failure.noAnswer(status: status)))
        }
    }

    private func finish(_ result: Result<Answer, any Error>) {
        guard let request = active else { return }
        active = nil
        writer?.cancel()
        writer = nil
        request.timer.cancel()
        request.result.resume(with: result)
        startNext()
    }

    private func expire(_ id: String) {
        end(id, with: TextReaderTool.Failure.timedOut)
    }

    private func cancel(_ id: String) {
        end(id, with: CancellationError())
    }

    private func end(_ id: String, with error: any Error) {
        if active?.id == id {
            discardSession()
            finish(.failure(error))
        } else if let index = waiting.firstIndex(where: { $0.id == id }) {
            let request = waiting.remove(at: index)
            request.timer.cancel()
            request.result.resume(throwing: error)
        }
    }

    private func retire(_ id: UUID) {
        guard session?.id == id, active == nil, waiting.isEmpty else { return }
        discardSession()
    }

    private func discardSession() {
        idle?.cancel()
        idle = nil
        writer?.cancel()
        writer = nil
        events?.cancel()
        events = nil
        session?.stop()
        session = nil
        buffered.removeAll(keepingCapacity: true)
        ended = false
        status = nil
    }

    private struct Request {
        let id: String
        let line: Data
        let result: CheckedContinuation<Answer, any Error>
        let timer: Task<Void, Never>
        let found: (@Sendable (TextReaderTool.Found) -> Void)?
    }

    private struct Job: Encodable {
        let id: String
        let path: String
        var reusesProcess = true
        var formulas: String?
        var vlm: String?
        var seconds: Double?
        var pressure: String?
        var visionCompatibility: Bool?
        var visionFormulas: [TextReaderTool.FoundFormula]?
        var visionInputLines: Data?
    }

    private struct Answer: Decodable, Sendable {
        let id: String
        let visionLines: Data?
        let found: Int?
        let foundTables: Int?
        let formulas: [TextReaderTool.FoundFormula]?
        let tables: [TextReaderTool.FoundTable]?
        let tablesLeft: Int?
        let retire: Bool?
        let error: String?

        var isProgress: Bool { found != nil && visionLines == nil && formulas == nil && error == nil }
    }

    private enum Event: Sendable {
        case bytes(Data)
        case eof
        case exited(Int32)
        case writeFailed
    }

    /// No Foundation handle is read or closed concurrently. Nonblocking POSIX IO also keeps a full
    /// input pipe, a queued readability callback, or an inherited output pipe outside job deadlines.
    private final class Session: Sendable {
        let id = UUID()
        let events: AsyncStream<Event>
        private let event: AsyncStream<Event>.Continuation
        private let process: Process
        private let reader: FileHandle
        private let writer: FileHandle
        private final class IOState: Sendable { let closed = Mutex(false) }
        private let io = IOState()

        init(helper: URL, resources: ActiveResources) throws {
            let process = Process()
            process.executableURL = helper
            process.qualityOfService = .userInitiated
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let (events, event) = AsyncStream.makeStream(of: Event.self)
            self.process = process
            self.reader = output.fileHandleForReading
            self.writer = input.fileHandleForWriting
            self.events = events
            self.event = event
            let lease = resources.acquire(.helperProcess)
            process.terminationHandler = { process in
                lease.end()
                event.yield(.exited(process.terminationStatus))
            }
            do { try process.run() } catch {
                lease.end()
                throw TextReaderTool.Failure.unavailable(error.localizedDescription)
            }
            let descriptor = reader.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(writer.fileDescriptor, F_SETFL, fcntl(writer.fileDescriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            let io = self.io
            reader.readabilityHandler = { handle in
                let next = io.closed.withLock { closed -> Event? in
                    guard !closed else { return nil }
                    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    if count > 0 { return .bytes(Data(bytes.prefix(count))) }
                    if count == 0 || (errno != EAGAIN && errno != EINTR) { return .eof }
                    return nil
                }
                if let next {
                    event.yield(next)
                    if case .eof = next { handle.readabilityHandler = nil }
                }
            }
        }

        func write(_ data: Data) async {
            var offset = 0
            while offset < data.count, !Task.isCancelled {
                let written = io.closed.withLock { closed -> Int in
                    guard !closed else { return -1 }
                    return data.withUnsafeBytes { buffer in
                        Darwin.write(writer.fileDescriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                    }
                }
                if written > 0 { offset += written }
                else if written == -1, errno == EAGAIN || errno == EINTR {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                } else {
                    event.yield(.writeFailed)
                    return
                }
            }
        }

        func stop() {
            reader.readabilityHandler = nil
            io.closed.withLock { closed in
                guard !closed else { return }
                closed = true
                try? reader.close()
                try? writer.close()
            }
            event.finish()
            guard process.isRunning else { return }
            process.terminate()
            let process = process
            Task.detached {
                try? await Task.sleep(for: .milliseconds(250))
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }

        deinit { stop() }
    }
}
