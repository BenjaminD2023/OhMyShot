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

    /// After a capture: also upload it to the default destination. Off by default, and only offered once a
    /// destination exists; with none the setting does nothing.
    public var uploadAfterCapture: Bool {
        didSet { defaults.set(uploadAfterCapture, forKey: Key.uploadAfterCapture) }
    }

    /// After an upload: put the link on the clipboard. On by default; with it off the link waits on the card
    /// until it is copied from there.
    public var copyLinkAfterUpload: Bool {
        didSet { defaults.set(copyLinkAfterUpload, forKey: Key.copyLinkAfterUpload) }
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

    /// How clicks show when Show Clicks is on: the system's circles, or accent rings.
    public var recordingClickStyle: ClickStyle {
        didSet { defaults.set(recordingClickStyle.rawValue, forKey: Key.recordingClickStyle) }
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

    /// Whether recordings show the keys pressed. Toggled on the recording bar.
    public var recordingShowsKeystrokes: Bool {
        didSet { defaults.set(recordingShowsKeystrokes, forKey: Key.recordingShowsKeystrokes) }
    }

    /// Which keys recordings show: every key, or shortcuts and function keys only.
    public var recordingKeystrokeMode: KeystrokeMode {
        didSet { defaults.set(recordingKeystrokeMode.rawValue, forKey: Key.recordingKeystrokeMode) }
    }

    /// Whether recordings show the camera in a bubble. Chosen on the recording bar.
    public var recordingCamera: Bool {
        didSet { defaults.set(recordingCamera, forKey: Key.recordingCamera) }
    }

    /// The camera recordings show, by its unique ID; empty for the system's default.
    public var recordingCameraID: String {
        didSet { defaults.set(recordingCameraID, forKey: Key.recordingCameraID) }
    }

    /// How the camera's bubble looks. Chosen from the camera's menu on the recording bar.
    public var recordingCameraStyle: CameraStyle {
        didSet {
            defaults.set(recordingCameraStyle.shape.rawValue, forKey: Key.recordingCameraShape)
            defaults.set(recordingCameraStyle.size.rawValue, forKey: Key.recordingCameraSize)
            defaults.set(recordingCameraStyle.mirrored, forKey: Key.recordingCameraMirrored)
        }
    }

    /// What recordings are kept as. Chosen on the recording bar.
    public var recordingOutput: RecordingOutput {
        didSet { defaults.set(recordingOutput.rawValue, forKey: Key.recordingOutput) }
    }

    /// Frames per second in a GIF: more is smoother and larger.
    public var recordingGIFFrameRate: Int {
        didSet { defaults.set(recordingGIFFrameRate, forKey: Key.recordingGIFFrameRate) }
    }

    /// The GIF frame rates Settings offers.
    public static let recordingGIFFrameRates = [10, 15, 20, 30]

    /// What clips saved from the replay keep of the sound buffered with them. Chosen in the menu bar's replay
    /// menu; remembered, though the replay itself stops when the app quits.
    public var replaySound: ReplaySound {
        didSet { defaults.set(replaySound.rawValue, forKey: Key.replaySound) }
    }

    /// Hide Desktop Icons: a picture of the wallpaper covers them, and does again after a relaunch.
    public var hidesDesktopIcons: Bool {
        didSet { defaults.set(hidesDesktopIcons, forKey: Key.hidesDesktopIcons) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.playSounds: true,
            Key.automationEnabled: true,
            Key.copyAfterCapture: true,
            Key.uploadAfterCapture: false,
            Key.copyLinkAfterUpload: true,
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
            Key.recordingClickStyle: ClickStyle.system.rawValue,
            Key.recordingSystemAudio: false,
            Key.recordingMicrophone: false,
            Key.recordingMicrophoneID: "",
            Key.recordingShowsControls: true,
            Key.recordingCamera: false,
            Key.recordingCameraID: "",
            Key.recordingCameraShape: CameraStyle.Shape.circle.rawValue,
            Key.recordingCameraSize: CameraStyle.Size.medium.rawValue,
            Key.recordingCameraMirrored: true,
            Key.recordingShowsKeystrokes: false,
            Key.recordingKeystrokeMode: KeystrokeMode.all.rawValue,
            Key.recordingOutput: RecordingOutput.video.rawValue,
            Key.recordingGIFFrameRate: 15,
            Key.replaySound: ReplaySound.all.rawValue,
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
        recordingClickStyle = defaults.string(forKey: Key.recordingClickStyle).flatMap(ClickStyle.init(rawValue:)) ?? .system
        recordingSystemAudio = defaults.bool(forKey: Key.recordingSystemAudio)
        recordingMicrophone = defaults.bool(forKey: Key.recordingMicrophone)
        recordingMicrophoneID = defaults.string(forKey: Key.recordingMicrophoneID) ?? ""
        recordingShowsControls = defaults.bool(forKey: Key.recordingShowsControls)
        recordingCamera = defaults.bool(forKey: Key.recordingCamera)
        recordingCameraID = defaults.string(forKey: Key.recordingCameraID) ?? ""
        recordingCameraStyle = CameraStyle(
            shape: defaults.string(forKey: Key.recordingCameraShape).flatMap(CameraStyle.Shape.init(rawValue:)) ?? .circle,
            size: defaults.string(forKey: Key.recordingCameraSize).flatMap(CameraStyle.Size.init(rawValue:)) ?? .medium,
            mirrored: defaults.bool(forKey: Key.recordingCameraMirrored)
        )
        recordingShowsKeystrokes = defaults.bool(forKey: Key.recordingShowsKeystrokes)
        recordingKeystrokeMode = defaults.string(forKey: Key.recordingKeystrokeMode).flatMap(KeystrokeMode.init(rawValue:)) ?? .all
        recordingOutput = defaults.string(forKey: Key.recordingOutput).flatMap(RecordingOutput.init(rawValue:)) ?? .video
        let gifFrameRate = defaults.integer(forKey: Key.recordingGIFFrameRate)
        recordingGIFFrameRate = Self.recordingGIFFrameRates.contains(gifFrameRate) ? gifFrameRate : 15
        replaySound = defaults.string(forKey: Key.replaySound).flatMap(ReplaySound.init(rawValue:)) ?? .all
        hidesDesktopIcons = defaults.bool(forKey: Key.hidesDesktopIcons)
        copyAfterCapture = defaults.bool(forKey: Key.copyAfterCapture)
        uploadAfterCapture = defaults.bool(forKey: Key.uploadAfterCapture)
        copyLinkAfterUpload = defaults.bool(forKey: Key.copyLinkAfterUpload)
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
        static let recordingClickStyle = "recordingClickStyle"
        static let recordingSystemAudio = "recordingSystemAudio"
        static let recordingMicrophone = "recordingMicrophone"
        static let recordingMicrophoneID = "recordingMicrophoneID"
        static let recordingShowsControls = "recordingShowsControls"
        static let recordingCamera = "recordingCamera"
        static let recordingCameraID = "recordingCameraID"
        static let recordingCameraShape = "recordingCameraShape"
        static let recordingCameraSize = "recordingCameraSize"
        static let recordingCameraMirrored = "recordingCameraMirrored"
        static let recordingShowsKeystrokes = "recordingShowsKeystrokes"
        static let recordingKeystrokeMode = "recordingKeystrokeMode"
        static let recordingOutput = "recordingOutput"
        static let recordingGIFFrameRate = "recordingGIFFrameRate"
        static let replaySound = "replaySound"
        static let copyAfterCapture = "copyAfterCapture"
        static let hidesDesktopIcons = "hidesDesktopIcons"
        static let uploadAfterCapture = "uploadAfterCapture"
        static let copyLinkAfterUpload = "copyLinkAfterUpload"
        static let saveAfterCapture = "saveAfterCapture"
        static let showQuickAccess = "showQuickAccess"
        static let historyRetention = "historyRetention"
        static let showTextResult = "showTextResult"
        static let translationTarget = "translationTarget"
    }
}
