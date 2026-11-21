import Foundation
import Testing
@testable import OMSCore

struct AtomicFileCopyTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSAtomicCopy-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func createsAndReplacesWithoutChangingTheSource() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mp4"), target = directory.appending(path: "movie.mp4")
        let bytes = Data((0..<65_536).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        try await AtomicFileCopy.copy(from: source, to: target)
        #expect(try Data(contentsOf: target) == bytes)
        try Data("previous movie".utf8).write(to: target)
        try await AtomicFileCopy.copy(from: source, to: target)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["movie.mp4", "source.mp4"])
    }

    @Test func partialCopyFailureLeavesTheExistingMovieIntact() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "movie.mp4")
        let old = Data("irreplaceable previous file".utf8)
        try old.write(to: target)
        #expect(throws: CocoaError.self) {
            try AtomicFileCopy.perform(from: directory.appending(path: "source.mp4"), to: target, copy: { _, temporary in
                try Data("partial copy".utf8).write(to: temporary)
                #expect(try Data(contentsOf: target) == old)
                throw CocoaError(.fileWriteOutOfSpace)
            })
        }
        #expect(try Data(contentsOf: target) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["movie.mp4"])
    }

    @Test func cancellationBeforeCommitLeavesTheExistingMovieIntact() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "movie.mp4")
        let old = Data("previous file".utf8)
        try old.write(to: target)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try AtomicFileCopy.perform(from: directory.appending(path: "source.mp4"), to: target, copy: { _, temporary in
                try Data("new file".utf8).write(to: temporary)
            }, checkCancellation: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            })
        }
        #expect(try Data(contentsOf: target) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["movie.mp4"])
    }

    @Test func aFailedRenamePreservesTheDestinationAndRemovesStaging() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mp4"), target = directory.appending(path: "existing-folder")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appending(path: "contents"))
        await #expect(throws: POSIXError.self) { try await AtomicFileCopy.copy(from: source, to: target) }
        #expect(try String(contentsOf: target.appending(path: "contents"), encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["existing-folder", "source.mp4"])
    }

    @Test func savingAsOverAMovieWhoseRecordingIsGoneKeepsTheMovieAndSaysWhy() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "movie.mp4")
        let old = Data("the movie that was there".utf8)
        try old.write(to: target)
        let outcome = await AtomicFileCopy.save(directory.appending(path: "gone.mp4"), as: target)
        #expect(outcome.failure?.cause == .sourceMissing)
        #expect(try Data(contentsOf: target) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["movie.mp4"])
    }

    @Test func savingARecordingAsItselfKeepsIt() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "recording.mp4")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        // Not saved: taken for a copy, the card would close as saved, and with History off the recording would go.
        let itself = await AtomicFileCopy.save(source, as: source)
        #expect(itself.url == nil && itself.failure != nil)
        // However its path is written.
        let alias = directory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        #expect(await AtomicFileCopy.save(source, as: alias.appending(path: "recording.mp4")).url == nil)
        #expect(try Data(contentsOf: source) == bytes)
        // A link to it is a file of its own: replaced by a copy, the recording left as it is.
        let link = directory.appending(path: "link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(await AtomicFileCopy.save(source, as: link) == .saved(link))
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try Data(contentsOf: link) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["alias", "link.mp4", "recording.mp4"])
    }

    @Test func savingOntoTheSourceAndReplacingASymlinkAreSafe() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mp4"), old = directory.appending(path: "old.mp4")
        let link = directory.appending(path: "link.mp4")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: old)
        try await AtomicFileCopy.copy(from: source, to: source)
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        try await AtomicFileCopy.copy(from: source, to: link)
        #expect(try String(contentsOf: link, encoding: .utf8) == "new")
        #expect(try String(contentsOf: old, encoding: .utf8) == "old")
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    }
}
