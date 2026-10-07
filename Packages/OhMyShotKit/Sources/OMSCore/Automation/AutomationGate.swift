/// The app or tool that sent an automation URL.
public struct AutomationCaller: Equatable, Sendable {
    /// The bundle identifier, or `command-line` for the command-line group.
    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }

    /// Senders that are not apps (`open`, `osascript`, shell scripts) usually exit before their command
    /// is handled, so they cannot be told apart. They are approved, or refused, as one group.
    public static let commandLine = AutomationCaller(identifier: "command-line", displayName: "Command-line tools")
}

public enum AutomationDecision: Equatable, Sendable {
    case allow
    case askUser
    case deny(reason: String)
}

/// Decides whether a URL command may run.
///
/// Every command needs an approved caller, not only the ones that read files: a capture command run
/// on behalf of an app that lacks Screen Recording permission would hand that app the user's screen.
public enum AutomationGate {
    public static func evaluate(
        caller: AutomationCaller?,
        isEnabled: Bool,
        approvedCallers: Set<String>,
        deniedCallers: Set<String> = []
    ) -> AutomationDecision {
        guard isEnabled else {
            return .deny(reason: "automation is turned off in Settings")
        }
        guard let caller else {
            return .deny(reason: "the sender could not be identified")
        }
        if approvedCallers.contains(caller.identifier) {
            return .allow
        }
        if deniedCallers.contains(caller.identifier) {
            return .deny(reason: "\(caller.displayName) was already refused")
        }
        return .askUser
    }
}
