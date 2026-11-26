import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import OSLog
import ScreenCaptureKit

/// Records the screen into a movie: a ScreenCaptureKit stream feeding a `RecordingWriter`.
///
/// What is recorded comes ready-made as a content filter (the app's composition root knows the displays,
/// the windows to leave out, and the ones to keep in); this only runs the stream. Frames arrive only when
/// something on screen changed, in 4:2:0 (what the encoder takes without converting), on one serial queue
/// that the writer runs on as well.
@MainActor
public final class ScreenRecorder {
    /// What to record and how.
    public struct Request {
        public var filter: SCContentFilter
        /// The part of the filter's content to record, in points from its top-left corner; nil for all of it.
        public var sourceRect: CGRect?
        public var format: RecordingFormat
        public var audio: RecordingAudio
        public var showsCursor: Bool
        public var showsClicks: Bool
        /// Where the movie is written while recording: a `.mov`, readable up to its last fragment if the app
        /// stops before finishing it.
        public var movieURL: URL

        public init(
            filter: SCContentFilter, sourceRect: CGRect?, format: RecordingFormat, audio: RecordingAudio,
            showsCursor: Bool, showsClicks: Bool, movieURL: URL
        ) {
            self.filter = filter
            self.sourceRect = sourceRect
            self.format = format
            self.audio = audio
            self.showsCursor = showsCursor
            self.showsClicks = showsClicks
            self.movieURL = movieURL
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case recording
        case paused
        case finishing
        case finished
    }

    private enum Target {
        case request(Request)
        case headless(format: RecordingFormat, audio: RecordingAudio)

        var format: RecordingFormat {
            switch self {
            case .request(let request): request.format
            case .headless(let format, _): format
            }
        }

        var audio: RecordingAudio {
            switch self {
            case .request(let request): request.audio
            case .headless(_, let audio): audio
            }
        }
    }

    public private(set) var state: State = .idle
    public var request: Request {
        guard case .request(let request) = target else {
            preconditionFailure("ScreenRecorder was created without a ScreenCaptureKit Request")
        }
        return request
    }
    /// The stream stopped on its own (a display went away, Screen Recording was turned off, or the system's
    /// own control stopped it): the recording so far should be finished and kept.
    public var onStreamStopped: ((any Error) -> Void)?
    /// The movie writer failed while recording (disk full, encoder error, etc.): the session should stop
    /// immediately and salvage what was written up to the last committed fragment.
    public var onWriterFailed: ((RecordingWriter.Failure) -> Void)?
    /// Fired once when the first video frame lands in the movie, with its host-clock timestamp.
    public var onFirstFrame: ((CMTime) -> Void)?

    private let target: Target
    let writer: RecordingWriter
    private let queue = DispatchSerialQueue(label: "OhMyShot.recording", qos: .userInitiated)
    private let output: StreamOutput
    private var stream: SCStream?
    private var leases: [ActiveResources.Lease] = []
    private var activity: (any NSObjectProtocol)?
    /// What a recording keeps from happening until it ends: App Nap, idle sleep, and the display going dark when
    /// nothing is touched, which would leave a long walkthrough or a build recorded against a black screen.
    static let activityOptions: ProcessInfo.ActivityOptions = [.userInitiated, .idleDisplaySleepDisabled]
    private var startedAt: ContinuousClock.Instant?
    private var pausedFor: Duration = .zero
    private var pausedSince: ContinuousClock.Instant?
    private var pendingWriterFailure: RecordingWriter.Failure?

    public init(_ request: Request) throws {
        self.target = .request(request)
        writer = try RecordingWriter(url: request.movieURL, format: request.format, audio: request.audio, queue: queue)
        output = StreamOutput(writer: writer)
    }

    init(movieURL: URL, format: RecordingFormat, audio: RecordingAudio) throws {
        self.target = .headless(format: format, audio: audio)
        writer = try RecordingWriter(url: movieURL, format: format, audio: audio, queue: queue)
        output = StreamOutput(writer: writer)
    }

