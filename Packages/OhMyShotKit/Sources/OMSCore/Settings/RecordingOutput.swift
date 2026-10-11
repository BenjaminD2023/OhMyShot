import Foundation

/// What a recording is kept as: a movie, an animated GIF for places that show pictures but not movies, or a
/// Studio recording, filmed again in the Studio window with zooms, a smooth cursor, and a background.
public enum RecordingOutput: String, CaseIterable, Codable, Sendable {
    case video
    case gif
    case studio

    /// A GIF has no sound.
    public var hasAudio: Bool {
        self != .gif
    }
}
