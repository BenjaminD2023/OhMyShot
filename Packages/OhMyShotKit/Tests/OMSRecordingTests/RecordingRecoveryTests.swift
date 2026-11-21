import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import Testing
@testable import OMSRecording

struct RecordingRecoveryTests {
    @Test func draftsLeftBehindAreFoundOldestFirst() throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let newer = try drafts.create(.init(startedAt: .now, appName: "Safari"))
        let older = try drafts.create(.init(startedAt: .now.addingTimeInterval(-60), appName: nil))
        let running = try drafts.create(.init(startedAt: .now, appName: nil))
        let neverWritten = try drafts.create(.init(startedAt: .now, appName: nil))
        for draft in [newer, older, running] {
            try Data([0]).write(to: draft.movieURL)
        }
        // A Studio recording's camera, beside its draft.
        try Data([0]).write(to: newer.cameraURL)
        // A movie whose record is gone still holds a recording.
        let orphan = drafts.directory.appending(path: "\(UUID().uuidString).mov")
        try Data([0]).write(to: orphan)

        let found = drafts.leftovers(excluding: [running.id])
        #expect(found.map(\.movieURL) == [orphan, older.movieURL, newer.movieURL])
        #expect(found.last?.info?.appName == "Safari")
        // A record without a movie is cleaned up.
        #expect(!drafts.leftovers().contains { $0.id == neverWritten.id })
        drafts.remove(newer)
        #expect(!drafts.leftovers().contains { $0.id == newer.id })
        // The camera's movie is no recording of its own, and goes with its draft.
        #expect(newer.cameraURL.lastPathComponent == "\(newer.id.uuidString).camera.mov")
        #expect(!FileManager.default.fileExists(atPath: newer.cameraURL.path(percentEncoded: false)))
    }

    @Test func aMovieCutShortIsReadableUpToItsLastFragment() async throws {
        let url = TestMedia.temporaryMovie()
        let copy = url.deletingLastPathComponent().appending(path: "cut-\(url.lastPathComponent)")
        let finished = copy.deletingPathExtension().appendingPathExtension("mp4")
        defer { [url, copy, finished].forEach { try? FileManager.default.removeItem(at: $0) } }
        let writer = try TestMedia.writer(url: url, audio: RecordingAudio(system: true, microphone: nil))
        // Five seconds, a frame and its audio at a time: fragments are written every two seconds.
        var audioTime = 0.0
        for index in 0..<150 {
            let seconds = Double(index) / 30
            try await TestMedia.append(TestMedia.frame(at: seconds, gray: UInt8(index % 200 + 20)), to: writer)
            while audioTime < seconds {
                await writer.appendAudio(TestMedia.audio(at: audioTime), to: .systemAudio)
                audioTime += 0.02
            }
        }
        // What a crash would leave: the file as it is while the writer still has it open.
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.copyItem(at: url, to: copy)
        await writer.cancel()

        let asset = AVURLAsset(url: copy)
        let duration = try await asset.load(.duration).seconds
        #expect(duration >= 2, "only \(duration) s readable")
        let movie = try await RecordingFinisher.finish(copy, to: finished)
        #expect(movie.duration >= 2)
        #expect(movie.hasAudio)
        #expect(try await TestMedia.frameCount(of: finished) >= 60)
    }

    @Test func telemetryCheckpointsStayWithTheirDraftAndAreRemovedTogether() throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = try drafts.create(.init(startedAt: .now, appName: "Xcode", output: .studio))
        try Data([0]).write(to: draft.movieURL)
        try Data([0]).write(to: draft.cameraURL)
        try Data("{\"telemetry\":true}".utf8).write(to: draft.telemetryURL)

        let found = drafts.leftovers()
        #expect(found.count == 1)
        #expect(found[0].id == draft.id)
        #expect(draft.telemetryURL.lastPathComponent == "\(draft.id.uuidString).telemetry.json")

        drafts.remove(draft)
        #expect(!FileManager.default.fileExists(atPath: draft.movieURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: draft.cameraURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: draft.telemetryURL.path(percentEncoded: false)))
        #expect(drafts.leftovers().isEmpty)
    }

    @Test func diskSpaceChecksEnforceStartAndRecordingThresholds() {
        let nonExistent = FileManager.default.temporaryDirectory.appending(path: "Missing-\(UUID().uuidString)/Drafts")
        let drafts = RecordingDrafts(directory: nonExistent)
        var probedURL: URL?
        let lowToStart = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesToStart) { url in
            probedURL = url
            return RecordingDrafts.minimumFreeBytesToStart - 1
        }
        #expect(probedURL != nil)
        #expect(FileManager.default.fileExists(atPath: probedURL!.path(percentEncoded: false)))
        #expect(lowToStart == .insufficient(
            availableBytes: RecordingDrafts.minimumFreeBytesToStart - 1,
            requiredBytes: RecordingDrafts.minimumFreeBytesToStart
        ))

        let okToStart = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesToStart) { _ in
            RecordingDrafts.minimumFreeBytesToStart
        }
        #expect(okToStart == .sufficient(availableBytes: RecordingDrafts.minimumFreeBytesToStart))

        let lowWhileRecording = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesWhileRecording) { _ in
            RecordingDrafts.minimumFreeBytesWhileRecording - 1024
        }
        #expect(lowWhileRecording == .insufficient(
            availableBytes: RecordingDrafts.minimumFreeBytesWhileRecording - 1024,
            requiredBytes: RecordingDrafts.minimumFreeBytesWhileRecording
        ))

        let unreadable = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesToStart) { _ in nil }
        #expect(unreadable == .sufficient(availableBytes: nil))
    }

    @Test func keptHistoryDraftSurvivesWithoutMovieAndOlderThanSevenDaysIsNotDeleted() async throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let oldDate = Date.now.addingTimeInterval(-10 * 86_400)
        let draft = try drafts.create(.init(startedAt: oldDate, appName: "Xcode", output: .studio))
        try Data("movie".utf8).write(to: draft.movieURL)
        try Data("camera".utf8).write(to: draft.cameraURL)
        try Data("{\"telemetry\":true}".utf8).write(to: draft.telemetryURL)

        let historyID = UUID()
        let kept = try drafts.markKeptInHistory(draft, historyID: historyID)

        // Draft movie is dropped once History holds it, while Studio sidecars stay for recovery.
        #expect(!FileManager.default.fileExists(atPath: kept.movieURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: kept.cameraURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: kept.telemetryURL.path(percentEncoded: false)))
        #expect(kept.info?.keptHistoryID == historyID)

        // Backdate every remaining file to 10 days ago.
        for file in [kept.cameraURL, kept.telemetryURL, drafts.directory.appending(path: "\(kept.id.uuidString).json")] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path(percentEncoded: false))
        }

        // Launch discovery keeps the partial Studio draft even though its movie file is gone.
        let found = drafts.leftovers()
        #expect(found.count == 1)
        #expect(found.first?.id == kept.id)
        #expect(found.first?.info?.keptHistoryID == historyID)

        // The 7-day cleanup never deletes a partial Studio draft linked to a History entry.
        let pruned = await drafts.pruneIfExpiredAndUnreadable(kept)
        #expect(!pruned)
        #expect(drafts.leftovers().count == 1)
        #expect(FileManager.default.fileExists(atPath: kept.cameraURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: kept.telemetryURL.path(percentEncoded: false)))
    }

    @Test func sevenDayCleanupDeletesOnlyVerifiedUnreadableMovieDrafts() async throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let oldDate = Date.now.addingTimeInterval(-10 * 86_400)
        let recentDate = Date.now.addingTimeInterval(-2 * 86_400)

        // 1. Readable 10-day-old movie draft: must NOT be deleted.
        let readableOld = try drafts.create(.init(startedAt: oldDate, appName: nil, output: .video))
        let writer = try TestMedia.writer(url: readableOld.movieURL)
        for index in 0..<15 {
            try await TestMedia.append(TestMedia.frame(at: Double(index) / 30), to: writer)
        }
        _ = try await writer.finish(at: TestMedia.time(0.6))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: readableOld.movieURL.path(percentEncoded: false))

        // 2. Unreadable 10-day-old movie draft: MUST be deleted.
        let corruptOld = try drafts.create(.init(startedAt: oldDate, appName: nil, output: .video))
        try Data([0, 1, 2, 3, 4]).write(to: corruptOld.movieURL)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: corruptOld.movieURL.path(percentEncoded: false))

        // 3. Unreadable 2-day-old movie draft: too young, must NOT be deleted yet.
        let corruptRecent = try drafts.create(.init(startedAt: recentDate, appName: nil, output: .video))
        try Data([0, 1, 2, 3, 4]).write(to: corruptRecent.movieURL)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: corruptRecent.movieURL.path(percentEncoded: false))

        #expect(!(await drafts.pruneIfExpiredAndUnreadable(readableOld)))
        #expect(FileManager.default.fileExists(atPath: readableOld.movieURL.path(percentEncoded: false)))

        #expect(!(await drafts.pruneIfExpiredAndUnreadable(corruptRecent)))
        #expect(FileManager.default.fileExists(atPath: corruptRecent.movieURL.path(percentEncoded: false)))

        #expect(await drafts.pruneIfExpiredAndUnreadable(corruptOld))
        #expect(!FileManager.default.fileExists(atPath: corruptOld.movieURL.path(percentEncoded: false)))
    }

    @Test func aStudioDraftKeepsItsMovieForItsSoundsOnceLinked() throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = try drafts.create(.init(startedAt: .now, appName: "Xcode", output: .studio))
        try Data("movie".utf8).write(to: draft.movieURL)

        let historyID = UUID()
        let kept = try drafts.markKeptInHistory(draft, historyID: historyID, removingMovie: false)

        // Linked, with the movie still there to read the sounds from, and found so by launch recovery.
        #expect(kept.info?.keptHistoryID == historyID)
        #expect(FileManager.default.fileExists(atPath: kept.movieURL.path(percentEncoded: false)))
        #expect(drafts.leftovers().first?.info?.keptHistoryID == historyID)
    }

    @Test func markKeptInHistoryKeepsDraftMovieWhenLinkWriteFails() throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let draft = try drafts.create(.init(startedAt: .now, appName: "Xcode", output: .studio))
        try Data("movie".utf8).write(to: draft.movieURL)
        try Data("camera".utf8).write(to: draft.cameraURL)
        try Data("{\"telemetry\":true}".utf8).write(to: draft.telemetryURL)

        #expect(throws: CocoaError.self) {
            try drafts.markKeptInHistory(draft, historyID: UUID()) { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }

        // The draft movie and Studio assets must remain on disk so launch recovery does not strand them.
        #expect(FileManager.default.fileExists(atPath: draft.movieURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: draft.cameraURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: draft.telemetryURL.path(percentEncoded: false)))
        let found = drafts.leftovers()
        #expect(found.count == 1)
        #expect(found.first?.id == draft.id)
        #expect(found.first?.info?.keptHistoryID == nil)
    }

    @Test func restartDecisionKeepsCurrentRecordingWhenFreeSpaceIsBelowStartMinimum() {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        let threeHundredMiB: Int64 = 300 * 1_024 * 1_024

        // Above the 250 MiB while-recording floor but below the 500 MiB start gate: keep the current recording.
        let refused = drafts.restartDecision { _ in threeHundredMiB }
        #expect(refused == .keepCurrent(
            availableBytes: threeHundredMiB,
            requiredBytes: RecordingDrafts.minimumFreeBytesToStart
        ))

        // At or above 500 MiB free (or when disk space can't be measured): allow restart.
        #expect(drafts.restartDecision { _ in RecordingDrafts.minimumFreeBytesToStart } == .restart)
        #expect(drafts.restartDecision { _ in nil } == .restart)
    }
}
