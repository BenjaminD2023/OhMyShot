import AppKit

/// What VoiceOver says aloud when something changes that the screen shows only in passing: a copy, a save, a
/// capture starting, a reading that found nothing.
public enum VoiceOver {
    /// Asks VoiceOver to say `message`. `element` is what says it: the view or window the change happened in, so
    /// VoiceOver can tie the words to it, or the app itself (nil) when nothing on screen is nearer. High priority
    /// interrupts what VoiceOver is saying; medium waits its turn, for news that only adds to what is shown.
    @MainActor
    public static func announce(_ message: String, from element: Any? = nil, priority: NSAccessibilityPriorityLevel = .high) {
        NSAccessibility.post(element: element ?? NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: priority.rawValue,
        ])
    }
}
