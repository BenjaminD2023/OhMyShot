/// Whether a track of sound is still arriving while recording, to notice a microphone that went away (a
/// headset switched off, a cable pulled) while the recording goes on, silent.
///
/// A microphone in a quiet room still sends buffers, of silence, so one that sends nothing for
/// `stallAfter` seconds is gone. Times are seconds of the host clock, the one the stream's samples are
/// stamped with; this reads no clock, it is told the time, so it can be checked without a stream.
public struct AudioWatch: Equatable, Sendable {
    /// How many seconds a track may send nothing before it counts as stalled.
    public static let stallAfter = 5.0

    /// When the quiet began: the start, the latest resume, or the latest buffer.
    private var quietSince: Double
    private var isPaused = false

    /// Watches a track that is recorded from `time` on. Nothing is stalled in the first `stallAfter` seconds.
    public init(startedAt time: Double) {
        quietSince = time
    }

    /// A buffer of sound arrived at `time`.
    public mutating func bufferArrived(at time: Double) {
        quietSince = max(quietSince, time)
    }

    /// Recording is paused: nothing is stalled until it resumes, whatever arrives or not.
    public mutating func pause() {
        isPaused = true
    }

    /// Recording resumed at `time`. The track gets `stallAfter` seconds again to send something.
    public mutating func resume(at time: Double) {
        isPaused = false
        quietSince = max(quietSince, time)
    }

    /// Whether the track has sent nothing for `stallAfter` seconds or more by `time`, while recording.
    public func isStalled(at time: Double) -> Bool {
        !isPaused && time - quietSince >= Self.stallAfter
    }
}
