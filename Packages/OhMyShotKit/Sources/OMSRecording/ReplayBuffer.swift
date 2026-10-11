import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import OSLog
import ScreenCaptureKit

/// The last 15 seconds of a display, kept while it runs so what just happened can be saved (macOS 27's
/// SCClipBufferingOutput).
///
/// ScreenCaptureKit keeps the buffer itself, encoded, in its own process; this runs the stream and asks it
/// for a clip. What the spike measured (Docs/perf.md › Replay spike) shapes it: the stream has to hand its
/// frames to the app too, or the buffer holds no video, so they come and are dropped; the buffer encodes
/// H.264 at the stream's size, so the frames are scaled to fit 4096; it keeps samples by time, so after 15
/// still seconds there is nothing to save; the export refuses a file that is there already; and a clip has
/// the system's sound first, then the microphone, each a track of its own.
@available(macOS 27, *)
@MainActor
public final class ReplayBuffer {
    /// What to buffer and how.
    public struct Request {
        public var filter: SCContentFilter
        /// The frames' size in pixels, as `size(fitting:_:)` makes it.
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        public var showsCursor: Bool
        /// The microphone buffered with the system's sound, or nil for none.
        public var microphone: RecordingAudio.Microphone?
        /// Leaves this app's own sounds out. A stream of one of this app's windows hears only this app, and
        /// with nothing to hear, the clip came out a few frames long.
        public var excludesOwnSound: Bool

        public init(
            filter: SCContentFilter, width: Int, height: Int, framesPerSecond: Int, showsCursor: Bool, microphone: RecordingAudio.Microphone?,
            excludesOwnSound: Bool = true
        ) {
            self.filter = filter
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.showsCursor = showsCursor
            self.microphone = microphone
            self.excludesOwnSound = excludesOwnSound
        }
    }

    public enum ReplayError: Error, Equatable {
        case notRunning
        /// Nothing on screen changed in the last 15 seconds, so the buffer holds no frame.
        case nothingChanged
    }

    /// Why a buffer stopped on its own.
    public enum Ending: Sendable {
        /// The stream ended: its display went away, or Screen Recording was turned off.
        case streamStopped
        /// The buffer failed while the stream went on; the stream is stopped too.
        case bufferFailed
    }

    /// How much is kept: ScreenCaptureKit's most.
    nonisolated public static let length: TimeInterval = 15
    /// The longest side the buffer's encoder takes: H.264's, with no choosing HEVC.
    nonisolated public static let largestSide = 4096

    public let request: Request
    public private(set) var isRunning = false
    /// The buffer stopped on its own, and why: the stream ended (the display went away, Screen Recording was
    /// turned off) or the buffer failed. Either way it is gone.
    public var onStopped: ((Ending) -> Void)?

    private var stream: SCStream?
    private var buffering: SCClipBufferingOutput?
    private let output = ReplayOutput()
    private let queue = DispatchSerialQueue(label: "OhMyShot.replay", qos: .utility)
    private var leases: [ActiveResources.Lease] = []
    private var activity: (any NSObjectProtocol)?

    public init(_ request: Request) {
        self.request = request
    }

    /// The audio tracks a saved clip has, in order: the system's sound, then the microphone when buffered.
    public var audioTracks: [RecordingWriter.Track] {
        [.systemAudio] + (request.microphone == nil ? [] : [.microphone])
    }

    /// The size a display of `width` × `height` pixels is buffered at: as it is, or scaled to fit
    /// `largestSide` on both sides; both even.
    nonisolated public static func size(fitting width: Int, _ height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(largestSide) / Double(max(width, height, 1)))
        func fitted(_ side: Int) -> Int { max(2, min(largestSide, Int((Double(side) * scale).rounded())) & ~1) }
        return (fitted(width), fitted(height))
    }

    static func configuration(for request: Request) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = request.width
        configuration.height = request.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, request.framesPerSecond)))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureDynamicRange = .SDR
        configuration.queueDepth = 3
        configuration.showsCursor = request.showsCursor
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = request.excludesOwnSound
        configuration.sampleRate = RecordingAudio.sampleRate
        configuration.channelCount = 2
        configuration.captureMicrophone = request.microphone != nil
        configuration.microphoneCaptureDeviceID = request.microphone?.deviceID
        configuration.streamName = "OhMyShot Replay"
        return configuration
    }

    /// Starts buffering. Throws when the stream cannot start; nothing is left running then.
    public func start() async throws {
        guard !isRunning else { return }
        let stream = SCStream(filter: request.filter, configuration: Self.configuration(for: request), delegate: output)
        output.onStop = { [weak self] error in
            Task { @MainActor in await self?.stopped(.streamStopped, error) }
        }
        output.onFail = { [weak self] error in
            Task { @MainActor in await self?.stopped(.bufferFailed, error) }
        }
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            let buffering = SCClipBufferingOutput(delegate: output)
            try stream.addClipBufferingOutput(buffering)
            self.buffering = buffering
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        self.stream = stream
        isRunning = true
        leases = [ActiveResources.shared.acquire(.captureStream)]
        // Kept from App Nap, so the frames the buffer needs keep coming; never from idle sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Keeping the last seconds of the screen")
        Log.recording.notice("Replay buffering \(self.request.width, privacy: .public)x\(self.request.height, privacy: .public) at \(self.request.framesPerSecond, privacy: .public) fps, microphone \(self.request.microphone != nil, privacy: .public)")
    }

    /// Writes the last `length` seconds to `url`, a `.mov` (anything there is removed first: the export
    /// refuses a file that is there). Throws `nothingChanged` when the buffer holds no frame.
    public func save(to url: URL) async throws {
        guard isRunning, let buffering else { throw ReplayError.notRunning }
        try? FileManager.default.removeItem(at: url)
        do {
            try await buffering.exportClip(to: url, duration: Self.length)
        } catch let error as NSError where error.domain == "com.apple.ReplayKit.RPRecordingErrorDomain" && error.code == -5822 {
            // "Failed due to failure to process first sample buffer": replayd found no video samples.
            throw ReplayError.nothingChanged
        }
    }

    /// Stops buffering and lets the buffer go.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        if let buffering, let stream { try? stream.removeClipBufferingOutput(buffering) }
        buffering = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        release()
        Log.recording.notice("Replay stopped")
    }

    private func stopped(_ ending: Ending, _ error: any Error) async {
        guard isRunning else { return }
        Log.recording.error("The replay stopped on its own (\(String(describing: ending), privacy: .public)): \(String(describing: error), privacy: .public)")
        isRunning = false
        // A buffer that failed leaves its stream running, with the system's capture indicator on: stop it.
        if ending == .bufferFailed, let stream {
            if let buffering { try? stream.removeClipBufferingOutput(buffering) }
            try? await stream.stopCapture()
        }
        buffering = nil
        stream = nil
        release()
        onStopped?(ending)
    }

    private func release() {
        leases.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Takes the replay stream's frames, which the buffer needs the app to take, and drops them; hears the
/// stream stop and the buffer fail. Called on the stream's queue: never isolated to the main actor.
@available(macOS 27, *)
nonisolated private final class ReplayOutput: NSObject, SCStreamOutput, SCStreamDelegate, SCClipBufferingOutputDelegate, @unchecked Sendable {
    /// Set before the stream starts: the stream ended, or the buffer failed while it went on.
    var onStop: (@Sendable (any Error) -> Void)?
    var onFail: (@Sendable (any Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop?(error)
    }

    func clipBufferingOutput(_ clipBufferingOutput: SCClipBufferingOutput, didFailWithError error: any Error) {
        onFail?(error)
    }
}
