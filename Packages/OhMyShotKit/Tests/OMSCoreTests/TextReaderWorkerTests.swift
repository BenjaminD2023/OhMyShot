import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing
@testable import OMSCore

struct TextReaderWorkerTests {
    private let picture = URL(filePath: "/tmp/p.tiff")

    private func helper(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSTextReaderWorkerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "reader")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private let identify = "id=$(printf '%s' \"$line\" | sed -E 's/.*\"id\":\"([^\"]+)\".*/\\1/')"
    private let emptyAnswer = "printf '{\"id\":\"%s\",\"visionLines\":\"W10=\"}\\n' \"$id\""

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func nearbyJobsKeepTheSameLoadedProcessAndIdleExpiryReleasesIt() async throws {
        let reader = try helper("""
        count=0
        while IFS= read -r line; do
          \(identify)
          count=$((count+1))
          printf '%s' "$count" > "$0.count"
          \(emptyAnswer)
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources, idleTimeout: .milliseconds(500))
        #expect(try await worker.visionLines(ofPictureAt: picture) == Data("[]".utf8))
        #expect(try await worker.visionLines(ofPictureAt: picture) == Data("[]".utf8))
        #expect(try String(contentsOfFile: reader.path + ".count", encoding: .utf8) == "2")
        #expect(resources.snapshot[.helperProcess] == 1)
        try await eventually { resources.isIdle }
        #expect(try await worker.visionLines(ofPictureAt: picture) == Data("[]".utf8))
        #expect(try String(contentsOfFile: reader.path + ".count", encoding: .utf8) == "1")
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func aSessionMayStayWarmUntilExplicitlyStopped() async throws {
        let reader = try helper("while IFS= read -r line; do\n\(identify)\n\(emptyAnswer)\ndone")
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources, idleTimeout: nil)
        _ = try await worker.visionLines(ofPictureAt: picture)
        try await Task.sleep(for: .milliseconds(150))
        #expect(resources.snapshot[.helperProcess] == 1)
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func droppingTheWorkerEndsItsIdleProcess() async throws {
        let reader = try helper("while IFS= read -r line; do\n\(identify)\n\(emptyAnswer)\ndone")
        let resources = ActiveResources()
        var worker: TextReaderWorker? = TextReaderWorker(helper: reader, resources: resources, idleTimeout: nil)
        _ = try await worker?.visionLines(ofPictureAt: picture)
        worker = nil
        try await eventually { resources.isIdle }
    }

    @Test func cancellationKillsStalledNativeWorkAndTheNextJobGetsAFreshWorker() async throws {
        let reader = try helper("""
        trap '' TERM
        while IFS= read -r line; do
          \(identify)
          case "$line" in *slow*) printf '%s' "$$" > "$0.pid"; while :; do :; done ;; esac
          \(emptyAnswer)
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        let reading = Task { try await worker.visionLines(ofPictureAt: URL(filePath: "/tmp/slow.tiff")) }
        defer { reading.cancel() }
        try await eventually { FileManager.default.fileExists(atPath: reader.path + ".pid") }
        let pid = try #require(Int32(String(contentsOfFile: reader.path + ".pid", encoding: .utf8)))
        let started = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(try await worker.visionLines(ofPictureAt: picture) == Data("[]".utf8))
        try await eventually { kill(pid, 0) != 0 }
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func waitingJobsHaveTheirOwnDeadlineWithoutKillingTheCurrentJob() async throws {
        let reader = try helper("""
        count=0
        while IFS= read -r line; do
          \(identify)
          count=$((count+1))
          printf '%s' "$count" > "$0.count"
          case "$line" in *slow*) /bin/sleep 0.5 ;; esac
          \(emptyAnswer)
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        let first = Task { try await worker.visionLines(ofPictureAt: URL(filePath: "/tmp/slow.tiff")) }
        try await eventually { FileManager.default.fileExists(atPath: reader.path + ".count") }
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await worker.visionLines(ofPictureAt: picture, timeout: .milliseconds(100))
        }
        #expect(try await first.value == Data("[]".utf8))
        #expect(try String(contentsOfFile: reader.path + ".count", encoding: .utf8) == "1")
        _ = try await worker.visionLines(ofPictureAt: picture)
        #expect(try String(contentsOfFile: reader.path + ".count", encoding: .utf8) == "2")
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func formulaInputMetadataAndElementProgressSurviveTheProtocol() async throws {
        let reader = try helper("""
        while IFS= read -r line; do
          \(identify)
          case "$line" in
            *visionCompatibility*) printf '%s' "$line" > "$0.job"; \(emptyAnswer) ;;
            *) printf '{"id":"%s","found":2,"foundTables":1}\\n' "$id"
               printf '{"id":"%s","formulas":[{"kind":"inline","box":[[1,2],[3,4]],"latex":"x"}],"tables":[],"tablesLeft":1}\\n' "$id" ;;
          esac
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        let formulas = [TextReaderTool.FoundFormula(kind: "inline", box: CGRect(x: 1, y: 2, width: 3, height: 4), latex: "x")]
        let payload = Data(#"[{"text":"exact","isExact":true}]"#.utf8)
        _ = try await worker.visionLines(ofPictureAt: picture, formulas: formulas, inputLines: payload)
        struct Posted: Decodable {
            let visionCompatibility: Bool
            let visionFormulas: [TextReaderTool.FoundFormula]
            let visionInputLines: Data
        }
        let posted = try JSONDecoder().decode(Posted.self, from: Data(contentsOf: URL(filePath: reader.path + ".job")))
        #expect(posted.visionCompatibility && posted.visionFormulas == formulas && posted.visionInputLines == payload)
        let counts = Mutex<[TextReaderTool.Found]>([])
        let result = try await worker.elements(ofPictureAt: picture, formulas: URL(filePath: "/packs/formulas"), found: { found in counts.withLock { $0.append(found) } })
        #expect(result.formulas == formulas && result.tables.isEmpty && result.tablesLeft == 1)
        #expect(counts.withLock { $0 } == [.init(formulas: 1, tables: 1)])
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func modernVisionIsRequestedExplicitlyWithoutChangingItsMode() async throws {
        let reader = try helper("""
        while IFS= read -r line; do
          \(identify)
          case "$line" in *'"visionCompatibility":false'*) ;; *) exit 4 ;; esac
          \(emptyAnswer)
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        #expect(try await worker.visionLines(ofPictureAt: picture, compatibility: false) == Data("[]".utf8))
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func staleAnswersCannotCompleteAnotherJob() async throws {
        let reader = try helper("""
        while IFS= read -r line; do
          \(identify)
          printf '{"id":"stale","visionLines":"e30="}\\n'
          \(emptyAnswer)
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        #expect(try await worker.visionLines(ofPictureAt: picture) == Data("[]".utf8))
        #expect(try await worker.visionLines(ofPictureAt: picture) == Data("[]".utf8))
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func anExitedReaderReportsItsStatusAndCanBeRestarted() async throws {
        let reader = try helper("read line\nexit 3")
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        for _ in 0..<2 {
            await #expect(throws: TextReaderTool.Failure.noAnswer(status: 3)) {
                try await worker.visionLines(ofPictureAt: picture)
            }
        }
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func aRetiringAnswerIsDeliveredBeforeTheNextJobStartsAFreshProcess() async throws {
        let reader = try helper("""
        count=0
        while IFS= read -r line; do
          \(identify)
          case "$line" in *'"reusesProcess":true'*) ;; *) exit 4 ;; esac
          count=$((count+1))
          printf '%s' "$count" > "$0.count"
          printf '{"id":"%s","visionLines":"W10=","retire":true}\\n' "$id"
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        let first = Task { try await worker.visionLines(ofPictureAt: picture) }
        let second = Task { try await worker.visionLines(ofPictureAt: picture) }
        #expect(try await first.value == Data("[]".utf8))
        #expect(try await second.value == Data("[]".utf8))
        #expect(try String(contentsOfFile: reader.path + ".count", encoding: .utf8) == "1")
        try await eventually { resources.isIdle }
        await worker.stop()
    }

    @Test func aFailedNativeReaderIsReplacedBeforeTheNextJob() async throws {
        let reader = try helper("""
        poisoned=false
        if [ ! -e "$0.started" ]; then
          touch "$0.started"
          poisoned=true
        fi
        while IFS= read -r line; do
          \(identify)
          if [ "$poisoned" = true ]; then
            printf '{"id":"%s","error":"nativePredictionFailed"}\\n' "$id"
          else
            \(emptyAnswer)
          fi
        done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        await #expect(throws: TextReaderTool.Failure.unreadable("nativePredictionFailed")) {
            try await worker.visionLines(ofPictureAt: picture)
        }
        #expect(try await worker.visionLines(ofPictureAt: picture) == Data("[]".utf8))
        await worker.stop()
        try await eventually { resources.isIdle }
    }

    @Test func aFullInputPipeCannotDelayTheDeadlineOrCleanup() async throws {
        let reader = try helper("trap '' TERM\nwhile :; do :; done")
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        let started = ContinuousClock.now
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await worker.visionLines(ofPictureAt: picture, inputLines: Data(repeating: 65, count: 2 * 1024 * 1024), timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        try await eventually { resources.isIdle }
    }

    @Test func elementProgressCannotExtendTheDeadline() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        \(identify)
        printf '{"id":"%s","found":1,"foundTables":0}\\n' "$id"
        while :; do :; done
        """)
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: reader, resources: resources)
        let counts = Mutex(0)
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await worker.elements(ofPictureAt: picture, found: { _ in counts.withLock { $0 += 1 } }, timeout: .seconds(1))
        }
        #expect(counts.withLock { $0 } == 1)
        try await eventually { resources.isIdle }
    }

    @Test func missingHelperFailsWithoutLeakingResources() async throws {
        let resources = ActiveResources()
        let worker = TextReaderWorker(helper: URL(filePath: "/nonexistent/reader"), resources: resources)
        await #expect(throws: TextReaderTool.Failure.self) { try await worker.visionLines(ofPictureAt: picture) }
        #expect(resources.isIdle)
    }
}
