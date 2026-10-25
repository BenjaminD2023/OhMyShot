import AVFoundation
import CoreImage
import Foundation
import OMSCore
import OSLog

/// A Studio recording put together for playing and for export: the recording with its cuts left out (and
/// the camera's movie beside it, cut alike), and a video composition whose compositor films each frame
/// through a `StudioRenderer`. An AVPlayerItem plays it in real time; `StudioExporter` writes it out. Both
/// draw the same frames.
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

    /// The camera's movie, recorded beside the recording.
    public struct CameraSource: @unchecked Sendable {
        public let asset: AVAsset
        /// Where it begins on the recording's timeline, in seconds; negative when it began first.
        public let start: Double

        public init(asset: AVAsset, start: Double) {
            self.asset = asset
            self.start = start
        }
    }

    /// Puts `source` (the recording's movie) together with `renderer`, leaving out `cuts`; the camera's movie
    /// goes in beside it when there is one, kept in step and cut alike.
    @concurrent public static func make(
        source: AVAsset, renderer: StudioRenderer, cuts: [ClosedRange<Double>], camera: CameraSource? = nil
    ) async throws -> StudioComposition {
        try Task.checkCancellation()
        let sourceDuration = try await source.load(.duration).seconds
        let segments = keptSegments(duration: sourceDuration, cuts: cuts)
        let composition = AVMutableComposition()
        let sourceVideo = try await source.loadTracks(withMediaType: .video).first
        let sourceAudio = try await source.loadTracks(withMediaType: .audio)
        guard let sourceVideo, let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.noVideo
        }
        let audio = sourceAudio.compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        // Each part goes in where the one before ended, as long as its ends in the movie's time make it: times
        // are rounded at the ends, never per length, so no gap or overlap of a 6000th of a second opens.
        var cursor = CMTime.zero
        for segment in segments {
            try Task.checkCancellation()
            let until = time(segment.movieStart + segment.duration)
            guard until > cursor else { continue }
            let range = CMTimeRange(start: time(segment.sourceStart), duration: until - cursor)
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            for (track, sourceTrack) in zip(audio, sourceAudio) {
                try track.insertTimeRange(range, of: sourceTrack, at: cursor)
            }
            cursor = until
        }
        let duration = segments.reduce(0) { $0 + $1.duration }
        let movieEnd = video.timeRange.end
        var cameraTrackID: CMPersistentTrackID?
        if let camera, let cameraVideo = try await camera.asset.loadTracks(withMediaType: .video).first,
           let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let cameraDuration = try await camera.asset.load(.duration).seconds
            let cameraEnd = try await cameraVideo.load(.timeRange).end
            let frame = time(max(try await cameraVideo.load(.minFrameDuration).seconds, 1.0 / 60))
            let ranges = cameraRanges(segments: segments, cameraStart: camera.start, cameraDuration: cameraDuration)
            // Where the camera has nothing (before it began, after it ended), its nearest frame is held, so its
            // bubble is there from the first frame to the last.
            var cursor = CMTime.zero
            func hold(_ cameraTime: CMTime, until end: CMTime) throws {
                guard end > cursor else { return }
                let held = min(max(cameraTime, .zero), cameraEnd - frame)
                try track.insertTimeRange(CMTimeRange(start: held, duration: frame), of: cameraVideo, at: cursor)
                track.scaleTimeRange(CMTimeRange(start: cursor, duration: frame), toDuration: end - cursor)
                cursor = end
            }
            for range in ranges {
                try Task.checkCancellation()
                let at = time(range.movieStart), from = time(range.cameraStart)
                try hold(from, until: at)
                // Never past the camera's own end, nor the movie's.
                let until = min(time(range.movieStart + range.duration), movieEnd)
                let start = from + (cursor - at)
                let length = min(until - cursor, cameraEnd - start)
                guard length > .zero else { continue }
                try track.insertTimeRange(CMTimeRange(start: start, duration: length), of: cameraVideo, at: cursor)
                cursor = cursor + length
            }
            if let last = ranges.last {
                try hold(time(last.cameraStart + last.duration) - frame, until: movieEnd)
            }
            if !track.segments.isEmpty { cameraTrackID = track.trackID }
        }
        // One instruction over the whole movie, to the tracks' own end.
        let instruction = StudioInstruction(
            timeRange: CMTimeRange(start: .zero, end: composition.duration), trackID: video.trackID, cameraTrackID: cameraTrackID,
            renderer: renderer, segments: segments
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
        try Task.checkCancellation()
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

    /// The camera's parts beside each kept part of the recording: where each starts in the camera's movie
    /// and in the movie made, and how long it is. Only what the camera's movie holds: nothing before it
    /// began or after it ended.
    static func cameraRanges(segments: [Segment], cameraStart: Double, cameraDuration: Double) -> [(cameraStart: Double, movieStart: Double, duration: Double)] {
        segments.compactMap { segment in
            // The camera's time at the segment's start is the recording's less where the camera began.
            let from = max(segment.sourceStart - cameraStart, 0)
            let to = min(segment.sourceStart + segment.duration - cameraStart, cameraDuration)
            guard to - from > 0.001 else { return nil }
            return (from, segment.movieStart + from - (segment.sourceStart - cameraStart), to - from)
        }
    }

    /// `seconds` in 6000ths of a second, to the nearest (CMTime(seconds:) rounds down: 1.78 s came out as
    /// 10679 of them).
    static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 6_000).rounded()), timescale: 6_000)
    }

    #if DEBUG
    /// Frames every Studio compositor was asked for and drew so far, for scripted checks.
    public static var debugCompositorCounts: (asked: Int, drawn: Int) {
        StudioCompositor.debugCounts
    }
    #endif
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
    /// The camera's track, when there is one.
    let cameraTrackID: CMPersistentTrackID?
    let renderer: StudioRenderer
    let segments: [StudioComposition.Segment]

    init(
        timeRange: CMTimeRange, trackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID? = nil, renderer: StudioRenderer,
        segments: [StudioComposition.Segment]
    ) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.cameraTrackID = cameraTrackID
        self.renderer = renderer
        self.segments = segments
        requiredSourceTrackIDs = ([trackID] + [cameraTrackID].compactMap(\.self)).map { NSNumber(value: $0) }
    }

    /// The recording's time at the movie's `time`.
    func sourceTime(_ time: Double) -> Double {
        guard !segments.isEmpty else { return time }
        var low = 0, high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].movieStart <= time { low = middle + 1 } else { high = middle }
        }
        let segment = segments[max(0, low - 1)]
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
    /// A frame that couldn't be drawn has been reported: once per compositor is enough.
    private var reportedFailure = false

    #if DEBUG
    /// Frames drawn and asked for by every compositor so far, for scripted checks.
    nonisolated(unsafe) private static var counts = (asked: 0, drawn: 0)
    private static let countsLock = NSLock()
    static var debugCounts: (asked: Int, drawn: Int) {
        countsLock.withLock { counts }
    }
    #endif

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock()
        outputColorSpace = nil
        lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        #if DEBUG
        Self.countsLock.withLock { Self.counts.asked += 1 }
        #endif
        guard
            let instruction = request.videoCompositionInstruction as? StudioInstruction,
            let source = request.sourceFrame(byTrackID: instruction.trackID),
            let output = request.renderContext.newPixelBuffer()
        else {
            report(request)
            request.finish(with: StudioError.renderFailed)
            return
        }
        let time = instruction.sourceTime(request.compositionTime.seconds)
        // The camera's frame, where its movie has one.
        let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
        let image = instruction.renderer.image(source: CIImage(cvPixelBuffer: source), camera: camera, at: time)
        Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.renderer.layout.canvas), colorSpace: colorSpace(of: output))
        request.finish(withComposedVideoFrame: output)
        #if DEBUG
        Self.countsLock.withLock { Self.counts.drawn += 1 }
        #endif
    }

    /// Says once why a frame couldn't be drawn.
    private func report(_ request: AVAsynchronousVideoCompositionRequest) {
        let first = lock.withLock {
            defer { reportedFailure = true }
            return !reportedFailure
        }
        guard first else { return }
        let instruction = request.videoCompositionInstruction as? StudioInstruction
        let recording = instruction.map { request.sourceFrame(byTrackID: $0.trackID) != nil } ?? false
        Log.studio.error("A Studio frame couldn't be drawn at \(request.compositionTime.seconds, format: .fixed(precision: 3), privacy: .public) s: instruction \(instruction != nil, privacy: .public), recording's frame \(recording, privacy: .public), tracks \(request.sourceTrackIDs.map(\.int32Value), privacy: .public)")
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
