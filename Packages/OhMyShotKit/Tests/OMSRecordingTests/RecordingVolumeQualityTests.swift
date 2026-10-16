import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import Testing
@testable import OMSRecording

/// The volume and the quality the recording window chooses, made when the recording is kept.
struct RecordingVolumeQualityTests {
    private let whole = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))

    // MARK: What asks for the picture to be encoded again

    @Test func theSoundAloneNeverTouchesThePicture() {
        #expect(!RecordingFinisher.Edits().encodesVideo(keeping: whole, of: whole))
        #expect(!RecordingFinisher.Edits(keepsAudio: false, volume: 0.3).encodesVideo(keeping: whole, of: whole))
    }

    @Test func aTrimASmallerSizeOrAnotherQualityEncodesItAgain() {
        let part = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 3, preferredTimescale: 600))
        #expect(RecordingFinisher.Edits(timeRange: part).encodesVideo(keeping: part, of: whole))
        #expect(RecordingFinisher.Edits(scale: 0.75).encodesVideo(keeping: whole, of: whole))
        #expect(RecordingFinisher.Edits(quality: .low).encodesVideo(keeping: whole, of: whole))
        #expect(RecordingFinisher.Edits(quality: .high).encodesVideo(keeping: whole, of: whole))
    }

    @Test func mediumIsTheQualityRecordingsAreMadeAt() {
        #expect(RecordingQuality.medium.videoQuality == RecordingFormat.standardQuality)
        #expect(RecordingQuality.low.videoQuality < RecordingQuality.medium.videoQuality)
        #expect(RecordingQuality.medium.videoQuality < RecordingQuality.high.videoQuality)
        #expect(RecordingQuality.allCases.allSatisfy { (0...1).contains($0.videoQuality) })
    }

    // MARK: Volume

    @Test func aQuieterRecordingKeepsItsPictureAsItIs() async throws {
        let movie = try await Self.recording(seconds: 2, audio: true)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        let result = try await RecordingFinisher.export(movie, to: edited, edits: .init(volume: 0.5))
        #expect(result.hasAudio)
        #expect((result.pixelWidth, result.pixelHeight) == (320, 240))
        // The picture is copied, not encoded again: its samples are the recording's, byte for byte. The sound is
        // decoded and encoded again, so its samples are not.
        #expect(try await TestMedia.frameCount(of: edited) == TestMedia.frameCount(of: movie))
        #expect(try await Self.storedSamples(of: edited, .video) == Self.storedSamples(of: movie, .video))
        #expect(try await Self.storedSamples(of: edited, .audio) != Self.storedSamples(of: movie, .audio))
        let ratio = try await Self.loudness(of: edited) / Self.loudness(of: movie)
        #expect(abs(ratio - 0.5) < 0.1, "\(ratio)")
    }

    @Test func aQuieterTrimmedRecordingIsQuieterToo() async throws {
        let movie = try await Self.recording(seconds: 4, audio: true)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 3, preferredTimescale: 600))
        let result = try await RecordingFinisher.export(movie, to: edited, edits: .init(timeRange: range, scale: 0.5, volume: 0.25))
        #expect(result.hasAudio && abs(result.duration - 2) < 0.02)
        #expect((result.pixelWidth, result.pixelHeight) == (160, 120))
        let ratio = try await Self.loudness(of: edited) / Self.loudness(of: movie)
        #expect(abs(ratio - 0.25) < 0.08, "\(ratio)")
    }

    @Test func fullVolumeCopiesTheSoundAsItWas() async throws {
        let movie = try await Self.recording(seconds: 2, audio: true)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        _ = try await RecordingFinisher.export(movie, to: edited, edits: .init(volume: 1))
        // Both tracks are copied as they were encoded.
        #expect(try await Self.storedSamples(of: edited, .video) == Self.storedSamples(of: movie, .video))
        #expect(try await Self.storedSamples(of: edited, .audio) == Self.storedSamples(of: movie, .audio))
        let ratio = try await Self.loudness(of: edited) / Self.loudness(of: movie)
        #expect(abs(ratio - 1) < 0.01, "\(ratio)")
    }

    @Test func soundLeftOutStaysOutWhateverItsVolume() async throws {
        let movie = try await Self.recording(seconds: 2, audio: true)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        let result = try await RecordingFinisher.export(movie, to: edited, edits: .init(keepsAudio: false, volume: 0.5))
        #expect(!result.hasAudio)
        #expect(try await AVURLAsset(url: edited).loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func aQuieterRecordingWithoutSoundIsStillMade() async throws {
        let movie = try await Self.recording(seconds: 2, audio: false)
        let edited = Self.temporaryMP4()
        defer { [movie, edited].forEach { try? FileManager.default.removeItem(at: $0) } }

        let result = try await RecordingFinisher.export(movie, to: edited, edits: .init(volume: 0.5))
        #expect(!result.hasAudio)
        #expect(try await TestMedia.frameCount(of: edited) == TestMedia.frameCount(of: movie))
    }

    // MARK: Quality

    @Test func aLowerQualityMakesASmallerFileOfTheSameSize() async throws {
        let movie = try await Self.noisyRecording(seconds: 2)
        let high = Self.temporaryMP4()
        let low = Self.temporaryMP4()
        defer { [movie, high, low].forEach { try? FileManager.default.removeItem(at: $0) } }

        let sharp = try await RecordingFinisher.export(movie, to: high, edits: .init(quality: .high))
        let small = try await RecordingFinisher.export(movie, to: low, edits: .init(quality: .low))
        #expect((sharp.pixelWidth, sharp.pixelHeight) == (320, 240) && (small.pixelWidth, small.pixelHeight) == (320, 240))
        #expect(abs(small.duration - 2) < 0.05 && abs(sharp.duration - 2) < 0.05)
        #expect(small.byteCount < sharp.byteCount, "low \(small.byteCount) bytes, high \(sharp.byteCount) bytes")
        // Another quality than Medium is an encoding of its own, not the recording's samples.
        let original = try await Self.storedSamples(of: movie, .video)
        #expect(try await Self.storedSamples(of: high, .video) != original)
        #expect(try await Self.storedSamples(of: low, .video) != original)
    }

    // MARK: Helpers

    private static func temporaryMP4() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "OMSRecordingTests-\(UUID().uuidString).mp4")
    }

    /// A recording of `seconds` whose gray steps every half second, with a tone when `audio`.
    private static func recording(seconds: Int, audio: Bool) async throws -> URL {
        let url = TestMedia.temporaryMovie()
        let writer = try TestMedia.writer(url: url, audio: audio ? RecordingAudio(system: true, microphone: nil) : .none)
        var audioTime = 0.0
        for step in 0..<(seconds * 2) {
            let time = Double(step) / 2
            nonisolated(unsafe) let frame = TestMedia.frame(at: time, gray: UInt8(40 + step * 30))
            try await TestMedia.append(frame, to: writer)
            while audio, audioTime < time + 0.5 {
                await writer.appendAudio(TestMedia.audio(at: audioTime), to: .systemAudio)
                audioTime += 0.02
            }
        }
        return try await finished(writer, at: url, seconds: seconds)
    }

    /// A recording of `seconds` of blocks of gray that change at random every frame, which an encoder spends
    /// more bytes on the closer it keeps them.
    private static func noisyRecording(seconds: Int) async throws -> URL {
        let url = TestMedia.temporaryMovie()
        let writer = try TestMedia.writer(url: url)
        var seed: UInt64 = 7
        for step in 0..<(seconds * 10) {
            var squares: [(x: Int, y: Int, size: Int, gray: UInt8)] = []
            for row in 0..<15 {
                for column in 0..<20 {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    squares.append((column * 16, row * 16, 16, UInt8(truncatingIfNeeded: 30 + (seed >> 33) % 190)))
                }
            }
            nonisolated(unsafe) let frame = TestMedia.frame(at: Double(step) / 10, squares: squares)
            try await TestMedia.append(frame, to: writer)
        }
        return try await finished(writer, at: url, seconds: seconds)
    }

    private static func finished(_ writer: RecordingWriter, at url: URL, seconds: Int) async throws -> URL {
        try await writer.finish(at: TestMedia.time(Double(seconds)))
        let finished = url.deletingPathExtension().appendingPathExtension("mp4")
        _ = try await RecordingFinisher.finish(url, to: finished)
        try? FileManager.default.removeItem(at: url)
        return finished
    }

    /// What a movie's first track of `mediaType` stores, as it is stored: how many samples and a hash of their
    /// bytes. A track copied from a movie stores the same, one encoded again does not.
    private struct StoredSamples: Equatable {
        var count: Int
        var hash: UInt64
    }

    private static func storedSamples(of url: URL, _ mediaType: AVMediaType) async throws -> StoredSamples {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: mediaType).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var stored = StoredSamples(count: 0, hash: 0xcbf2_9ce4_8422_2325)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else { continue }
            for byte in bytes { stored.hash = (stored.hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            stored.count += 1
        }
        try #require(stored.count > 0)
        return stored
    }

    /// The root mean square of the movie's first audio track, decoded.
    private static func loudness(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var sum = 0.0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let copied = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard copied == kCMBlockBufferNoErr else { continue }
            for value in values { sum += Double(value) * Double(value) }
            count += values.count
        }
        try #require(count > 0)
        return (sum / Double(count)).squareRoot()
    }
}
