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

    public private(set) var state: State = .idle
    public let request: Request
    /// The stream stopped on its own (a display went away, Screen Recording was turned off, or the system's
    /// own control stopped it): the recording so far should be finished and kept.
    public var onStreamStopped: ((any Error) -> Void)?

    private let writer: RecordingWriter
    private let queue = DispatchSerialQueue(label: "OhMyShot.recording", qos: .userInitiated)
    private let output: StreamOutput
    private var stream: SCStream?
    private var leases: [ActiveResources.Lease] = []
    private var activity: (any NSObjectProtocol)?
    private var startedAt: ContinuousClock.Instant?
    private var pausedFor: Duration = .zero
    private var pausedSince: ContinuousClock.Instant?

    public init(_ request: Request) throws {
        self.request = request
        writer = try RecordingWriter(url: request.movieURL, format: request.format, audio: request.audio, queue: queue)
        output = StreamOutput(writer: writer)
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
        guard state == .idle else { return }
        let stream = SCStream(filter: request.filter, configuration: Self.configuration(for: request), delegate: output)
        output.onStop = { [weak self] error in
            Task { @MainActor in self?.streamStopped(error) }
        }
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            if request.audio.system { try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue) }
            if request.audio.microphone != nil { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue) }
            try await stream.startCapture()
        } catch {
            await writer.cancel()
            throw error
        }
        self.stream = stream
        state = .recording
        startedAt = .now
        leases = [ActiveResources.shared.acquire(.captureStream), ActiveResources.shared.acquire(.activity)]
        // Kept from App Nap and idle sleep while recording; the display may still sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Recording the screen")
        Log.recording.notice("Recording \(self.request.format.width, privacy: .public)x\(self.request.format.height, privacy: .public) \(self.request.format.codec.rawValue, privacy: .public) at \(self.request.format.framesPerSecond, privacy: .public) fps")
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
        Task { await writer.pause(at: time) }
    }

    public func resume() {
        guard state == .paused else { return }
        state = .recording
        if let since = pausedSince { pausedFor += .now - since }
        pausedSince = nil
        let time = Self.hostTime()
        Task { await writer.resume(at: time) }
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
        defer { release() }
        let statistics = try await writer.finish(at: end)
        state = .finished
        Log.recording.notice("Recording finished: \(statistics.duration.seconds, format: .fixed(precision: 2), privacy: .public) s, \(statistics.framesWritten, privacy: .public) frames written, \(statistics.framesDropped, privacy: .public) dropped, \(statistics.audioBuffersWritten + statistics.microphoneBuffersWritten, privacy: .public) audio buffers")
        return statistics
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

    private func release() {
        leases.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// How loud the microphone has been since this was last read, from 0 to 1 on a meter's scale; nil when
    /// the microphone isn't recorded.
    public func takeMicrophoneLevel() -> Double? {
        guard request.audio.microphone != nil else { return nil }
        return AudioLevel.meterValue(rms: output.takeMicrophoneLevel())
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

    init(writer: RecordingWriter) {
        self.writer = writer
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
            writer.assumeIsolated { $0.appendAudio(sample, to: .systemAudio) }
        case .microphone:
            if let level = AudioLevel.rms(of: sample) {
                lock.withLock { microphoneLevel = max(microphoneLevel, level) }
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
