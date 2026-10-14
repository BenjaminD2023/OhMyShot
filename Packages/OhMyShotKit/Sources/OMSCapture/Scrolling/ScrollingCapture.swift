import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OMSCore
import OSLog
import ScreenCaptureKit
import Synchronization

/// Streams an area of the screen while what is under it scrolls, stitching the views as they come: the
/// engine under scrolling capture.
///
/// The stream sends a frame only when something in the area changes, so a page left still costs nothing.
/// Each frame is taken in on the stream's own queue; what it did, and now and then a preview of the picture
/// so far, is told on the main actor.
public final class ScrollingCapture {
    /// What to stream.
    public struct Source {
        public let filter: SCContentFilter
        /// The area in points from the display's top-left corner; nil for a window streamed on its own.
        public let sourceRect: CGRect?
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let pixelsPerPoint: CGFloat
        /// The area in AppKit's global space.
        public let frame: CGRect
        public let displayID: CGDirectDisplayID

        public init(
            filter: SCContentFilter, sourceRect: CGRect?, pixelWidth: Int, pixelHeight: Int, pixelsPerPoint: CGFloat, frame: CGRect,
            displayID: CGDirectDisplayID
        ) {
            self.filter = filter
            self.sourceRect = sourceRect
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.pixelsPerPoint = pixelsPerPoint
            self.frame = frame
            self.displayID = displayID
        }
    }

    /// How the capture is going: told after each view that changed something. Made on the stream's queue.
    nonisolated public struct Progress: Sendable {
        public var step: ScrollStitcher.Step
        public var axis: ScrollStitcher.Axis?
        /// The picture's size in pixels as it stands.
        public var pictureWidth: Int
        public var pictureHeight: Int
        /// Views in a row that lined up with nothing.
        public var lostInARow: Int
        public var isFull: Bool
        /// The newest end of the picture, when one was made with this report.
        public var preview: CGImage?
        /// Views taken in so far.
        public var views: Int
        /// The picture's length along the axis but for what an elastic overscroll pulled into view past the
        /// content's end: how far the capture got.
        public var settledLength: Int
        /// The content is pulled past its end (or start): it came to its end, and the app pushes on.
        public var isPulled: Bool
        /// The part of the view that moved with the content when it last scrolled, in fractions of the view: where
        /// a scroller inside the page is, when only that scrolls.
        public var moving: CGRect?
        /// A scroller inside the page that took the gesture making the app scroll, and alone scrolled in the view just
        /// taken in, which was left out for it: where it is, in fractions of the view.
        public var inner: CGRect?

        public init(
            step: ScrollStitcher.Step, axis: ScrollStitcher.Axis?, pictureWidth: Int, pictureHeight: Int, lostInARow: Int, isFull: Bool,
            preview: CGImage?, views: Int, settledLength: Int? = nil, isPulled: Bool = false, moving: CGRect? = nil, inner: CGRect? = nil
        ) {
            self.step = step
            self.axis = axis
            self.pictureWidth = pictureWidth
            self.pictureHeight = pictureHeight
            self.lostInARow = lostInARow
            self.isFull = isFull
            self.preview = preview
            self.views = views
            self.settledLength = settledLength ?? (axis == .horizontal ? pictureWidth : pictureHeight)
            self.isPulled = isPulled
            self.moving = moving
            self.inner = inner
        }
    }

    public let source: Source
    /// Told on the main actor.
    public var onProgress: ((Progress) -> Void)?
    /// The stream ended on its own (the display went away, Screen Recording was turned off).
    public var onStopped: ((any Error) -> Void)?
    public private(set) var isRunning = false

    private let output: Output
    private let queue = DispatchSerialQueue(label: "OhMyShot.scrolling", qos: .userInitiated)
    private var stream: SCStream?
    private var leases: [ActiveResources.Lease] = []
    private var activity: (any NSObjectProtocol)?

