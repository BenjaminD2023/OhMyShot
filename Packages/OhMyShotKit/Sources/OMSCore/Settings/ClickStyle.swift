import Foundation

/// How clicks show in a recording, when Show Clicks is on.
public enum ClickStyle: String, CaseIterable, Sendable {
    /// The circles the system draws into the stream.
    case system
    /// An accent ring that widens and fades where each press lands.
    case ring
}
