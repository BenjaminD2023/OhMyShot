import Foundation

/// What a recording is kept as: a movie, or an animated GIF for places that show pictures but not movies.
public enum RecordingOutput: String, CaseIterable, Codable, Sendable {
    case video
    case gif

    /// A GIF has no sound.
    public var hasAudio: Bool {
        self == .video
    }
}
