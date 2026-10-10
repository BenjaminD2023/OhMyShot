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

    /// After Capture Text: also show a card with what was copied. Off by default: the selection's
    /// highlight fading out says the text is on the clipboard.
    public var showTextResult: Bool {
        didSet { defaults.set(showTextResult, forKey: Key.showTextResult) }
    }

    /// The language text is translated into, as "zh-Hans" or "ja"; empty for automatic: the first
    /// preferred language the text is not already in.
    public var translationTarget: String {
        didSet { defaults.set(translationTarget, forKey: Key.translationTarget) }
    }

    /// Hold the screen still while selecting, so hover states and open menus can be captured.
    public var freezeScreen: Bool {
        didSet { defaults.set(freezeScreen, forKey: Key.freezeScreen) }
    }

    /// How long Self-Timer waits, in seconds, between choosing what to capture and capturing it.
    public var selfTimerDelay: Int {
        didSet { defaults.set(selfTimerDelay, forKey: Key.selfTimerDelay) }
    }

    /// The delays Self-Timer offers, in seconds.
    public static let selfTimerDelays = [2, 3, 5, 10, 15]

    /// Pins' corners, in points; 0 is square. Pins have their own look, apart from how captures are taken.
    public var pinCornerRadius: Double {
        didSet { defaults.set(pinCornerRadius, forKey: Key.pinCornerRadius) }
    }

    /// The corner radii Settings offers for pins, in points.
    public static let pinCornerRadii: ClosedRange<Double> = 0...24

    /// Whether pins cast a shadow.
    public var pinShadow: Bool {
        didSet { defaults.set(pinShadow, forKey: Key.pinShadow) }
    }

    /// Whether pins have a hairline edge, so a white picture still reads against a white window.
    public var pinBorder: Bool {
        didSet { defaults.set(pinBorder, forKey: Key.pinBorder) }
    }

    /// Whether pins are in new screenshots, as they are on screen.
    public var pinsAppearInCaptures: Bool {
        didSet { defaults.set(pinsAppearInCaptures, forKey: Key.pinsAppearInCaptures) }
    }

    /// The notation a picked color goes to the clipboard in.
    public var colorFormat: ColorFormat {
        didSet { defaults.set(colorFormat.rawValue, forKey: Key.colorFormat) }
    }

    /// What the ruler reads in; switched with Tab while measuring, and remembered.
    public var measureUnit: MeasureUnit {
        didSet { defaults.set(measureUnit.rawValue, forKey: Key.measureUnit) }
    }

    // MARK: Recording

    /// Frames per second recordings aim for; Low Power Mode records at 30 whatever this says.
    public var recordingFrameRate: Int {
        didSet { defaults.set(recordingFrameRate, forKey: Key.recordingFrameRate) }
    }

    /// The frame rates Settings offers.
    public static let recordingFrameRates = [30, 60]

    /// HEVC for every recording rather than only those too large for H.264: smaller files, fewer players.
    public var recordingPrefersHEVC: Bool {
        didSet { defaults.set(recordingPrefersHEVC, forKey: Key.recordingPrefersHEVC) }
    }

    /// Seconds counted down between choosing what to record and recording it; 0 starts at once.
    public var recordingCountdown: Int {
        didSet { defaults.set(recordingCountdown, forKey: Key.recordingCountdown) }
    }

    /// The countdowns Settings offers, in seconds.
    public static let recordingCountdowns = [0, 3, 5]

    /// Whether the pointer is in recordings.
    public var recordingShowsCursor: Bool {
        didSet { defaults.set(recordingShowsCursor, forKey: Key.recordingShowsCursor) }
    }

    /// Whether clicks show in recordings, as the system draws them. Toggled on the recording bar too.
    public var recordingShowsClicks: Bool {
        didSet { defaults.set(recordingShowsClicks, forKey: Key.recordingShowsClicks) }
    }

    /// Whether recordings take what the Mac plays. Toggled on the recording bar.
    public var recordingSystemAudio: Bool {
        didSet { defaults.set(recordingSystemAudio, forKey: Key.recordingSystemAudio) }
    }

    /// Whether recordings take the microphone. Toggled on the recording bar.
    public var recordingMicrophone: Bool {
        didSet { defaults.set(recordingMicrophone, forKey: Key.recordingMicrophone) }
    }

    /// The microphone recordings take, by its unique ID; empty for the system's default input.
    public var recordingMicrophoneID: String {
        didSet { defaults.set(recordingMicrophoneID, forKey: Key.recordingMicrophoneID) }
    }

    /// Whether the small bar with the time, Pause, Restart, Delete, and Stop shows by what is recorded.
    public var recordingShowsControls: Bool {
        didSet { defaults.set(recordingShowsControls, forKey: Key.recordingShowsControls) }
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
            Key.showTextResult: false,
            Key.translationTarget: "",
            // Frozen by default: a hover card or menu that closes as the pointer leaves it can still be
            // captured, since the screen is taken the moment the shortcut is pressed.
            Key.freezeScreen: true,
            Key.selfTimerDelay: 5,
            Key.pinCornerRadius: 12.0,
            Key.pinShadow: true,
            Key.pinBorder: true,
            Key.pinsAppearInCaptures: true,
            Key.colorFormat: ColorFormat.hex.rawValue,
            Key.measureUnit: MeasureUnit.points.rawValue,
            Key.recordingFrameRate: 60,
            Key.recordingPrefersHEVC: false,
            Key.recordingCountdown: 3,
            Key.recordingShowsCursor: true,
            Key.recordingShowsClicks: false,
            Key.recordingSystemAudio: false,
            Key.recordingMicrophone: false,
            Key.recordingMicrophoneID: "",
            Key.recordingShowsControls: true,
        ])
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        playSounds = defaults.bool(forKey: Key.playSounds)
        automationEnabled = defaults.bool(forKey: Key.automationEnabled)
        approvedAutomationCallers = defaults.stringArray(forKey: Key.approvedAutomationCallers) ?? []
        exportDirectory = defaults.string(forKey: Key.exportDirectory).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.desktopDirectory
        freezeScreen = defaults.bool(forKey: Key.freezeScreen)
        let delay = defaults.integer(forKey: Key.selfTimerDelay)
        selfTimerDelay = Self.selfTimerDelays.contains(delay) ? delay : 5
        pinCornerRadius = min(max(defaults.double(forKey: Key.pinCornerRadius), Self.pinCornerRadii.lowerBound), Self.pinCornerRadii.upperBound)
        pinShadow = defaults.bool(forKey: Key.pinShadow)
        pinBorder = defaults.bool(forKey: Key.pinBorder)
        pinsAppearInCaptures = defaults.bool(forKey: Key.pinsAppearInCaptures)
        colorFormat = defaults.string(forKey: Key.colorFormat).flatMap(ColorFormat.init(rawValue:)) ?? .hex
        measureUnit = defaults.string(forKey: Key.measureUnit).flatMap(MeasureUnit.init(rawValue:)) ?? .points
        let frameRate = defaults.integer(forKey: Key.recordingFrameRate)
        recordingFrameRate = Self.recordingFrameRates.contains(frameRate) ? frameRate : 60
        recordingPrefersHEVC = defaults.bool(forKey: Key.recordingPrefersHEVC)
        let countdown = defaults.integer(forKey: Key.recordingCountdown)
        recordingCountdown = Self.recordingCountdowns.contains(countdown) ? countdown : 3
        recordingShowsCursor = defaults.bool(forKey: Key.recordingShowsCursor)
        recordingShowsClicks = defaults.bool(forKey: Key.recordingShowsClicks)
        recordingSystemAudio = defaults.bool(forKey: Key.recordingSystemAudio)
        recordingMicrophone = defaults.bool(forKey: Key.recordingMicrophone)
        recordingMicrophoneID = defaults.string(forKey: Key.recordingMicrophoneID) ?? ""
        recordingShowsControls = defaults.bool(forKey: Key.recordingShowsControls)
        copyAfterCapture = defaults.bool(forKey: Key.copyAfterCapture)
        saveAfterCapture = defaults.bool(forKey: Key.saveAfterCapture)
        showQuickAccess = defaults.bool(forKey: Key.showQuickAccess)
        historyRetention = defaults.string(forKey: Key.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? .oneWeek
        showTextResult = defaults.bool(forKey: Key.showTextResult)
        translationTarget = defaults.string(forKey: Key.translationTarget) ?? ""
    }

    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let playSounds = "playSounds"
        static let automationEnabled = "automationEnabled"
        static let approvedAutomationCallers = "approvedAutomationCallers"
        static let exportDirectory = "exportDirectory"
        static let freezeScreen = "freezeScreen"
        static let selfTimerDelay = "selfTimerDelay"
        static let pinCornerRadius = "pinCornerRadius"
        static let pinShadow = "pinShadow"
        static let pinBorder = "pinBorder"
        static let pinsAppearInCaptures = "pinsAppearInCaptures"
        static let colorFormat = "colorFormat"
        static let measureUnit = "measureUnit"
        static let recordingFrameRate = "recordingFrameRate"
        static let recordingPrefersHEVC = "recordingPrefersHEVC"
        static let recordingCountdown = "recordingCountdown"
        static let recordingShowsCursor = "recordingShowsCursor"
        static let recordingShowsClicks = "recordingShowsClicks"
        static let recordingSystemAudio = "recordingSystemAudio"
        static let recordingMicrophone = "recordingMicrophone"
        static let recordingMicrophoneID = "recordingMicrophoneID"
        static let recordingShowsControls = "recordingShowsControls"
        static let copyAfterCapture = "copyAfterCapture"
        static let saveAfterCapture = "saveAfterCapture"
        static let showQuickAccess = "showQuickAccess"
        static let historyRetention = "historyRetention"
        static let showTextResult = "showTextResult"
        static let translationTarget = "translationTarget"
    }
}
