import Foundation

/// How closely the recording window encodes a recording's picture again, when edits make it: a sharper
/// picture in a larger file, or a smaller file. Medium is the quality recordings are made at, so a recording
/// left at Medium is not encoded again for its quality.
public enum RecordingQuality: String, CaseIterable, Codable, Sendable {
    case high
    case medium
    case low
}
