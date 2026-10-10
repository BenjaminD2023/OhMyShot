import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import OMSRecording

/// Synthetic samples as the stream would deliver them, with host-clock-like times.
enum TestMedia {
    /// Where the fake host clock starts, so times never begin at zero as real ones never do.
    static let origin = 5_000.0

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: origin + seconds, preferredTimescale: 1_000_000_000)
    }

    /// A 420v frame of one gray level, presented at `seconds`.
    static func frame(at seconds: Double, width: Int = 320, height: Int = 240, gray: UInt8 = 128) -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 0), Int32(gray), CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * height)
        memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample!
    }

    /// `frames` frames of interleaved float stereo at 48 kHz (a quiet tone), presented at `seconds`.
    static func audio(at seconds: Double, frames: Int = 960, channels: Int = 2) -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        )
        let byteCount = frames * channels * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        var samples = [Float](repeating: 0, count: frames * channels)
        for index in 0..<frames {
            let value = Float(sin(Double(index) / 48_000 * 440 * 2 * .pi) * 0.1)
            for channel in 0..<channels { samples[index * channels + channel] = value }
        }
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: origin + seconds, preferredTimescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample
        )
        return sample!
    }

    static func temporaryMovie() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "OMSRecordingTests-\(UUID().uuidString).mov")
    }

    static func writer(url: URL, audio: RecordingAudio = .none, framesPerSecond: Int = 30) throws -> RecordingWriter {
        let format = RecordingFormat.choose(width: 320, height: 240, framesPerSecond: framesPerSecond)
        return try RecordingWriter(url: url, format: format, audio: audio, queue: DispatchSerialQueue(label: "test.recording"))
    }

    /// Appends a frame once the encoder takes one, as a stream's pace would allow.
    static func append(_ sample: sending CMSampleBuffer, to writer: RecordingWriter) async throws {
        var waited = 0
        while !(await writer.isReadyForFrame), waited < 2_000 {
            try await Task.sleep(for: .milliseconds(1))
            waited += 1
        }
        await writer.appendFrame(sample)
    }

    /// The movie's duration and each track's time range, in seconds.
    static func timing(of url: URL) async throws -> (duration: Double, video: ClosedRange<Double>, audio: [ClosedRange<Double>]) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoRange = try await videoTrack.load(.timeRange)
        var audio: [ClosedRange<Double>] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let range = try await track.load(.timeRange)
            audio.append(range.start.seconds...range.end.seconds)
        }
        return (duration, videoRange.start.seconds...videoRange.end.seconds, audio)
    }

    /// How many video frames the movie holds.
    static func frameCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        // The reader also hands out markers without data, which are no frames.
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetDataBuffer(sample) != nil { count += CMSampleBufferGetNumSamples(sample) }
        }
        return count
    }
}
