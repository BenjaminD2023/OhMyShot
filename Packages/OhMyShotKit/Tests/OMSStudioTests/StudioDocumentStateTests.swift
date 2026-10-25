import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import OMSStudio

@MainActor
struct StudioDocumentStateTests {
    private func document(project: StudioProject = StudioProject()) -> StudioDocument {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioStateTests-\(UUID())")
        return StudioDocument(
            source: folder.appending(path: "source.mp4"),
            telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)]),
            project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), folder: folder,
            hasBeenExported: false, background: { _, _ in nil }
        )
    }

    @Test func aNewRangeReplacesTheOldCutAndDeleteCutsThatRange() async throws {
        let document = document(project: StudioProject(cuts: [0.2...0.5]))
        defer { document.releasePreview(); try? FileManager.default.removeItem(at: document.folder) }
        document.selectedCut = 0.2
        document.selectedRange = 2...3
        #expect(document.selectedCut == nil)
        document.deleteSelection()
        #expect(document.project.cuts == [0.2...0.5, 2...3])
        #expect(document.selectedRange == nil)
        try await document.flushSave()
    }

    @Test func selectingAnObjectClearsTheRangeAndUndoClearsStaleIDs() async throws {
        let document = document()
        defer { document.releasePreview(); try? FileManager.default.removeItem(at: document.folder) }
        document.addZoom()
        let id = try #require(document.project.zooms.first?.id)
        document.selectedRange = 2...3
        document.selectedZoom = id
        #expect(document.selectedRange == nil && document.selection == .zoom(id))
        document.project.zooms = []
        #expect(document.selection == .none)
        try await document.flushSave()
    }

    @Test func burstEditsWriteOnlyTheLatestSnapshotAndFlushIsIdempotent() async throws {
        let document = document()
        let writes = ProjectWrites()
        document.setProjectWriter(StudioProjectWriter(write: { data, _ in writes.append(data) }))
        for index in 0..<50 { document.project.quality = index.isMultiple(of: 2) ? .smaller : .best }
        try await document.flushSave()
        try await document.flushSave()
        #expect(writes.values.count == 1)
        let last = try #require(writes.values.last)
        #expect(try JSONDecoder().decode(StudioProject.self, from: last) == document.project)
        #expect(document.saveState == .saved && !document.hasPendingSave)
    }

    @Test func aFailedWriteStaysDirtyAndCanBeRetriedWithoutLosingEdits() async throws {
        let document = document()
        defer { document.releasePreview(); try? FileManager.default.removeItem(at: document.folder) }
        // A file where the project directory should be is a deterministic filesystem failure even as root.
        try Data("blocked".utf8).write(to: document.folder)
        document.project.quality = .best
        await #expect(throws: (any Error).self) { try await document.flushSave() }
        guard case .failed = document.saveState else { Issue.record("Failed save was not visible"); return }
        #expect(document.hasPendingSave)
        try FileManager.default.removeItem(at: document.folder)
        try await document.flushSave()
        #expect(document.saveState == .saved && !document.hasPendingSave)
        let saved = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: document.folder.appending(path: StudioFiles.project)))
        #expect(saved.quality == .best)
    }

    @Test func anOlderSnapshotCannotOverwriteANewerOne() async throws {
        let writes = ProjectWrites()
        let writer = StudioProjectWriter(write: { data, _ in writes.append(data) })
        var newer = StudioProject()
        newer.quality = .best
        let url = URL(filePath: "/unused-project.json")
        try await writer.save(newer, revision: 2, to: url)
        try await writer.save(StudioProject(), revision: 1, to: url)
        #expect(writes.values.count == 1)
        #expect(try JSONDecoder().decode(StudioProject.self, from: #require(writes.values.first)).quality == .best)
    }

    @Test func appearanceAndZoomIdentityReuseMotionButMotionEditsRebuildIt() async throws {
        let zoom = StudioProject.Zoom(start: 0.5, end: 3, scale: 2, isAutomatic: true)
        let document = document(project: StudioProject(zooms: [zoom]))
        defer { document.releasePreview(); try? FileManager.default.removeItem(at: document.folder) }
        let first = try await document.preparedMotion(for: document.project)
        var appearance = document.project
        appearance.padding = 0.2
        appearance.shadow = 0
        appearance.quality = .best
        appearance.cuts = [1...1.5]
        appearance.cursor.size = 2
        appearance.zooms[0].id = UUID()
        appearance.zooms[0].isAutomatic = false
        let reused = try await document.preparedMotion(for: appearance)
        #expect(document.motionBuildCount == 1)
        #expect(first.frames == reused.frames)
        document.project.cursor.smoothing = 0
        _ = try await document.preparedMotion(for: document.project)
        #expect(document.motionBuildCount == 2)
        try await document.flushSave()
    }

    @Test func stalePreviewCannotReplaceANewerOneAndFailureRetainsAVisibleState() async throws {
        let document = document()
        let loader = ControlledComposition()
        document.compositionLoader = { project, _ in try await loader.load(project.padding) }
        defer { document.releasePreview(); try? FileManager.default.removeItem(at: document.folder) }
        let oldPadding = document.project.padding
        let old = Task { await document.makeComposition() }
        await loader.started(oldPadding)
        document.project.padding = 0.23
        let newest = Task { await document.makeComposition() }
        await loader.started(0.23)
        let movie = Self.composition(project: document.project)
        await loader.finish(0.23, with: .success(movie))
        await newest.value
        let generation = document.compositionGeneration
        await loader.finish(oldPadding, with: .success(Self.composition(project: StudioProject())))
        await old.value
        #expect(document.compositionGeneration == generation)
        #expect(document.composition?.renderer.project.padding == 0.23)
        #expect(document.previewState == .ready)

        document.compositionLoader = { _, _ in throw StudioError.noVideo }
        await document.makeComposition()
        #expect(document.composition != nil && document.compositionFailed)
        document.compositionLoader = { _, _ in movie }
        await document.makeComposition()
        #expect(document.previewState == .ready)
        document.previewFailed("Decoder failed")
        #expect(document.previewState == .failed("Decoder failed") && !document.isPlaying)
        try await document.flushSave()
    }

    private static func composition(project: StudioProject) -> StudioComposition {
        let renderer = StudioRenderer(
            telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2), project: project,
            duration: 4, recordingSize: CGSize(width: 320, height: 200), background: nil
        )
        let configuration = AVVideoComposition.Configuration(
            customVideoCompositorClass: StudioCompositor.self, frameDuration: CMTime(value: 1, timescale: 60),
            instructions: [], renderSize: renderer.layout.canvas
        )
        return StudioComposition(
            asset: AVMutableComposition(), videoComposition: AVVideoComposition(configuration: configuration),
            renderer: renderer, duration: 4, colors: .init(of: nil)
        )
    }
}

nonisolated private final class ProjectWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data] = []
    var values: [Data] { lock.withLock { data } }
    func append(_ value: Data) { lock.withLock { data.append(value) } }
}

private actor ControlledComposition {
    private var pending: [Double: CheckedContinuation<StudioComposition, Error>] = [:]
    private var waiters: [Double: CheckedContinuation<Void, Never>] = [:]

    func load(_ key: Double) async throws -> StudioComposition {
        try await withCheckedThrowingContinuation { continuation in
            pending[key] = continuation
            waiters.removeValue(forKey: key)?.resume()
        }
    }

    func started(_ key: Double) async {
        if pending[key] != nil { return }
        await withCheckedContinuation { waiters[key] = $0 }
    }

    func finish(_ key: Double, with result: Result<StudioComposition, Error>) {
        pending.removeValue(forKey: key)?.resume(with: result)
    }
}
