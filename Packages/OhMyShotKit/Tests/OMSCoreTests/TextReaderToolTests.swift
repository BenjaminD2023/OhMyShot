import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// The one-picture run of the text reader, against stand-in readers written as shell scripts. Each test keeps its
/// own `ActiveResources`, so suites watching the shared one (HistoryTextTests) never see these runs.
struct TextReaderToolTests {
    private func helper(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSTextReaderToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "reader")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        return script
    }

    /// Reads the job, then answers for its id.
    private let answering = """
    read line
    id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
    join=$(printf '%s' "$line" | sed -E 's/.*"joinsWrappedLines":(true|false).*/\\1/')
    """

    @Test func theReaderIsAskedHowToAssembleAndItsTextComesBack() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"text\":\"join=%s\"}\\n' \"$id\" \"$join\"")
        let resources = ActiveResources()
        let joined = try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources)
        #expect(joined == "join=true")
        let kept = try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: false, helper: reader, resources: resources)
        #expect(kept == "join=false")
        #expect(resources.isIdle)
    }

    @Test func aReaderThatCouldNotReadSaysWhy() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"error\":\"unreadableImage\"}\\n' \"$id\"")
        await #expect(throws: TextReaderTool.Failure.unreadable("unreadableImage")) {
            try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: ActiveResources())
        }
    }

    @Test func aReaderThatEndsWithoutAnsweringIsNoAnswer() async throws {
        let reader = try helper("read line\nexit 3")
        let resources = ActiveResources()
        await #expect(throws: TextReaderTool.Failure.noAnswer(status: 3)) {
            try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources)
        }
        #expect(resources.isIdle)
    }

    @Test func thePacksOwnLinesComeBackWithTheirBoxes() async throws {
        // The job asks for the pack's lines alone, from its folder.
        let reader = try helper(answering + """

        case "$line" in *'"lines":true'*) ;; *) exit 4 ;; esac
        case "$line" in *packs*l2*) ;; *) exit 5 ;; esac
        printf '{"id":"%s","lines":[{"text":"打开设置","box":[[10,20],[120,30]],"confidence":0.98}]}\\n' "$id"
        """)
        let resources = ActiveResources()
        let lines = try await TextReaderTool.lines(ofPictureAt: URL(filePath: "/tmp/p.tiff"), pack: URL(filePath: "/packs/l2"), helper: reader, resources: resources)
        #expect(lines == [.init(text: "打开设置", box: CGRect(x: 10, y: 20, width: 120, height: 30), confidence: 0.98)])
        #expect(resources.isIdle)
    }

    @Test func compatibilityVisionAsksForNoPacksAndKeepsTheCompleteLinePayload() async throws {
        // OMSCore transports the full OCR payload without interpreting or dropping any metadata.
        let payload = Data(#"[{"text":"打开设置 Text","box":[[10,20],[120,30]],"confidence":0.98,"direction":"leftToRight","wrapsToNextLine":true}]"#.utf8)
        let reader = try helper(answering + """

        case "$line" in *'"visionCompatibility":true'*) ;; *) exit 4 ;; esac
        case "$line" in *'"pack"'*|*'"formulas"'*|*'"vlm"'*|*'"lines"'*) exit 5 ;; esac
        case "$line" in *'"path":"/tmp/p.tiff"'*) ;; *) exit 6 ;; esac
        printf '{"id":"%s","visionLines":"\(payload.base64EncodedString())"}\\n' "$id"
        """)
        let resources = ActiveResources()
        let lines = try await TextReaderTool.visionLines(ofPictureAt: URL(filePath: "/tmp/p.tiff"), helper: reader, resources: resources)
        #expect(lines == payload)
        #expect(resources.isIdle)
    }

    @Test func compatibilityVisionCanReturnNoLines() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"visionLines\":\"W10=\"}\\n' \"$id\"")
        let lines = try await TextReaderTool.visionLines(ofPictureAt: URL(filePath: "/tmp/p.tiff"), helper: reader, resources: ActiveResources())
        #expect(lines == Data("[]".utf8))
    }

    @Test func compatibilityVisionCarriesFormulaGeometryWithoutLoadingAPack() async throws {
        let reader = try helper(answering + """

        printf '%s' "$line" > "$0.job"
        printf '{"id":"%s","visionLines":"W10="}\\n' "$id"
        """)
        let formulas = [TextReaderTool.FoundFormula(kind: .display, box: CGRect(x: 10.5, y: 20, width: 120, height: 30.25), latex: "x^{2}")]
        let input = Data(#"[{"text":"exact original","box":[[1,2],[3,4]],"confidence":1,"isExact":true,"isTableRow":false}]"#.utf8)
        _ = try await TextReaderTool.visionLines(
            ofPictureAt: URL(filePath: "/tmp/p.tiff"), helper: reader, formulas: formulas, inputLines: input, resources: ActiveResources()
        )
        struct Posted: Decodable {
            let visionCompatibility: Bool
            let visionFormulas: [TextReaderTool.FoundFormula]
            let visionInputLines: Data
            let pack: String?
            let formulas: String?
            let vlm: String?
        }
        let posted = try JSONDecoder().decode(Posted.self, from: Data(contentsOf: URL(filePath: reader.path + ".job")))
        #expect(posted.visionCompatibility && posted.visionFormulas == formulas)
        #expect(posted.visionInputLines == input)
        #expect(posted.pack == nil && posted.formulas == nil && posted.vlm == nil)
    }

    @Test func compatibilityVisionReportsItsFailure() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"error\":\"unsupportedLanguages\"}\\n' \"$id\"")
        await #expect(throws: TextReaderTool.Failure.unreadable("unsupportedLanguages")) {
            try await TextReaderTool.visionLines(ofPictureAt: URL(filePath: "/tmp/p.tiff"), helper: reader, resources: ActiveResources())
        }
    }

    @Test func compatibilityVisionDoesNotAcceptAnUnrelatedAnswer() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"text\":\"unrelated\"}\\n' \"$id\"")
        await #expect(throws: TextReaderTool.Failure.unreadable("")) {
            try await TextReaderTool.visionLines(ofPictureAt: URL(filePath: "/tmp/p.tiff"), helper: reader, resources: ActiveResources())
        }
    }

    @Test func warmingAPackReadsNoPicture() async throws {
        let reader = try helper(answering + """

        case "$line" in *'"path"'*) exit 4 ;; *'"warm":true'*) ;; *) exit 5 ;; esac
        printf '{"id":"%s","text":""}\\n' "$id"
        """)
        try await TextReaderTool.warm(pack: URL(filePath: "/packs/l2"), helper: reader, resources: ActiveResources())
    }

    @Test func aFormulaComesBackWithHowItsReadingEnded() async throws {
        // The job names the formula pack, not a PP-OCR one; the LaTeX comes back without spaces at its ends.
        let reader = try helper(answering + """

        case "$line" in *'"formula":"/packs/formula"'*) ;; *) exit 4 ;; esac
        case "$line" in *'"pack"'*) exit 5 ;; esac
        printf '{"id":"%s","latex":" x^{2}+y^{2} ","ending":"end"}\\n' "$id"
        """)
        let resources = ActiveResources()
        let formula = try await TextReaderTool.formula(ofPictureAt: URL(filePath: "/tmp/f.tiff"), pack: URL(filePath: "/packs/formula"), helper: reader, resources: resources)
        #expect(formula == .init(latex: "x^{2}+y^{2}", ended: .end))
        #expect(formula.isFormula)
        #expect(resources.isIdle)
    }

    @Test func aStoppedReadingIsNoFormula() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"latex\":\"0000000000\",\"ending\":\"repeats\"}\\n' \"$id\"")
        let formula = try await TextReaderTool.formula(ofPictureAt: URL(filePath: "/tmp/f.tiff"), pack: URL(filePath: "/packs/formula"), helper: reader, resources: ActiveResources())
        #expect(formula.ended == .repeats && !formula.isFormula)
        #expect(!TextReaderTool.Formula(latex: " ", ended: .end).isFormula)
    }

    @Test func warmingTheFormulaPackReadsNoPicture() async throws {
        let reader = try helper(answering + """

        case "$line" in *'"path"'*) exit 4 ;; *'"warm":true'*) ;; *) exit 5 ;; esac
        case "$line" in *'"formula":"/packs/formula"'*) ;; *) exit 6 ;; esac
        printf '{"id":"%s","text":""}\\n' "$id"
        """)
        try await TextReaderTool.warm(formula: URL(filePath: "/packs/formula"), helper: reader, resources: ActiveResources())
    }

    private final class FoundCounts: Sendable {
        let all = Mutex<[TextReaderTool.Found]>([])
    }

    @Test func tablesLeftForWantOfMemoryAreCounted() async throws {
        // The pressure the app stands in for the system's goes to the reader, which says how many tables it left.
        let reader = try helper(answering + """

        case "$line" in *'"vlm":"/packs/vlm"'*) ;; *) exit 6 ;; esac
        case "$line" in *'"pressure":"warning"'*) ;; *) exit 7 ;; esac
        printf '{"id":"%s","found":1,"foundTables":0}\\n' "$id"
        printf '{"id":"%s","formulas":[{"kind":"inline","box":[[1,2],[3,4]],"latex":"x"}],"tables":[],"tablesLeft":2}\\n' "$id"
        """)
        let found = FoundCounts()
        let read = try await TextReaderTool.elements(
            ofPictureAt: URL(filePath: "/tmp/p.png"), formulas: URL(filePath: "/packs/formula"), vlm: URL(filePath: "/packs/vlm"),
            pressure: .warning, helper: reader, found: { counts in found.all.withLock { $0.append(counts) } }, resources: ActiveResources()
        )
        #expect(read.formulas.map(\.latex) == ["x"] && read.tables.isEmpty && read.tablesLeft == 2)
        #expect(found.all.withLock { $0 } == [TextReaderTool.Found(formulas: 1, tables: 0)])
        #expect(MemoryPressure(name: "critical") == .critical && MemoryPressure(name: "high") == nil)
        #expect(MemoryPressure.warning > .normal && MemoryPressure.current() >= .normal)
    }

    @Test func tidyingReadsNothingAndSaysHowMuchWent() async throws {
        let reader = try helper(answering + """

        case "$line" in *'"path"'*|*'"pack"'*|*'"formula"'*) exit 4 ;; *'"tidy":true'*) ;; *) exit 5 ;; esac
        printf '{"id":"%s","removed":2}\\n' "$id"
        """)
        let resources = ActiveResources()
        #expect(try await TextReaderTool.tidy(helper: reader, resources: resources) == 2)
        #expect(resources.isIdle)
    }

    @Test func theWireLeavesOutWhatIsNotSaid() throws {
        // The lines the app and the reader passed each other when each declared the messages for itself. The encoder
        // puts the keys in no particular order; sorted, they can be compared.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let job = TextReaderWire.Job(id: "a", path: "/p.png", pack: "/packs/l2", pressure: .warning)
        #expect(String(decoding: try encoder.encode(job), as: UTF8.self) == #"{"id":"a","pack":"\/packs\/l2","path":"\/p.png","pressure":"warning"}"#)
        let found = TextReaderWire.Answer.found(id: "a", formulas: 2, tables: 1)
        #expect(String(decoding: try encoder.encode(found), as: UTF8.self) == #"{"found":3,"foundTables":1,"id":"a"}"#)
        #expect(found.progress == TextReaderTool.Found(formulas: 2, tables: 1))

        let answer = try JSONDecoder().decode(TextReaderWire.Answer.self, from: Data(#"""
        {"id":"a","formulas":[{"kind":"display","box":[[1,2],[3,4]],"latex":"x"}],"tables":[{"kind":"chart","box":[[0,0],[5,5]],"rows":[["1"]],"whole":false}]}
        """#.utf8))
        #expect(answer.progress == nil)
        #expect(answer.formulas == [.init(kind: .display, box: CGRect(x: 1, y: 2, width: 3, height: 4), latex: "x")])
        #expect(answer.tables?.map(\.kind) == [.chart])
        #expect(try JSONDecoder().decode(TextReaderWire.Job.self, from: Data(#"{"id":"a","pressure":"critical"}"#.utf8)).pressure == .critical)
        // A pressure the reader has no name for is none, and the job is still read and answered.
        let unnamed = try JSONDecoder().decode(TextReaderWire.Job.self, from: Data(#"{"id":"a","path":"/p.png","pressure":"dire"}"#.utf8))
        #expect(unnamed.pressure == nil && unnamed.path == "/p.png")
    }

    @Test func aJobIsTheFirstModeItsFieldsName() {
        #expect(TextReaderWire.Job(id: "a", pack: "/l2", tidy: true).mode == .tidy)
        #expect(TextReaderWire.Job(id: "a", warm: true, formula: "/f", vlm: "/v").mode == .warmVLM(pack: "/v"))
        #expect(TextReaderWire.Job(id: "a", path: "/p", vlm: "/v", task: "table").mode == .vlm(pack: "/v", task: "table"))
        #expect(TextReaderWire.Job(id: "a", warm: true, formula: "/f").mode == .warmFormula(pack: "/f"))
        #expect(TextReaderWire.Job(id: "a", path: "/p", pack: "/l2", formula: "/f").mode == .formula(pack: "/f"))
        #expect(TextReaderWire.Job(id: "a", pack: "/l2", warm: true).mode == .warmPack(pack: "/l2"))
        #expect(TextReaderWire.Job(id: "a", path: "/p", pack: "/l2", lines: true).mode == .lines(pack: "/l2"))
        #expect(TextReaderWire.Job(id: "a", path: "/p", formulas: "/f", vlm: "/v").mode == .elements)
        #expect(TextReaderWire.Job(id: "a", path: "/p", joinsWrappedLines: true, formulas: "/f").mode == .text)
        #expect(TextReaderWire.Job(id: "a", path: "/p", pack: "/l2").mode == .text)
    }

    @Test func noReaderIsUnavailable() async throws {
        await #expect(throws: TextReaderTool.Failure.self) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: URL(filePath: "/nonexistent/reader"), resources: ActiveResources()
            )
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func finishingTheElementBudgetStillReturnsCompletedFormulasAndTables() async throws {
        let reader = try helper(answering + """

        seconds=$(printf '%s' "$line" | sed -E 's/.*"seconds":([0-9.]+).*/\\1/')
        # Startup and decoding precede the helper's own reading budget.
        /bin/sleep 0.05
        printf '{"id":"%s","found":3,"foundTables":2}\\n' "$id"
        # The first formula and table are complete; the last table uses the remaining budget.
        /bin/sleep "$seconds"
        printf '{"id":"%s","formulas":[{"kind":"inline","box":[[1,2],[3,4]],"latex":"x"}],"tables":[{"kind":"table","box":[[10,20],[30,40]],"rows":[["A","B"]],"whole":true}]}\\n' "$id"
        /bin/sleep 0.05
        """)
        defer { try? FileManager.default.removeItem(at: reader.deletingLastPathComponent()) }
        let resources = ActiveResources()
        let read = try await TextReaderTool.elements(
            ofPictureAt: URL(filePath: "/tmp/p.png"), formulas: URL(filePath: "/packs/formula"), vlm: URL(filePath: "/packs/vlm"),
            seconds: 0.3, helper: reader, resources: resources
        )
        #expect(read.formulas.map(\.latex) == ["x"])
        #expect(read.tables.map(\.rows) == [[["A", "B"]]])
        #expect(resources.isIdle)
    }

    @Test func anElementBudgetStillBoundsAReaderThatNeverAnswers() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        while :; do :; done
        """)
        defer { try? FileManager.default.removeItem(at: reader.deletingLastPathComponent()) }
        let resources = ActiveResources()
        let reading = Task {
            try await TextReaderTool.elements(
                ofPictureAt: URL(filePath: "/tmp/p.png"), vlm: URL(filePath: "/packs/vlm"), seconds: 0.1,
                helper: reader, resources: resources
            )
        }
        // Bound the test too if the implicit process deadline ever regresses to the 120-second default.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { reading.cancel() }
        }
        defer { watchdog.cancel(); reading.cancel() }
        await #expect(throws: TextReaderTool.Failure.timedOut) { try await reading.value }
        try await eventually { resources.isIdle }
    }

    @Test func aDeadlineStopsNativeWorkThatIgnoresTermination() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """)
        let resources = ActiveResources()
        // Process startup on a busy Mac can itself take a few hundred milliseconds. Leave enough
        // time to exercise the scripted hang, rather than timing out before the script reaches it.
        let started = ContinuousClock.now
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources,
                timeout: .seconds(2)
            )
        }
        #expect(ContinuousClock.now - started < .seconds(4))
        let pid = try #require(Int32(String(contentsOfFile: reader.path + ".pid", encoding: .utf8)))
        try await eventually { resources.isIdle && kill(pid, 0) != 0 }
    }

    @Test func cancellingAHungReaderReturnsAndKillsIt() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """)
        let resources = ActiveResources()
        let reading = Task {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources
            )
        }
        defer { reading.cancel() }
        try await eventually { FileManager.default.fileExists(atPath: reader.path + ".pid") }
        let pid = try #require(Int32(String(contentsOfFile: reader.path + ".pid", encoding: .utf8)))
        let started = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        try await eventually { resources.isIdle && kill(pid, 0) != 0 }
    }

    @Test func compatibilityVisionHasACompleteRunDeadline() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """)
        let resources = ActiveResources()
        let started = ContinuousClock.now
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.visionLines(
                ofPictureAt: URL(filePath: "/tmp/p.tiff"), helper: reader, resources: resources, timeout: .seconds(2)
            )
        }
        #expect(ContinuousClock.now - started < .seconds(4))
        let pid = try #require(Int32(String(contentsOfFile: reader.path + ".pid", encoding: .utf8)))
        try await eventually { resources.isIdle && kill(pid, 0) != 0 }
    }

    @Test func cancellingCompatibilityVisionKillsItsNativeProcess() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """)
        let resources = ActiveResources()
        let reading = Task {
            try await TextReaderTool.visionLines(ofPictureAt: URL(filePath: "/tmp/p.tiff"), helper: reader, resources: resources)
        }
        defer { reading.cancel() }
        try await eventually { FileManager.default.fileExists(atPath: reader.path + ".pid") }
        let pid = try #require(Int32(String(contentsOfFile: reader.path + ".pid", encoding: .utf8)))
        let started = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        try await eventually { resources.isIdle && kill(pid, 0) != 0 }
    }

    @Test func closingOutputWithoutExitingStillHasADeadline() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        exec 1>&-
        while :; do :; done
        """)
        let resources = ActiveResources()
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.lines(
                ofPictureAt: URL(filePath: "/tmp/p.png"), pack: URL(filePath: "/packs/l2"), helper: reader,
                resources: resources, timeout: .seconds(2)
            )
        }
        try await eventually { resources.isIdle }
    }

    @Test func progressDoesNotResetTheWholeRunDeadline() async throws {
        let reader = try helper(answering + """

        trap '' TERM
        printf '{"id":"%s","found":2,"foundTables":1}\\n' "$id"
        while :; do :; done
        """)
        let resources = ActiveResources()
        let found = FoundCounts()
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.elements(
                ofPictureAt: URL(filePath: "/tmp/p.png"), formulas: URL(filePath: "/packs/formula"), helper: reader,
                found: { value in found.all.withLock { $0.append(value) } }, resources: resources, timeout: .seconds(2)
            )
        }
        #expect(found.all.withLock { $0 } == [.init(formulas: 1, tables: 1)])
        try await eventually { resources.isIdle }
    }

    @Test func anExitedReadersDescendantCannotKeepTheCallerWaitingOnOutput() async throws {
        let reader = try helper("""
        read line
        /bin/sleep 10 &
        printf '%s' "$!" > "$0.child"
        exit 0
        """)
        defer {
            if let text = try? String(contentsOfFile: reader.path + ".child", encoding: .utf8), let pid = Int32(text) {
                _ = kill(pid, SIGKILL)
            }
        }
        let resources = ActiveResources()
        // Process startup on a busy Mac can itself take a few hundred milliseconds. Leave enough
        // time to exercise the scripted hang, rather than timing out before the script reaches it.
        let started = ContinuousClock.now
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources,
                timeout: .seconds(2)
            )
        }
        #expect(ContinuousClock.now - started < .seconds(4))
        try await eventually { resources.isIdle }
    }

    @Test func cancellingContinuousProgressStopsCallbacksAndCleansUp() async throws {
        let reader = try helper(answering + """

        trap '' TERM
        while :; do
            printf '{"id":"%s","found":1,"foundTables":0}\\n' "$id"
        done
        """)
        let resources = ActiveResources()
        let updates = Mutex(0)
        let reading = Task {
            try await TextReaderTool.elements(
                ofPictureAt: URL(filePath: "/tmp/p.png"), formulas: URL(filePath: "/packs/formula"), helper: reader,
                found: { _ in updates.withLock { $0 += 1 } }, resources: resources
            )
        }
        defer { reading.cancel() }
        try await eventually { updates.withLock { $0 > 0 } }
        let started = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        let stoppedAt = updates.withLock { $0 }
        try await eventually { resources.isIdle }
        try await Task.sleep(for: .milliseconds(100))
        #expect(updates.withLock { $0 } == stoppedAt)
    }
}
