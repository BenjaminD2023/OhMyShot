import AVFoundation
import Foundation
import VideoToolbox

/// Writes a Studio composition out as an MP4: the frames its compositor films, encoded as fast as the
/// hardware goes (H.264 while the movie fits it, HEVC beyond 4096 pixels) at the project's quality, and the
/// sound mixed into one AAC track.
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
        try await export(composition, to: destination, progress: progress, finishing: {})
    }

    /// The finalization boundary is injectable so cancellation during file packaging can be exercised
    /// without relying on encoder speed. All callers, including this boundary, use the same cleanup.
    @concurrent
    static func export(
        _ composition: StudioComposition, to destination: URL, progress: (@Sendable (Double) -> Void)? = nil,
        finishing: @escaping @Sendable () async throws -> Void
    ) async throws -> Movie {
        try Task.checkCancellation()
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
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        defer {
            if !completed {
                reader.cancelReading()
                writer.cancelWriting()
            }
        }
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: videoSettings(canvas: canvas, quality: composition.renderer.project.quality, colors: composition.colors)
        )
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
                guard reader.status != .failed else { throw StudioError.readingFailed(String(describing: reader.error)) }
                guard writer.status == .writing else { throw StudioError.writingFailed(String(describing: writer.error)) }
                writer.endSession(atSourceTime: StudioComposition.time(duration))
                await writer.finishWriting()
                try await finishing()
                try Task.checkCancellation()
            } onCancel: {
                stopper.stop()
                videoPump.stop()
                audioPump?.stop()
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard writer.status == .completed else { throw StudioError.writingFailed(String(describing: writer.error)) }
        try Task.checkCancellation()
        progress?(1)
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        completed = true
        return Movie(url: destination, pixelWidth: Int(canvas.width), pixelHeight: Int(canvas.height), duration: duration, byteCount: bytes)
    }

    /// The writer's settings for the movie's video track: H.264 while `canvas` fits it, HEVC beyond, either at
    /// `quality`'s constant quality, encoded and tagged in the recording's color space (`colors`), as the frames
    /// are drawn.
    static func videoSettings(canvas: CGSize, quality: StudioProject.Quality, colors: StudioComposition.Colors) -> [String: Any] {
        let fitsH264 = canvas.width <= 4096 && canvas.height <= 4096
        var properties: [String: Any] = [
            AVVideoQualityKey: videoQuality(for: quality), AVVideoExpectedSourceFrameRateKey: 60, AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        properties[AVVideoProfileLevelKey] = fitsH264 ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String
        return [
            AVVideoCodecKey: fitsH264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height), AVVideoCompressionPropertiesKey: properties,
            AVVideoColorPropertiesKey: colors.properties,
        ]
    }

    /// The encoder's constant quality, from 0 to 1, for each of the movie's qualities. Standard is the quality
    /// the recording is made at.
    static func videoQuality(for quality: StudioProject.Quality) -> Double {
        switch quality {
        case .smaller: 0.45
        case .standard: 0.6
        case .best: 0.8
        }
    }

    // MARK: Estimate

    /// About how many bytes the movie will be, from what is known before it is made. A recording's bytes go
    /// with its length, and with the size of its picture more slowly than with its pixels (the background
    /// around the recording costs next to nothing), so the movie weighs the recording's bytes for the part of
    /// it that is kept, times the square root of the pixels the movie has for each of the recording's, times
    /// what its quality changes. Nil when the recording's size isn't known.
    static func estimatedByteCount(
        sourceByteCount: Int, sourceSize: CGSize, sourceDuration: Double, canvas: CGSize, keptDuration: Double, quality: StudioProject.Quality
    ) -> Int? {
        let sourcePixels = sourceSize.width * sourceSize.height
        guard sourceByteCount > 0, sourceDuration > 0, sourcePixels > 0 else { return nil }
        let share = max(0, keptDuration) / sourceDuration
        let growth = (max(0, canvas.width * canvas.height) / sourcePixels).squareRoot()
        return Int((Double(sourceByteCount) * share * growth * sizeFactor(for: quality)).rounded())
    }

    /// How the bytes of the same picture at each quality compare with the recording's, as measured on a
    /// scrolling page of text (Docs/perf.md, "Studio movie quality"): standard weighs what the recording did,
    /// the encoder's 0.45 two thirds of that, and its 0.8 seven tenths more.
    static func sizeFactor(for quality: StudioProject.Quality) -> Double {
        switch quality {
        case .smaller: 0.65
        case .standard: 1
        case .best: 1.7
        }
    }

    /// An estimate as the inspector says it, rounded to two figures: "About 24 MB", or "Under 1 MB".
    public static func estimateDescription(byteCount: Int) -> String {
        guard byteCount >= 1_000_000 else { return String(localized: "Under 1 MB", bundle: .module) }
        let step = pow(10, log10(Double(byteCount)).rounded(.down) - 1)
        let size = ByteCountFormatter.string(fromByteCount: Int64((Double(byteCount) / step).rounded() * step), countStyle: .file)
        return String(localized: "About \(size)", bundle: .module)
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
    private var continuation: CheckedContinuation<Void, Never>?

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, onSample: ((Double) -> Void)? = nil) {
        self.output = output
        self.input = input
        self.onSample = onSample
        queue = DispatchQueue(label: "OhMyShot.\(label)")
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard !isDone else { return continuation.resume() }
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !isDone else { return }
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else { return finish() }
                        guard CMSampleBufferGetDataBuffer(sample) != nil || CMSampleBufferGetImageBuffer(sample) != nil else { continue }
                        guard input.append(sample) else { return finish() }
                        onSample?(sample.presentationTimeStamp.seconds)
                    }
                }
            }
        }
    }

    /// Cancelling must also finish a pump waiting for encoder capacity, whose readiness callback may
    /// otherwise never run again. All continuation state belongs to the pump's serial queue.
    func stop() {
        queue.async { [self] in finish() }
    }

    private func finish() {
        guard !isDone else { return }
        isDone = true
        input.markAsFinished()
        continuation?.resume()
        continuation = nil
    }
}
