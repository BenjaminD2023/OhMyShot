import Foundation

/// A one-event calendar file (iCalendar, RFC 5545) for a date found in recognized text. Opened, Calendar offers to
/// add it, so no calendar access is needed; writing the file and opening it is the interface's.
public struct CalendarEvent: Sendable, Equatable {
    /// What the event is called: the line the date is on.
    public var title: String
    public var date: Date
    /// Whether the date's text gave a time of day: then an hour-long event at it, else an all-day one on the date.
    public var hasTime: Bool

    public init(title: String, date: Date, hasTime: Bool) {
        self.title = title
        self.date = date
        self.hasTime = hasTime
    }

    /// The event for a date found in `text`, named after the line it is on (trimmed, at most 120 characters), or the
    /// date's own text when its range is no longer in `text`. Nil for an item without a date.
    public init?(for item: DetectedItem, in text: String) {
        guard let date = item.date else { return nil }
        let string = text as NSString
        let line = NSMaxRange(item.range) <= string.length ? string.substring(with: string.lineRange(for: item.range)) : item.text
        self.init(title: String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)), date: date, hasTime: Self.hasTime(item.text))
    }

    /// Whether a date's text says a time of day: digits either side of a colon (a full-width one too), a.m. or p.m.,
    /// or the Chinese and Japanese marks of an hour.
    public static func hasTime(_ text: String) -> Bool {
        text.range(of: #"\d\s*[:：]\s*\d|(?i)\b[ap]\.?m\b|[点點时時]"#, options: .regularExpression) != nil
    }

    /// The file's text, its lines ended with CRLF as RFC 5545 has them. A timed event is written in UTC; an all-day
    /// one as dates in `timeZone`, the Mac's own unless a test fixes it, as are the event's `uid` and when it was
    /// made (`stamped`).
    public func iCalendar(uid: UUID = UUID(), stamped now: Date = .now, timeZone: TimeZone = .current) -> String {
        func stamp(_ date: Date, _ format: String, utc: Bool) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = utc ? TimeZone(identifier: "UTC") : timeZone
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        let span = hasTime
            ? ["DTSTART:" + stamp(date, "yyyyMMdd'T'HHmmss'Z'", utc: true), "DTEND:" + stamp(date.addingTimeInterval(3600), "yyyyMMdd'T'HHmmss'Z'", utc: true)]
            : ["DTSTART;VALUE=DATE:" + stamp(date, "yyyyMMdd", utc: false), "DTEND;VALUE=DATE:" + stamp(date.addingTimeInterval(86400), "yyyyMMdd", utc: false)]
        return (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//OhMyShot//OCR Panel//EN", "BEGIN:VEVENT",
                 "UID:\(uid.uuidString)", "DTSTAMP:" + stamp(now, "yyyyMMdd'T'HHmmss'Z'", utc: true)]
            + span + ["SUMMARY:\(Self.escaped(title))", "END:VEVENT", "END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
    }

    /// A text value as RFC 5545 has it: backslash, semicolon, comma, and newline escaped with a backslash.
    static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

extension OCRCode {
    /// The web page a code points to, which is all a code may open: a code can carry any URL scheme, and a picture
    /// is no reason to launch whatever app claims it. Nil for any other payload.
    public var webURL: URL? {
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}
