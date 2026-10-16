import Foundation
import Testing
@testable import OMSCore

@MainActor
struct SnapSelectionSettingTests {
    @Test func selectionsDoNotSnapToTextUnlessAskedFor() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.snapSelectionToText)
        settings.snapSelectionToText = true
        #expect(SettingsStore(defaults: defaults).snapSelectionToText)
        settings.snapSelectionToText = false
        #expect(!SettingsStore(defaults: defaults).snapSelectionToText)
    }
}
