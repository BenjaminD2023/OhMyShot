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
        try await make(source: source, renderer: renderer, cuts: cuts, camera: camera, reusesFrames: true)
    }

    /// The same; `reusesFrames` false draws every frame, even where the one before could be handed back.
    @concurrent static func make(
        source: AVAsset, renderer: StudioRenderer, cuts: [ClosedRange<Double>], camera: CameraSource? = nil, reusesFrames: Bool
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
            renderer: renderer, segments: segments, reusesFrames: reusesFrames
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

    /// The frames this composition's compositors finished so far: drawn, handed back again unchanged, and
    /// the most asked for and not yet finished at once.
    var frameCounts: StudioInstruction.FrameCounts.Counts {
        (videoComposition.instructions.first as? StudioInstruction)?.frameCounts.counts ?? .init()
    }

    #if DEBUG
    /// Frames every Studio compositor was asked for and finished with a picture (drawn, or handed back again)
    /// so far, for scripted checks.
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
    /// A frame drawn as the one before it may be that one handed back again.
    let reusesFrames: Bool
    let frameCounts = FrameCounts()

    init(
        timeRange: CMTimeRange, trackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID? = nil, renderer: StudioRenderer,
        segments: [StudioComposition.Segment], reusesFrames: Bool = true
    ) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.cameraTrackID = cameraTrackID
        self.renderer = renderer
        self.segments = segments
        self.reusesFrames = reusesFrames
        requiredSourceTrackIDs = ([trackID] + [cameraTrackID].compactMap(\.self)).map { NSNumber(value: $0) }
    }

    /// What the compositors did with this instruction's frames, for tests and benchmarks.
    final class FrameCounts: @unchecked Sendable {
        struct Counts: Equatable {
            var drawn = 0
            var reused = 0
            var mostInFlight = 0
        }

        private let lock = NSLock()
        private var values = Counts()

        var counts: Counts { lock.withLock { values } }

        func finished(reused: Bool) {
            lock.withLock {
                if reused { values.reused += 1 } else { values.drawn += 1 }
            }
        }

        func inFlight(_ count: Int) {
            lock.withLock { values.mostInFlight = max(values.mostInFlight, count) }
        }
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

/// Draws each frame of a Studio composition with its instruction's renderer, a few at once: a frame's picture
/// is put together on one queue and drawn on the GPU while the next is put together, and the frames are
/// finished in the order they were asked for on another. Drawn one at a time, the CPU waited for the GPU
/// and the GPU for the CPU.
///
/// Where nothing drawn changes from one frame to the next (`StudioRenderer.isStill`), with the recording's
/// frame the same one and no camera, the frame drawn last is handed back again: a recording holds one frame
/// for as long as the screen holds still, and the movie asks for sixty a second.
nonisolated final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false,
    ])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The most frames asked for and not yet finished: one put together, one drawing, one waiting to be
    /// finished. More only holds more of the decoder's frames and the movie's.
    static let framesInFlight = 3

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

    /// A frame drawn, kept to be handed back while nothing changes: what it was drawn for, from, and into.
    /// Holding the recording's frame keeps the decoder from filling the same buffer with another. Its buffers
    /// are only read once it is drawn.
    private struct Drawn: @unchecked Sendable {
        let instruction: StudioInstruction
        let renderContext: AVVideoCompositionRenderContext
        let source: CVPixelBuffer
        /// The recording's time it shows.
        let time: Double
        let output: CVPixelBuffer
        let generation: Int
    }

    private let lock = NSLock()
    /// The color space of the frames drawn, read from the first one's tags in each render context.
    private var outputColorSpace: (renderContext: AVVideoCompositionRenderContext, space: CGColorSpace)?
    /// A frame that couldn't be drawn has been reported: once per compositor is enough.
    private var reportedFailure = false
    /// The frames asked for and not yet finished, by the order they came in. Whoever takes one out
    /// finishes it, once: its drawing, or cancelling.
    private var pending: [Int: AVAsynchronousVideoCompositionRequest] = [:]
    private var lastNumber = 0
    /// Moves on with each render context, so a frame drawn for the one before is never kept.
    private var generation = 0
    /// The last frame drawn: only one.
    private var last: Drawn?
    private let slots = DispatchSemaphore(value: framesInFlight)
    private let building = DispatchQueue(label: "OhMyShot.studio.compositor.build", qos: .userInitiated)
    private let finishing = DispatchQueue(label: "OhMyShot.studio.compositor.finish", qos: .userInitiated)
    private static let onFinishing = DispatchSpecificKey<Bool>()

    override init() {
        super.init()
        finishing.setSpecific(key: Self.onFinishing, value: true)
    }

    #if DEBUG
    /// Frames asked for, and finished with a picture, by every compositor so far, for scripted checks.
    nonisolated(unsafe) private static var counts = (asked: 0, drawn: 0)
    private static let countsLock = NSLock()
    static var debugCounts: (asked: Int, drawn: Int) {
        countsLock.withLock { counts }
    }
    #endif

    /// Frames asked for and not yet finished, for tests: none once every one has been.
    var pendingCount: Int { lock.withLock { pending.count } }
    /// How many times this compositor was told to cancel its frames, for tests.
    var cancelCount: Int { lock.withLock { cancels } }
    private var cancels = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.withLock {
            outputColorSpace = nil
            last = nil
            generation += 1
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        #if DEBUG
        Self.countsLock.withLock { Self.counts.asked += 1 }
        #endif
        // The decoder waits here while enough frames are on their way, as it waited for each one before.
        slots.wait()
        let (number, inFlight, generation) = lock.withLock {
            lastNumber += 1
            pending[lastNumber] = request
            return (lastNumber, pending.count, generation)
        }
        (request.videoCompositionInstruction as? StudioInstruction)?.frameCounts.inFlight(inFlight)
        building.async { [self] in build(request, number: number, generation: generation) }
    }

    /// Cancels the frames not yet finished, and returns once each has been: none is finished after.
    func cancelAllPendingVideoCompositionRequests() {
        let cancel = { [self] in
            let requests = lock.withLock {
                defer {
                    pending.removeAll()
                    last = nil
                    cancels += 1
                }
                return pending.sorted { $0.key < $1.key }.map(\.value)
            }
            for request in requests {
                slots.signal()
                request.finishCancelledRequest()
            }
        }
        // Every frame is finished on `finishing`, so one being finished now is done when this runs.
        if DispatchQueue.getSpecific(key: Self.onFinishing) == true { cancel() } else { finishing.sync(execute: cancel) }
    }

    /// Puts frame `number` together and starts drawing it, or hands back the last one drawn where it would
    /// come out the same; `finishing` finishes it. `generation` is the render context's when it was asked for.
    private func build(_ request: AVAsynchronousVideoCompositionRequest, number: Int, generation: Int) {
        guard lock.withLock({ pending[number] != nil }) else { return }
        guard
            let instruction = request.videoCompositionInstruction as? StudioInstruction,
            let source = request.sourceFrame(byTrackID: instruction.trackID)
        else { return fail(request, number: number) }
        let time = instruction.sourceTime(request.compositionTime.seconds)
        if let kept = reusable(for: request, instruction: instruction, source: source, at: time) {
            finishing.async { [self] in finish(number, with: kept, reused: true) }
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else { return fail(request, number: number) }
        // The camera's frame, where its movie has one.
        let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
        let image = instruction.renderer.image(source: CIImage(cvPixelBuffer: source), camera: camera, at: time)
        let drawing: Drawing
        do {
            let task = try Self.startDrawing(
                image, into: output, canvas: instruction.renderer.layout.canvas, colorSpace: colorSpace(of: output, in: request.renderContext)
            )
            let drawn = Drawn(
                instruction: instruction, renderContext: request.renderContext, source: source, time: time, output: output, generation: generation
            )
            drawing = Drawing(task: task, drawn: drawn)
        } catch {
            return fail(request, number: number)
        }
        finishing.async { [self] in
            do {
                _ = try drawing.task.waitUntilCompleted()
            } catch {
                return fail(request, number: number)
            }
            finish(number, with: drawing.drawn, reused: false)
        }
    }

    /// Starts drawing `image`'s `canvas` into `output`, in `colorSpace`, as `CIContext.render(_:to:bounds:colorSpace:)`
    /// draws it, without waiting for the GPU.
    static func startDrawing(_ image: CIImage, into output: CVPixelBuffer, canvas: CGSize, colorSpace: CGColorSpace) throws -> CIRenderTask {
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = colorSpace
        return try context.startTask(toRender: image, from: CGRect(origin: .zero, size: canvas), to: destination, at: .zero)
    }

    /// A frame being drawn on the GPU, and what it will be once it is.
    private struct Drawing: @unchecked Sendable {
        let task: CIRenderTask
        let drawn: Drawn
    }

    /// The last frame drawn, when this one, `time` in the recording from `source`, would come out the same:
    /// the same composition and render context, the same recording's frame, no camera, and nothing else
    /// drawn changed between the two times.
    private func reusable(
        for request: AVAsynchronousVideoCompositionRequest, instruction: StudioInstruction, source: CVPixelBuffer, at time: Double
    ) -> Drawn? {
        guard instruction.reusesFrames, instruction.cameraTrackID == nil, let drawn = lock.withLock({ last }),
              drawn.instruction === instruction, drawn.renderContext === request.renderContext, drawn.source === source,
              instruction.renderer.isStill(from: drawn.time, to: time) else { return nil }
        return drawn
    }

    /// Finishes frame `number` with `drawn`'s picture, unless it was cancelled meanwhile. A frame just drawn,
    /// for the render context still current, is kept for the frames after it. On `finishing`.
    private func finish(_ number: Int, with drawn: Drawn, reused: Bool) {
        let request: AVAsynchronousVideoCompositionRequest? = lock.withLock {
            guard let request = pending.removeValue(forKey: number) else { return nil }
            if !reused, drawn.generation == generation { last = drawn }
            return request
        }
        guard let request else { return }
        // The slot first: finishing may ask for the next frame at once.
        slots.signal()
        request.finish(withComposedVideoFrame: drawn.output)
        drawn.instruction.frameCounts.finished(reused: reused)
        #if DEBUG
        Self.countsLock.withLock { Self.counts.drawn += 1 }
        #endif
    }

    /// Says why frame `number` couldn't be drawn, and finishes it with that, on `finishing`.
    private func fail(_ request: AVAsynchronousVideoCompositionRequest, number: Int) {
        report(request)
        let finish: @Sendable () -> Void = { [self] in
            guard let request = lock.withLock({ pending.removeValue(forKey: number) }) else { return }
            slots.signal()
            request.finish(with: StudioError.renderFailed)
        }
        if DispatchQueue.getSpecific(key: Self.onFinishing) == true { finish() } else { finishing.async(execute: finish) }
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
    private func colorSpace(of buffer: CVPixelBuffer, in renderContext: AVVideoCompositionRenderContext) -> CGColorSpace {
        lock.lock()
        defer { lock.unlock() }
        if let outputColorSpace, outputColorSpace.renderContext === renderContext { return outputColorSpace.space }
        let made = CVBufferCopyAttachments(buffer, .shouldPropagate)
            .flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() } ?? Self.colorSpace
        outputColorSpace = (renderContext, made)
        return made
    }
}
