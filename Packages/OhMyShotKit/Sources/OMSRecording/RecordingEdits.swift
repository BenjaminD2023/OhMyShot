import AVFoundation
import CoreMedia
import Foundation
import OMSCore

extension RecordingFinisher {
    /// What the recording window changes in a kept recording: the part kept, its sound and how loud it is, its
    /// size, and how closely its picture is encoded again.
    public struct Edits: Equatable, Sendable {
        /// The part kept, in the movie's time; nil keeps all of it.
        public var timeRange: CMTimeRange?
        /// Whether the sound stays.
        public var keepsAudio: Bool
        /// The size against the recording's own, from a twentieth up to 1.
        public var scale: Double
        /// How loud the sound that stays is against the recording's own, from 0 to 1.
        public var volume: Double
        /// How closely the picture is encoded when it is encoded again.
        public var quality: RecordingQuality

        public init(
            timeRange: CMTimeRange? = nil, keepsAudio: Bool = true, scale: Double = 1, volume: Double = 1, quality: RecordingQuality = .medium
        ) {
            self.timeRange = timeRange
            self.keepsAudio = keepsAudio
            self.scale = scale
            self.volume = volume
            self.quality = quality
        }

        public static let none = Edits()

        /// Whether the picture is encoded again to make these edits of a movie lasting `whole`, keeping
        /// `range` of it. A trim falls between key frames and a smaller size has fewer pixels, so both are; a
        /// quality other than Medium asks for it. The sound alone is changed with the picture copied.
        func encodesVideo(keeping range: CMTimeRange, of whole: CMTimeRange) -> Bool {
            range != whole || min(max(scale, 0.05), 1) < 1 || quality != .medium
        }
    }

    /// Writes the movie at `source` with `edits` as an MP4 at `destination` (replacing anything there).
    ///
    /// The video is encoded again only when the movie is trimmed or made smaller, since a trim falls between
    /// key frames; leaving out the sound alone copies the video as it is. Encoding again keeps the codec (H.264
    /// unless the movie was HEVC) and the recorder's quality, and runs as fast as the encoder goes. The last
    /// frame is written again just before the end, as the recorder does, so the video lasts as long as the
    /// part kept.
    @concurrent
    public static func export(_ source: URL, to destination: URL, edits: Edits) async throws -> Movie {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw FinishError.noVideo }
        let audioTracks = edits.keepsAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        let whole = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let range = (edits.timeRange ?? whole).intersection(whole)
        guard range.duration.seconds > 0 else { throw FinishError.noVideo }
        let scale = min(max(edits.scale, 0.05), 1)
        let natural = try await videoTrack.load(.naturalSize)
        guard edits.encodesVideo(keeping: range, of: whole) else {
            return try await finish(source, to: destination, audio: edits.keepsAudio ? .all : .none, volume: edits.volume)
        }

        let description = try await videoTrack.load(.formatDescriptions).first
        let isHEVC = description.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC } ?? false
        let nominal = try await videoTrack.load(.nominalFrameRate)
        let format = RecordingFormat.choose(
            width: Int((natural.width * scale).rounded()), height: Int((natural.height * scale).rounded()),
            framesPerSecond: nominal > 1 ? min(Int(nominal.rounded()), 120) : 60, quality: edits.quality.videoQuality, prefersHEVC: isHEVC
        )

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: RecordingAudio.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            output.audioMix = audioMix(for: audioTracks, volume: edits.volume)
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var videoSettings = format.videoSettings(realTime: false)
        // Frames come at the recording's size and are scaled to the new one as they are encoded.
        videoSettings[AVVideoScalingModeKey] = AVVideoScalingModeResize
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        writer.add(videoInput)
        let audioInput = audioOutput.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingAudio.settings(channels: 2)) }
        if let audioInput { writer.add(audioInput) }

        guard reader.startReading() else { throw FinishError.readingFailed(String(describing: reader.error)) }
        guard writer.startWriting() else { throw FinishError.writingFailed(String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)

        // Samples move to the part's own time. The frame showing when the part begins comes first, a little
        // before it: it starts the movie. Times must keep increasing.
        let start = range.start
        let length = range.duration
        let interval = format.frameInterval
        let videoTiming = VideoTiming()
        let videoPump = Pump(
            output: videoOutput, input: videoInput, label: "edit.video",
            transform: { sample in
                let time = max(sample.presentationTimeStamp - start, .zero)
                guard time < length, videoTiming.accepts(time) else { return nil }
                return RecordingWriter.retimed(sample, to: time)
            },
            ending: { last in
                // The last frame again a frame before the end, for a frame's length.
                let time = length - interval
                guard time > last.presentationTimeStamp else { return nil }
                return RecordingWriter.retimed(last, to: time, duration: interval)
            }
        )
        let audioPump = audioOutput.flatMap { output in
            audioInput.map { input in
                Pump(output: output, input: input, label: "edit.audio", transform: { sample in
                    let time = sample.presentationTimeStamp - start
                    guard time >= .zero, time < length else { return nil }
                    return RecordingWriter.retimed(sample, to: time)
                })
            }
        }
        async let video: Void = videoPump.run()
        async let audio: Void = audioPump?.run() ?? ()
        _ = await (video, audio)

        guard reader.status != .failed else {
            writer.cancelWriting()
            throw FinishError.readingFailed(String(describing: reader.error))
        }
        writer.endSession(atSourceTime: length)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FinishError.writingFailed(String(describing: writer.error))
        }
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Movie(
            url: destination, duration: length.seconds, pixelWidth: format.width, pixelHeight: format.height,
            byteCount: bytes, hasAudio: audioInput != nil
        )
    }
}

extension RecordingQuality {
    /// The encoder's constant quality, from 0 to 1. Medium is the quality recordings are made at; Low is
    /// Studio's smaller file, and High its best quality (Docs/perf.md, "Studio movie quality").
    var videoQuality: Double {
        switch self {
        case .high: 0.8
        case .medium: RecordingFormat.standardQuality
        case .low: 0.45
        }
    }
}

/// The newest frame time written, so frames that would not move forward are left out. Touched only on the
/// video pump's queue.
private final class VideoTiming: @unchecked Sendable {
    private var last: CMTime?

    func accepts(_ time: CMTime) -> Bool {
        if let last, time <= last { return false }
        last = time
        return true
    }
}
