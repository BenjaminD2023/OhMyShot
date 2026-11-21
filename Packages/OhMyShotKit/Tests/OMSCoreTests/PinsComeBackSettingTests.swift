import Foundation
import Testing
@testable import OMSCore

@MainActor
struct PinsComeBackSettingTests {
    @Test func untilChosenItFollowsKeepCaptures() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.pinsComeBack)
        settings.historyRetention = .never
        #expect(!settings.pinsComeBack)
        #expect(!SettingsStore(defaults: defaults).pinsComeBack)
        settings.historyRetention = .oneDay
        #expect(settings.pinsComeBack)
    }

    @Test func aChoiceStaysWhateverKeepCapturesSays() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        settings.historyRetention = .never
        settings.pinsComeBack = true
        #expect(settings.pinsComeBack)
        #expect(SettingsStore(defaults: defaults).pinsComeBack)
        settings.historyRetention = .oneMonth
        settings.pinsComeBack = false
        #expect(!SettingsStore(defaults: defaults).pinsComeBack)

        // Reset forgets the choice, so it follows Keep captures again.
        settings.resetToDefaults()
        #expect(settings.pinsComeBack)
        settings.historyRetention = .never
        #expect(!settings.pinsComeBack)
    }
}
