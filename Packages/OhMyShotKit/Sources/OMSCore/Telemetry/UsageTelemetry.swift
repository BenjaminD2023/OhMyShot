import Foundation
import OSLog

/// Keeps at most seven UTC days of cumulative usage. The current day's acknowledged
/// snapshot stays on disk so a relaunch can continue its counts under the same UUID.
@MainActor
public final class UsageTelemetry {
    /// What came of something the person did.
    public enum Outcome: String, Sendable {
        case screenshot
        case recording
        case textRecognition
        case upload
        case uploadFailure
        case exportFailure
        case permissionBlocked
    }

    /// Where a feature was started.
    public enum Source: String, Sendable {
        case hotkey
        case menu
        case automation
    }

    /// What a day's report says about the Mac and the app, read as the day opens. None of it names the Mac or its person.
    public struct Context: Sendable {
        /// "26.4": the major and minor version.
        public var macOS: String
        /// The chip's name without "Apple", "M3 Pro"; anything else is sent as "other".
        public var chip: String
        /// The localization the app runs in, "zh-Hans".
        public var language: String
        public var displays: Int
        /// When OhMyShot first ran on this Mac, sent only as how long ago it was, in a few broad spans.
        public var installed: Date
        /// The few choices the report says, by their report names, "format": "png".
        public var settings: [String: String]

        public init(macOS: String, chip: String, language: String, displays: Int, installed: Date, settings: [String: String]) {
            self.macOS = macOS
            self.chip = chip
            self.language = language
            self.displays = displays
            self.installed = installed
            self.settings = settings
        }
    }

    struct Snapshot: Codable, Equatable {
        let schema: Int
        let day: String
        let id: UUID
        let version: String
        let macOS: String
        let chip: String
        let language: String
        let displays: Int
        let installAge: String
        let usedDays: Int
        let settings: [String: String]
        /// Each feature's starts by where they came from: "captureArea": ["hotkey": 3].
        var features: [String: [String: Int]] = [:]
        var outcomes: [String: Int] = [:]

        // Decoding must preserve the UUID assigned at creation.
        init(day: String, version: String, context: Context, installAge: String, usedDays: Int) {
            schema = 2
            self.day = day
            id = UUID()
            self.version = version
            macOS = context.macOS
            chip = context.chip.wholeMatch(of: /[AM][1-9][0-9]?( (Pro|Max|Ultra))?/) != nil ? context.chip : "other"
            language = context.language.wholeMatch(of: /[a-z]{2,3}(-[A-Z][a-z]{3})?(-[A-Z]{2})?/) != nil
                ? context.language : "und"
            displays = min(max(context.displays, 1), 16)
            self.installAge = installAge
            self.usedDays = usedDays
            settings = context.settings
        }

        mutating func record(_ outcome: Outcome) {
            outcomes[outcome.rawValue] = min(outcomes[outcome.rawValue, default: 0] + 1, 1_000_000)
        }

        mutating func recordFeature(_ name: String, from source: Source) {
            let count = features[name, default: [:]][source.rawValue, default: 0]
            features[name, default: [:]][source.rawValue] = min(count + 1, 1_000_000)
        }
    }

    private struct Day: Codable, Equatable {
        var snapshot: Snapshot
        var pending = true
        var lastAttempt: Date?
    }

    /// What the file keeps: each unsent or current day, and the UTC days of the last four weeks something was used.
    private struct Stored: Codable {
        var days: [String: Day] = [:]
        var usedDays: Set<String> = []
    }

    private static let retryInterval: TimeInterval = 15 * 60
    private static let dayFormat = Date.ISO8601FormatStyle(
        dateSeparator: .dash, timeZone: TimeZone(secondsFromGMT: 0)!
    ).year().month().day()

    private let file: URL
    private let version: String
    private let context: @MainActor () -> Context
    private let send: (Data) async throws -> Void
    private let now: () -> Date
    private var days: [String: Day] = [:]
    private var usedDays: Set<String> = []
    private var needsWrite = false
    private var isEnabled = false
    private var loop: Task<Void, Never>?
    private var sleeping: Task<Void, Never>?
    private var uploadingGeneration: Int?
    private var consentGeneration = 0

    public init?(
        file: URL, version: String, now: @escaping () -> Date = Date.init, context: @escaping @MainActor () -> Context,
        send: @escaping (Data) async throws -> Void
    ) {
        guard version.utf8.count <= 24, version.wholeMatch(of: /[0-9]+(\.[0-9]+){0,3}/) != nil else { return nil }
        self.file = file
        self.version = version
        self.context = context
        self.now = now
        self.send = send
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else {
            cancelLoop()
            days.removeAll()
            usedDays.removeAll()
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
        // A file an earlier version wrote, in the first format, starts over.
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            days = stored.days
            usedDays = stored.usedDays
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

    public func record(_ outcome: Outcome) {
        update { $0.record(outcome) }
    }

    /// Counts a start of a feature by its name, a `CaptureShortcut` or automation command's: "captureArea".
    public func recordFeature(_ name: String, from source: Source) {
        guard name.wholeMatch(of: /[a-z][A-Za-z]{1,39}/) != nil else { return }
        update { $0.recordFeature(name, from: source) }
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        guard isEnabled else { return }
        let date = now()
        let existing = days[Self.day(of: date)]
        let day = openDay(at: date)
        if var entry = days[day] {
            let before = entry.snapshot
            change(&entry.snapshot)
            if entry.snapshot != before {
                entry.pending = true
                days[day] = entry
                needsWrite = true
            }
        }
        if usedDays.insert(day).inserted { needsWrite = true }
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

    /// How long ago OhMyShot first ran, by the start of its span: the first day, a week, a month, a quarter, a year.
    static func installAge(since installed: Date, at date: Date) -> String {
        switch Int(max(0, date.timeIntervalSince(installed)) / 86_400) {
        case ..<1: "d0"
        case ..<7: "d1"
        case ..<30: "d7"
        case ..<90: "d30"
        case ..<365: "d90"
        default: "d365"
        }
    }

    @discardableResult
    private func openDay(at date: Date) -> String {
        let today = Self.day(of: date)
        let oldest = Self.day(of: date.addingTimeInterval(-6 * 86_400))
        for day in days.keys where day < oldest || day > today || (day < today && days[day]?.pending == false) {
            days.removeValue(forKey: day)
            needsWrite = true
        }
        let fourWeeksAgo = Self.day(of: date.addingTimeInterval(-28 * 86_400))
        for day in usedDays where day < fourWeeksAgo || day > today {
            usedDays.remove(day)
            needsWrite = true
        }
        if days[today] == nil {
            let context = context()
            days[today] = Day(snapshot: Snapshot(
                day: today, version: version, context: context,
                installAge: Self.installAge(since: context.installed, at: date),
                usedDays: usedDays.count(where: { $0 < today })
            ))
            needsWrite = true
        }
        return today
    }

    @discardableResult
    private func save() -> Bool {
        guard needsWrite else { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(days: days, usedDays: usedDays)).write(to: file, options: .atomic)
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
