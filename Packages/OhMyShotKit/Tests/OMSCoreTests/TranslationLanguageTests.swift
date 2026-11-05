import Foundation
import Testing
@testable import OMSCore

/// The translation target setting, read as a language.
@MainActor
struct TranslationLanguageTests {
    @Test func emptyIsAutomaticAndAnIdentifierIsItsLanguage() throws {
        let name = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.translationLanguage == nil)
        settings.translationTarget = "zh-Hans"
        #expect(settings.translationLanguage == Locale.Language(identifier: "zh-Hans"))
        settings.translationTarget = ""
        #expect(settings.translationLanguage == nil)
    }
}
