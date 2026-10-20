import Foundation
import Testing
@testable import OMSCore

@MainActor
struct TextResultPositionSettingTests {
    @Test func newAndUnknownPreferencesKeepTheCardByItsSelection() throws {
        let suite = "TextResultPositionTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsStore(defaults: defaults).textResultPosition == .belowSelection)
        defaults.set("future-position", forKey: "textResultPosition")
        #expect(SettingsStore(defaults: defaults).textResultPosition == .belowSelection)
    }

    @Test func eachChoicePersistsWithoutEnablingTheOptionalPopup() throws {
        let suite = "TextResultPositionTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        for position in TextResultPosition.allCases {
            settings.textResultPosition = position
            let reopened = SettingsStore(defaults: defaults)
            #expect(reopened.textResultPosition == position)
            #expect(!reopened.showTextResult)
        }
    }
}