    var hasPendingWriterFailure: Bool {
        pendingWriterFailure != nil
    }

    /// Returns and clears any writer failure that arrived while `start()` was awaiting capture startup.
    public func takePendingWriterFailure() -> RecordingWriter.Failure? {
        defer { pendingWriterFailure = nil }
        return pendingWriterFailure
    }

    /// The stream's settings for a request.
    static func configuration(for request: Request) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = request.format.width
        configuration.height = request.format.height
        if let rect = request.sourceRect { configuration.sourceRect = rect }
        configuration.minimumFrameInterval = request.format.frameInterval
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureDynamicRange = .SDR
        // Room for a few frames while the encoder catches up; more only holds more of the screen in memory.
        configuration.queueDepth = 5
        configuration.showsCursor = request.showsCursor
        configuration.showMouseClicks = request.showsClicks
        // A window that is resized keeps its place in the frame, scaled to fit.
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = request.audio.system
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = RecordingAudio.sampleRate
        configuration.channelCount = 2
        configuration.captureMicrophone = request.audio.microphone != nil
        configuration.microphoneCaptureDeviceID = request.audio.microphone?.deviceID
        configuration.streamName = "OhMyShot Recording"
        return configuration
    }

    /// Starts recording. Throws when the stream cannot start; nothing is left behind then.
    public func start() async throws {
        let request = self.request
        try await start {
            let stream = SCStream(filter: request.filter, configuration: Self.configuration(for: request), delegate: self.output)
            try stream.addStreamOutput(self.output, type: .screen, sampleHandlerQueue: self.queue)
            if request.audio.system { try stream.addStreamOutput(self.output, type: .audio, sampleHandlerQueue: self.queue) }
            if request.audio.microphone != nil { try stream.addStreamOutput(self.output, type: .microphone, sampleHandlerQueue: self.queue) }
            try await stream.startCapture()
            self.stream = stream
        }
    }

    func start(beginCapture: () async throws -> Void) async throws {
        guard state == .idle else { return }
        output.onStop = { [weak self] error in
            Task { @MainActor in self?.streamStopped(error) }
        }
        await writer.setCallbacks(
            onFirstFrame: { [weak self] time in
                Task { @MainActor in self?.onFirstFrame?(time) }
            },
            onFailure: { [weak self] failure in
                Task { @MainActor in self?.writerFailed(failure) }
            }
        )
        do {
            try await beginCapture()
        } catch {
            pendingWriterFailure = nil
            await writer.cancel()
            throw error
        }
        state = .recording
        startedAt = .now
        output.watchAudio(microphone: target.audio.microphone != nil, systemAudio: target.audio.system, from: Self.hostTime().seconds)
        leases = [ActiveResources.shared.acquire(.captureStream), ActiveResources.shared.acquire(.activity)]
        activity = ProcessInfo.processInfo.beginActivity(options: Self.activityOptions, reason: "Recording the screen")
        Log.recording.notice("Recording \(self.target.format.width, privacy: .public)x\(self.target.format.height, privacy: .public) \(self.target.format.codec.rawValue, privacy: .public) at \(self.target.format.framesPerSecond, privacy: .public) fps")
    }

    /// How long the recording has run, pauses left out.
    public var elapsed: Duration {
        guard let startedAt else { return .zero }
        let now = ContinuousClock.now
        return (now - startedAt) - pausedFor - (pausedSince.map { now - $0 } ?? .zero)
    }

    public func pause() {
        guard state == .recording else { return }
        state = .paused
        pausedSince = .now
        let time = Self.hostTime()
        output.pauseWatchingAudio()
        Task { await writer.pause(at: time) }
    }

    public func resume() {
        guard state == .paused else { return }
        state = .recording
        if let since = pausedSince { pausedFor += .now - since }
        pausedSince = nil
        let time = Self.hostTime()
        output.resumeWatchingAudio(at: time.seconds)
        Task { await writer.resume(at: time) }
    }

