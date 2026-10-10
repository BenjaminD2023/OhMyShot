import AVFoundation
import CoreMedia
import Foundation
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
}
