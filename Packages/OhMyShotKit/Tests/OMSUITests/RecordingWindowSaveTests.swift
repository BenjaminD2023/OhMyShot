import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSUI

@MainActor
@Suite(.serialized)
struct RecordingWindowSaveTests {
    private func window(file: URL, save: @escaping (URL) -> URL?) -> RecordingWindowController {
        RecordingWindowController(
            fileURL: file, title: "Recording", pixelWidth: 1, pixelHeight: 1, pixelsPerPoint: nil, hasOriginal: false,
            actions: .init(keep: { _ in file }, revert: { file }, makeGIF: { _ in }, save: save, copy: { _ in })
        )
    }

    @Test func saveAndSaveAsReportOnlyCompletedExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RecordingWindowSaveTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try Data([1, 2, 3]).write(to: source)
        let saved = folder.appending(path: "saved.mp4")
        var saveResult: URL? = saved
        let editor = window(file: source) { _ in saveResult }
        defer { editor.window?.close() }
        var reportedURLs: [URL] = []
        var reportedCurrentness: [Bool] = []
        editor.onSaved = { url, isCurrent in
            reportedURLs.append(url)
            reportedCurrentness.append(isCurrent)
        }

        #expect(editor.saveCopy(source) == saved)
        saveResult = nil
        #expect(editor.saveCopy(source) == nil)
        #expect(reportedURLs == [saved])
        #expect(reportedCurrentness == [true])

        let canceled = await editor.saveCopyAs(from: source, to: nil)
        if case .some = canceled { #expect(Bool(false), "Canceled Save As reported a result") }
        #expect(reportedURLs == [saved])
        #expect(reportedCurrentness == [true])

        let destination = folder.appending(path: "saved-as.mp4")
        let copied = await editor.saveCopyAs(from: source, to: destination)
        guard case .saved(let copiedURL)? = copied else {
            #expect(Bool(false), "Save As should complete")
            return
        }
        #expect(copiedURL == destination)
        #expect(reportedURLs == [saved, destination])
        #expect(reportedCurrentness == [true, true])

        let alias = folder.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let sameFile = await editor.saveCopyAs(from: source, to: alias.appending(path: source.lastPathComponent))
        #expect(sameFile?.url == nil && sameFile?.failure != nil)
        #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
        #expect(reportedURLs == [saved, destination])
        #expect(reportedCurrentness == [true, true])

        let missing = folder.appending(path: "missing.mp4")
        let failed = await editor.saveCopyAs(from: missing, to: folder.appending(path: "failed.mp4"))
        guard case .failed? = failed else {
            #expect(Bool(false), "A failed copy should return a failure")
            return
        }
        #expect(reportedURLs == [saved, destination])
        #expect(reportedCurrentness == [true, true])
    }

    @Test func saveAsResultAfterContentRevisionChangeDoesNotMarkTheOldExportCurrent() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RecordingWindowSaveRevisionTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try Data([1, 2, 3]).write(to: source)
        let destination = folder.appending(path: "saved-as.mp4")
        let editor = window(file: source) { _ in nil }
        defer { editor.window?.close() }
        var reportedURLs: [URL] = []
        var reportedCurrentness: [Bool] = []
        editor.onSaved = { url, isCurrent in
            reportedURLs.append(url)
            reportedCurrentness.append(isCurrent)
        }

        let (startedEvents, announceStarted) = AsyncStream<Void>.makeStream()
        let startedReader = AsyncEventReader(startedEvents)
        let gate = AsyncSaveOutcomeGate()
        let saveTask = Task {
            await editor.saveCopyAs(from: source, to: destination) { _, _ in
                announceStarted.yield(())
                return await gate.wait()
            }
        }
        guard await waitForEvent(from: startedReader) != nil else {
            await gate.complete(.cancelled)
            _ = await saveTask.value
            #expect(Bool(false), "Save As did not reach the controlled copy")
            return
        }

        editor.contentChanged(to: source)
        await gate.complete(.saved(destination))
        #expect(await saveTask.value == .saved(destination))
        #expect(reportedURLs == [destination])
        #expect(reportedCurrentness == [false])
        announceStarted.finish()
    }
}