    #if DEBUG
    /// Where the views are written when the capture first loses track, for checks.
    nonisolated(unsafe) public static var debugDumpFolder: URL?
    /// Told every view the stitcher takes in, on the stream's queue, with what it made of it: the pixels (valid only
    /// during the call), their bytes per row, the step, and why it lined up with nothing. For end-to-end checks that
    /// replay the very views offline.
    nonisolated(unsafe) public static var debugViewSink: (@Sendable (UnsafeRawPointer, Int, ScrollStitcher.Step, String) -> Void)?
    /// Told every frame left out before the stitcher: its status or its size, for checks.
    nonisolated(unsafe) public static var debugSkipSink: (@Sendable (String) -> Void)?
    /// Told, on the stream's queue between views, what the capture was told about the scrolling (driven, and where
    /// the gesture lands; the overscroll let go of), for checks that replay a run offline.
    nonisolated(unsafe) public static var debugEventSink: (@Sendable (String) -> Void)?
    #endif

    /// The pictures are made in Display P3: the stream is asked for it, so nothing the display shows is lost.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// - Parameter preview: The preview's size in pixels: across the scroll, and the most along it.
    public init(_ source: Source, preview: (across: Int, along: Int)) {
        self.source = source
        output = Output(
            stitcher: ScrollStitcher(
                width: source.pixelWidth, height: source.pixelHeight, pixelsPerPoint: source.pixelsPerPoint, colorSpace: Self.colorSpace
            ),
            preview: preview, queue: queue
        )
    }

