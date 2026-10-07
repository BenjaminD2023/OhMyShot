import Foundation
import Observation

/// User preferences, persisted in the app's defaults domain. Debug and release builds have separate
/// domains because their bundle identifiers differ.
@MainActor
@Observable
public final class SettingsStore {
    public var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    public var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Key.playSounds) }
    }

    /// Whether other apps may send `ohmyshot://` commands at all.
    public var automationEnabled: Bool {
        didSet { defaults.set(automationEnabled, forKey: Key.automationEnabled) }
    }

    /// Bundle identifiers the user allowed to send commands, or `command-line` for scripts.
    public var approvedAutomationCallers: [String] {
        didSet { defaults.set(approvedAutomationCallers, forKey: Key.approvedAutomationCallers) }
    }

    /// After a capture: put it on the clipboard.
    public var copyAfterCapture: Bool {
        didSet { defaults.set(copyAfterCapture, forKey: Key.copyAfterCapture) }
    }

    /// After a capture: also save a copy to the export location without asking. Off by default;
    /// captures go to the history and are saved from their Quick Access card.
    public var saveAfterCapture: Bool {
        didSet { defaults.set(saveAfterCapture, forKey: Key.saveAfterCapture) }
    }

    /// After a capture: show its Quick Access card.
    public var showQuickAccess: Bool {
        didSet { defaults.set(showQuickAccess, forKey: Key.showQuickAccess) }
    }

    /// How long captures stay in the history.
    public var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Key.historyRetention) }
    }

    /// Where saved captures go. Defaults to the Desktop, like macOS's own screenshots.
    public var exportDirectory: URL {
        didSet { defaults.set(exportDirectory.path(percentEncoded: false), forKey: Key.exportDirectory) }
    }

    /// Hold the screen still while selecting, so hover states and open menus can be captured.
    public var freezeScreen: Bool {
        didSet { defaults.set(freezeScreen, forKey: Key.freezeScreen) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.playSounds: true,
            Key.automationEnabled: true,
            Key.copyAfterCapture: true,
            Key.saveAfterCapture: false,
            Key.showQuickAccess: true,
            Key.historyRetention: HistoryRetention.oneWeek.rawValue,
        ])
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        playSounds = defaults.bool(forKey: Key.playSounds)
        automationEnabled = defaults.bool(forKey: Key.automationEnabled)
        approvedAutomationCallers = defaults.stringArray(forKey: Key.approvedAutomationCallers) ?? []
        exportDirectory = defaults.string(forKey: Key.exportDirectory).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.desktopDirectory
        freezeScreen = defaults.bool(forKey: Key.freezeScreen)
        copyAfterCapture = defaults.bool(forKey: Key.copyAfterCapture)
        saveAfterCapture = defaults.bool(forKey: Key.saveAfterCapture)
        showQuickAccess = defaults.bool(forKey: Key.showQuickAccess)
        historyRetention = defaults.string(forKey: Key.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? .oneWeek
    }

    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let playSounds = "playSounds"
        static let automationEnabled = "automationEnabled"
        static let approvedAutomationCallers = "approvedAutomationCallers"
        static let exportDirectory = "exportDirectory"
        static let freezeScreen = "freezeScreen"
        static let copyAfterCapture = "copyAfterCapture"
        static let saveAfterCapture = "saveAfterCapture"
        static let showQuickAccess = "showQuickAccess"
        static let historyRetention = "historyRetention"
    }
}
