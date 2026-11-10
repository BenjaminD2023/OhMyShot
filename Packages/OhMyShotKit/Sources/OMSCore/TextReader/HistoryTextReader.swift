import Foundation
import Observation
import OSLog

/// Reads the text in the history's screenshots, for searching them, and keeps it beside each one.
///
/// The reading is done by the text reader, a tool inside the app that runs only while there is something to
/// read: Vision keeps what a recognition used for as long as its process lives (Docs/perf.md, M2), so reading
/// in the app would leave it at 70 MB or more for good. One run reads every screenshot waiting, one after
/// another, and exits; one asked for while another runs follows it.
///
/// With a model pack installed (`pack`), the reader reads it beside Vision where a capture holds Chinese or Japanese
/// (L2 beside L1, Docs/ocr.md › L2 beside L1), and the captures read before it was there that hold either are read
/// again.
@MainActor
@Observable
public final class HistoryTextReader {
    /// Screenshots being read now, for the History window to say so.
    public private(set) var reading = 0

    /// Told each time a screenshot's text is kept.
    @ObservationIgnored public var onRead: ((UUID) -> Void)?

    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let helper: URL?
    @ObservationIgnored private let pack: () -> TextReaderPack?
    @ObservationIgnored private var run: Run?
    /// While the screenshots waiting are being found, before a run starts.
    @ObservationIgnored private(set) var starting = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var runsAgain: QualityOfService?
    /// How often each screenshot was sent and not read this time the app runs: the reader answered with an error (a
    /// reading that timed out while Vision compiled its models, say), or stopped while it had the screenshot. Tried
    /// again at the next reading until `attempts` reach `maxAttempts`, so a picture that stops the reader every time
    /// isn't sent after every capture; opening History tries them all once more.
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var soon: Task<Void, Never>?
    @ObservationIgnored private var soonLease: ActiveResources.Lease?

    /// How long `readSoon()` waits, so captures taken one after another are read in one run.
    static let delay: Duration = .seconds(3)

    /// How many readings a screenshot is sent to before it waits for History to open.
    static let maxAttempts = 3

    private final class Run {
        let process: Process
        let priority: QualityOfService
        let lease: ActiveResources.Lease
        /// The pack the run reads beside Vision, kept with what it reads.
        let reading: String?
        /// What was sent, by id: the record and its file as it was when sent.
        var sent: [String: (item: HistoryItem, stamp: HistoryText.Stamp)]
        /// The ids in the order they were sent, which the reader reads and answers them in.
        let order: [String]
        var stopped = false

        init(
            process: Process, priority: QualityOfService, lease: ActiveResources.Lease, reading: String?,
            sent: [String: (item: HistoryItem, stamp: HistoryText.Stamp)], order: [String]
        ) {
            self.process = process
            self.priority = priority
            self.lease = lease
            self.reading = reading
            self.sent = sent
            self.order = order
        }
    }

    /// - Parameters:
    ///   - helper: the text reader; nil reads nothing (a build without it).
    ///   - pack: the model pack to read beside Vision, asked as each run starts; nil while none is installed.
    public init(store: HistoryStore, helper: URL?, pack: @escaping () -> TextReaderPack? = { nil }) {
        self.store = store
        self.helper = helper
        self.pack = pack
    }

