import Foundation
import Testing
@testable import OMSCore

@MainActor
struct UsageTelemetryTests {
    private static func context(macOS: String = "26.1", installed: Date = .distantPast) -> UsageTelemetry.Context {
        UsageTelemetry.Context(
            macOS: macOS, chip: "M3 Pro", language: "zh-Hans", displays: 2, installed: installed,
            settings: ["format": "png", "copy": "on"]
        )
    }

    @Test func usageDataDefaultsToOnAndResetKeepsTheChoice() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        var changes: [Bool] = []
        settings.onUsageDataChange = { changes.append($0) }

        #expect(settings.sendsUsageData)
        settings.sendsUsageData = false
        #expect(!SettingsStore(defaults: defaults).sendsUsageData)
        settings.resetToDefaults()

        #expect(changes == [false])
        #expect(!settings.sendsUsageData)
        #expect(!SettingsStore(defaults: defaults).sendsUsageData)
    }

    @Test func retryAndRelaunchPreserveCumulativeSnapshots() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: "usage.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        var now = try Date("2026-11-19T23:30:00Z", strategy: .iso8601)
        var sent: [Data] = []
        let original = try #require(UsageTelemetry(file: file, version: "1.2.3", now: { now }, context: { Self.context() }) { data in
            sent.append(data)
            throw URLError(.notConnectedToInternet)
        })
        original.record(.screenshot)
        await original.uploadPending()
        #expect(sent.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        original.setEnabled(true)
        original.record(.screenshot)
        original.recordFeature("captureArea", from: .hotkey)
        await original.uploadPending()
        original.stop()
        let firstData = try #require(sent.first)
        let first = try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: firstData)
        let payload = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        #expect(Set(payload.keys) == [
            "schema", "day", "id", "version", "macOS", "chip", "language", "displays", "installAge", "usedDays",
            "settings", "features", "outcomes",
        ])
        #expect(payload["schema"] as? Int == 2)
        #expect(first.id.uuidString.split(separator: "-")[2].first == "4")
        #expect(first.day == "2026-11-19")
        #expect(first.macOS == "26.1")
        #expect(first.chip == "M3 Pro")
        #expect(first.language == "zh-Hans")
        #expect(first.displays == 2)
        #expect(first.installAge == "d365")
        #expect(first.usedDays == 0)
        #expect(first.settings == ["format": "png", "copy": "on"])
        #expect(first.outcomes == ["screenshot": 1])
        #expect(first.features == ["captureArea": ["hotkey": 1]])

        let relaunched = try #require(UsageTelemetry(file: file, version: "2.0", now: { now }, context: { Self.context(macOS: "27.0") }) {
            sent.append($0)
        })
        defer { relaunched.stop() }
        relaunched.setEnabled(true)
        relaunched.record(.recording)
        relaunched.record(.textRecognition)
        relaunched.recordFeature("captureArea", from: .hotkey)
        relaunched.recordFeature("captureArea", from: .menu)
        await relaunched.uploadPending()
        #expect(sent.count == 1)

        now += 15 * 60
        await relaunched.uploadPending()
        let updated = try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: try #require(sent.last))
        #expect(sent.count == 2)
        #expect(updated.id == first.id)
        #expect(updated.version == "1.2.3")
        #expect(updated.macOS == "26.1")
        #expect(updated.outcomes == ["screenshot": 1, "recording": 1, "textRecognition": 1])
        #expect(updated.features == ["captureArea": ["hotkey": 2, "menu": 1]])
        await relaunched.uploadPending()
        #expect(sent.count == 2)

        now += 15 * 60
        await relaunched.uploadPending()
        let tomorrow = try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: try #require(sent.last))
        #expect(sent.count == 3)
        #expect(tomorrow.day == "2026-11-20")
        #expect(tomorrow.id != first.id)
        #expect(tomorrow.version == "2.0")
        #expect(tomorrow.macOS == "27.0")
        #expect(tomorrow.usedDays == 1)
        #expect(tomorrow.outcomes.isEmpty)
        #expect(tomorrow.features.isEmpty)

        relaunched.record(.screenshot)
        relaunched.setEnabled(false)
        await relaunched.uploadPending()
        #expect(sent.count == 3)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func expiredOfflineDaysAreDiscarded() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var now = try Date("2026-11-10T08:00:00Z", strategy: .iso8601)
        var received: [String] = []
        let service = try #require(UsageTelemetry(
            file: folder.appending(path: "usage.json"), version: "1.2.3", now: { now }, context: { Self.context() }
        ) { data in
            received.append(try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: data).day)
        })
        defer { service.stop() }
        service.setEnabled(true)
        for _ in 0..<7 {
            now += 86_400
            service.record(.screenshot)
        }
        await service.uploadPending()
        #expect(received == (11...17).map { "2026-11-\($0)" })
    }

    @Test func daysUsedCountTheFourWeeksBeforeTodayAndRestartWhenTurnedOff() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: "usage.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        var now = try Date("2026-10-01T08:00:00Z", strategy: .iso8601)
        var reports: [UsageTelemetry.Snapshot] = []
        let service = try #require(UsageTelemetry(file: file, version: "1", now: { now }, context: { Self.context() }) {
            reports.append(try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: $0))
        })
        defer { service.stop() }
        service.setEnabled(true)
        // Used on 30 days in a row, then idle for two, so the next report counts the 26 days of the four weeks before it.
        for _ in 0..<30 {
            service.recordFeature("pickColor", from: .menu)
            now += 86_400
        }
        now += 2 * 86_400
        await service.uploadPending()
        #expect(reports.last?.usedDays == 26)

        service.setEnabled(false)
        service.setEnabled(true)
        now += 86_400
        await service.uploadPending()
        #expect(reports.last?.usedDays == 0)
    }

    @Test func reportsSayOnlyWhatTheWorkerAccepts() {
        let installed = Date(timeIntervalSince1970: 0)
        for (days, age) in [(0.5, "d0"), (1, "d1"), (6.9, "d1"), (7, "d7"), (29, "d7"), (30, "d30"), (89, "d30"), (90, "d90"), (364, "d90"), (365, "d365")] {
            #expect(UsageTelemetry.installAge(since: installed, at: installed.addingTimeInterval(days * 86_400)) == age)
        }
        #expect(UsageTelemetry.installAge(since: installed.addingTimeInterval(60), at: installed) == "d0")

        var context = Self.context()
        context.chip = "Intel(R) Core(TM) i9"
        context.language = "Base"
        context.displays = 40
        let snapshot = UsageTelemetry.Snapshot(day: "2026-11-19", version: "1", context: context, installAge: "d0", usedDays: 0)
        #expect(snapshot.chip == "other")
        #expect(snapshot.language == "und")
        #expect(snapshot.displays == 16)
        for chip in ["M1", "M4 Max", "M10 Ultra", "A18 Pro"] {
            context.chip = chip
            #expect(UsageTelemetry.Snapshot(day: "2026-11-19", version: "1", context: context, installAge: "d0", usedDays: 0).chip == chip)
        }
    }

    @Test func featureNamesOutsideTheReportFormatAreIgnored() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var sent: [UsageTelemetry.Snapshot] = []
        let service = try #require(UsageTelemetry(
            file: folder.appending(path: "usage.json"), version: "1", context: { Self.context() }
        ) { sent.append(try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: $0)) })
        defer { service.stop() }
        service.setEnabled(true)
        for name in ["", "x", "capture-area", "CaptureArea", "capture area", String(repeating: "a", count: 41)] {
            service.recordFeature(name, from: .hotkey)
        }
        service.recordFeature("measure", from: .automation)
        await service.uploadPending()
        #expect(sent.last?.features == ["measure": ["automation": 1]])
    }

    @Test(.timeLimit(.minutes(1))) func disablingCancelsAnInFlightRequest() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: "usage.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        var starts = started.stream.makeAsyncIterator()
        var cancellations = cancelled.stream.makeAsyncIterator()
        let service = try #require(UsageTelemetry(file: file, version: "1", context: { Self.context() }) { _ in
            started.continuation.yield()
            do {
                try await Task.sleep(for: .seconds(5))
                Issue.record("The in-flight request was still running after opt-out")
            } catch is CancellationError {
                cancelled.continuation.yield()
            }
            cancelled.continuation.finish()
        })
        defer { service.stop() }
        service.setEnabled(true)
        await starts.next()
        service.setEnabled(false)
        #expect(await cancellations.next() != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func capsCounters() {
        var snapshot = UsageTelemetry.Snapshot(day: "2026-11-19", version: "1", context: Self.context(), installAge: "d0", usedDays: 0)
        snapshot.outcomes = ["screenshot": 1_000_000, "recording": 999_999]
        snapshot.features = ["captureArea": ["hotkey": 1_000_000]]
        snapshot.record(.screenshot)
        snapshot.record(.recording)
        snapshot.record(.recording)
        snapshot.recordFeature("captureArea", from: .hotkey)
        #expect(snapshot.outcomes == ["screenshot": 1_000_000, "recording": 1_000_000])
        #expect(snapshot.features == ["captureArea": ["hotkey": 1_000_000]])
    }
}
