import Foundation
import Testing
@testable import OMSCore

@MainActor
struct TextRecognitionLineBreakSettingTests {
    @Test func theImagesLineBreaksAreKeptByDefault() throws {
        let suite = "TextRecognitionLineBreakSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SettingsStore(defaults: defaults).textRecognitionKeepsLineBreaks)
    }

    @Test func bothLineBreakChoicesPersistIndependentlyOfDisplayWrapping() throws {
        let suite = "TextRecognitionLineBreakSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        settings.textRecognitionKeepsLineBreaks = false
        let joined = SettingsStore(defaults: defaults)
        #expect(!joined.textRecognitionKeepsLineBreaks && joined.textRecognitionWrapsText)

        joined.textRecognitionWrapsText = false
        joined.textRecognitionKeepsLineBreaks = true
        let kept = SettingsStore(defaults: defaults)
        #expect(kept.textRecognitionKeepsLineBreaks && !kept.textRecognitionWrapsText)
    }
}
