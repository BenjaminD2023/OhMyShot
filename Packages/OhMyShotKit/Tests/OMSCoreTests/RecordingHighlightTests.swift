import Foundation
import Testing
@testable import OMSCore

@MainActor
struct RecordingHighlightSettingTests {
    @Test func anAreaIsOutlinedUnlessChosenOtherwise() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.recordingHighlight == .outline)
        for highlight in RecordingHighlight.allCases {
            settings.recordingHighlight = highlight
            #expect(SettingsStore(defaults: defaults).recordingHighlight == highlight)
        }
    }

    @Test func aChoiceNoLongerKnownFallsBackToTheOutline() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("flash", forKey: "recordingHighlight")
        #expect(SettingsStore(defaults: defaults).recordingHighlight == .outline)
    }
}
