import Foundation
import Testing
@testable import OMSCore

struct FilenameTemplateTests {
    let date = Date(timeIntervalSince1970: 1_791_419_110) // 2026-10-08 00:25:10 UTC
    let utc = TimeZone(identifier: "UTC")!

    @Test func standardNameMatchesMacOSStyle() {
        #expect(FilenameTemplate.standard.name(date: date, timeZone: utc) == "OhMyShot 2026-10-08 at 00.25.10")
    }

    @Test func tokensAreReplaced() {
        let template = FilenameTemplate(pattern: "{app} – {counter} – {date}")
        #expect(template.name(date: date, appName: "Safari", counter: 7, timeZone: utc) == "Safari – 7 – 2026-10-08")
    }

    @Test func slashesAndColonsCannotBreakTheFileName() {
        let template = FilenameTemplate(pattern: "a/b:c {app}")
        #expect(template.name(date: date, appName: "x/y", timeZone: utc) == "a-b.c x-y")
    }

    @Test func emptyResultFallsBackToTheAppName() {
        #expect(FilenameTemplate(pattern: "{app}").name(date: date, timeZone: utc) == "OhMyShot")
    }
}