    /// Reads, in a few seconds and at background priority, every screenshot waiting: after a capture. Not in
    /// Low Power Mode; the History window reads them when it opens.
    public func readSoon() {
        guard helper != nil, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        soon?.cancel()
        soonLease = soonLease ?? ActiveResources.shared.acquire(.timer)
        soon = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            soonLease?.end()
            soonLease = nil
            soon = nil
            read(priority: .background)
        }
    }

    /// Reads every screenshot waiting now, at utility priority: the History window is open, and its search
    /// waits on them. `retryingFailed` (History opening) sends the screenshots the reader failed on again.
    public func readNow(retryingFailed: Bool = false) {
        if retryingFailed { attempts.removeAll() }
        soon?.cancel()
        soon = nil
        soonLease?.end()
        soonLease = nil
        read(priority: .utility)
    }

    /// Stops reading (the app is quitting); what was read is kept.
    public func stop() {
        soon?.cancel()
        soon = nil
        soonLease?.end()
        soonLease = nil
        runsAgain = nil
        stopped = true
        if let run {
            run.stopped = true
            run.process.terminate()
        }
    }

    func read(priority: QualityOfService) {
        guard run == nil, !starting else {
            // After the run going, at the higher of the two priorities.
            runsAgain = runsAgain.map { $0.rawValue >= priority.rawValue ? $0 : priority } ?? priority
            // A run at a lower priority is stopped and started again at this one: what it read is kept, and
            // History waits on the rest. Reading on the efficiency cores takes three times as long.
            if let run, !run.stopped, run.priority.rawValue < priority.rawValue {
                run.stopped = true
                run.process.terminate()
            }
            return
        }
        guard let helper, !stopped else { return }
        starting = true
        let store = store, failed = Set(attempts.filter { $0.value >= Self.maxAttempts }.keys), pack = pack()
        Task {
            // Off the main actor: a record and a text file for every capture in the history.
            let waiting = await Self.waiting(in: store, except: failed, pack: pack)
            starting = false
            guard !stopped else { return }
            start(helper, reading: waiting, with: pack, priority: priority)
        }
    }

    /// The screenshots waiting to be read, with their files as they are now, and the reader's input for them.
    @concurrent
    private static func waiting(
        in store: HistoryStore, except failed: Set<UUID>, pack: TextReaderPack?
    ) async -> (sent: [String: (item: HistoryItem, stamp: HistoryText.Stamp)], order: [String], jobs: Data) {
        var sent: [String: (item: HistoryItem, stamp: HistoryText.Stamp)] = [:]
        var order: [String] = []
        var jobs = Data()
        for item in store.needingText(store.items(), reading: pack?.reading) where !failed.contains(item.id) {
            let job = TextReaderWire.Job(
                id: item.id.uuidString, path: store.fileURL(for: item).path(percentEncoded: false), pack: pack?.folder.path(percentEncoded: false)
            )
            guard let stamp = store.stamp(of: item), var line = try? JSONEncoder().encode(job) else { continue }
            line.append(0x0A)
            jobs.append(line)
            sent[item.id.uuidString] = (item, stamp)
            order.append(item.id.uuidString)
        }
        return (sent, order, jobs)
    }

    private func start(
        _ helper: URL, reading waiting: (sent: [String: (item: HistoryItem, stamp: HistoryText.Stamp)], order: [String], jobs: Data),
        with pack: TextReaderPack?, priority requested: QualityOfService
    ) {
        let (sent, order, jobs) = waiting
        guard !sent.isEmpty else { return runAgainIfAsked() }
        // Asked again at a higher priority while the screenshots were being found: this run is that one.
        var priority = requested
        if let again = runsAgain, again.rawValue >= requested.rawValue {
            priority = again
            runsAgain = nil
        }

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
            Log.history.error("The text reader didn't start: \(error.localizedDescription, privacy: .public)")
            return runAgainIfAsked()
        }
        let run = Run(
            process: process, priority: priority, lease: ActiveResources.shared.acquire(.helperProcess), reading: pack?.reading, sent: sent, order: order
        )
        self.run = run
        reading = sent.count
        Log.history.notice("Reading the text in \(sent.count, privacy: .public) capture(s)\(pack.map { " with \($0.reading)" } ?? "", privacy: .public)")

        // Written off the main actor: the pipe holds 64 KB, and the reader takes a line only when it has read
        // the picture before.
        let writer = input.fileHandleForWriting
        // A reader that stops partway closes the pipe: writing then fails, rather than the signal ending the app.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        Task.detached(priority: .utility) {
            try? writer.write(contentsOf: jobs)
            try? writer.close()
        }
        // Every answer is taken before the run counts as over: the reader can exit before the last lines are read.
        let reader = output.fileHandleForReading
        Task { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    self?.received(line, in: run)
                }
            } catch {}
            var status: Int32 = -1
            for await code in exited { status = code }
            self?.finished(run, status: status)
        }
    }

    private func received(_ line: String, in run: Run) {
        guard let result = try? JSONDecoder().decode(TextReaderWire.Answer.self, from: Data(line.utf8)),
              let (item, stamp) = run.sent.removeValue(forKey: result.id)
        else { return }
        reading = run.sent.count
        if let text = result.text {
            attempts[item.id] = nil
            // Unless the capture left the history while it was read.
            guard store.stamp(of: item) != nil else { return }
            do {
                try store.setText(text, of: item, readFrom: stamp, reading: run.reading)
                onRead?(item.id)
            } catch {
                Log.history.error("Keeping the text of \(item.fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            attempts[item.id, default: 0] += 1
            Log.history.error("The text reader couldn't read \(item.fileName, privacy: .public) (try \(self.attempts[item.id] ?? 0, privacy: .public)): \(result.error ?? "", privacy: .public)")
        }
    }

    private func finished(_ run: Run, status: Int32) {
        guard self.run === run else { return }
        self.run = nil
        run.lease.end()
        Log.history.notice("The text reader finished with status \(status, privacy: .public)")
        // It stopped partway: the first capture it hadn't answered for is the one it had, which counts as a try; the
        // ones after it were never tried, and are sent again at the next reading.
        if !run.stopped, let had = run.order.first(where: { run.sent[$0] != nil }), let item = run.sent[had]?.item {
            attempts[item.id, default: 0] += 1
            Log.history.error("The text reader stopped with status \(status, privacy: .public) on \(item.fileName, privacy: .public), \(run.sent.count, privacy: .public) capture(s) unread")
        }
        reading = 0
        runAgainIfAsked()
    }

    private func runAgainIfAsked() {
        guard let again = runsAgain else { return }
        runsAgain = nil
        read(priority: again)
    }
}
