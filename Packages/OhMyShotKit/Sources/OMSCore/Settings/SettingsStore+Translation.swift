import Foundation

extension SettingsStore {
    /// The language text is translated into, as a language: `translationTarget` read, nil for automatic.
    public var translationLanguage: Locale.Language? {
        translationTarget.isEmpty ? nil : Locale.Language(identifier: translationTarget)
    }
}
