import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import OMSRecording

@MainActor
struct ScreenRecorderTests {
    private nonisolated static func failingVideoFrame(at seconds: Double) -> CMSampleBuffer {
        var badPixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_DepthFloat32, nil, &badPixels)
        var badDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: badPixels!, formatDescriptionOut: &badDescription
        )
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: TestMedia.time(seconds), decodeTimeStamp: .invalid
        )
        var badSample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: badPixels!, formatDescription: badDescription!,
            sampleTiming: &timing, sampleBufferOut: &badSample
        )
        return badSample!
    }

    @Test func aRecordingKeepsTheDisplayAwakeAndTheReplayBufferDoesNot() {
        #expect(ScreenRecorder.activityOptions.contains(.idleDisplaySleepDisabled))
        #expect(ScreenRecorder.activityOptions.contains(.userInitiated))
        guard #available(macOS 27, *) else { return }
        #expect(!ReplayBuffer.activityOptions.contains(.idleDisplaySleepDisabled))
        #expect(!ReplayBuffer.activityOptions.contains(.idleSystemSleepDisabled))
    }

    @Test func writerFailureDuringStartupIsNotLostBeforeSessionIsInstalled() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = RecordingFormat.choose(width: 320, height: 240, framesPerSecond: 30)
        let recorder = try ScreenRecorder(movieURL: url, format: format, audio: .none)

        // Mirrors RecordingCoordinator: the recording session is only installed once start() returns.
        var sessionInstalled = false
        var prematureCallbacks = 0
        var handledFailures: [RecordingWriter.Failure] = []
        recorder.onWriterFailed = { failure in
            guard sessionInstalled else {
                prematureCallbacks += 1
                return
            }
            handledFailures.append(failure)
        }

        try await recorder.start {
            for index in 0..<5 {
                try await TestMedia.append(TestMedia.frame(at: Double(index) / 30), to: recorder.writer)
            }
            try await TestMedia.append(Self.failingVideoFrame(at: 0.3), to: recorder.writer)
            var attempts = 0
            while !recorder.hasPendingWriterFailure, attempts < 200 {
                await recorder.writer.checkHealth()
                try await Task.sleep(for: .milliseconds(10))
                attempts += 1
            }
            #expect(recorder.hasPendingWriterFailure)
        }

        #expect(prematureCallbacks == 0)
        #expect(recorder.state == .recording)

        // Install session right after start() returns, then drain any startup failure before showing chrome.
        sessionInstalled = true
        if let pending = recorder.takePendingWriterFailure() {
            handledFailures.append(pending)
            do {
                _ = try await recorder.stop()
            } catch RecordingWriter.WriterError.writerFailed {
                // Expected after a writer failure.
            }
        }

        #expect(handledFailures.count == 1)
        #expect(recorder.takePendingWriterFailure() == nil)
        #expect(recorder.state == .finished)
    }

    @Test func writerFailureAfterStartupReturnsStillDeliversToCallback() async throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = RecordingFormat.choose(width: 320, height: 240, framesPerSecond: 30)
        let recorder = try ScreenRecorder(movieURL: url, format: format, audio: .none)

        var handledFailures: [RecordingWriter.Failure] = []
        recorder.onWriterFailed = { failure in
            handledFailures.append(failure)
        }

        try await recorder.start {}
        #expect(recorder.takePendingWriterFailure() == nil)
        #expect(recorder.state == .recording)

        for index in 0..<5 {
            try await TestMedia.append(TestMedia.frame(at: Double(index) / 30), to: recorder.writer)
        }
        try await TestMedia.append(Self.failingVideoFrame(at: 0.3), to: recorder.writer)

        var attempts = 0
        while handledFailures.isEmpty, attempts < 200 {
            await recorder.checkWriterHealth()
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(handledFailures.count == 1)
        do {
            _ = try await recorder.stop()
        } catch RecordingWriter.WriterError.writerFailed {
            // Expected after a writer failure.
        }
        #expect(recorder.state == .finished)
    }

    @Test func mutingMicrophoneLivePropagatesToWriterAndZeroesMeter() throws {
        let url = TestMedia.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = RecordingFormat.choose(width: 320, height: 240, framesPerSecond: 30)
        let recorder = try ScreenRecorder(
            movieURL: url, format: format, audio: RecordingAudio(system: false, microphone: .systemDefault)
        )
        #expect(!recorder.isMicrophoneMuted)
        #expect(!recorder.writer.isMicrophoneMuted)

        recorder.isMicrophoneMuted = true
        #expect(recorder.isMicrophoneMuted)
        #expect(recorder.writer.isMicrophoneMuted)
        #expect(recorder.takeMicrophoneLevel() == 0)

        recorder.isMicrophoneMuted = false
        #expect(!recorder.isMicrophoneMuted)
        #expect(!recorder.writer.isMicrophoneMuted)
    }
}
