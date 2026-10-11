import AVFoundation
import CoreImage
import Foundation

/// A Studio recording put together for playing and for export: the recording with its cuts left out, and a
/// video composition whose compositor films each frame through a `StudioRenderer`. An AVPlayerItem plays it
/// in real time; `StudioExporter` writes it out. Both draw the same frames.
nonisolated public struct StudioComposition: @unchecked Sendable {
    public let asset: AVComposition
    public let videoComposition: AVVideoComposition
    public let renderer: StudioRenderer
    /// The movie's length, cuts left out.
    public let duration: Double
    /// The color space its frames are drawn and tagged in.
    public let colors: Colors

    /// The parts of the recording kept, where each starts in the movie.
    struct Segment: Equatable {
        let movieStart: Double
        let sourceStart: Double
        let duration: Double
    }

    /// Puts `source` (the recording's movie) together with `renderer`, leaving out `cuts`.
    public static func make(source: AVAsset, renderer: StudioRenderer, cuts: [ClosedRange<Double>]) async throws -> StudioComposition {
        let sourceDuration = try await source.load(.duration).seconds
        let segments = keptSegments(duration: sourceDuration, cuts: cuts)
        let composition = AVMutableComposition()
        let sourceVideo = try await source.loadTracks(withMediaType: .video).first
        let sourceAudio = try await source.loadTracks(withMediaType: .audio)
        guard let sourceVideo, let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.noVideo
        }
        let audio = sourceAudio.compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        for segment in segments {
            let range = CMTimeRange(start: time(segment.sourceStart), duration: time(segment.duration))
            let at = time(segment.movieStart)
            try video.insertTimeRange(range, of: sourceVideo, at: at)
            for (track, sourceTrack) in zip(audio, sourceAudio) {
                try track.insertTimeRange(range, of: sourceTrack, at: at)
            }
        }
        let duration = segments.reduce(0) { $0 + $1.duration }
        let instruction = StudioInstruction(
            timeRange: CMTimeRange(start: .zero, duration: time(duration)), trackID: video.trackID, renderer: renderer, segments: segments
        )
        var configuration = AVVideoComposition.Configuration(
            customVideoCompositorClass: StudioCompositor.self, frameDuration: CMTime(value: 1, timescale: 60),
            instructions: [instruction], renderSize: renderer.layout.canvas
        )
        // The recording's colors, kept: its frames come in as they are, the movie's frames are tagged alike,
        // and the compositor draws in that color space. Untagged, the movie came out lighter than the
        // recording (a gray of 111 played as 121).
        let colors = Colors(of: try await sourceVideo.load(.formatDescriptions).first)
        configuration.colorPrimaries = colors.primaries
        configuration.colorTransferFunction = colors.transferFunction
        configuration.colorYCbCrMatrix = colors.matrix
        return StudioComposition(
            asset: composition.copy() as? AVComposition ?? composition, videoComposition: AVVideoComposition(configuration: configuration),
            renderer: renderer, duration: duration, colors: colors
        )
    }

    /// The color space of the movie's frames, as the AVVideoColorPropertiesKey triple: the recording's own,
    /// or Rec. 709 (ScreenCaptureKit's) where it says nothing.
    public struct Colors: Equatable, Sendable {
        public let primaries: String
        public let transferFunction: String
        public let matrix: String

        init(of format: CMFormatDescription?) {
            let extensions = format.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
            primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? AVVideoColorPrimaries_ITU_R_709_2
            transferFunction = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? AVVideoTransferFunction_ITU_R_709_2
            matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String ?? AVVideoYCbCrMatrix_ITU_R_709_2
        }

        /// For a writer's AVVideoColorPropertiesKey.
        public var properties: [String: String] {
            [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transferFunction, AVVideoYCbCrMatrixKey: matrix]
        }
    }

    /// The recording's parts between the cuts, laid end to end.
    static func keptSegments(duration: Double, cuts: [ClosedRange<Double>]) -> [Segment] {
        var segments: [Segment] = []
        var cursor = 0.0
        var movie = 0.0
        for cut in cuts.map({ max(0, $0.lowerBound)...min(duration, $0.upperBound) }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if cut.lowerBound > cursor {
                segments.append(Segment(movieStart: movie, sourceStart: cursor, duration: cut.lowerBound - cursor))
                movie += cut.lowerBound - cursor
            }
            cursor = max(cursor, cut.upperBound)
        }
        if duration > cursor {
            segments.append(Segment(movieStart: movie, sourceStart: cursor, duration: duration - cursor))
        }
        return segments
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 6_000)
    }
}

public enum StudioError: Error, Equatable {
    case noVideo
    case renderFailed
    case readingFailed(String)
    case writingFailed(String)
}

/// The one instruction of a Studio composition: which track is the recording, the renderer, and how the
/// movie's time maps back to the recording's around the cuts.
nonisolated final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let renderer: StudioRenderer
    let segments: [StudioComposition.Segment]

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, renderer: StudioRenderer, segments: [StudioComposition.Segment]) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.renderer = renderer
        self.segments = segments
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }

    /// The recording's time at the movie's `time`.
    func sourceTime(_ time: Double) -> Double {
        guard let segment = segments.last(where: { $0.movieStart <= time }) ?? segments.first else { return time }
        return segment.sourceStart + min(max(time - segment.movieStart, 0), segment.duration)
    }
}

/// Draws each frame of a Studio composition with its instruction's renderer.
nonisolated final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false,
    ])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The recording's frames as the decoder makes them, 4:2:0 (a byte and a half a pixel), which Core Image
    /// reads as they are: asked for in BGRA, every frame of a full-screen recording was converted into 66 MB
    /// first, and the frames read ahead took the export past a gigabyte.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    /// The movie's frames drawn straight into 4:2:0, as the encoder takes them and the player shows them:
    /// a third the size of BGRA, and nothing for the encoder to convert.
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    private let lock = NSLock()
    /// The color space of the frames drawn, read from the first one's tags.
    private var outputColorSpace: CGColorSpace?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock()
        outputColorSpace = nil
        lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard
            let instruction = request.videoCompositionInstruction as? StudioInstruction,
            let source = request.sourceFrame(byTrackID: instruction.trackID),
            let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: StudioError.renderFailed)
            return
        }
        let time = instruction.sourceTime(request.compositionTime.seconds)
        let image = instruction.renderer.image(source: CIImage(cvPixelBuffer: source), at: time)
        Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.renderer.layout.canvas), colorSpace: colorSpace(of: output))
        request.finish(withComposedVideoFrame: output)
    }

    /// The color space a frame is tagged with (the composition's), the one it is drawn in.
    private func colorSpace(of buffer: CVPixelBuffer) -> CGColorSpace {
        lock.lock()
        defer { lock.unlock() }
        if let outputColorSpace { return outputColorSpace }
        let made = CVBufferCopyAttachments(buffer, .shouldPropagate)
            .flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() } ?? Self.colorSpace
        outputColorSpace = made
        return made
    }
}
