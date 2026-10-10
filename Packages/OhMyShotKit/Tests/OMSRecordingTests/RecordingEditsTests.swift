import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import Testing
@testable import OMSRecording

struct RecordingEditsTests {
    @Test func aTrimKeepsThePartAndItsSound() async throws {
        let movie = try await Self.recording(seconds: 4, audio: true)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 3, preferredTimescale: 600))
        let result = try await RecordingFinisher.export(movie, to: edited, edits: .init(timeRange: range))
        #expect(abs(result.duration - 2) < 0.02)
        #expect(result.hasAudio)
        let timing = try await TestMedia.timing(of: edited)
        #expect(abs(timing.duration - 2) < 0.03)
        // The video starts at the start and lasts to the end, as does the sound.
        #expect(timing.video.lowerBound < 0.01 && timing.video.upperBound > 1.95, "\(timing.video)")
        let audio = try #require(timing.audio.first)
        #expect(audio.lowerBound < 0.03 && audio.upperBound > 1.95, "\(audio)")
        // The first frame is the one showing a second in (gray steps every half second).
        let first = try await Self.lumaOfFirstFrame(edited)
        #expect(abs(first - Self.gray(at: 1)) < 15, "\(first)")
    }

    @Test func smallerAndSilent() async throws {
        let movie = try await Self.recording(seconds: 2, audio: true)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        let result = try await RecordingFinisher.export(movie, to: edited, edits: .init(keepsAudio: false, scale: 0.5))
        #expect((result.pixelWidth, result.pixelHeight) == (160, 120))
        #expect(!result.hasAudio)
        let asset = AVURLAsset(url: edited)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 160, height: 120))
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.03)
    }

    @Test func leavingOutTheSoundAloneCopiesTheVideo() async throws {
        let movie = try await Self.recording(seconds: 2, audio: true)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        let result = try await RecordingFinisher.export(movie, to: edited, edits: .init(keepsAudio: false))
        #expect(!result.hasAudio)
        #expect((result.pixelWidth, result.pixelHeight) == (320, 240))
        #expect(try await TestMedia.frameCount(of: edited) == TestMedia.frameCount(of: movie))
    }

    @Test func anEditedRecordingInTheHistoryCanBePutBack() async throws {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingEditsTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let movie = try await Self.recording(seconds: 4, audio: false)
        let entry = try store.add(movingFileAt: movie, name: "Recording", kind: .recording, pixelWidth: 320, pixelHeight: 240, appName: nil, duration: 4)
        let edited = Self.temporaryMP4()
        let range = CMTimeRange(start: .zero, end: CMTime(seconds: 1.5, preferredTimescale: 600))
        let result = try await RecordingFinisher.export(store.fileURL(for: entry), to: edited, edits: .init(timeRange: range, scale: 0.5))
        let trimmed = try store.replaceRecording(of: entry, withFileAt: result.url, pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight, duration: result.duration)
        #expect(trimmed.pixelWidth == 160)
        #expect(abs((trimmed.duration ?? 0) - 1.5) < 0.02)

        let restored = try await store.restoreRecording(of: trimmed)
        #expect((restored.pixelWidth, restored.pixelHeight) == (320, 240))
        #expect(abs((restored.duration ?? 0) - 4) < 0.03)
        #expect(!store.hasOriginal(restored))
        #expect(abs(try await AVURLAsset(url: store.fileURL(for: restored)).load(.duration).seconds - 4) < 0.03)
    }

    // MARK: Helpers

    /// The gray of the frame shown at `seconds` in the test recording.
    private static func gray(at seconds: Double) -> Double {
        Double(40 + Int(seconds * 2) * 30)
    }

    /// A recording of `seconds` whose gray steps every half second, with a tone when `audio`.
    private static func recording(seconds: Int, audio: Bool) async throws -> URL {
        let url = TestMedia.temporaryMovie()
        let writer = try TestMedia.writer(url: url, audio: audio ? RecordingAudio(system: true, microphone: nil) : .none)
        var audioTime = 0.0
        for step in 0..<(seconds * 2) {
            let time = Double(step) / 2
            nonisolated(unsafe) let frame = TestMedia.frame(at: time, gray: UInt8(gray(at: time)))
            try await TestMedia.append(frame, to: writer)
            while audio, audioTime < time + 0.5 {
                await writer.appendAudio(TestMedia.audio(at: audioTime), to: .systemAudio)
                audioTime += 0.02
            }
        }
        try await writer.finish(at: TestMedia.time(Double(seconds)))
        let finished = url.deletingPathExtension().appendingPathExtension("mp4")
        _ = try await RecordingFinisher.finish(url, to: finished)
        try? FileManager.default.removeItem(at: url)
        return finished
    }

    private static func temporaryMP4() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "OMSRecordingTests-\(UUID().uuidString).mp4")
    }

    /// The luma of the middle of the movie’s first frame, roughly: color management moves it a few levels.
    private static func lumaOfFirstFrame(_ url: URL) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Back from full range to the luma the frame was made with.
        return Double(pixel[1]) * 219 / 255 + 16
    }
}
