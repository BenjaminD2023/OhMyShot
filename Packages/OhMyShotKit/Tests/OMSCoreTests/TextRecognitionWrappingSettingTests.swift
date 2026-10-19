import Foundation
import Testing
@testable import OMSCore

@MainActor
struct TextRecognitionWrappingSettingTests {
    @Test func recognizedTextWrapsByDefault() throws {
        let suite = "TextRecognitionWrappingSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SettingsStore(defaults: defaults).textRecognitionWrapsText)
    }

    @Test func wrappingPreferenceKeepsBothChoices() throws {
        let suite = "TextRecognitionWrappingSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        settings.textRecognitionWrapsText = false
        #expect(!SettingsStore(defaults: defaults).textRecognitionWrapsText)

        settings.textRecognitionWrapsText = true
        #expect(SettingsStore(defaults: defaults).textRecognitionWrapsText)
    }
}
