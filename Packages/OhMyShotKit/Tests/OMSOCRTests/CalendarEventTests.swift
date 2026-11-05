import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

/// The calendar file the OCR panel opens for a date it found, and the links a code may open.
struct CalendarEventTests {
    private let uid = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    /// 2026-03-14 15:30:00 UTC.
    private let afternoon = Date(timeIntervalSince1970: 1_773_502_200)
    /// 2026-01-02 03:04:05 UTC.
    private let made = Date(timeIntervalSince1970: 1_767_323_045)

    private func dateItem(_ text: String, in whole: String, date: Date) -> DetectedItem {
        DetectedItem(kind: .date, range: (whole as NSString).range(of: text), text: text, date: date)
    }

    @Test func aTimeOfDayIsToldFromADateAlone() {
        #expect(CalendarEvent.hasTime("March 14, 3:30 PM"))
        #expect(CalendarEvent.hasTime("15：30"))
        #expect(CalendarEvent.hasTime("10 a.m. tomorrow"))
        #expect(CalendarEvent.hasTime("3月14日下午3点"))
        #expect(!CalendarEvent.hasTime("March 14"))
        #expect(!CalendarEvent.hasTime("Amsterdam, 14 March"))
    }

    /// Named after the line the date is on, trimmed; timed when the date's text has a time.
    @Test func theEventIsNamedAfterItsLine() throws {
        let text = "Notes\n  Dinner with Ann on March 14 at 7:30 pm  \nMore"
        let event = try #require(CalendarEvent(for: dateItem("March 14 at 7:30 pm", in: text, date: afternoon), in: text))
        #expect(event.title == "Dinner with Ann on March 14 at 7:30 pm")
        #expect(event.hasTime)
        #expect(CalendarEvent(for: DetectedItem(kind: .date, range: NSRange(location: 0, length: 5), text: "Notes"), in: text) == nil)
    }

    @Test func aTitleIsAtMost120Characters() throws {
        let text = String(repeating: "x", count: 200) + " March 14"
        let event = try #require(CalendarEvent(for: dateItem("March 14", in: text, date: afternoon), in: text))
        #expect(event.title.count == 120)
    }

    /// A date whose range is no longer in the text is named after its own text.
    @Test func aDateOutsideTheTextIsNamedAfterItself() throws {
        let item = DetectedItem(kind: .date, range: NSRange(location: 40, length: 8), text: "March 14", date: afternoon)
        #expect(try #require(CalendarEvent(for: item, in: "short")).title == "March 14")
    }

    @Test func aTimedEventLastsAnHourInUTC() {
        let file = CalendarEvent(title: "Dinner; Ann, Bob \\ co", date: afternoon, hasTime: true)
            .iCalendar(uid: uid, stamped: made, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(file == [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//OhMyShot//OCR Panel//EN", "BEGIN:VEVENT",
            "UID:6F9619FF-8B86-D011-B42D-00C04FC964FF", "DTSTAMP:20260102T030405Z",
            "DTSTART:20260314T153000Z", "DTEND:20260314T163000Z",
            "SUMMARY:Dinner\\; Ann\\, Bob \\\\ co", "END:VEVENT", "END:VCALENDAR", "",
        ].joined(separator: "\r\n"))
    }

    /// An all-day event is the date where the Mac is: 15:30 UTC is already the 15th in Tokyo.
    @Test func anAllDayEventIsTheLocalDate() {
        let event = CalendarEvent(title: "Line one\nline two", date: afternoon, hasTime: false)
        let tokyo = event.iCalendar(uid: uid, stamped: made, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(tokyo.contains("\r\nDTSTART;VALUE=DATE:20260315\r\nDTEND;VALUE=DATE:20260316\r\n"))
        #expect(tokyo.contains("\r\nSUMMARY:Line one\\nline two\r\n"))
        let losAngeles = event.iCalendar(uid: uid, stamped: made, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(losAngeles.contains("\r\nDTSTART;VALUE=DATE:20260314\r\nDTEND;VALUE=DATE:20260315\r\n"))
        // The stamp is UTC wherever the Mac is.
        #expect(losAngeles.contains("\r\nDTSTAMP:20260102T030405Z\r\n"))
    }

    @Test func onlyWebLinksOpenFromACode() {
        func code(_ payload: String) -> OCRCode { OCRCode(payload: payload, kind: .qr, box: .zero) }
        #expect(code("https://example.com/a?b=c").webURL == URL(string: "https://example.com/a?b=c"))
        #expect(code("HTTP://example.com").webURL != nil)
        #expect(code("mailto:someone@example.com").webURL == nil)
        #expect(code("file:///etc/passwd").webURL == nil)
        #expect(code("tel:+15551234567").webURL == nil)
        #expect(code("just some text").webURL == nil)
    }
}
