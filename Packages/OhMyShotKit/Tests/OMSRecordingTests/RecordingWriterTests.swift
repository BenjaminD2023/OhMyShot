import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import OMSRecording

struct RecordingFormatTests {
    @Test func h264WhileTheFrameFitsTheHardwareEncoder() {
        #expect(RecordingFormat.choose(width: 1920, height: 1080, framesPerSecond: 60).codec == .h264)
        #expect(RecordingFormat.choose(width: 4096, height: 2304, framesPerSecond: 60).codec == .h264)
        #expect(RecordingFormat.choose(width: 2304, height: 4096, framesPerSecond: 60).codec == .h264)
    }

    @Test func hevcBeyondIt() {
        // The built-in XDR's own framebuffer in its scaled mode is already too wide for H.264.
        #expect(RecordingFormat.choose(width: 4112, height: 2658, framesPerSecond: 60).codec == .hevc)
        #expect(RecordingFormat.choose(width: 6880, height: 2880, framesPerSecond: 60).codec == .hevc)
        #expect(RecordingFormat.choose(width: 2000, height: 4098, framesPerSecond: 60).codec == .hevc)
    }

    @Test func hevcWhenPreferred() {
        #expect(RecordingFormat.choose(width: 1920, height: 1080, framesPerSecond: 60, prefersHEVC: true).codec == .hevc)
    }

    @Test func sidesAreMadeEvenNeverLarger() {
        let format = RecordingFormat.choose(width: 1001, height: 701, framesPerSecond: 30)
        #expect(format.width == 1000)
        #expect(format.height == 700)
        // An odd side just over the limit comes back under it.
        #expect(RecordingFormat.choose(width: 4097, height: 2000, framesPerSecond: 30).codec == .h264)
        #expect(RecordingFormat.choose(width: 1, height: 1, framesPerSecond: 30).width == 2)
    }
}