    /// Changes what the stream takes in while it records, as when a window it must show (Draw on Screen's canvas)
    /// opens after it began: the frames that follow show what `filter` says.
    public func updateFilter(_ filter: SCContentFilter) async throws {
        try await stream?.updateContentFilter(filter)
    }

    /// Stops and closes the movie. Throws `RecordingWriter.WriterError.noFrames` when nothing was recorded.
    @discardableResult
    public func stop() async throws -> RecordingWriter.Statistics {
        guard state == .recording || state == .paused else { return await writer.currentStatistics }
        state = .finishing
        if let stream { try? await stream.stopCapture() }
        stream = nil
        // Taken once the stream has stopped, so no frame comes after the end.
        let end = Self.hostTime()
        defer {
            state = .finished
            release()
        }
        let statistics = try await writer.finish(at: end)
        Log.recording.notice("Recording finished: \(statistics.duration.seconds, format: .fixed(precision: 2), privacy: .public) s, \(statistics.framesWritten, privacy: .public) frames written, \(statistics.framesDropped, privacy: .public) dropped, \(statistics.audioBuffersWritten + statistics.microphoneBuffersWritten, privacy: .public) audio buffers")
        return statistics
    }

    /// The writer's statistics as recorded so far, including the first frame's host time and pauses.
    public func currentStatistics() async -> RecordingWriter.Statistics {
        await writer.currentStatistics
    }

    /// Checks for an asynchronous writer failure when no new samples are arriving (such as a still screen).
    public func checkWriterHealth() async {
        guard state == .recording || state == .paused else { return }
        await writer.checkHealth()
    }

    /// Stops and throws the movie away.
    public func cancel() async {
        guard state == .recording || state == .paused else { return }
        state = .finished
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await writer.cancel()
        release()
        Log.recording.notice("Recording cancelled")
    }

    /// Frames counted by the stream so far, for scripted checks.
    public var frameCounts: (complete: Int, idle: Int) {
        output.counts
    }

    // MARK: Private

    private func streamStopped(_ error: any Error) {
        guard state == .recording || state == .paused else { return }
        Log.recording.error("The recording stream stopped: \(String(describing: error), privacy: .public)")
        stream = nil
        onStreamStopped?(error)
    }

    private func writerFailed(_ failure: RecordingWriter.Failure) {
        guard state == .recording || state == .paused else {
            if state == .idle {
                Log.recording.error("The recording writer failed while starting after \(failure.writtenDuration.seconds, format: .fixed(precision: 2), privacy: .public) s: \(failure.message, privacy: .public)")
                pendingWriterFailure = failure
            }
            return
        }
        Log.recording.error("The recording writer failed after \(failure.writtenDuration.seconds, format: .fixed(precision: 2), privacy: .public) s: \(failure.message, privacy: .public)")
        onWriterFailed?(failure)
    }

    private func release() {
        pendingWriterFailure = nil
        leases.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// How loud the microphone has been since this was last read, from 0 to 1 on a meter's scale; nil when
    /// the microphone isn't recorded.
    public func takeMicrophoneLevel() -> Double? {
        guard target.audio.microphone != nil else { return nil }
        guard !isMicrophoneMuted else {
            _ = output.takeMicrophoneLevel()
            return 0
        }
        return AudioLevel.meterValue(rms: output.takeMicrophoneLevel())
    }

    /// Whether the microphone is muted live without stopping the recording stream.
    public var isMicrophoneMuted: Bool {
        get { writer.isMicrophoneMuted }
        set {
            writer.isMicrophoneMuted = newValue
            output.setMicrophoneMuted(newValue)
        }
    }

    /// Whether the microphone has stopped sending sound, as when a headset is switched off: nothing has come
    /// from it for `AudioWatch.stallAfter` seconds of recording. A quiet room still sends buffers, of silence.
    /// False when the microphone isn't recorded, while paused, and for that long after starting or resuming.
    public var isMicrophoneStalled: Bool {
        output.isStalled(.microphone, at: Self.hostTime().seconds)
    }

    /// Whether what the Mac plays has stopped arriving, by the same rule as the microphone.
    public var isSystemAudioStalled: Bool {
        output.isStalled(.systemAudio, at: Self.hostTime().seconds)
    }

    /// The host clock's time now, which stream samples are stamped with.
    nonisolated static func hostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}

/// Receives the stream's samples on its queue and hands them to the writer, which runs on that queue.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: RecordingWriter
    /// Set before the stream starts; called on the stream's own thread.
    var onStop: (@Sendable (any Error) -> Void)?
    private let lock = NSLock()
    private var complete = 0
    private var idle = 0
    /// The loudest microphone buffer since the meter last read it.
    private var microphoneLevel: Float = 0
    /// Whether the microphone is currently muted live.
    private var microphoneMuted = false
    /// Whether each audio track still sends buffers; nil for one that isn't recorded.
    private var microphoneWatch: AudioWatch?
    private var systemAudioWatch: AudioWatch?

