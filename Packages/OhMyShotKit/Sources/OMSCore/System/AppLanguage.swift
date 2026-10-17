import Foundation

/// The language OhMyShot shows itself in: the system's choice by default, or one picked in Settings › General.
///
/// The languages offered are the ones the app bundle is translated into, so a language added to the string
/// catalogs (see Docs/localization.md) is offered here with nothing else to change. macOS reads the choice at
/// launch from the app's own `AppleLanguages` default, the one System Settings › General › Language & Region ›
/// Applications writes too, so a change shows once the app relaunches.
public enum AppLanguage {
    private static let key = "AppleLanguages"

    /// The codes of the languages the app is translated into ("en", "fr", "zh-Hans"…), English first, then by
    /// their names in their own language.
    public static var available: [String] {
        let codes = Bundle.main.localizations.filter { $0 != "Base" }
        return codes.sorted { a, b in
            if a == "en" || b == "en" { return a == "en" }
            return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
        }
    }

    /// The language picked for the app, or nil when it follows the system.
    public static var chosen: String? {
        get {
            guard let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:)),
                  let languages = domain[key] as? [String] else { return nil }
            return languages.first
        }
        set {
            _ = atLaunch
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// The choice the app launched with, to tell whether a relaunch is needed to show the one picked since.
    public static let atLaunch: String? = chosen

    /// A language's name in that language, as people look for it in a list: "Français", "日本語".
    public static func displayName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code) else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
