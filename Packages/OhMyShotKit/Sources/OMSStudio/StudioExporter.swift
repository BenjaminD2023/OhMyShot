import AVFoundation
import Foundation
import VideoToolbox

/// Writes a Studio composition out as an MP4: the frames its compositor films, encoded as fast as the
/// hardware goes (H.264 while the movie fits it, HEVC beyond 4096 pixels), and the sound mixed into one AAC
/// track.
nonisolated public enum StudioExporter {
    public struct Movie: Equatable, Sendable {
        public let url: URL
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let duration: Double
        public let byteCount: Int
    }

    /// Writes `composition` to `destination` (replacing anything there). `progress` hears how far along it is,
    /// from 0 to 1, now and then; cancelling the task stops it and removes the file.
    @concurrent
    public static func export(
        _ composition: StudioComposition, to destination: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Movie {
        let asset = composition.asset
        let canvas = composition.renderer.layout.canvas
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw StudioError.noVideo }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = composition.videoComposition
        // The frames go straight to the encoder untouched: no copy of each one first.
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let fitsH264 = canvas.width <= 4096 && canvas.height <= 4096
        var properties: [String: Any] = [
            AVVideoQualityKey: 0.6, AVVideoExpectedSourceFrameRateKey: 60, AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        properties[AVVideoProfileLevelKey] = fitsH264 ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: fitsH264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height), AVVideoCompressionPropertiesKey: properties,
            // Encoded and tagged in the recording's color space, as the frames are drawn.
            AVVideoColorPropertiesKey: composition.colors.properties,
        ])
        writer.add(videoInput)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let audioInput = audioOutput.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
        }
        if let audioInput { writer.add(audioInput) }

        guard reader.startReading() else { throw StudioError.readingFailed(String(describing: reader.error)) }
        guard writer.startWriting() else { throw StudioError.writingFailed(String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)
        let duration = composition.duration
        let videoPump = Pump(output: videoOutput, input: videoInput, label: "studio.video") { time in
            if duration > 0 { progress?(min(time / duration, 1)) }
        }
        let audioPump = audioOutput.flatMap { output in audioInput.map { Pump(output: output, input: $0, label: "studio.audio") } }
        let stopper = ReaderStopper(reader)
        do {
            try await withTaskCancellationHandler {
                async let video: Void = videoPump.run()
                async let audio: Void = audioPump?.run() ?? ()
                _ = await (video, audio)
                try Task.checkCancellation()
            } onCancel: {
                stopper.stop()
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard reader.status != .failed else {
            writer.cancelWriting()
            throw StudioError.readingFailed(String(describing: reader.error))
        }
        writer.endSession(atSourceTime: StudioComposition.time(duration))
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.writingFailed(String(describing: writer.error)) }
        progress?(1)
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Movie(url: destination, pixelWidth: Int(canvas.width), pixelHeight: Int(canvas.height), duration: duration, byteCount: bytes)
    }
}

/// Stops a reader from the cancellation handler, whichever thread that runs on: reading stops and the pumps
/// find no more samples.
nonisolated private final class ReaderStopper: @unchecked Sendable {
    private let reader: AVAssetReader

    init(_ reader: AVAssetReader) {
        self.reader = reader
    }

    func stop() {
        reader.cancelReading()
    }
}

/// Copies one track's samples from a reader to a writer input whenever the input can take more.
nonisolated private final class Pump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    private let onSample: ((Double) -> Void)?
    /// Touched only on `queue`.
    private var isDone = false

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, onSample: ((Double) -> Void)? = nil) {
        self.output = output
        self.input = input
        self.onSample = onSample
        queue = DispatchQueue(label: "OhMyShot.\(label)")
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !isDone else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        isDone = true
                        continuation.resume()
                        return
                    }
                    guard CMSampleBufferGetDataBuffer(sample) != nil || CMSampleBufferGetImageBuffer(sample) != nil else { continue }
                    if !input.append(sample) {
                        isDone = true
                        continuation.resume()
                        return
                    }
                    onSample?(sample.presentationTimeStamp.seconds)
                }
            }
        }
    }
}
