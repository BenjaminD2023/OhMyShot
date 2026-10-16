import Foundation

/// How an area being recorded shows on screen, from its countdown to the end. None of it is in the recording.
public enum RecordingHighlight: String, CaseIterable, Sendable {
    /// A white edge over a dark outline, nothing dimmed.
    case outline
    /// The rest of the display dimmed, the area clear.
    case dim
    /// A red frame just outside the area.
    case redFrame
}
