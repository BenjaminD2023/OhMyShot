import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import OSLog

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

    /// Writes the movie at `source` as an MP4 at `destination` (replacing anything there), its index first so
    /// it starts playing before it has all loaded; without `includingAudio`, without its sound. `source` is
    /// left as it is.
    @concurrent
    public static func finish(_ source: URL, to destination: URL, includingAudio: Bool = true) async throws -> Movie {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw FinishError.noVideo }
        let audioTracks = includingAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        let duration = try await asset.load(.duration)
        let size = try await videoTrack.load(.naturalSize)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderOutput?
        var audioSettings: [String: Any]?
        var audioHint: CMFormatDescription?
        if audioTracks.count == 1 {
            let output = AVAssetReaderTrackOutput(track: audioTracks[0], outputSettings: nil)
            output.alwaysCopiesSampleData = false
            audioHint = try await audioTracks[0].load(.formatDescriptions).first
            audioOutput = output
        } else if audioTracks.count > 1 {
            audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: RecordingAudio.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            audioSettings = RecordingAudio.settings(channels: 2)
        }
        if let audioOutput { reader.add(audioOutput) }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: try await videoTrack.load(.formatDescriptions).first
        )
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        writer.add(videoInput)
        let audioInput = audioOutput.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioHint)
        }
        if let audioInput { writer.add(audioInput) }

        guard reader.startReading() else { throw FinishError.readingFailed(String(describing: reader.error)) }
        guard writer.startWriting() else { throw FinishError.writingFailed(String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)
        // Both at once: the writer interleaves the tracks and waits for whichever is behind.
        let videoPump = Pump(output: videoOutput, input: videoInput, label: "video")
        let audioPump = audioOutput.flatMap { output in audioInput.map { Pump(output: output, input: $0, label: "audio") } }
        async let video: Void = videoPump.run()
        async let audio: Void = audioPump?.run() ?? ()
        _ = await (video, audio)

        guard reader.status != .failed else {
            writer.cancelWriting()
            throw FinishError.readingFailed(String(describing: reader.error))
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FinishError.writingFailed(String(describing: writer.error))
        }
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Movie(
            url: destination, duration: duration.seconds, pixelWidth: Int(size.width.rounded()), pixelHeight: Int(size.height.rounded()),
            byteCount: bytes, hasAudio: audioInput != nil
        )
    }

    /// A still of the recording's first frame, at most `maxPixels` on its long side.
    @concurrent
    public static func poster(of url: URL, maxPixels: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        return try? await generator.image(at: .zero).image
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
    /// Touched only on `queue`.
    private var isDone = false
    private var last: CMSampleBuffer?

    init(
        output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String,
        transform: ((CMSampleBuffer) -> CMSampleBuffer?)? = nil, ending: ((CMSampleBuffer) -> CMSampleBuffer?)? = nil
    ) {
        self.output = output
        self.input = input
        self.transform = transform
        self.ending = ending
        queue = DispatchQueue(label: "OhMyShot.finish.\(label)")
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !isDone else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        if let last, let final = ending?(last) {
                            input.append(final)
                        }
                        input.markAsFinished()
                        isDone = true
                        continuation.resume()
                        return
                    }
                    // The reader also hands out markers that hold no media.
                    guard CMSampleBufferGetDataBuffer(sample) != nil || CMSampleBufferGetImageBuffer(sample) != nil else { continue }
                    guard let changed = transform.map({ $0(sample) }) ?? sample else { continue }
                    if !input.append(changed) {
                        isDone = true
                        continuation.resume()
                        return
                    }
                    last = changed
                }
            }
        }
    }
}