    static func configuration(for source: Source) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = source.pixelWidth
        configuration.height = source.pixelHeight
        if let rect = source.sourceRect { configuration.sourceRect = rect }
        // As often as the screen changes, up to 60 times a second: the more often, the more two views share.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.captureDynamicRange = .SDR
        configuration.queueDepth = 4
        // The pointer stays put while the page moves under it: it would be stitched in again and again.
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.streamName = "OhMyShot Scrolling Capture"
        return configuration
    }

    /// Starts streaming. Throws when the stream cannot start; nothing is left running then.
    public func start() async throws {
        guard !isRunning, stream == nil else { return }
        let stream = SCStream(filter: source.filter, configuration: Self.configuration(for: source), delegate: output)
        output.onProgress = { [weak self] progress in
            Task { @MainActor in self?.onProgress?(progress) }
        }
        output.onStop = { [weak self] error in
            Task { @MainActor in self?.streamStopped(error) }
        }
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        self.stream = stream
        isRunning = true
        leases = [ActiveResources.shared.acquire(.captureStream)]
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Scrolling capture")
        Log.capture.notice("Scrolling capture streaming \(self.source.pixelWidth, privacy: .public)x\(self.source.pixelHeight, privacy: .public)")
    }

    /// Stops streaming and puts the picture together; nil when nothing came.
    public func finish() async -> CGImage? {
        await stop()
        let output = output
        return await withCheckedContinuation { continuation in
            // After every frame the stream had handed over: the queue runs them in order.
            queue.async {
                output.applyPending()
                continuation.resume(returning: output.picture())
            }
        }
    }

    /// Stops streaming and lets everything go.
    public func cancel() async {
        await stop()
        Log.capture.notice("Scrolling capture cancelled")
    }

    /// The direction the app is made to scroll in (Auto-scroll), which the stitching keeps to until the first
    /// scroll says; nil for either.
    public func prefer(_ axis: ScrollStitcher.Axis?) {
        output.post(.prefer(axis))
    }

    /// Whether the app is being made to scroll (Auto-scroll), which tells content pushed past its end apart, and
    /// where the gesture lands, in fractions of the area from its top left: a scroller inside the page there is left
    /// out (nil takes in whatever scrolls).
    public func setDriven(_ driven: Bool, at point: CGPoint? = nil) {
        output.post(.driven(driven, at: point))
    }

    /// Lets go of what an elastic overscroll pulled into view past the content's end: Auto-scroll pushed on and
    /// nothing more came.
    public func trimOverscroll() {
        output.post(.trim)
    }

    /// How the stitching went, for the log.
    public func summary() async -> String {
        let output = output
        return await withCheckedContinuation { continuation in
            queue.async {
                output.applyPending()
                continuation.resume(returning: output.summary)
            }
        }
    }

    private func stop() async {
        guard isRunning else { return }
        isRunning = false
        if let stream { try? await stream.stopCapture() }
        stream = nil
        release()
    }

    private func streamStopped(_ error: any Error) {
        guard isRunning else { return }
        Log.capture.error("The scrolling capture's stream stopped: \(String(describing: error), privacy: .public)")
        isRunning = false
        stream = nil
        release()
        onStopped?(error)
    }

    private func release() {
        leases.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Takes the stream's frames into the stitcher on the stream's queue, and reports how it went. Never
/// isolated to the main actor: the stream calls it on its own queue.
nonisolated private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Set before the stream starts.
    var onProgress: (@Sendable (ScrollingCapture.Progress) -> Void)?
    var onStop: (@Sendable (any Error) -> Void)?
    /// Touched only on the stream's queue, and after it stops.
    private let stitcher: ScrollStitcher
    private let preview: (across: Int, along: Int)
    private let queue: DispatchSerialQueue
    private var views = 0
    private var lostInARow = 0
    /// The picture has been made: no view is taken in after it.
    private var madePicture = false
    private var lastPreview: ContinuousClock.Instant?
    private var waitingPreview = false
    /// How long taking in the views took, for the log.
    private var busy: Duration = .zero
    /// What the capture was told since, in order: applied before the next frame is taken in, or as soon as the queue
    /// is free, whichever comes first. A stream handing over frame after frame, each taking a while, kept the queue
    /// busy for seconds, and the views were taken in as nothing told them meanwhile (not driven, so a pull past the
    /// page's end went unrecognized).
    private let pending = Mutex<[Control]>([])

    enum Control: Sendable {
        case prefer(ScrollStitcher.Axis?)
        case driven(Bool, at: CGPoint?)
        case trim
    }

    /// Previews at most this often: a panel's picture, not a film; less often once the picture is long, as each
    /// draws thousands of its lines small.
    private var previewInterval: Duration {
        let size = stitcher.pictureSize
        return max(size.width, size.height) > 4 * max(stitcher.width, stitcher.height) ? .milliseconds(250) : .milliseconds(100)
    }

    init(stitcher: ScrollStitcher, preview: (across: Int, along: Int), queue: DispatchSerialQueue) {
        self.stitcher = stitcher
        self.preview = preview
        self.queue = queue
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        applyPending()
        #if DEBUG
        if !madePicture, type == .screen, sampleBuffer.isValid, !Self.isComplete(sampleBuffer) {
            let raw = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first?[.status] as? Int
            ScrollingCapture.debugSkipSink?("status \(raw.map(String.init) ?? "none")")
        }
        #endif
        guard !madePicture, type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer), let pixels = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        // What changed is a sliver of the area (a caret blinking, a spinner): nothing scrolled, and the view is left
        // out before it is copied and hashed.
        if Self.changedFraction(sampleBuffer, width: stitcher.width, height: stitcher.height).map({ $0 < 0.02 }) ?? false {
            #if DEBUG
            ScrollingCapture.debugSkipSink?("sliver")
            #endif
            return
        }
        guard let base = CVPixelBufferGetBaseAddress(pixels),
              CVPixelBufferGetWidth(pixels) == stitcher.width, CVPixelBufferGetHeight(pixels) == stitcher.height else {
            #if DEBUG
            ScrollingCapture.debugSkipSink?("size \(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels)), stitcher \(stitcher.width)x\(stitcher.height)")
            #endif
            return
        }
        let started = ContinuousClock.now
        let step = stitcher.add(base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
        #if DEBUG
        ScrollingCapture.debugViewSink?(base, CVPixelBufferGetBytesPerRow(pixels), step, step == .lost ? stitcher.lostBecause : "")
        #endif
        views += 1
        let wasLost = lostInARow > 0
        switch step {
        case .lost:
            if lostInARow == 0 {
                Log.capture.notice("Scrolling capture lost track at view \(self.views, privacy: .public): \(self.stitcher.lostBecause, privacy: .public)")
                #if DEBUG
                if let folder = ScrollingCapture.debugDumpFolder { stitcher.debugDump(to: folder) }
                #endif
            }
            lostInARow += 1
        case .scrolled, .unchanged, .started: lostInARow = 0
        case .full: break
        }
        // A view that changed nothing says nothing, unless it ends a run of lost ones or a scroller inside the page
        // scrolled in it.
        guard step != .unchanged || wasLost || stitcher.innerPart != nil else {
            busy += .now - started
            return
        }
        // The preview follows the picture as it grows, at most ten times a second; a growth that comes too soon
        // is shown a moment later, so the last one is never left out when the scrolling stops.
        var image: CGImage?
        let grew = step == .started || { if case .scrolled = step { true } else { false } }()
        if grew {
            let wait = lastPreview.map { previewInterval - (ContinuousClock.now - $0) } ?? .zero
            if wait <= .zero {
                image = makePreview()
            } else if !waitingPreview {
                waitingPreview = true
                queue.asyncAfter(deadline: .now() + wait / .seconds(1)) { [self] in
                    guard waitingPreview else { return }
                    report(.unchanged, preview: makePreview())
                }
            }
        }
        busy += .now - started
        report(step, preview: image)
    }

    private func makePreview() -> CGImage? {
        lastPreview = .now
        waitingPreview = false
        return stitcher.preview(across: preview.across, along: preview.along)
    }

    private func report(_ step: ScrollStitcher.Step, preview: CGImage?) {
        let size = stitcher.pictureSize
        onProgress?(ScrollingCapture.Progress(
            step: step, axis: stitcher.axis, pictureWidth: size.width, pictureHeight: size.height, lostInARow: lostInARow,
            isFull: stitcher.isFull, preview: preview, views: views, settledLength: stitcher.settledLength, isPulled: stitcher.isPulled,
            moving: stitcher.movingPart, inner: stitcher.innerPart
        ))
    }

    /// Tells the capture something, from anywhere.
    func post(_ control: Control) {
        pending.withLock { $0.append(control) }
        queue.async { [self] in applyPending() }
    }

    /// Applies what the capture was told, in order: on the stream's queue only.
    func applyPending() {
        let controls = pending.withLock { controls in
            defer { controls.removeAll() }
            return controls
        }
        for control in controls {
            switch control {
            case .prefer(let axis): prefer(axis)
            case .driven(let driven, let point): setDriven(driven, at: point)
            case .trim: trimOverscroll()
            }
        }
    }

    private func prefer(_ axis: ScrollStitcher.Axis?) {
        stitcher.preferredAxis = axis
    }

    private func setDriven(_ driven: Bool, at point: CGPoint?) {
        stitcher.isDriven = driven
        stitcher.drivenAt = driven ? point : nil
        #if DEBUG
        ScrollingCapture.debugEventSink?("driven \(driven) " + (stitcher.drivenAt.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "-"))
        #endif
    }

    private func trimOverscroll() {
        #if DEBUG
        ScrollingCapture.debugEventSink?("trim pulled \(stitcher.isPulled)")
        #endif
        guard !madePicture, stitcher.isPulled else { return }
        stitcher.trimOverscroll()
        report(.unchanged, preview: views > 0 ? makePreview() : nil)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop?(error)
    }

    /// The picture, once the stream has stopped: the stitcher's lines move into it, so no view is taken in after it.
    func picture() -> CGImage? {
        madePicture = true
        return views > 0 ? stitcher.takePicture() : nil
    }

    var summary: String {
        let average = views > 0 ? busy / views : .zero
        return "\(views) views, \(average.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))) each; \(stitcher.summary)"
    }

    /// How much of the frame changed since the last, by the stream's dirty rectangles: the most it could be, their
    /// area over the frame's (whether they come in points or pixels). Nil when the stream does not say.
    private static func changedFraction(_ sample: CMSampleBuffer, width: Int, height: Int) -> Double? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rects = attachments.first?[.dirtyRects] as? [Any] else { return nil }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        var area = 0.0
        for case let value as NSDictionary in rects {
            guard let rect = CGRect(dictionaryRepresentation: value) else { return nil }
            let shown = rect.intersection(frame)
            if !shown.isNull { area += shown.width * shown.height }
        }
        return area * 4 / (frame.width * frame.height)
    }

    private static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
