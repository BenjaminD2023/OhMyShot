import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import Testing
@testable import OMSRecording

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

    @Test func thePosterIsTheFirstFrame() async throws {
        let source = try await record(audio: .none)
        defer { try? FileManager.default.removeItem(at: source) }
        let poster = try #require(await RecordingFinisher.poster(of: source, maxPixels: 160))
        #expect(poster.width == 160)
        #expect(poster.height == 120)
    }
}
