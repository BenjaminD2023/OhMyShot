import Foundation
import OSLog

/// Keeps at most seven UTC days of cumulative usage. The current day's acknowledged
/// snapshot stays on disk so a relaunch can continue its counts under the same UUID.
@MainActor
public final class UsageTelemetry {
    public enum Event {
        case screenshot
        case recording
        case textRecognition
    }

    struct Snapshot: Codable, Equatable {
        let schema: Int
        let day: String
        let id: UUID
        let version: String
        let macOS: Int
        var screenshots = 0
        var recordings = 0
        var textRecognitions = 0

        // Decoding must preserve the UUID assigned at creation.
        init(day: String, version: String, macOS: Int) {
            schema = 1
            self.day = day
            id = UUID()
            self.version = version
            self.macOS = macOS
        }

        mutating func record(_ event: Event) {
            switch event {
            case .screenshot: screenshots = min(screenshots + 1, 1_000_000)
            case .recording: recordings = min(recordings + 1, 1_000_000)
            case .textRecognition: textRecognitions = min(textRecognitions + 1, 1_000_000)
            }
        }
    }

    private struct Day: Codable, Equatable {
        var snapshot: Snapshot
        var pending = true
        var lastAttempt: Date?
    }

    private static let retryInterval: TimeInterval = 15 * 60
    private static let dayFormat = Date.ISO8601FormatStyle(
        dateSeparator: .dash, timeZone: TimeZone(secondsFromGMT: 0)!
    ).year().month().day()

    private let file: URL
    private let version: String
    private let macOS: Int
    private let send: (Data) async throws -> Void
    private let now: () -> Date
    private var days: [String: Day] = [:]
    private var needsWrite = false
    private var isEnabled = false
    private var loop: Task<Void, Never>?
    private var sleeping: Task<Void, Never>?
    private var uploadingGeneration: Int?
    private var consentGeneration = 0

    public init?(
        file: URL, version: String, macOS: Int, now: @escaping () -> Date = Date.init,
        send: @escaping (Data) async throws -> Void
    ) {
        guard version.utf8.count <= 24, version.wholeMatch(of: /[0-9]+(\.[0-9]+){0,3}/) != nil,
              (1...99).contains(macOS) else { return nil }
        self.file = file
        self.version = version
        self.macOS = macOS
        self.now = now
        self.send = send
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else {
            cancelLoop()
            days.removeAll()
            needsWrite = false
            do {
                try FileManager.default.removeItem(at: file)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // No pending reports.
            } catch {
                Log.app.error("Could not remove the local usage data file")
            }
            return
        }
        guard !isEnabled else { return }
        isEnabled = true
        if let data = try? Data(contentsOf: file) {
            days = (try? JSONDecoder().decode([String: Day].self, from: data)) ?? [:]
        }
        openDay(at: now())
        save()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.uploadPending()
                guard !Task.isCancelled, let sleep = self?.scheduleNextPass() else { return }
                await sleep.value
            }
        }
    }

    /// Quitting cancels the request and leaves the current snapshots ready for next launch.
    public func stop() {
        if isEnabled {
            openDay(at: now())
            save()
        }
        cancelLoop()
    }

    private func cancelLoop() {
        isEnabled = false
        consentGeneration += 1
        loop?.cancel()
        loop = nil
        sleeping?.cancel()
        sleeping = nil
    }

    public func record(_ event: Event) {
        guard isEnabled else { return }
        let date = now()
        let existing = days[Self.day(of: date)]
        let day = openDay(at: date)
        if var entry = days[day] {
            let before = entry.snapshot
            entry.snapshot.record(event)
            if entry.snapshot != before {
                entry.pending = true
                days[day] = entry
                needsWrite = true
            }
        }
        save()
        if existing?.pending != true { sleeping?.cancel() }
    }

    private func scheduleNextPass() -> Task<Void, Never> {
        let date = now()
        openDay(at: date)
        save()
        // UTC days are aligned to the Unix epoch, independent of this Mac's calendar and timezone.
        let secondsSinceEpoch = date.timeIntervalSince1970
        let nextMidnight = (floor(secondsSinceEpoch / 86_400) + 1) * 86_400
        var delay = nextMidnight - secondsSinceEpoch
        for entry in days.values where entry.pending {
            delay = min(delay, Self.timeUntilAttempt(for: entry, at: date))
        }
        if needsWrite { delay = min(delay, Self.retryInterval) }
        // A write failure can leave an unsent report due now. Avoid spinning on unavailable storage.
        if needsWrite, delay <= 0 { delay = Self.retryInterval }
        let sleep = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(max(0, delay)), tolerance: .seconds(1))
        }
        sleeping = sleep
        return sleep
    }

    private static func timeUntilAttempt(for entry: Day, at date: Date) -> TimeInterval {
        guard let last = entry.lastAttempt, last <= date else { return 0 }
        return max(0, retryInterval - date.timeIntervalSince(last))
    }

    private static func day(of date: Date) -> String { date.formatted(dayFormat) }

    @discardableResult
    private func openDay(at date: Date) -> String {
        let today = Self.day(of: date)
        let oldest = Self.day(of: date.addingTimeInterval(-6 * 86_400))
        for day in days.keys where day < oldest || day > today || (day < today && days[day]?.pending == false) {
            days.removeValue(forKey: day)
            needsWrite = true
        }
        if days[today] == nil {
            days[today] = Day(snapshot: Snapshot(day: today, version: version, macOS: macOS))
            needsWrite = true
        }
        return today
    }

    @discardableResult
    private func save() -> Bool {
        guard needsWrite else { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(days).write(to: file, options: .atomic)
            needsWrite = false
            return true
        } catch {
            Log.app.error("Could not save local usage data")
            return false
        }
    }

    func uploadPending() async {
        let generation = consentGeneration
        guard isEnabled, !Task.isCancelled, uploadingGeneration != generation else { return }
        uploadingGeneration = generation
        defer {
            if uploadingGeneration == generation { uploadingGeneration = nil }
        }
        openDay(at: now())
        guard save() else { return }
        for day in days.keys.sorted() {
            guard !Task.isCancelled, isEnabled, consentGeneration == generation else { return }
            let date = now()
            openDay(at: date)
            guard var entry = days[day], entry.pending else { continue }
            guard Self.timeUntilAttempt(for: entry, at: date) == 0 else { continue }
            let snapshot = entry.snapshot
            entry.lastAttempt = date
            days[day] = entry
            needsWrite = true
            guard save() else { return }
            do {
                try await send(JSONEncoder().encode(snapshot))
                guard !Task.isCancelled, isEnabled, consentGeneration == generation else { return }
                if days[day]?.snapshot == snapshot {
                    days[day]?.pending = false
                    needsWrite = true
                    save()
                }
            } catch {
                // Leave the full snapshot pending. Sending it again uses the same day and UUID.
            }
        }
    }
}
