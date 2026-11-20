import Foundation
import OMSCore
import Testing
@testable import OMSStudio

struct StudioDraftStorageTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "StudioDraftStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func incrementalTelemetryCheckpointRetimesWithMovieStartPausesAndCamera() async throws {
        let root = temporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpointURL = root.appending(path: "draft.telemetry.json")

        let origin = 1_000.0
        let raw = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [
                .init(time: origin - 0.1, x: 100, y: 100, cursor: 0),
                .init(time: origin + 1.0, x: 400, y: 300, cursor: 0),
                .init(time: origin + 3.0, x: 900, y: 500, cursor: 0), // inside completed pause [1002, 1004]
                .init(time: origin + 5.0, x: 420, y: 310, cursor: 0), // movie time 3.0
                .init(time: origin + 8.5, x: 1200, y: 700, cursor: 0), // inside open pause [1008, ...]
            ],
            clicks: [
                .init(time: origin + 1.0, x: 400, y: 300, button: .primary),
                .init(time: origin + 1.4, x: 410, y: 305, button: .primary),
                .init(time: origin + 5.0, x: 420, y: 310, button: .primary),
                .init(time: origin + 8.6, x: 1200, y: 700, button: .primary),
            ]
        )
        let draft = StudioDraftTelemetry(
            telemetry: raw, isRetimed: false, movieStart: origin,
            pauses: [.init(start: origin + 2.0, end: origin + 4.0), .init(start: origin + 8.0, end: nil)],
            cameraStart: origin - 0.1,
            cameraFills: [.init(time: origin + 1.0, fills: true), .init(time: origin + 5.0, fills: false)],
            cameraBubble: StudioProject.Camera(shape: .roundedSquare, size: 220, corner: .bottomLeft, mirrored: true),
            cameraWanted: true, showsClicks: true, showsKeystrokes: false
        )

        let checkpointer = StudioDraftCheckpointer()
        await checkpointer.checkpoint(draft, to: checkpointURL)
        let firstModified = try checkpointURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // Identical snapshot skips redundant disk write.
        await checkpointer.checkpoint(draft, to: checkpointURL)
        let secondModified = try checkpointURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(firstModified == secondModified)

        let reloaded = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: checkpointURL))
        let resolved = reloaded.resolvedTelemetry(movieDuration: 6.0, hasCameraFile: true)
        // Pause [1002, 1004] cut out and open pause [1008, ...] dropped.
        #expect(resolved.clicks.map(\.time).count == 3)
        #expect(abs(resolved.clicks[0].time - 1.0) < 1e-9)
        #expect(abs(resolved.clicks[1].time - 1.4) < 1e-9)
        #expect(abs(resolved.clicks[2].time - 3.0) < 1e-9)
        #expect(resolved.samples.allSatisfy { $0.time < 6.0 })
        // Recovered telemetry generates Studio auto-zooms.
        #expect(!AutoZoom.zooms(for: resolved, duration: 6.0).isEmpty)
        // Camera offset and fill ranges are aligned to the movie timeline.
        #expect(abs((resolved.camera?.start ?? 0) - (-0.1)) < 1e-9)
        #expect(resolved.camera?.fills == [1.0...3.0])
        #expect(resolved.camera?.bubble.corner == .bottomLeft)
    }

    @Test func aCheckpointThatOnlyAddsReadingsWaitsWhileAPauseIsWrittenAtOnce() async throws {
        let root = temporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "draft.telemetry.json")
        var draft = StudioDraftTelemetry(
            telemetry: StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 1, x: 10, y: 10, cursor: 0)], clicks: []),
            isRetimed: false, movieStart: 1
        )
        let checkpointer = StudioDraftCheckpointer(minimumInterval: .seconds(3600))
        await checkpointer.checkpoint(draft, to: url)
        draft.telemetry.samples.append(.init(time: 2, x: 20, y: 20, cursor: 0))
        await checkpointer.checkpoint(draft, to: url)
        var written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.samples.count == 1)

        draft.pauses.append(.init(start: 3))
        await checkpointer.checkpoint(draft, to: url)
        written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.samples.count == 2)
        #expect(written.pauses.count == 1)
    }

    @Test func dragReleaseWithoutNewSamplesOrClicksIsCheckpointedAfterInterval() async throws {
        let root = temporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "draft.telemetry.json")

        nonisolated final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var current = ContinuousClock.now
            func now() -> ContinuousClock.Instant { lock.withLock { current } }
            func advance(by duration: Duration) { lock.withLock { current += duration } }
        }
        let clock = Clock()
        let checkpointer = StudioDraftCheckpointer(minimumInterval: .seconds(10), now: { clock.now() })

        var draft = StudioDraftTelemetry(
            telemetry: StudioTelemetry(
                width: 1600, height: 1000, pixelsPerPoint: 2,
                samples: [.init(time: 10, x: 200, y: 200, cursor: 0), .init(time: 11, x: 500, y: 300, cursor: 0)],
                clicks: [.init(time: 10, x: 200, y: 200, button: .primary)]
            ),
            isRetimed: false, movieStart: 10
        )
        await checkpointer.checkpoint(draft, to: url)
        var written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.clicks.count == 1)
        #expect(written.telemetry.clicks[0].releaseTime == nil)

        // Mutate the drag release in place: neither click count nor sample count changes.
        draft.telemetry.clicks[0].releaseTime = 11.2
        draft.telemetry.clicks[0].releaseX = 500
        draft.telemetry.clicks[0].releaseY = 300

        // Within the 10 s readings-only throttle, the checkpoint waits.
        clock.advance(by: .seconds(1))
        await checkpointer.checkpoint(draft, to: url)
        written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.clicks[0].releaseTime == nil)

        // Once the throttle passes, the release is written to disk.
        clock.advance(by: .seconds(60))
        await checkpointer.checkpoint(draft, to: url)
        written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.clicks[0].releaseTime == 11.2)
        #expect(written.telemetry.clicks[0].releaseX == 500)
        #expect(written.telemetry.clicks[0].releaseY == 300)
        #expect(written.telemetry.clicks[0].isDrag)
    }

    @Test func studioProjectStorageCopiesCameraAndReportsPartialFailuresWithoutLosingDraft() throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let projectDir = root.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        try Data("camera-bytes".utf8).write(to: draftCamera)
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 400, y: 300, cursor: 0)],
            camera: .init(start: 0, fills: [], bubble: StudioProject.Camera())
        )
        let project = StudioProject(zooms: [.init(start: 1, end: 3, scale: 2, isAutomatic: true)])

        // Full success: all sidecars written and draft camera stays on disk until caller removes the draft.
        let ok = StudioProjectStorage.save(telemetry: telemetry, project: project, cameraURL: draftCamera, to: projectDir)
        #expect(ok.isComplete)
        #expect(ok.savedCamera && ok.savedTelemetry && ok.savedProject)
        #expect(FileManager.default.fileExists(atPath: draftCamera.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.camera).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.telemetry).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.project).path(percentEncoded: false)))

        // Camera copy failure: reports partial save, keeps draft camera intact, marks written telemetry cameraFailed.
        let cameraFailDir = root.appending(path: "CameraFail", directoryHint: .isDirectory)
        let cameraFail = StudioProjectStorage.save(
            telemetry: telemetry, project: project, cameraURL: draftCamera, to: cameraFailDir,
            copyCamera: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        #expect(!cameraFail.isComplete)
        #expect(cameraFail.expectedCamera && !cameraFail.savedCamera)
        #expect(cameraFail.savedTelemetry && cameraFail.savedProject)
        #expect(cameraFail.errorDescription != nil)
        #expect(FileManager.default.fileExists(atPath: draftCamera.path(percentEncoded: false)))
        let fallbackTelemetry = try JSONDecoder().decode(
            StudioTelemetry.self, from: Data(contentsOf: cameraFailDir.appending(path: StudioFiles.telemetry))
        )
        #expect(fallbackTelemetry.camera == nil)
        #expect(fallbackTelemetry.cameraFailed == true)

        // Telemetry JSON write failure: reports incomplete so caller preserves the draft.
        let telemetryFailDir = root.appending(path: "TelemetryFail", directoryHint: .isDirectory)
        let telemetryFail = StudioProjectStorage.save(
            telemetry: telemetry, project: project, cameraURL: draftCamera, to: telemetryFailDir,
            writeData: { data, url in
                if url.lastPathComponent == StudioFiles.telemetry { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        #expect(!telemetryFail.isComplete)
        #expect(!telemetryFail.savedTelemetry && telemetryFail.savedProject && telemetryFail.savedCamera)

        // Project JSON write failure: reports incomplete so caller preserves the draft.
        let projectFailDir = root.appending(path: "ProjectFail", directoryHint: .isDirectory)
        let projectFail = StudioProjectStorage.save(
            telemetry: telemetry, project: project, cameraURL: draftCamera, to: projectFailDir,
            writeData: { data, url in
                if url.lastPathComponent == StudioFiles.project { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        #expect(!projectFail.isComplete)
        #expect(projectFail.savedTelemetry && !projectFail.savedProject && projectFail.savedCamera)
    }

    @Test func partialStudioSaveRecoversMissingAssetsIntoExistingHistoryEntryWithoutDuplicating() async throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let historyDir = root.appending(path: "History", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = HistoryStore(directory: historyDir)
        let finishedMovie = root.appending(path: "recording.mp4")
        try Data("mp4-bytes".utf8).write(to: finishedMovie)
        let entry = try history.add(
            movingFileAt: finishedMovie, name: "Studio Clip", kind: .recording,
            pixelWidth: 1600, pixelHeight: 1000, appName: "Xcode", duration: 6.0, pixelsPerPoint: 2
        )

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        let draftTelemetryURL = draftDir.appending(path: "clip.telemetry.json")
        try Data("camera-bytes".utf8).write(to: draftCamera)

        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 400, y: 300, cursor: 0)],
            clicks: [.init(time: 1.0, x: 400, y: 300, button: .primary), .init(time: 1.5, x: 410, y: 305, button: .primary)],
            camera: .init(start: 0, fills: [], bubble: StudioProject.Camera(corner: .bottomLeft))
        )
        let draftTelemetry = StudioDraftTelemetry(
            telemetry: telemetry, isRetimed: true, movieStart: 100,
            cameraStart: 100, cameraBubble: StudioProject.Camera(corner: .bottomLeft),
            cameraWanted: true, showsClicks: true, showsKeystrokes: false
        )
        try JSONEncoder().encode(draftTelemetry).write(to: draftTelemetryURL, options: .atomic)

        // Simulate initial partial save: camera copy failed (disk full), telemetry saved with cameraFailed,
        // project saved, and the user subsequently edited the saved project's zooms.
        let projectDir = history.studioURL(for: entry)
        let initialProject = StudioProject(zooms: [.init(start: 1, end: 3, scale: 2, isAutomatic: true)])
        let partial = StudioProjectStorage.save(
            telemetry: telemetry, project: initialProject, cameraURL: draftCamera, to: projectDir,
            copyCamera: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        #expect(!partial.isComplete)
        #expect(!partial.savedCamera && partial.savedTelemetry && partial.savedProject)

        var userEditedProject = initialProject
        userEditedProject.zooms = [.init(start: 2, end: 5, scale: 1.75, isAutomatic: false)]
        try JSONEncoder().encode(userEditedProject).write(to: projectDir.appending(path: StudioFiles.project), options: .atomic)

        // Recovery retries into the existing History entry: copies camera, updates telemetry with camera
        // restored, preserves user-edited project.json, and adds no duplicate History item.
        var copyCount = 0
        var writtenFiles: [String] = []
        let outcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) },
            copyCamera: { source, destination in
                copyCount += 1
                try FileManager.default.copyItem(at: source, to: destination)
            },
            writeData: { data, destination in
                writtenFiles.append(destination.lastPathComponent)
                try data.write(to: destination, options: .atomic)
            }
        )

        #expect(history.items().count == 1)
        #expect(history.items().first?.id == entry.id)
        guard case .completed(let result) = outcome else {
            Issue.record("Expected completed recovery, got \(outcome)")
            return
        }
        #expect(result.isComplete)
        #expect(copyCount == 1)
        #expect(writtenFiles == [StudioFiles.telemetry])
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.camera).path(percentEncoded: false)))

        let recoveredTelemetry = try JSONDecoder().decode(
            StudioTelemetry.self, from: Data(contentsOf: projectDir.appending(path: StudioFiles.telemetry))
        )
        #expect(recoveredTelemetry.camera != nil)
        #expect(recoveredTelemetry.cameraFailed != true)

        let preservedProject = try JSONDecoder().decode(
            StudioProject.self, from: Data(contentsOf: projectDir.appending(path: StudioFiles.project))
        )
        #expect(preservedProject.zooms == userEditedProject.zooms)

        // Second scenario: only project.json failed originally; recovery writes only project.json and
        // does not re-copy camera.mov or overwrite telemetry.json.
        try FileManager.default.removeItem(at: projectDir.appending(path: StudioFiles.project))
        copyCount = 0
        writtenFiles = []
        let projectOnlyOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) },
            copyCamera: { source, destination in
                copyCount += 1
                try FileManager.default.copyItem(at: source, to: destination)
            },
            writeData: { data, destination in
                writtenFiles.append(destination.lastPathComponent)
                try data.write(to: destination, options: .atomic)
            }
        )
        guard case .completed(let projectOnlyResult) = projectOnlyOutcome else {
            Issue.record("Expected completed project-only recovery, got \(projectOnlyOutcome)")
            return
        }
        #expect(projectOnlyResult.isComplete)
        #expect(copyCount == 0)
        #expect(writtenFiles == [StudioFiles.project])
        #expect(history.items().count == 1)

        // Third scenario: if the user deleted the history entry before next launch, recovery discards
        // the orphaned draft cleanly without creating any History entry.
        history.delete(entry)
        let deletedOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        #expect(deletedOutcome == .discarded)
        #expect(history.items().isEmpty)
    }

    @Test func recoveryDropsDraftWhenHistoryMovieWasReplacedByEdit() async throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let historyDir = root.appending(path: "History", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = HistoryStore(directory: historyDir)
        let originalMovie = root.appending(path: "original.mp4")
        try Data("original-untrimmed-movie-bytes".utf8).write(to: originalMovie)
        let entry = try history.add(
            movingFileAt: originalMovie, name: "Studio Clip", kind: .recording,
            pixelWidth: 1600, pixelHeight: 1000, appName: "Xcode", duration: 6.0, pixelsPerPoint: 2
        )
        let keptValues = try history.fileURL(for: entry).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let keptSize = Int64(try #require(keptValues.fileSize))
        let keptModified = try #require(keptValues.contentModificationDate).timeIntervalSince1970

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        let draftTelemetryURL = draftDir.appending(path: "clip.telemetry.json")
        try Data("camera-bytes".utf8).write(to: draftCamera)
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 400, y: 300, cursor: 0)],
            camera: .init(start: 0, fills: [], bubble: StudioProject.Camera())
        )
        let draftTelemetry = StudioDraftTelemetry(telemetry: telemetry, isRetimed: true, cameraWanted: true)
        try JSONEncoder().encode(draftTelemetry).write(to: draftTelemetryURL, options: .atomic)

        // Scenario A: telemetry originally failed while project.json saved (leaving an incomplete .studio folder),
        // openStudio fell back to the regular recording editor, and keepEdit trimmed the movie via replaceRecording.
        let projectDir = history.studioURL(for: entry)
        let partial = StudioProjectStorage.save(
            telemetry: telemetry, project: StudioProject(), cameraURL: draftCamera, to: projectDir,
            writeData: { data, url in
                if url.lastPathComponent == StudioFiles.telemetry { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        #expect(!partial.savedTelemetry && partial.savedProject && partial.savedCamera)
        #expect(history.hasStudioProject(entry))

        let trimmedMovie = root.appending(path: "trimmed.mp4")
        try Data("trimmed-movie".utf8).write(to: trimmedMovie)
        _ = try history.replaceRecording(of: entry, withFileAt: trimmedMovie, pixelWidth: 1600, pixelHeight: 1000, duration: 3.0)
        #expect(history.hasOriginal(entry))

        let editedOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            expectedMovieByteCount: keptSize,
            expectedMovieModifiedAt: keptModified,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        #expect(editedOutcome == .movieReplaced)
        #expect(!history.hasStudioProject(entry))
        #expect(!FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.telemetry).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.camera).path(percentEncoded: false)))

        // Even without a stored fingerprint (older draft), history.hasOriginal alone blocks attaching telemetry.
        let editedWithoutFingerprint = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        #expect(editedWithoutFingerprint == .movieReplaced)

        // Scenario B: the movie file was replaced without keeping `.original` (e.g., flattened or externally
        // replaced); comparing the recorded movie size / modification time still detects the replacement.
        try FileManager.default.removeItem(at: history.originalURL(for: entry))
        #expect(!history.hasOriginal(entry))
        let flattenedOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            expectedMovieByteCount: keptSize,
            expectedMovieModifiedAt: keptModified,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        #expect(flattenedOutcome == .movieReplaced)
        #expect(!FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.telemetry).path(percentEncoded: false)))
    }

    @Test func recoveryInvalidatesPreviousStudioExportWhenAddingMedia() async throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let historyDir = root.appending(path: "History", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = HistoryStore(directory: historyDir)
        let originalMovie = root.appending(path: "original.mp4")
        try Data("original-recording-bytes".utf8).write(to: originalMovie)
        let entry = try history.add(
            movingFileAt: originalMovie, name: "Studio Clip", kind: .recording,
            pixelWidth: 1600, pixelHeight: 1000, appName: "Xcode", duration: 6.0, pixelsPerPoint: 2
        )
        let keptValues = try history.fileURL(for: entry).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let keptSize = Int64(try #require(keptValues.fileSize))
        let keptModified = try #require(keptValues.contentModificationDate).timeIntervalSince1970

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        let draftTelemetryURL = draftDir.appending(path: "clip.telemetry.json")
        try Data("camera-bytes".utf8).write(to: draftCamera)

        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 400, y: 300, cursor: 0)],
            camera: .init(start: 0, fills: [], bubble: StudioProject.Camera(corner: .bottomLeft))
        )
        let draftTelemetry = StudioDraftTelemetry(
            telemetry: telemetry, isRetimed: true, movieStart: 100,
            cameraStart: 100, cameraBubble: StudioProject.Camera(corner: .bottomLeft),
            cameraWanted: true, showsClicks: true, showsKeystrokes: false
        )
        try JSONEncoder().encode(draftTelemetry).write(to: draftTelemetryURL, options: .atomic)

        // Initial save: camera copy failed, telemetry saved with cameraFailed, project saved.
        let projectDir = history.studioURL(for: entry)
        var project = StudioProject(zooms: [.init(start: 1, end: 3, scale: 2, isAutomatic: true)])
        project.camera = StudioProject.Camera(corner: .bottomLeft)
        let partial = StudioProjectStorage.save(
            telemetry: telemetry, project: project, cameraURL: draftCamera, to: projectDir,
            copyCamera: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        #expect(!partial.isComplete && !partial.savedCamera)

        // User opens Studio before relaunch and exports a camera-less movie.
        let cameraLessExport = root.appending(path: "exported-no-camera.mp4")
        try Data("camera-less-export".utf8).write(to: cameraLessExport)
        let exportedEntry = try history.replaceStudioMovie(
            of: entry, withFileAt: cameraLessExport, pixelWidth: 1600, pixelHeight: 1000, duration: 6.0,
            project: try JSONEncoder().encode(project)
        )
        #expect(history.hasStudioMovie(exportedEntry))
        #expect(history.studioMovieProject(of: exportedEntry) != nil)

        // Relaunch recovery adds camera.mov and updates telemetry.json. Because source.mp4 matches the kept
        // recording, recovery succeeds (does not treat the Studio export as an external edit) and invalidates
        // the previous camera-less export so Studio will re-export with the camera.
        let outcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            expectedMovieByteCount: keptSize,
            expectedMovieModifiedAt: keptModified,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        guard case .completed(let result) = outcome else {
            Issue.record("Expected completed recovery after Studio export, got \(outcome)")
            return
        }
        #expect(result.isComplete)
        #expect(result.addedMedia)
        #expect(history.hasStudioMovie(exportedEntry))
        #expect(history.studioMovieProject(of: exportedEntry) == nil)
        #expect(try history.studioSource(for: exportedEntry) == history.studioSourceURL(for: exportedEntry))

        // Verify the exact openStudio check now marks the document as needing a fresh export.
        let recoveredTelemetry = try JSONDecoder().decode(
            StudioTelemetry.self, from: Data(contentsOf: projectDir.appending(path: StudioFiles.telemetry))
        )
        let made = history.studioMovieProject(of: exportedEntry).flatMap { try? JSONDecoder().decode(StudioProject.self, from: $0) }
        let hasBeenExported = made?.opened(for: recoveredTelemetry, duration: 6.0) == project.opened(for: recoveredTelemetry, duration: 6.0)
        #expect(!hasBeenExported)
        let document = StudioDocument(
            source: try history.studioSource(for: exportedEntry), telemetry: recoveredTelemetry, project: project,
            duration: 6.0, recordingSize: CGSize(width: 1600, height: 1000), folder: projectDir,
            hasBeenExported: hasBeenExported, background: { _, _ in nil }
        )
        defer { document.releasePreview() }
        #expect(document.hasUnexportedChanges)

        // If Studio later re-exports WITH camera and a subsequent recovery only restores missing project.json
        // (no media added), the fresh export marker stays valid.
        let cameraExport = root.appending(path: "exported-with-camera.mp4")
        try Data("export-with-camera".utf8).write(to: cameraExport)
        let reexported = try history.replaceStudioMovie(
            of: exportedEntry, withFileAt: cameraExport, pixelWidth: 1600, pixelHeight: 1000, duration: 6.0,
            project: try JSONEncoder().encode(project)
        )
        try FileManager.default.removeItem(at: projectDir.appending(path: StudioFiles.project))
        let projectOnlyOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            expectedMovieByteCount: keptSize,
            expectedMovieModifiedAt: keptModified,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        guard case .completed(let projectOnlyResult) = projectOnlyOutcome else {
            Issue.record("Expected completed project-only recovery, got \(projectOnlyOutcome)")
            return
        }
        #expect(!projectOnlyResult.addedMedia)
        #expect(history.studioMovieProject(of: reexported) != nil)
    }

    @Test func recoveryStaysIncompleteWhenDraftTelemetryCannotBeReadAndHistoryExists() async throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let historyDir = root.appending(path: "History", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = HistoryStore(directory: historyDir)
        let movie = root.appending(path: "recording.mp4")
        try Data("mp4-bytes".utf8).write(to: movie)
        let entry = try history.add(
            movingFileAt: movie, name: "Studio Clip", kind: .recording,
            pixelWidth: 1600, pixelHeight: 1000, appName: "Xcode", duration: 6.0, pixelsPerPoint: 2
        )

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        let draftTelemetryURL = draftDir.appending(path: "clip.telemetry.json")
        try Data("camera-bytes".utf8).write(to: draftCamera)
        try Data("not-valid-json".utf8).write(to: draftTelemetryURL)

        // Corrupt/unreadable telemetry while History entry exists must stay incomplete (never discarded)
        // so the draft and its camera copy are preserved for a later launch.
        let corruptOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        guard case .incomplete(let corruptResult) = corruptOutcome else {
            Issue.record("Expected .incomplete when telemetry cannot be decoded and History entry exists, got \(corruptOutcome)")
            return
        }
        #expect(!corruptResult.isComplete)
        #expect(!corruptResult.savedTelemetry)
        #expect(corruptResult.expectedCamera)
        #expect(corruptResult.errorDescription != nil)

        // Missing telemetry file while History entry exists also stays incomplete rather than discarding the camera.
        try FileManager.default.removeItem(at: draftTelemetryURL)
        let missingOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        guard case .incomplete(let missingResult) = missingOutcome else {
            Issue.record("Expected .incomplete when telemetry is unreadable and History entry exists, got \(missingOutcome)")
            return
        }
        #expect(!missingResult.isComplete)
        #expect(missingResult.expectedCamera)

        // Only once the History entry itself is gone does recovery return .discarded.
        history.delete(entry)
        let goneOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        #expect(goneOutcome == .discarded)
    }

    @Test func recoveryStaysIncompleteWhenDraftCameraFileExistsButProbeFails() async throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let historyDir = root.appending(path: "History", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = HistoryStore(directory: historyDir)
        let movie = root.appending(path: "recording.mp4")
        try Data("mp4-bytes".utf8).write(to: movie)
        let entry = try history.add(
            movingFileAt: movie, name: "Studio Clip", kind: .recording,
            pixelWidth: 1600, pixelHeight: 1000, appName: "Xcode", duration: 6.0, pixelsPerPoint: 2
        )

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        let draftTelemetryURL = draftDir.appending(path: "clip.telemetry.json")
        try Data("camera-bytes".utf8).write(to: draftCamera)
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 400, y: 300, cursor: 0)],
            camera: .init(start: 0, fills: [], bubble: StudioProject.Camera(corner: .bottomLeft))
        )
        let draftTelemetry = StudioDraftTelemetry(
            telemetry: telemetry, isRetimed: true, cameraWanted: true,
            showsClicks: true, showsKeystrokes: false
        )
        try JSONEncoder().encode(draftTelemetry).write(to: draftTelemetryURL, options: .atomic)

        // A draft camera file is present on disk, but the readability probe fails right now:
        // recovery must stay incomplete so the draft camera is kept for a later launch.
        let unreadableOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { _ in false }
        )
        guard case .incomplete(let unreadableResult) = unreadableOutcome else {
            Issue.record("Expected .incomplete when draft camera exists on disk but probe fails, got \(unreadableOutcome)")
            return
        }
        #expect(!unreadableResult.isComplete)
        #expect(unreadableResult.expectedCamera)
        #expect(!unreadableResult.savedCamera)
        #expect(unreadableResult.errorDescription != nil)

        // On a later launch when the camera file becomes readable, recovery completes and restores camera.mov + telemetry.
        let recoveredOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        guard case .completed(let recoveredResult) = recoveredOutcome else {
            Issue.record("Expected .completed once draft camera is readable, got \(recoveredOutcome)")
            return
        }
        #expect(recoveredResult.isComplete && recoveredResult.savedCamera)
        let projectDir = history.studioURL(for: entry)
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.camera).path(percentEncoded: false)))
        let updatedTelemetry = try JSONDecoder().decode(
            StudioTelemetry.self, from: Data(contentsOf: projectDir.appending(path: StudioFiles.telemetry))
        )
        #expect(updatedTelemetry.camera != nil)
        let savedProject = try JSONDecoder().decode(
            StudioProject.self, from: Data(contentsOf: projectDir.appending(path: StudioFiles.project))
        )
        #expect(savedProject.camera.corner == .bottomLeft)

        // Contrast: when no camera file was recorded (absent on disk), recovery completes without a camera.
        let noCamMovie = root.appending(path: "nocam.mp4")
        try Data("mp4-bytes".utf8).write(to: noCamMovie)
        let noCamEntry = try history.add(
            movingFileAt: noCamMovie, name: "Screen Only", kind: .recording,
            pixelWidth: 1600, pixelHeight: 1000, appName: "Xcode", duration: 6.0, pixelsPerPoint: 2
        )
        let missingCameraURL = draftDir.appending(path: "missing.camera.mov")
        let screenOnlyTelemetry = StudioDraftTelemetry(
            telemetry: StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 0, x: 400, y: 300, cursor: 0)]),
            isRetimed: true, cameraWanted: false
        )
        let screenOnlyTelemetryURL = draftDir.appending(path: "nocam.telemetry.json")
        try JSONEncoder().encode(screenOnlyTelemetry).write(to: screenOnlyTelemetryURL, options: .atomic)
        let noCamOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: noCamEntry.id,
            telemetryURL: screenOnlyTelemetryURL,
            cameraURL: missingCameraURL,
            in: history,
            hasReadableVideo: { _ in false }
        )
        guard case .completed(let noCamResult) = noCamOutcome else {
            Issue.record("Expected .completed when no camera file was recorded, got \(noCamOutcome)")
            return
        }
        #expect(noCamResult.isComplete && !noCamResult.expectedCamera)
    }
}
