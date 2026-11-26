import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import OSLog
import Synchronization

/// Makes the file a recording is kept as from the movie written while recording: an MP4, which every player
/// and upload form takes, with one audio track.
///
/// The video is copied as it was encoded, never encoded again, so finishing takes about as long as reading
/// the file. Audio recorded in one track is copied too; the system's sound and the microphone, recorded in
/// tracks of their own, are mixed into one, since most players play only a file's first audio track.
public enum RecordingFinisher {
    public struct Movie: Equatable, Sendable {
        public let url: URL
        public let duration: TimeInterval
        /// The size it is shown at: a movie from a phone held upright is encoded on its side and turned as it plays.
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let byteCount: Int
        public let hasAudio: Bool
    }

    public enum FinishError: Error, Equatable {
        case noVideo
        case readingFailed(String)
        case writingFailed(String)
    }

    /// Which of a movie's audio tracks the finished file keeps, by their place among its audio tracks; more
    /// than one are mixed into one.
    public enum AudioTracks: Equatable, Sendable {
        case all
        case none
        case only([Int])

        /// The tracks a clip saved from the replay keeps for `sound`, when its tracks hold `buffered`, in order.
        public static func keeping(_ sound: ReplaySound, of buffered: [RecordingWriter.Track]) -> AudioTracks {
            let kept = buffered.indices.filter { index in
                switch buffered[index] {
                case .systemAudio: sound.keepsSystem
                case .microphone: sound.keepsMicrophone
                }
            }
            return kept.count == buffered.count ? .all : kept.isEmpty ? .none : .only(kept)
        }
    }

    /// The audio mix that plays `tracks` at `volume`, or nil at full volume, which needs none.
    static func audioMix(for tracks: [AVAssetTrack], volume: Double) -> AVAudioMix? {
        guard !RecordingVolume.isFull(volume), !tracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(max(volume, 0)), at: .zero)
            return parameters
        }
        return mix
    }

    /// Writes the movie at `source` as an MP4 at `destination` (replacing anything there), or as a QuickTime movie
    /// when `destination` ends in .mov, its index first so it starts playing before it has all loaded, with the audio
    /// tracks `audio` keeps, at `volume` against their own. `source` is left as it is.
    ///
    /// Sound at full volume is copied as it was encoded when it is one track; at a lower volume, or mixed from
    /// more tracks, it is decoded and encoded again.
    @concurrent
    public static func finish(
        _ source: URL,
        to destination: URL,
        audio: AudioTracks = .all,
        volume: Double = 1,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Movie {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw FinishError.noVideo }
        let allAudio = try await asset.loadTracks(withMediaType: .audio)
        let audioTracks: [AVAssetTrack] = switch audio {
        case .all: allAudio
        case .none: []
        case .only(let indices): indices.filter(allAudio.indices.contains).map { allAudio[$0] }
        }
        let duration = try await asset.load(.duration)
        let size = try await videoTrack.load(.naturalSize)
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderOutput?
        var audioSettings: [String: Any]?
        var audioHint: CMFormatDescription?
        let mix = audioMix(for: audioTracks, volume: volume)
        if audioTracks.count == 1, mix == nil {
            let output = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: nil)
            output.alwaysCopiesSampleData = false
            audioHint = try await audioTracks[0].load(.formatDescriptions).first
            audioOutput = output
        } else if !audioTracks.isEmpty {
            audioOutput = mixedOutput(of: audioTracks, mix: mix)
            audioSettings = RecordingAudio.settings(channels: 2)
        }
        if let audioOutput { reader.add(audioOutput) }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType(for: destination))
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: try await videoTrack.load(.formatDescriptions).first
        )
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        try add(videoInput, to: writer)
        let audioInput = audioOutput.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioHint)
        }
        if let audioInput { try add(audioInput, to: writer) }

        try Task.checkCancellation()
        guard reader.startReading() else { throw FinishError.readingFailed(String(describing: reader.error)) }
        guard writer.startWriting() else { throw FinishError.writingFailed(String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)
        let videoPump = Pump(
            output: videoOutput, input: videoInput, label: "video",
            onSample: sampleProgress(totalSeconds: duration.seconds, report: progress)
        )
        let audioPump = audioOutput.flatMap { output in audioInput.map { Pump(output: output, input: $0, label: "audio") } }
        return try await write(
            video: videoPump, audio: audioPump, from: reader, with: writer, endingAt: duration, to: destination,
            pixelWidth: Int(size.width.rounded()), pixelHeight: Int(size.height.rounded()), progress: progress
        )
    }

    /// The container a movie written at `destination` takes: a QuickTime movie for .mov, which holds whatever a movie
    /// opened from Finder was encoded with, such as ProRes; an MP4 for anything else.
    static func fileType(for destination: URL) -> AVFileType {
        destination.pathExtension.lowercased() == "mov" ? .mov : .mp4
    }

    /// Adds `input` to `writer`, or throws when its container can't hold the track, as an MP4 can't hold ProRes.
    static func add(_ input: AVAssetWriterInput, to writer: AVAssetWriter) throws {
        guard writer.canAdd(input) else {
            throw FinishError.writingFailed("An \(writer.outputFileType.rawValue) file can't hold this \(input.mediaType.rawValue) track")
        }
        writer.add(input)
    }

    /// A reader output mixing `tracks` into one, played with `mix`: stereo 32-bit float PCM at the recorder's sample
    /// rate, to be encoded again.
    static func mixedOutput(of tracks: [AVAssetTrack], mix: AVAudioMix?) -> AVAssetReaderAudioMixOutput {
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RecordingAudio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = mix
        return output
    }

    /// Maps written video timestamps to monotonically increasing progress values in `0...0.99`, throttled to
    /// ~1% steps so progress observers stay responsive without flooding.
    static func sampleProgress(
        totalSeconds: Double,
        report: (@Sendable (Double) -> Void)?
    ) -> (@Sendable (CMTime) -> Void)? {
        guard let report else { return nil }
        let total = max(totalSeconds, 0.001)
        let lastReported = Mutex<Double>(-1)
        return { time in
            let fraction = min(max(time.seconds / total, 0), 0.99)
            let shouldReport = lastReported.withLock { last in
                guard last < 0 || fraction >= last + 0.01 else { return false }
                last = fraction
                return true
            }
            if shouldReport { report(fraction) }
        }
    }

    /// Runs the pumps, ends the movie `end` into it, and says what was written at `destination`, the writer's file.
    static func write(
        video: Pump, audio: Pump?, from reader: AVAssetReader, with writer: AVAssetWriter, endingAt end: CMTime, to destination: URL,
        pixelWidth: Int, pixelHeight: Int, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Movie {
        // Both at once: the writer interleaves the tracks and waits for whichever is behind.
        await withTaskCancellationHandler {
            async let videoPumped: Void = video.run()
            async let audioPumped: Void = audio?.run() ?? ()
            _ = await (videoPumped, audioPumped)
        } onCancel: {
            video.cancel()
            audio?.cancel()
        }

        if Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        guard reader.status != .failed else {
            writer.cancelWriting()
            throw FinishError.readingFailed(String(describing: reader.error))
        }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw FinishError.writingFailed(String(describing: writer.error))
        }
        progress?(1)
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let turn = writer.inputs.first { $0.mediaType == .video }?.transform ?? .identity
        let shown = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).applying(turn)
        return Movie(
            url: destination, duration: end.seconds, pixelWidth: Int(abs(shown.width).rounded()), pixelHeight: Int(abs(shown.height).rounded()),
            byteCount: bytes, hasAudio: audio != nil
        )
    }
}

