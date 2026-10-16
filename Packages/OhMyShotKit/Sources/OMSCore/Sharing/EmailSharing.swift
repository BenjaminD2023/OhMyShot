import AppKit
import Foundation

/// Send by Email: a new message with a screenshot or a recording attached, started through the system's
/// mail sharing service, so it goes to whatever account Mail composes with.
@MainActor
public enum EmailSharing {
    /// Kept while its message is being made; the service does not hold on to itself.
    private static var current: NSSharingService?

    /// Whether a message can be started with `file` attached. Asked each time a menu is built, not once:
    /// accounts come and go while the app runs.
    public static func canSend(_ file: URL) -> Bool {
        NSSharingService(named: .composeEmail)?.canPerform(withItems: [file]) == true
    }

    /// An answer kept for a while, so places that ask over and over do not each ask the system.
    struct Remembered {
        let lifetime: TimeInterval
        private var last: (at: Date, answer: Bool)?

        init(lifetime: TimeInterval) {
            self.lifetime = lifetime
        }

        /// The answer given within `lifetime` of `now`, or else a fresh one from `ask`, which is then kept.
        mutating func answer(now: Date, ask: () -> Bool) -> Bool {
            if let last, now.timeIntervalSince(last.at) < lifetime { return last.answer }
            let answer = ask()
            last = (now, answer)
            return answer
        }
    }

    private static var recent = Remembered(lifetime: 30)

    /// `canSend`, remembered for 30 seconds, for places asked over and over (every History row's menu and
    /// VoiceOver actions are worked out each time the row is drawn): asking the system takes about a
    /// millisecond and a half.
    public static func canSendRecently(_ file: URL, now: Date = .now) -> Bool {
        recent.answer(now: now) { canSend(file) }
    }

    /// Starts a message with `file` attached and its name as the subject. Beeps when no message can be started.
    public static func send(_ file: URL) {
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [file]) else {
            return NSSound.beep()
        }
        service.subject = subject(for: file)
        current = service
        service.perform(withItems: [file])
    }

    /// The file's name without its extension: a capture's name says when it was taken.
    nonisolated public static func subject(for file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }
}
