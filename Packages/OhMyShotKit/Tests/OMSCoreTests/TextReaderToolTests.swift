import CoreGraphics
import Foundation
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
        #expect(formula == .init(latex: "x^{2}+y^{2}", ending: "end"))
        #expect(formula.isFormula)
        #expect(resources.isIdle)
    }

    @Test func aStoppedReadingIsNoFormula() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"latex\":\"0000000000\",\"ending\":\"repeats\"}\\n' \"$id\"")
        let formula = try await TextReaderTool.formula(ofPictureAt: URL(filePath: "/tmp/f.tiff"), pack: URL(filePath: "/packs/formula"), helper: reader, resources: ActiveResources())
        #expect(formula.ending == "repeats" && !formula.isFormula)
        #expect(!TextReaderTool.Formula(latex: " ", ending: "end").isFormula)
    }

    @Test func warmingTheFormulaPackReadsNoPicture() async throws {
        let reader = try helper(answering + """

        case "$line" in *'"path"'*) exit 4 ;; *'"warm":true'*) ;; *) exit 5 ;; esac
        case "$line" in *'"formula":"/packs/formula"'*) ;; *) exit 6 ;; esac
        printf '{"id":"%s","text":""}\\n' "$id"
        """)
        try await TextReaderTool.warm(formula: URL(filePath: "/packs/formula"), helper: reader, resources: ActiveResources())
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

    @Test func noReaderIsUnavailable() async throws {
        await #expect(throws: TextReaderTool.Failure.self) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: URL(filePath: "/nonexistent/reader"), resources: ActiveResources()
            )
        }
    }
}