/// Copies one track's samples from a reader to a writer input whenever the input can take more.
final class Pump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    /// Changes each sample before it is written (its time); nil leaves it out.
    private let transform: ((CMSampleBuffer) -> CMSampleBuffer?)?
    /// Given the last sample written, one more to write before the track ends.
    private let ending: ((CMSampleBuffer) -> CMSampleBuffer?)?
    /// Called on `queue` with the presentation timestamp of each sample written.
    private let onSample: (@Sendable (CMTime) -> Void)?
    /// Set from any thread on task cancellation; checked synchronously inside the pump loop.
    private let cancelled = Mutex(false)
    /// Touched only on `queue`.
    private var isDone = false
    private var last: CMSampleBuffer?
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String,
        transform: ((CMSampleBuffer) -> CMSampleBuffer?)? = nil,
        ending: ((CMSampleBuffer) -> CMSampleBuffer?)? = nil,
        onSample: (@Sendable (CMTime) -> Void)? = nil
    ) {
        self.output = output
        self.input = input
        self.transform = transform
        self.ending = ending
        self.onSample = onSample
        queue = DispatchQueue(label: "OhMyShot.finish.\(label)")
    }

    private var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        queue.async { [self] in
            finishIfNeeded(markInputFinished: false)
        }
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard !isDone, !isCancelled else {
                    isDone = true
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !isDone else { return }
                    if isCancelled {
                        finishIfNeeded(markInputFinished: false)
                        return
                    }
                    while input.isReadyForMoreMediaData {
                        if isCancelled {
                            finishIfNeeded(markInputFinished: false)
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            if let last, let final = ending?(last) {
                                input.append(final)
                            }
                            finishIfNeeded(markInputFinished: true)
                            return
                        }
                        // The reader also hands out markers that hold no media.
                        guard CMSampleBufferGetDataBuffer(sample) != nil || CMSampleBufferGetImageBuffer(sample) != nil else { continue }
                        guard let changed = transform.map({ $0(sample) }) ?? sample else { continue }
                        if !input.append(changed) {
                            finishIfNeeded(markInputFinished: false)
                            return
                        }
                        last = changed
                        onSample?(changed.presentationTimeStamp)
                    }
                }
            }
        }
    }

    private func finishIfNeeded(markInputFinished: Bool) {
        guard !isDone else { return }
        if markInputFinished {
            input.markAsFinished()
        }
        isDone = true
        let active = continuation
        continuation = nil
        active?.resume()
    }
}
