import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import OSLog

/// Writes a recording's samples into a QuickTime movie, on the queue the stream delivers them on.
///
/// The actor's executor is that serial queue, so frames are appended where they arrive, with no hop
/// between threads per frame; the app's calls (pause, resume, finish) hop onto it. The movie is written in
/// fragments every two seconds, so a recording cut short by a crash is still readable up to the last one.
///
/// Times: samples carry the host clock's time. The movie starts at the first frame; pauses are cut out by
/// moving every later sample earlier by the paused time. The screen sends a frame only when something
/// changed, so the last frame is written again a frame before the end: the video lasts as long as the
/// recording did, whatever the other tracks do (ending the session alone stretches it only without audio).
public actor RecordingWriter {
    public enum Track: Sendable {
        case systemAudio
        case microphone
    }

    public struct Statistics: Equatable, Sendable {
        public var framesWritten = 0
        /// Frames left out because the encoder was not ready for them.
        public var framesDropped = 0
        /// Frames that came while paused.
        public var framesWhilePaused = 0
        /// The last frame written once more before the end (1), when the screen stopped changing before it.
        public var framesRepeated = 0
        public var audioBuffersWritten = 0
        public var microphoneBuffersWritten = 0
        /// Audio buffers left out: before the first frame, reaching into a pause, or with the encoder busy.
        public var audioBuffersDropped = 0
        /// The movie's length: from the first frame to the end, pauses left out.
        public var duration: CMTime = .zero
        /// Where the movie began on the host clock (its first frame), and the pauses cut out of it, so what
        /// happened while recording can be placed in the movie's time.
        public var start: CMTime?
        public var pauses: [CMTimeRange] = []
    }

    public enum WriterError: Error, Equatable {
        /// Stopped before the first frame arrived: there is nothing to keep.
        case noFrames
        case writerFailed(String)
    }

    private struct Pause {
        let start: CMTime
        var end: CMTime?
    }

    public nonisolated let url: URL
    public nonisolated let format: RecordingFormat
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?

    /// The first frame's time, where the movie starts.
    private var start: CMTime?
    /// Every pause so far, in host time; the last one is still going on while its end is nil.
    private var pauses: [Pause] = []
    /// The newest frame written and its time in the movie.
    private var lastFrame: (sample: CMSampleBuffer, time: CMTime)?
    /// The newest frame that came during the current pause: what the screen shows when recording resumes.
    private var heldFrame: CMSampleBuffer?
    /// Where each audio track's last buffer ends in the movie, so none overlaps the one before it.
    private var audioEnds: [Track: CMTime] = [:]
    private var statistics = Statistics()
    private var isFinished = false

    /// Creates the movie at `url` (a `.mov`; anything there already is replaced). Samples are then appended
    /// on `queue`, the queue the stream delivers them on.
    public init(url: URL, format: RecordingFormat, audio: RecordingAudio, queue: DispatchSerialQueue) throws {
        self.url = url
        self.format = format
        self.queue = queue
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard writer.canApply(outputSettings: format.videoSettings, forMediaType: .video) else {
            throw WriterError.writerFailed("video settings refused for \(format)")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: format.videoSettings)
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if audio.system {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingAudio.settings(channels: 2))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            systemAudio = input
        } else {
            systemAudio = nil
        }
        if audio.microphone != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingAudio.settings(channels: 1))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            microphone = input
        } else {
            microphone = nil
        }
        guard writer.startWriting() else {
            throw WriterError.writerFailed(writer.error.map { "\($0)" } ?? "could not start writing")
        }
    }

    public var isPaused: Bool {
        pauses.last.map { $0.end == nil } ?? false
    }

    public var currentStatistics: Statistics {
        statistics
    }

    /// Whether the encoder would take a frame now, for tests that feed frames faster than a stream would.
    var isReadyForFrame: Bool {
        video.isReadyForMoreMediaData
    }

    // MARK: Samples

    /// Appends a frame that has new content. Frames during a pause are held back, the newest written when
    /// recording resumes.
    public func appendFrame(_ sample: CMSampleBuffer) {
        guard !isFinished, writer.status == .writing else { return }
        let time = sample.presentationTimeStamp
        guard time.isValid else { return }
        if isPaused, time >= pauses[pauses.count - 1].start {
            heldFrame = sample
            statistics.framesWhilePaused += 1
            return
        }
        if start == nil {
            writer.startSession(atSourceTime: time)
            start = time
        }
        guard let output = movieTime(of: time) else {
            // Taken during a pause that has ended since: the frame held back then stands for it.
            statistics.framesWhilePaused += 1
            return
        }
        write(sample, at: output)
    }

    /// Appends audio to its track. Only whole buffers between pauses are kept, so the track never overlaps
    /// itself once a pause is cut out; audio before the first frame is left out.
    public func appendAudio(_ sample: CMSampleBuffer, to track: Track) {
        guard !isFinished, writer.status == .writing, let input = input(for: track) else { return }
        let time = sample.presentationTimeStamp
        let duration = sample.duration
        guard let start, time.isValid, time >= start, duration.isValid,
              let output = movieTime(of: time),
              let outputEnd = movieTime(of: time + duration - CMTime(value: 1, timescale: time.timescale)),
              outputEnd >= output
        else {
            statistics.audioBuffersDropped += 1
            return
        }
        if let end = audioEnds[track], output < end - CMTime(value: 1, timescale: 1000) {
            statistics.audioBuffersDropped += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            statistics.audioBuffersDropped += 1
            return
        }
        guard let retimed = output == time ? sample : Self.retimed(sample, to: output) else { return }
        if input.append(retimed) {
            audioEnds[track] = output + duration
            switch track {
            case .systemAudio: statistics.audioBuffersWritten += 1
            case .microphone: statistics.microphoneBuffersWritten += 1
            }
        } else {
            Log.recording.error("Appending audio failed: \(String(describing: self.writer.error), privacy: .public)")
        }
    }

    // MARK: Pausing

    /// Pauses at `time` (host clock): samples from then on are left out until `resume`.
    public func pause(at time: CMTime) {
        guard !isFinished, !isPaused else { return }
        pauses.append(Pause(start: time, end: nil))
    }

    /// Resumes at `time` (host clock). The newest frame that came while paused is written at once, so the
    /// movie shows the screen as it is now even when nothing changes after resuming.
    public func resume(at time: CMTime) {
        guard !isFinished, isPaused else { return }
        let pause = pauses[pauses.count - 1]
        let end = max(time, pause.start)
        let held = heldFrame
        heldFrame = nil
        guard start != nil else {
            // Paused before the first frame arrived: the movie has not begun, so there is nothing to cut out,
            // and the frame held back begins it now.
            pauses.removeLast()
            if let held, let first = Self.retimed(held, to: end) { appendFrame(first) }
            return
        }
        pauses[pauses.count - 1].end = end
        if let held, let output = movieTime(of: end) {
            write(held, at: output)
        }
    }

    // MARK: Finishing

    /// Ends the movie at `time` (host clock), or where the current pause began, and closes the file.
    /// Throws `noFrames` when no frame ever came; the file is then removed.
    @discardableResult
    public func finish(at time: CMTime) async throws -> Statistics {
        guard !isFinished else { return statistics }
        isFinished = true
        guard let start, let last = lastFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw WriterError.noFrames
        }
        let completed = pauses.filter { $0.end != nil }.reduce(CMTime.zero) { $0 + ($1.end! - $1.start) }
        let endSource = pauses.last.flatMap { $0.end == nil ? $0.start : nil } ?? time
        // At least a frame's length after the last frame, which shows for that long.
        let interval = format.frameInterval
        let end = max(endSource - completed, last.time + interval)
        // The last frame again for the final frame's length, so the video reaches the end.
        let repeatTime = end - interval
        if repeatTime > last.time, video.isReadyForMoreMediaData,
           let repeated = Self.retimed(last.sample, to: repeatTime, duration: interval), video.append(repeated) {
            statistics.framesRepeated = 1
        }
        writer.endSession(atSourceTime: end)
        video.markAsFinished()
        systemAudio?.markAsFinished()
        microphone?.markAsFinished()
        await writer.finishWriting()
        statistics.duration = end - start
        statistics.start = start
        statistics.pauses = pauses.compactMap { pause in pause.end.map { CMTimeRange(start: pause.start, end: $0) } }
        guard writer.status == .completed else {
            throw WriterError.writerFailed(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")
        }
        return statistics
    }

    /// Abandons the movie and removes its file.
    public func cancel() {
        guard !isFinished else { return }
        isFinished = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Private

    private func input(for track: Track) -> AVAssetWriterInput? {
        switch track {
        case .systemAudio: systemAudio
        case .microphone: microphone
        }
    }

    private func write(_ sample: CMSampleBuffer, at time: CMTime) {
        // Times must keep increasing, or the writer fails the whole movie.
        if let last = lastFrame?.time, time <= last {
            statistics.framesDropped += 1
            return
        }
        guard video.isReadyForMoreMediaData else {
            statistics.framesDropped += 1
            return
        }
        guard let retimed = time == sample.presentationTimeStamp ? sample : Self.retimed(sample, to: time) else { return }
        if video.append(retimed) {
            lastFrame = (sample, time)
            statistics.framesWritten += 1
        } else {
            Log.recording.error("Appending a frame failed: \(String(describing: self.writer.error), privacy: .public)")
        }
    }

    /// The time a sample taken at `time` (host clock) has in the movie: earlier by every pause that ended
    /// before it. Nil when it was taken during a pause.
    private func movieTime(of time: CMTime) -> CMTime? {
        var offset = CMTime.zero
        for pause in pauses {
            if time < pause.start { break }
            guard let end = pause.end, time >= end else { return nil }
            offset = offset + (end - pause.start)
        }
        return time - offset
    }

    /// A copy of `sample` presented at `time`, with its own duration unless another is given.
    static func retimed(_ sample: CMSampleBuffer, to time: CMTime, duration: CMTime? = nil) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration ?? sample.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
