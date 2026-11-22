import AppKit
import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSStudio

private actor StudioSaveOutcomeGate {
    private var continuation: CheckedContinuation<SaveOutcome, Never>?
    private var pendingOutcome: SaveOutcome?

    func wait() async -> SaveOutcome {
        if let pendingOutcome {
            self.pendingOutcome = nil
            return pendingOutcome
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ outcome: SaveOutcome) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: outcome)
        } else {
            pendingOutcome = outcome
        }
    }
}

private func waitForEvent(_ stream: AsyncStream<Void>, timeout: Duration = .seconds(3)) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let received = await group.next() ?? false
        group.cancelAll()
        return received
    }
}

@MainActor
@Suite(.serialized)
struct StudioWindowSaveTests {
    private func window(folder: URL, save: @escaping (URL) -> URL?) -> (StudioWindowController, StudioDocument) {
        let source = folder.appending(path: "source.mp4")
        let document = StudioDocument(
            source: source, telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 1), project: StudioProject(), duration: 1,
            recordingSize: CGSize(width: 160, height: 100), folder: folder, hasBeenExported: true, background: { _, _ in nil }
        )
        document.compositionLoader = { _, _ in throw CancellationError() }
        let controller = StudioWindowController(
            document: document, title: "Studio", swatches: [], movie: nil,
            actions: .init(keep: { _, _ in source }, copy: { _ in }, save: save, progress: { _ in })
        )
        return (controller, document)
    }

    @Test func saveAndSaveAsReportOnlyCompletedExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "StudioWindowSaveTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try Data([1, 2, 3]).write(to: source)
        let saved = folder.appending(path: "saved.mp4")
        var saveResult: URL? = saved
        let (editor, document) = window(folder: folder) { _ in saveResult }
        defer {
            editor.window?.close()
            document.releasePreview()
        }
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
        try await document.flushSave()
    }

    @Test func saveAsResultAfterProjectRevisionChangeDoesNotMarkTheOldExportCurrent() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "StudioWindowSaveRevisionTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try Data([1, 2, 3]).write(to: source)
        let destination = folder.appending(path: "saved-as.mp4")
        let (editor, document) = window(folder: folder) { _ in nil }
        defer {
            editor.window?.close()
            document.releasePreview()
        }
        var reportedURLs: [URL] = []
        var reportedCurrentness: [Bool] = []
        editor.onSaved = { url, isCurrent in
            reportedURLs.append(url)
            reportedCurrentness.append(isCurrent)
        }

        let (startedEvents, announceStarted) = AsyncStream<Void>.makeStream()
        let gate = StudioSaveOutcomeGate()
        let saveTask = Task {
            await editor.saveCopyAs(from: source, to: destination) { _, _ in
                announceStarted.yield(())
                return await gate.wait()
            }
        }
        guard await waitForEvent(startedEvents) else {
            await gate.complete(.cancelled)
            _ = await saveTask.value
            #expect(Bool(false), "Save As did not reach the controlled copy")
            return
        }

        var changedProject = document.project
        changedProject.aspect = .square
        document.project = changedProject
        await gate.complete(.saved(destination))
        #expect(await saveTask.value == .saved(destination))
        #expect(reportedURLs == [destination])
        #expect(reportedCurrentness == [false])
        try await document.flushSave()
    }
}