struct RecordingWriterTests {
    @Test func aStillScreenLastsUntilTheEnd() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TestMedia.writer(url: url)
        // Half a second of change, then nothing: the stream sends no more frames.
        for index in 0..<15 {
            try await TestMedia.append(TestMedia.frame(at: Double(index) / 30, gray: UInt8(40 + index * 8)), to: writer)
        }
        let statistics = try await writer.finish(at: TestMedia.time(3))
        #expect(statistics.framesWritten == 15)
        #expect(abs(statistics.duration.seconds - 3) < 0.001)
        let timing = try await TestMedia.timing(of: url)
        #expect(abs(timing.duration - 3) < 0.05)
        #expect(abs(timing.video.upperBound - timing.video.lowerBound - 3) < 0.05)
    }

    @Test func pausesAreCutOut() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TestMedia.writer(url: url)
        for index in 0..<30 {
            try await TestMedia.append(TestMedia.frame(at: Double(index) / 30), to: writer)
        }
        await writer.pause(at: TestMedia.time(1))
        for index in 0..<60 {
            try await TestMedia.append(TestMedia.frame(at: 1 + Double(index) / 30, gray: 200), to: writer)
        }
        await writer.resume(at: TestMedia.time(3))
        for index in 1..<30 {
            try await TestMedia.append(TestMedia.frame(at: 3 + Double(index) / 30, gray: 60), to: writer)
        }
        let statistics = try await writer.finish(at: TestMedia.time(4))
        #expect(statistics.framesWhilePaused == 60)
        // The 30 before, the newest held back during the pause, and 29 after.
        #expect(statistics.framesWritten == 60)
        #expect(abs(statistics.duration.seconds - 2) < 0.001)
        let timing = try await TestMedia.timing(of: url)
        #expect(abs(timing.duration - 2) < 0.05)
        // Those 60, and the last once more a frame before the end.
        #expect(statistics.framesRepeated == 1)
        #expect(try await TestMedia.frameCount(of: url) == 61)
    }

    @Test func stoppingWhilePausedEndsWhereThePauseBegan() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TestMedia.writer(url: url)
        for index in 0..<30 {
            try await TestMedia.append(TestMedia.frame(at: Double(index) / 30), to: writer)
        }
        await writer.pause(at: TestMedia.time(1.5))
        try await TestMedia.append(TestMedia.frame(at: 2), to: writer)
        let statistics = try await writer.finish(at: TestMedia.time(5))
        #expect(abs(statistics.duration.seconds - 1.5) < 0.001)
        #expect(abs(try await TestMedia.timing(of: url).duration - 1.5) < 0.05)
    }

    @Test func framesTakenBeforeAPauseButDeliveredAfterItAreKept() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TestMedia.writer(url: url)
        try await TestMedia.append(TestMedia.frame(at: 0), to: writer)
        await writer.pause(at: TestMedia.time(1))
        // Taken just before the pause, delivered a moment after it was asked for.
        try await TestMedia.append(TestMedia.frame(at: 0.99), to: writer)
        await writer.resume(at: TestMedia.time(2))
        let statistics = try await writer.finish(at: TestMedia.time(3))
        #expect(statistics.framesWritten == 2)
        #expect(statistics.framesWhilePaused == 0)
    }

    @Test func pausedBeforeTheFirstFrameStartsWhenResumed() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TestMedia.writer(url: url)
        await writer.pause(at: TestMedia.time(0))
        try await TestMedia.append(TestMedia.frame(at: 0.1), to: writer)
        await writer.resume(at: TestMedia.time(2))
        try await TestMedia.append(TestMedia.frame(at: 2.5), to: writer)
        let statistics = try await writer.finish(at: TestMedia.time(3))
        #expect(statistics.framesWritten == 2)
        #expect(abs(statistics.duration.seconds - 1) < 0.001)
    }

    @Test func framesOutOfOrderAreLeftOutWithoutFailingTheMovie() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TestMedia.writer(url: url)
        try await TestMedia.append(TestMedia.frame(at: 0), to: writer)
        try await TestMedia.append(TestMedia.frame(at: 0.5), to: writer)
        try await TestMedia.append(TestMedia.frame(at: 0.4), to: writer)
        try await TestMedia.append(TestMedia.frame(at: 0.5), to: writer)
        let statistics = try await writer.finish(at: TestMedia.time(1))
        #expect(statistics.framesWritten == 2)
        #expect(statistics.framesDropped == 2)
    }

    @Test func noFramesMeansNothingToKeep() async throws {
        let url = TestMedia.temporaryMovie()
        let writer = try TestMedia.writer(url: url)
        await #expect(throws: RecordingWriter.WriterError.noFrames) {
            try await writer.finish(at: TestMedia.time(1))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func cancellingRemovesTheFile() async throws {
        let url = TestMedia.temporaryMovie()
        let writer = try TestMedia.writer(url: url)
        try await TestMedia.append(TestMedia.frame(at: 0), to: writer)
        await writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func audioFollowsTheFramesAndItsPauses() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TestMedia.writer(url: url, audio: RecordingAudio(system: true, microphone: .systemDefault))
        // Audio before the first frame is left out.
        await writer.appendAudio(TestMedia.audio(at: -0.04), to: .systemAudio)
        try await TestMedia.append(TestMedia.frame(at: 0), to: writer)
        var seconds = 0.0
        await writer.pause(at: TestMedia.time(1))
        while seconds < 3 {
            if seconds >= 2 { await writer.resume(at: TestMedia.time(2)) }
            await writer.appendAudio(TestMedia.audio(at: seconds), to: .systemAudio)
            await writer.appendAudio(TestMedia.audio(at: seconds, channels: 1), to: .microphone)
            seconds += 0.02
        }
        let statistics = try await writer.finish(at: TestMedia.time(3))
        #expect(abs(statistics.duration.seconds - 2) < 0.001)
        // 50 buffers a second over the two seconds kept, give or take one at each edge.
        #expect((98...101).contains(statistics.audioBuffersWritten))
        #expect((98...101).contains(statistics.microphoneBuffersWritten))
        let timing = try await TestMedia.timing(of: url)
        #expect(timing.audio.count == 2)
        for track in timing.audio {
            #expect(abs(track.upperBound - track.lowerBound - 2) < 0.1)
        }
        // With audio beside it, the video still reaches the end although its only frame came first.
        #expect(abs(timing.video.upperBound - timing.video.lowerBound - 2) < 0.05)
    }
}