    init(writer: RecordingWriter) {
        self.writer = writer
    }

    func setMicrophoneMuted(_ muted: Bool) {
        lock.withLock {
            microphoneMuted = muted
            if muted { microphoneLevel = 0 }
        }
    }

    var counts: (complete: Int, idle: Int) {
        lock.withLock { (complete, idle) }
    }

    /// The loudest microphone buffer since the last call, as an RMS fraction of full scale.
    func takeMicrophoneLevel() -> Float {
        lock.withLock {
            let level = microphoneLevel
            microphoneLevel = 0
            return level
        }
    }

    /// Begins watching the audio tracks that are recorded, from `time` (host clock seconds).
    func watchAudio(microphone: Bool, systemAudio: Bool, from time: Double) {
        lock.withLock {
            microphoneWatch = microphone ? AudioWatch(startedAt: time) : nil
            systemAudioWatch = systemAudio ? AudioWatch(startedAt: time) : nil
        }
    }

    func pauseWatchingAudio() {
        lock.withLock {
            microphoneWatch?.pause()
            systemAudioWatch?.pause()
        }
    }

    func resumeWatchingAudio(at time: Double) {
        lock.withLock {
            microphoneWatch?.resume(at: time)
            systemAudioWatch?.resume(at: time)
        }
    }

    /// Whether `track` has stopped sending buffers by `time` (host clock seconds); false for one that isn't recorded.
    func isStalled(_ track: RecordingWriter.Track, at time: Double) -> Bool {
        lock.withLock {
            switch track {
            case .microphone: microphoneWatch?.isStalled(at: time) ?? false
            case .systemAudio: systemAudioWatch?.isStalled(at: time) ?? false
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        // The stream hands the buffer over and keeps no hold on it; the writer runs on this same queue.
        nonisolated(unsafe) let sample = sampleBuffer
        switch type {
        case .screen:
            // Only frames with new content carry a picture; idle ones say nothing changed.
            guard Self.isComplete(sample) else {
                lock.withLock { idle += 1 }
                return
            }
            lock.withLock { complete += 1 }
            writer.assumeIsolated { $0.appendFrame(sample) }
        case .audio:
            let arrival = ScreenRecorder.hostTime().seconds
            lock.withLock { systemAudioWatch?.bufferArrived(at: arrival) }
            writer.assumeIsolated { $0.appendAudio(sample, to: .systemAudio) }
        case .microphone:
            let arrival = ScreenRecorder.hostTime().seconds
            let muted = lock.withLock { () -> Bool in
                microphoneWatch?.bufferArrived(at: arrival)
                if microphoneMuted {
                    microphoneLevel = 0
                    return true
                }
                return false
            }
            if !muted, let level = AudioLevel.rms(of: sample) {
                lock.withLock {
                    if !microphoneMuted { microphoneLevel = max(microphoneLevel, level) }
                }
            }
            writer.assumeIsolated { $0.appendAudio(sample, to: .microphone) }
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop?(error)
    }

    private static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete && sample.imageBuffer != nil
    }
}
