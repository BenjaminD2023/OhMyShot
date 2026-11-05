import Foundation

/// Which keys a recording shows.
public enum KeystrokeMode: String, CaseIterable, Codable, Sendable {
    /// Every key: typing runs on as it is typed, shortcuts and special keys by name.
    case all
    /// Shortcuts only (keys held with Command, Control, or Option) and function keys.
    case shortcuts
}
