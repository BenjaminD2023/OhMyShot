import Foundation

/// What a clip saved from the replay keeps of the sound buffered with it: the system's sound and the
/// microphone both are always buffered, and each clip keeps them both, one, or neither.
public enum ReplaySound: String, CaseIterable, Codable, Sendable {
    case all
    case system
    case microphone
    case none

    /// Whether the clip keeps what the Mac played.
    public var keepsSystem: Bool {
        self == .all || self == .system
    }

    /// Whether the clip keeps the microphone.
    public var keepsMicrophone: Bool {
        self == .all || self == .microphone
    }
}
