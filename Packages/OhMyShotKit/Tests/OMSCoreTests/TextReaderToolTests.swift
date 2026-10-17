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

    @Test func noReaderIsUnavailable() async throws {
        await #expect(throws: TextReaderTool.Failure.self) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: URL(filePath: "/nonexistent/reader"), resources: ActiveResources()
            )
        }
    }
}
