import AVFoundation
import CoreMedia
import Foundation
import OSLog
import OMSCore

/// Records a camera into a movie of its own while a Studio recording runs, so Studio can place the camera
/// over the movie it films rather than zoom it with the screen.
///
/// Its `output` is added to the capture session that already shows the camera on screen; frames come on a
/// queue of their own, which the movie's writer runs on, as the screen's writer runs on the stream's. Times
/// are the host clock's, as the screen's are, and the recording's pauses are cut out of both alike, so the
/// two movies stay in step: Studio needs only where the camera's begins.
public final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// The frames' output, for the capture session showing the camera.
    public let output = AVCaptureVideoDataOutput()
    public let url: URL

    private let writer: RecordingWriter
    private let queue = DispatchSerialQueue(label: "OhMyShot.camera-recording", qos: .userInitiated)
    /// The capture session's clock, when it is not the host clock: frames are moved onto the host clock.
    private let clock: CMClock?
    private let lock = NSLock()
    private var frames = 0

    /// A camera's frames: 30 a second at most, and they are faces, not text, so a lower quality keeps the
    /// file small.
    static let framesPerSecond = 30
    static let quality = 0.5

    /// Creates the movie at `url` (a `.mov`) for frames of `width` × `height` pixels. `clock` is the capture
    /// session's synchronization clock.
    public init(url: URL, width: Int, height: Int, clock: CMClock?) throws {
        self.url = url
        let format = RecordingFormat.choose(width: width, height: height, framesPerSecond: Self.framesPerSecond, quality: Self.quality)
        writer = try RecordingWriter(url: url, format: format, audio: .none, queue: queue)
        self.clock = clock.flatMap { CFEqual($0, CMClockGetHostTimeClock()) ? nil : $0 }
        super.init()
        // 4:2:0, as the encoder takes it, and as Studio's compositor reads it.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Frames are taken as the camera sees them: the mirror is Studio's to draw.
    public func unmirror() {
        guard let connection = output.connection(with: .video), connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    /// The frames written so far, for scripted checks.
    public var framesReceived: Int {
        lock.withLock { frames }
    }

    public func pause(at time: CMTime) {
        Task { await writer.pause(at: time) }
    }

    public func resume(at time: CMTime) {
        Task { await writer.resume(at: time) }
    }

    /// Ends the movie at `time` (host clock) and closes it. Throws `RecordingWriter.WriterError.noFrames`
    /// when the camera sent nothing; the file is then gone.
    public func finish(at time: CMTime) async throws -> RecordingWriter.Statistics {
        output.setSampleBufferDelegate(nil, queue: nil)
        let statistics = try await writer.finish(at: time)
        Log.recording.notice("Camera recording finished: \(statistics.duration.seconds, format: .fixed(precision: 2), privacy: .public) s, \(statistics.framesWritten, privacy: .public) frames written, \(statistics.framesDropped, privacy: .public) dropped")
        return statistics
    }

    /// Abandons the movie and removes its file.
    public func cancel() async {
        output.setSampleBufferDelegate(nil, queue: nil)
        await writer.cancel()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, sampleBuffer.imageBuffer != nil else { return }
        // The output hands the buffer over; the writer runs on this same queue.
        nonisolated(unsafe) var sample = sampleBuffer
        if let clock {
            let time = CMSyncConvertTime(sample.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
            guard let moved = RecordingWriter.retimed(sample, to: time) else { return }
            sample = moved
        }
        lock.withLock { frames += 1 }
        nonisolated(unsafe) let frame = sample
        writer.assumeIsolated { $0.appendFrame(frame) }
    }
}
