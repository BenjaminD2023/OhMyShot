/// The panes of Settings. Here rather than with the Settings window, because an `open-settings?tab=` URL names one
/// and the URL is read here, where what it may name is decided once.
public enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case capture
    case screenshots
    case quickAccess
    case recording
    case text
    case tools
    case sharing
    case shortcuts
    case automation
    case permissions
    case about

    /// The pane an `open-settings?tab=` URL names: ours as they are, in any case, and CleanShot's names mapped onto
    /// ours. Anything else, or no tab at all, is General.
    public init(urlTab: String?) {
        let name = urlTab?.lowercased() ?? ""
        if let tab = SettingsTab(rawValue: name) ?? Self.allCases.first(where: { $0.rawValue.lowercased() == name }) {
            self = tab
            return
        }
        switch name {
        // Backgrounds are set where what happens after a screenshot is.
        case "wallpaper": self = .screenshots
        // Pins, Pick Color, and Measure; reading text has a pane of its own.
        case "annotate": self = .tools
        // CleanShot's Cloud tab is where uploads are set up.
        case "cloud": self = .sharing
        // The URL scheme is set up there.
        case "advanced": self = .automation
        default: self = .general
        }
    }
}
