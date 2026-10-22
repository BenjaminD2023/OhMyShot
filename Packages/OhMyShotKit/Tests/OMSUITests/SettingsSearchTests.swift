import Foundation
import Testing
@testable import OMSUI

/// What the Settings sidebar's search finds, and where it lands.
@MainActor
struct SettingsSearchTests {
    /// Every row a pane draws is in its pane's search rows, so a search can't miss a row added later: the panes' source
    /// is read for the titles their rows are given.
    @Test func everyRowAPaneDrawsCanBeFound() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/OMSUI/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let pattern = /SettingsRow\(String\(localized: "((?:[^"\\]|\\.)*)", bundle: \.module\)/
        let drawn = try files.flatMap { file in try String(contentsOf: file, encoding: .utf8).matches(of: pattern).map { String($0.1) } }
        #expect(drawn.count > 40)
        let searched = Set(SettingsTab.allCases.flatMap { $0.searchRows.map(\.title) })
        for title in drawn {
            #expect(searched.contains(title), "\(title) can't be found")
        }
    }

    @Test func aSearchLandsOnTheRowThatHasWhatItFound() {
        #expect(SettingsTab.tools.row(matching: "shadow") == "Pins")
        #expect(SettingsTab.capture.row(matching: "shadow") == "Windows")
        #expect(SettingsTab.screenshots.row(matching: "JPEG") == "Format")
        #expect(SettingsTab.screenshots.row(matching: "ask for a name") == "File name")
        #expect(SettingsTab.quickAccess.row(matching: "bottom left") == "Position")
        #expect(SettingsTab.general.row(matching: "nothing like this") == nil)
    }

    @Test func eachPanesRowsHaveTitlesOfTheirOwn() {
        for tab in SettingsTab.allCases {
            let titles = tab.searchRows.map(\.title)
            #expect(Set(titles).count == titles.count, "\(tab) has two rows of one title")
        }
    }
}
