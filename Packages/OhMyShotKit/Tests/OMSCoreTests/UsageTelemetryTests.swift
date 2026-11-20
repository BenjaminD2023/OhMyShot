import Foundation
import Testing
@testable import OMSCore

@MainActor
struct UsageTelemetryTests {
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
        let original = try #require(UsageTelemetry(file: file, version: "1.2.3", macOS: 26, now: { now }) { data in
            sent.append(data)
            throw URLError(.notConnectedToInternet)
        })
        original.record(.screenshot)
        await original.uploadPending()
        #expect(sent.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        original.setEnabled(true)
        original.record(.screenshot)
        await original.uploadPending()
        original.stop()
        let firstData = try #require(sent.first)
        let first = try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: firstData)
        let payload = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        #expect(Set(payload.keys) == ["schema", "day", "id", "version", "macOS", "screenshots", "recordings", "textRecognitions"])
        #expect(first.id.uuidString.split(separator: "-")[2].first == "4")
        #expect(first.day == "2026-11-19")
        #expect(first.screenshots == 1)

        let relaunched = try #require(UsageTelemetry(file: file, version: "2.0", macOS: 27, now: { now }) { sent.append($0) })
        defer { relaunched.stop() }
        relaunched.setEnabled(true)
        relaunched.record(.recording)
        relaunched.record(.textRecognition)
        await relaunched.uploadPending()
        #expect(sent.count == 1)

        now += 15 * 60
        await relaunched.uploadPending()
        let updated = try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: try #require(sent.last))
        #expect(sent.count == 2)
        #expect(updated.id == first.id)
        #expect(updated.version == "1.2.3")
        #expect(updated.macOS == 26)
        #expect(updated.screenshots == 1)
        #expect(updated.recordings == 1)
        #expect(updated.textRecognitions == 1)
        await relaunched.uploadPending()
        #expect(sent.count == 2)

        now += 15 * 60
        await relaunched.uploadPending()
        let tomorrow = try JSONDecoder().decode(UsageTelemetry.Snapshot.self, from: try #require(sent.last))
        #expect(sent.count == 3)
        #expect(tomorrow.day == "2026-11-20")
        #expect(tomorrow.id != first.id)
        #expect(tomorrow.version == "2.0")
        #expect(tomorrow.macOS == 27)
        #expect(tomorrow.screenshots == 0)
        #expect(tomorrow.recordings == 0)
        #expect(tomorrow.textRecognitions == 0)

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
            file: folder.appending(path: "usage.json"), version: "1.2.3", macOS: 26, now: { now }
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

    @Test(.timeLimit(.minutes(1))) func disablingCancelsAnInFlightRequest() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: "usage.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        var starts = started.stream.makeAsyncIterator()
        var cancellations = cancelled.stream.makeAsyncIterator()
        let service = try #require(UsageTelemetry(file: file, version: "1", macOS: 26) { _ in
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
        var snapshot = UsageTelemetry.Snapshot(day: "2026-11-19", version: "1", macOS: 26)
        snapshot.screenshots = 1_000_000
        snapshot.recordings = 999_999
        snapshot.textRecognitions = 1_000_000
        snapshot.record(.screenshot)
        snapshot.record(.recording)
        snapshot.record(.textRecognition)
        #expect(snapshot.screenshots == 1_000_000)
        #expect(snapshot.recordings == 1_000_000)
        #expect(snapshot.textRecognitions == 1_000_000)
    }
}
