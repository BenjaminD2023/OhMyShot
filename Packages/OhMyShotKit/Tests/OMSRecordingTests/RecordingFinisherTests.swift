import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import Synchronization
import Testing
@testable import OMSRecording

@Suite(.serialized)
struct RecordingFinisherTests {
    /// Two seconds of frames that stop changing after half a second, with the audio asked for.
    private func record(audio: RecordingAudio) async throws -> URL {
        let url = TestMedia.temporaryMovie()
        let writer = try TestMedia.writer(url: url, audio: audio)
        for index in 0..<15 {
            try await TestMedia.append(TestMedia.frame(at: Double(index) / 30, gray: UInt8(40 + index * 8)), to: writer)
        }
        var seconds = 0.0
        while seconds < 2 {
            if audio.system { await writer.appendAudio(TestMedia.audio(at: seconds), to: .systemAudio) }
            if audio.microphone != nil { await writer.appendAudio(TestMedia.audio(at: seconds, channels: 1), to: .microphone) }
            seconds += 0.02
        }
        try await writer.finish(at: TestMedia.time(2))
        return url
    }

    private func check(_ movie: RecordingFinisher.Movie, audioTracks: Int) async throws {
        let asset = AVURLAsset(url: movie.url)
        #expect(movie.url.pathExtension == "mp4")
        #expect(abs(movie.duration - 2) < 0.05)
        #expect(movie.pixelWidth == 320)
        #expect(movie.pixelHeight == 240)
        #expect(movie.byteCount > 0)
        #expect(movie.hasAudio == (audioTracks > 0))
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == audioTracks)
        // The still ending is kept: the video track lasts as long as the recording.
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let range = try await video.load(.timeRange)
        #expect(abs(range.duration.seconds - 2) < 0.05)
        // The 15 that changed, and the last once more a frame before the end.
        #expect(try await TestMedia.frameCount(of: movie.url) == 16)
    }

    @Test func videoAloneIsCopied() async throws {
        let source = try await record(audio: .none)
        let destination = source.deletingPathExtension().appendingPathExtension("mp4")
        defer { [source, destination].forEach { try? FileManager.default.removeItem(at: $0) } }
        try await check(try await RecordingFinisher.finish(source, to: destination), audioTracks: 0)
    }

    @Test func oneAudioTrackIsCopied() async throws {
        let source = try await record(audio: RecordingAudio(system: true, microphone: nil))
        let destination = source.deletingPathExtension().appendingPathExtension("mp4")
        defer { [source, destination].forEach { try? FileManager.default.removeItem(at: $0) } }
        let movie = try await RecordingFinisher.finish(source, to: destination)
        try await check(movie, audioTracks: 1)
    }

    @Test func theSystemAndTheMicrophoneAreMixedIntoOneTrack() async throws {
        let source = try await record(audio: RecordingAudio(system: true, microphone: .systemDefault))
        let destination = source.deletingPathExtension().appendingPathExtension("mp4")
        defer { [source, destination].forEach { try? FileManager.default.removeItem(at: $0) } }
        let movie = try await RecordingFinisher.finish(source, to: destination)
        try await check(movie, audioTracks: 1)
        let audio = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).first)
        let range = try await audio.load(.timeRange)
        #expect(abs(range.duration.seconds - 2) < 0.1)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 2)
    }

    @Test func aReplaysClipKeepsTheSoundChosen() async throws {
        // As a replay's clip has them: the system's sound (stereo here) first, then the microphone (mono).
        let source = try await record(audio: RecordingAudio(system: true, microphone: .systemDefault))
        defer { try? FileManager.default.removeItem(at: source) }
        let cases: [(ReplaySound, Int, UInt32?)] = [(.system, 1, 2), (.microphone, 1, 1), (.none, 0, nil), (.all, 1, 2)]
        for (sound, tracks, channels) in cases {
            let destination = source.deletingLastPathComponent().appending(path: "\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: destination) }
            let movie = try await RecordingFinisher.finish(source, to: destination, audio: .keeping(sound, of: [.systemAudio, .microphone]))
            try await check(movie, audioTracks: tracks)
            if let channels {
                let audio = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio).first)
                let format = try #require(try await audio.load(.formatDescriptions).first)
                #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == channels, "\(sound)")
            }
        }
        // Without the microphone buffered, there is none to keep.
        #expect(RecordingFinisher.AudioTracks.keeping(.microphone, of: [.systemAudio]) == .none)
        #expect(RecordingFinisher.AudioTracks.keeping(.system, of: [.systemAudio]) == .all)
    }

    /// A recording's thumbnail in the history, on its card, and in a pin is its first frame. Checked here, where a
    /// movie is recorded to look at.
    @Test func aRecordingsThumbnailIsItsFirstFrame() async throws {
        let source = try await record(audio: .none)
        defer { try? FileManager.default.removeItem(at: source) }
        let thumbnail = try #require(await HistoryStore.thumbnail(of: source, maxPixels: 160))
        #expect(thumbnail.width == 160)
        #expect(thumbnail.height == 120)
    }

    @Test func finishAndExportReportMonotonicProgressAndRespectCancellation() async throws {
        let source = try await record(audio: RecordingAudio(system: true, microphone: nil))
        let finished = source.deletingPathExtension().appendingPathExtension("mp4")
        let exported = source.deletingLastPathComponent().appending(path: "\(UUID().uuidString)-edited.mp4")
        let cancelledFinish = source.deletingLastPathComponent().appending(path: "\(UUID().uuidString)-cancelled-finish.mp4")
        let cancelledExport = source.deletingLastPathComponent().appending(path: "\(UUID().uuidString)-cancelled-export.mp4")
        defer {
            [source, finished, exported, cancelledFinish, cancelledExport].forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }

        let finishReports = Mutex<[Double]>([])
        _ = try await RecordingFinisher.finish(source, to: finished) { value in
            finishReports.withLock { $0.append(value) }
        }
        let finishValues = finishReports.withLock { $0 }
        #expect(!finishValues.isEmpty)
        #expect(finishValues.last == 1.0)
        for pair in zip(finishValues, finishValues.dropFirst()) {
            #expect(pair.0 <= pair.1)
        }

        let exportReports = Mutex<[Double]>([])
        let trim = CMTimeRange(start: CMTime(seconds: 0.25, preferredTimescale: 600), end: CMTime(seconds: 1.5, preferredTimescale: 600))
        _ = try await RecordingFinisher.export(finished, to: exported, edits: .init(timeRange: trim, scale: 0.5)) { value in
            exportReports.withLock { $0.append(value) }
        }
        let exportValues = exportReports.withLock { $0 }
        #expect(!exportValues.isEmpty)
        #expect(exportValues.last == 1.0)
        for pair in zip(exportValues, exportValues.dropFirst()) {
            #expect(pair.0 <= pair.1)
        }

        // Pre-cancelled tasks throw CancellationError without writing output.
        let finishTask = Task {
            try await RecordingFinisher.finish(source, to: cancelledFinish)
        }
        finishTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await finishTask.value
        }

        let exportTask = Task {
            try await RecordingFinisher.export(finished, to: cancelledExport, edits: .init(timeRange: trim, scale: 0.5))
        }
        exportTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await exportTask.value
        }
    }
}
