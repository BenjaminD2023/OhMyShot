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

    @Test func theWindowTitleIsATokenAndAnAreaWithNoneHasEmptyText() {
        let template = FilenameTemplate(pattern: "{app} - {window}")
        #expect(template.name(date: date, appName: "Safari", windowTitle: "Apple", timeZone: utc) == "Safari - Apple")
        #expect(template.name(date: date, appName: "Safari", timeZone: utc) == "Safari -")
    }

    @Test func aLongWindowTitleIsCutAndANameNeverPassesWhatTheFileSystemTakes() {
        let title = String(repeating: "a", count: 300)
        let name = FilenameTemplate(pattern: "{window}").name(date: date, windowTitle: title, timeZone: utc)
        #expect(name.count == FilenameTemplate.longestWindowTitle)
        // A pattern of the person's own that is too long is cut as a whole, in characters that are several bytes.
        let long = FilenameTemplate(pattern: String(repeating: "界", count: 200)).name(date: date, timeZone: utc)
        #expect(long.utf8.count <= FilenameTemplate.longestName)
        #expect(long.hasPrefix("界"))
    }

    @Test func aTitleWithLineBreaksOrLeadingDotsMakesAnOrdinaryName() {
        let name = FilenameTemplate(pattern: "{window}.png").name(date: date, windowTitle: "..\nhidden:/title\u{7}", timeZone: utc)
        #expect(!name.contains("\n") && !name.contains("/") && !name.contains(":"))
        #expect(!name.hasPrefix("."))
        #expect(FilenameTemplate.sanitized("  ...a/b:c\u{0}  ") == "a-b.c")
        #expect(FilenameTemplate.sanitized("...") == "")
    }

    @Test func aPatternCountsOnlyWhenItHoldsTheCounter() {
        #expect(FilenameTemplate(pattern: "Shot {counter}").usesCounter)
        #expect(!FilenameTemplate.standard.usesCounter)
        #expect(FilenameTemplate(pattern: "{counter}").name(date: date, counter: 12, timeZone: utc) == "12")
    }

    @Test func aTypedNameLosesTheExtensionSavingAddsAndAnythingThatCannotBeInAFileName() {
        let fallback = "OhMyShot 2026-10-08 at 00.25.10"
        #expect(FilenameTemplate.typedName("Receipt", fallback: fallback) == "Receipt")
        #expect(FilenameTemplate.typedName("Receipt.PNG", fallback: fallback) == "Receipt")
        #expect(FilenameTemplate.typedName("scan.v2", fallback: fallback) == "scan.v2")
        #expect(FilenameTemplate.typedName("a/b: c.jpeg  ", fallback: fallback) == "a-b. c")
        // Nothing usable left: the name that was offered.
        #expect(FilenameTemplate.typedName("   ", fallback: fallback) == fallback)
        #expect(FilenameTemplate.typedName(".heic", fallback: fallback) == fallback)
        #expect(FilenameTemplate.typedName(String(repeating: "界", count: 200), fallback: fallback).utf8.count <= FilenameTemplate.longestName)
    }

    @Test func theTokensAreTheOnesSettingsOffer() {
        #expect(FilenameTemplate.Token.allCases.map(\.placeholder) == ["{date}", "{time}", "{app}", "{window}", "{counter}"])
    }

    @Test func aPatternIsCutIntoTokensWordsAndSeparators() {
        #expect(FilenameTemplate.standard.pieces == [
            .word("OhMyShot"), .separator(" "), .token(.date), .separator(" "), .word("at"), .separator(" "), .token(.time),
        ])
        #expect(FilenameTemplate(pattern: "{time}{window}x{foo}").pieces == [.token(.time), .token(.window), .word("x{foo}")])
        #expect(FilenameTemplate(pattern: "").pieces.isEmpty)
    }

    @Test func piecesJoinBackIntoThePatternTheyCameFrom() {
        for pattern in ["OhMyShot {date} at {time}", "{app} – {counter} – {date}", "  a__b{", "{date", "界 {window}.{app}"] {
            #expect(FilenameTemplate(pieces: FilenameTemplate(pattern: pattern).pieces).pattern == pattern)
        }
    }
}
