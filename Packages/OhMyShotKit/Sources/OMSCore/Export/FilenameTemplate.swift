import Foundation

/// Builds file names for captures from a pattern of tokens.
///
/// Tokens: `{date}` (2026-10-07), `{time}` (22.45.10, dots because macOS file names cannot hold
/// colons in Finder), `{app}` (the frontmost app), `{counter}` (a running number). Anything else is
/// kept as typed; slashes and colons are replaced so the result is always a valid file name.
public struct FilenameTemplate: Equatable, Sendable {
    public var pattern: String

    public static let standard = FilenameTemplate(pattern: "OhMyShot {date} at {time}")

    public init(pattern: String) {
        self.pattern = pattern
    }

    public func name(date: Date, appName: String? = nil, counter: Int = 1, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateText = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let timeText = String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let result = pattern
            .replacingOccurrences(of: "{date}", with: dateText)
            .replacingOccurrences(of: "{time}", with: timeText)
            .replacingOccurrences(of: "{app}", with: appName ?? "")
            .replacingOccurrences(of: "{counter}", with: String(counter))
        let cleaned = result
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "OhMyShot" : cleaned
    }
}
