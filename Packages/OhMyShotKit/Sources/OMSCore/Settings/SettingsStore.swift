import CoreFoundation
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

    /// After a recording: put its file on the clipboard. The four choices for recordings began as the ones for
    /// screenshots were when recordings first had their own, so no recording is kept differently than before.
    public var copyAfterRecording: Bool {
        didSet { defaults.set(copyAfterRecording, forKey: Key.copyAfterRecording) }
    }

    /// After a recording: show its Quick Access card.
    public var showRecordingQuickAccess: Bool {
        didSet { defaults.set(showRecordingQuickAccess, forKey: Key.showRecordingQuickAccess) }
    }

    /// After a recording: also save a copy to the export location without asking.
    public var saveAfterRecording: Bool {
        didSet { defaults.set(saveAfterRecording, forKey: Key.saveAfterRecording) }
    }

    /// After a recording: also upload it to the default destination; only offered once a destination exists.
    public var uploadAfterRecording: Bool {
        didSet { defaults.set(uploadAfterRecording, forKey: Key.uploadAfterRecording) }
    }

    /// How long captures stay in the history.
    public var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Key.historyRetention) }
    }

    /// Where saved captures go. Defaults to the Desktop, like macOS's own screenshots.
    public var exportDirectory: URL {
        didSet { defaults.set(exportDirectory.path(percentEncoded: false), forKey: Key.exportDirectory) }
    }

    /// The file format screenshots are saved, dragged out, and uploaded in. The history keeps every capture as PNG.
    public var screenshotFormat: ImageExporter.Format {
        didSet { defaults.set(screenshotFormat.rawValue, forKey: Key.screenshotFormat) }
    }

    /// JPEG's and HEIC's quality, 0.5 to 1.
    public var screenshotQuality: Double {
        didSet { defaults.set(screenshotQuality, forKey: Key.screenshotQuality) }
    }

    /// A screenshot taken on a Retina display is scaled down to 1× where it leaves the app.
    public var savesRetinaAtOneX: Bool {
        didSet { defaults.set(savesRetinaAtOneX, forKey: Key.savesRetinaAtOneX) }
    }

    /// A screenshot is converted to sRGB where it leaves the app; a wide-gamut display captures in Display P3.
    public var convertsToSRGB: Bool {
        didSet { defaults.set(convertsToSRGB, forKey: Key.convertsToSRGB) }
    }

    /// A screenshot gets a 1 px border where it leaves the app.
    public var addsBorder: Bool {
        didSet { defaults.set(addsBorder, forKey: Key.addsBorder) }
    }

    /// The pattern saved files are named from: `{date}`, `{time}`, `{app}`, `{window}`, and `{counter}`.
    public var fileNamePattern: String {
        didSet { defaults.set(fileNamePattern, forKey: Key.fileNamePattern) }
    }

    /// The number the next saved file takes for `{counter}`. It counts files saved, and starts at 1.
    public internal(set) var nextFileNumber: Int {
        didSet { defaults.set(nextFileNumber, forKey: Key.nextFileNumber) }
    }

    /// Saving asks for the file's name first, in a small panel that offers the one the pattern gives.
    public var asksForFileName: Bool {
        didSet { defaults.set(asksForFileName, forKey: Key.asksForFileName) }
    }

    /// What a screenshot puts on the clipboard: the picture alone, or the file as well.
    public var clipboardFormat: ClipboardFormat {
        didSet { defaults.set(clipboardFormat.rawValue, forKey: Key.clipboardFormat) }
    }

    /// After Capture Text: also show a card with what was copied. Off by default: the selection's
    /// highlight fading out says the text is on the clipboard.
    public var showTextResult: Bool {
        didSet { defaults.set(showTextResult, forKey: Key.showTextResult) }
    }

    /// The small copied-text/formula card stays by its selection unless a screen corner is chosen.
    public var textResultPosition: TextResultPosition {
        didSet { defaults.set(textResultPosition.rawValue, forKey: Key.textResultPosition) }
    }

    /// Seconds the copied-text/formula popup stays before closing; 0 keeps it open until closed.
    public var textResultCloseAfter: Int {
        didSet { defaults.set(textResultCloseAfter, forKey: Key.textResultCloseAfter) }
    }

    /// Popup close delays in seconds; the one-second default stays separate from Quick Access cards.
    public static let textResultCloseDelays = [0, 1, 2, 3, 5, 10, 20, 30, 60]

    /// Capture Text and new Recognized Text windows keep the image's detected line breaks by default.
    /// A window's line-break choice changes only that window, without changing this saved default.
    public var textRecognitionKeepsLineBreaks: Bool {
        didSet { defaults.set(textRecognitionKeepsLineBreaks, forKey: Key.textRecognitionKeepsLineBreaks) }
    }

    /// Whether recognized text wraps to the window's width by default. Each Recognized Text window
    /// takes this value when it opens and can change its own wrapping without changing the default.
    public var textRecognitionWrapsText: Bool {
        didSet { defaults.set(textRecognitionWrapsText, forKey: Key.textRecognitionWrapsText) }
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

    /// Whether screenshots show the pointer, where it was when they were taken. Off by default, as macOS's own are.
    public var screenshotShowsCursor: Bool {
        didSet { defaults.set(screenshotShowsCursor, forKey: Key.screenshotShowsCursor) }
    }

    /// The magnifier at the capture target before the first press; Small leaves more of the screen visible.
    public var captureLoupeSize: CaptureLoupeSize {
        didSet { defaults.set(captureLoupeSize.rawValue, forKey: Key.captureLoupeSize) }
    }

    /// How much the centered screenshot and annotation picker enlarges device pixels.
    public var captureLoupeMagnification: CaptureLoupeMagnification {
        didSet { defaults.set(captureLoupeMagnification.rawValue, forKey: Key.captureLoupeMagnification) }
    }

    /// The shape Shift keeps while an area is dragged out, as "16:9"; empty for a square.
    public var areaShape: String {
        didSet { defaults.set(areaShape, forKey: Key.areaShape) }
    }

    /// The shape Shift keeps, or nil for a square.
    public var areaRatio: AspectRatio? {
        AspectRatio(label: areaShape)
    }

    /// On a frozen screen, the edges of a selection snap to the blocks of text near them. Off by default: it
    /// pulls edges as the pointer passes, which only a person who wants it should have to put up with.
    public var snapSelectionToText: Bool {
        didSet { defaults.set(snapSelectionToText, forKey: Key.snapSelectionToText) }
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

    /// Copies a color with a modifier-click before selecting an area, or while picking colors.
    public var colorCopyGesture: ColorCopyGesture {
        didSet { defaults.set(colorCopyGesture.rawValue, forKey: Key.colorCopyGesture) }
    }

    /// What the ruler reads in; switched with Tab while measuring, and remembered.
    public var measureUnit: MeasureUnit {
        didSet { defaults.set(measureUnit.rawValue, forKey: Key.measureUnit) }
    }

    /// How readily the ruler detects pixel boundaries; adjusted while measuring and remembered.
    public var measureTolerance: MeasureTolerance {
        didSet { defaults.set(measureTolerance.rawValue, forKey: Key.measureTolerance) }
    }

    /// Whether drawn measurement boxes shrink to the content they enclose.
    public var measureSnapsToContent: Bool {
        didSet { defaults.set(measureSnapsToContent, forKey: Key.measureSnapsToContent) }
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

    /// How an area being recorded shows on screen: outlined, the rest of the display dimmed, or framed in red.
    public var recordingHighlight: RecordingHighlight {
        didSet { defaults.set(recordingHighlight.rawValue, forKey: Key.recordingHighlight) }
    }

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

    /// Whether a Studio recording writes down the keys pressed even when the bar's Show Keystrokes is off, so
    /// Studio can show them afterwards. Which keys is the Keystrokes choice above.
    public var recordingKeepsKeysForStudio: Bool {
        didSet { defaults.set(recordingKeepsKeysForStudio, forKey: Key.recordingKeepsKeysForStudio) }
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

    /// Window screenshots keep the window's shadow, as macOS's do.
    public var windowShadow: Bool {
        didSet { defaults.set(windowShadow, forKey: Key.windowShadow) }
    }

    /// What window screenshots are put on; Shift held as the window is clicked takes it the other way round.
    public var windowBackground: WindowBackground {
        didSet { defaults.set(windowBackground.rawValue, forKey: Key.windowBackground) }
    }

    /// All-In-One opens with the area it last captured, framed to adjust or take again.
    public var allInOneRemembersArea: Bool {
        didSet {
            defaults.set(allInOneRemembersArea, forKey: Key.allInOneRemembersArea)
            if !allInOneRemembersArea { allInOneArea = nil }
        }
    }

    /// The area All-In-One last captured, kept across launches.
    public var allInOneArea: RememberedArea? {
        didSet { defaults.set(allInOneArea.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.allInOneArea) }
    }

    // MARK: Quick Access

    /// The corner Quick Access cards stack in.
    public var quickAccessCorner: QuickAccessCorner {
        didSet { defaults.set(quickAccessCorner.rawValue, forKey: Key.quickAccessCorner) }
    }

    /// How large Quick Access cards are.
    public var quickAccessSize: QuickAccessSize {
        didSet { defaults.set(quickAccessSize.rawValue, forKey: Key.quickAccessSize) }
    }

    /// Quick Access goes to the display with the pointer. Off by default: the cards stay on the display the
    /// capture was taken on.
    public var quickAccessOnPointerDisplay: Bool {
        didSet { defaults.set(quickAccessOnPointerDisplay, forKey: Key.quickAccessOnPointerDisplay) }
    }

    /// Seconds a Quick Access card stays before it closes by itself; 3 by default, or 0 to keep cards until
    /// they are closed.
    public var quickAccessCloseAfter: Int {
        didSet { defaults.set(quickAccessCloseAfter, forKey: Key.quickAccessCloseAfter) }
    }

    /// The delays Settings offers for closing cards, in seconds; 0 is never.
    public static let quickAccessCloseDelays = [0, 1, 2, 3, 5, 10, 20, 30, 60]

    /// What a card does when its time is up.
    public var quickAccessCloseAction: QuickAccessCloseAction {
        didSet { defaults.set(quickAccessCloseAction.rawValue, forKey: Key.quickAccessCloseAction) }
    }

    /// The Quick Access settings together, as the cards read them.
    public var quickAccessPreferences: QuickAccessPreferences {
        QuickAccessPreferences(
            corner: quickAccessCorner, size: quickAccessSize, onPointerDisplay: quickAccessOnPointerDisplay,
            closeAfter: quickAccessCloseAfter, closeAction: quickAccessCloseAction
        )
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
            Key.screenshotFormat: ImageExporter.Format.png.rawValue,
            Key.screenshotQuality: ScreenshotOutput.standardQuality,
            Key.savesRetinaAtOneX: false,
            Key.convertsToSRGB: false,
            Key.addsBorder: false,
            Key.fileNamePattern: FilenameTemplate.standard.pattern,
            Key.nextFileNumber: 1,
            Key.asksForFileName: false,
            Key.clipboardFormat: ClipboardFormat.pictureOnly.rawValue,
            Key.showQuickAccess: true,
            Key.historyRetention: HistoryRetention.oneWeek.rawValue,
            Key.showTextResult: false,
            Key.textResultPosition: TextResultPosition.belowSelection.rawValue,
            Key.textResultCloseAfter: 1,
            Key.textRecognitionKeepsLineBreaks: true,
            Key.textRecognitionWrapsText: true,
            Key.translationTarget: "",
            // Frozen by default: a hover card or menu that closes as the pointer leaves it can still be
            // captured, since the screen is taken the moment the shortcut is pressed.
            Key.freezeScreen: true,
            Key.screenshotShowsCursor: false,
            Key.captureLoupeSize: CaptureLoupeSize.small.rawValue,
            Key.captureLoupeMagnification: CaptureLoupeMagnification.four.rawValue,
            Key.areaShape: "",
            Key.snapSelectionToText: false,
            Key.allInOneRemembersArea: true,
            Key.windowShadow: true,
            Key.selfTimerDelay: 5,
            Key.pinCornerRadius: 12.0,
            Key.pinShadow: true,
            Key.pinBorder: true,
            Key.pinsAppearInCaptures: true,
            Key.colorFormat: ColorFormat.hex.rawValue,
            Key.colorCopyGesture: ColorCopyGesture.option.rawValue,
            Key.measureUnit: MeasureUnit.points.rawValue,
            Key.measureTolerance: MeasureTolerance.medium.rawValue,
            Key.measureSnapsToContent: true,
            Key.recordingFrameRate: 60,
            Key.recordingPrefersHEVC: false,
            Key.recordingCountdown: 3,
            Key.recordingHighlight: RecordingHighlight.outline.rawValue,
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
            // Off: what is typed is kept only when asked for.
            Key.recordingKeepsKeysForStudio: false,
            Key.recordingOutput: RecordingOutput.video.rawValue,
            Key.recordingGIFFrameRate: 15,
            Key.replaySound: ReplaySound.all.rawValue,
            Key.quickAccessCorner: QuickAccessCorner.bottomLeft.rawValue,
            Key.quickAccessSize: QuickAccessSize.medium.rawValue,
            Key.quickAccessOnPointerDisplay: false,
            Key.quickAccessCloseAfter: 3,
            Key.quickAccessCloseAction: QuickAccessCloseAction.close.rawValue,
        ])
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        playSounds = defaults.bool(forKey: Key.playSounds)
        automationEnabled = defaults.bool(forKey: Key.automationEnabled)
        approvedAutomationCallers = defaults.stringArray(forKey: Key.approvedAutomationCallers) ?? []
        exportDirectory = defaults.string(forKey: Key.exportDirectory).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.desktopDirectory
        freezeScreen = defaults.bool(forKey: Key.freezeScreen)
        screenshotShowsCursor = defaults.bool(forKey: Key.screenshotShowsCursor)
        captureLoupeSize = defaults.string(forKey: Key.captureLoupeSize).flatMap(CaptureLoupeSize.init(rawValue:)) ?? .small
        captureLoupeMagnification = defaults.string(forKey: Key.captureLoupeMagnification).flatMap(CaptureLoupeMagnification.init(rawValue:)) ?? .four
        // Only a shape the picker lists is kept; anything else, a square included, is a square.
        let shape = defaults.string(forKey: Key.areaShape) ?? ""
        areaShape = AspectRatio.presets.dropFirst().contains { $0.label == shape } ? shape : ""
        snapSelectionToText = defaults.bool(forKey: Key.snapSelectionToText)
        let delay = defaults.integer(forKey: Key.selfTimerDelay)
        selfTimerDelay = Self.selfTimerDelays.contains(delay) ? delay : 5
        pinCornerRadius = min(max(defaults.double(forKey: Key.pinCornerRadius), Self.pinCornerRadii.lowerBound), Self.pinCornerRadii.upperBound)
        pinShadow = defaults.bool(forKey: Key.pinShadow)
        pinBorder = defaults.bool(forKey: Key.pinBorder)
        pinsAppearInCaptures = defaults.bool(forKey: Key.pinsAppearInCaptures)
        colorFormat = defaults.string(forKey: Key.colorFormat).flatMap(ColorFormat.init(rawValue:)) ?? .hex
        colorCopyGesture = defaults.string(forKey: Key.colorCopyGesture).flatMap(ColorCopyGesture.init(rawValue:)) ?? .option
        measureUnit = defaults.string(forKey: Key.measureUnit).flatMap(MeasureUnit.init(rawValue:)) ?? .points
        measureTolerance = defaults.string(forKey: Key.measureTolerance).flatMap(MeasureTolerance.init(rawValue:)) ?? .medium
        measureSnapsToContent = defaults.bool(forKey: Key.measureSnapsToContent)
        let frameRate = defaults.integer(forKey: Key.recordingFrameRate)
        recordingFrameRate = Self.recordingFrameRates.contains(frameRate) ? frameRate : 60
        recordingPrefersHEVC = defaults.bool(forKey: Key.recordingPrefersHEVC)
        let countdown = defaults.integer(forKey: Key.recordingCountdown)
        recordingCountdown = Self.recordingCountdowns.contains(countdown) ? countdown : 3
        recordingHighlight = defaults.string(forKey: Key.recordingHighlight).flatMap(RecordingHighlight.init(rawValue:)) ?? .outline
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
        recordingKeepsKeysForStudio = defaults.bool(forKey: Key.recordingKeepsKeysForStudio)
        recordingOutput = defaults.string(forKey: Key.recordingOutput).flatMap(RecordingOutput.init(rawValue:)) ?? .video
        let gifFrameRate = defaults.integer(forKey: Key.recordingGIFFrameRate)
        recordingGIFFrameRate = Self.recordingGIFFrameRates.contains(gifFrameRate) ? gifFrameRate : 15
        replaySound = defaults.string(forKey: Key.replaySound).flatMap(ReplaySound.init(rawValue:)) ?? .all
        hidesDesktopIcons = defaults.bool(forKey: Key.hidesDesktopIcons)
        allInOneRemembersArea = defaults.bool(forKey: Key.allInOneRemembersArea)
        windowShadow = defaults.bool(forKey: Key.windowShadow)
        windowBackground = defaults.string(forKey: Key.windowBackground).flatMap(WindowBackground.init(rawValue:)) ?? .asScreenshots
        allInOneArea = defaults.data(forKey: Key.allInOneArea).flatMap { try? JSONDecoder().decode(RememberedArea.self, from: $0) }
        quickAccessCorner = defaults.string(forKey: Key.quickAccessCorner).flatMap(QuickAccessCorner.init(rawValue:)) ?? .bottomLeft
        quickAccessSize = defaults.string(forKey: Key.quickAccessSize).flatMap(QuickAccessSize.init(rawValue:)) ?? .medium
        quickAccessOnPointerDisplay = defaults.bool(forKey: Key.quickAccessOnPointerDisplay)
        let closeAfter = defaults.object(forKey: Key.quickAccessCloseAfter) as? Int ?? 3
        quickAccessCloseAfter = Self.quickAccessCloseDelays.contains(closeAfter) ? closeAfter : 3
        quickAccessCloseAction = defaults.string(forKey: Key.quickAccessCloseAction).flatMap(QuickAccessCloseAction.init(rawValue:)) ?? .close
        copyAfterCapture = defaults.bool(forKey: Key.copyAfterCapture)
        uploadAfterCapture = defaults.bool(forKey: Key.uploadAfterCapture)
        copyLinkAfterUpload = defaults.bool(forKey: Key.copyLinkAfterUpload)
        saveAfterCapture = defaults.bool(forKey: Key.saveAfterCapture)
        screenshotFormat = defaults.string(forKey: Key.screenshotFormat).flatMap(ImageExporter.Format.init(rawValue:)) ?? .png
        let quality = defaults.double(forKey: Key.screenshotQuality)
        screenshotQuality = min(max(quality, ScreenshotOutput.qualities.lowerBound), ScreenshotOutput.qualities.upperBound)
        savesRetinaAtOneX = defaults.bool(forKey: Key.savesRetinaAtOneX)
        convertsToSRGB = defaults.bool(forKey: Key.convertsToSRGB)
        addsBorder = defaults.bool(forKey: Key.addsBorder)
        fileNamePattern = defaults.string(forKey: Key.fileNamePattern) ?? FilenameTemplate.standard.pattern
        nextFileNumber = max(defaults.integer(forKey: Key.nextFileNumber), 1)
        asksForFileName = defaults.bool(forKey: Key.asksForFileName)
        clipboardFormat = defaults.string(forKey: Key.clipboardFormat).flatMap(ClipboardFormat.init(rawValue:)) ?? .pictureOnly
        showQuickAccess = defaults.bool(forKey: Key.showQuickAccess)
        copyAfterRecording = Self.recordingChoice(Key.copyAfterRecording, startingAs: Key.copyAfterCapture, in: defaults)
        showRecordingQuickAccess = Self.recordingChoice(Key.showRecordingQuickAccess, startingAs: Key.showQuickAccess, in: defaults)
        saveAfterRecording = Self.recordingChoice(Key.saveAfterRecording, startingAs: Key.saveAfterCapture, in: defaults)
        uploadAfterRecording = Self.recordingChoice(Key.uploadAfterRecording, startingAs: Key.uploadAfterCapture, in: defaults)
        historyRetention = defaults.string(forKey: Key.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? .oneWeek
        showTextResult = defaults.bool(forKey: Key.showTextResult)
        textResultPosition = defaults.string(forKey: Key.textResultPosition).flatMap(TextResultPosition.init(rawValue:)) ?? .belowSelection
        // Invalid types must not become 0 (Never), as integer(forKey:) would make an unreadable string.
        let storedTextResultCloseAfter = defaults.object(forKey: Key.textResultCloseAfter) as? NSNumber
        let textResultDelay = storedTextResultCloseAfter.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 as? Int } ?? 1
        textResultCloseAfter = Self.textResultCloseDelays.contains(textResultDelay) ? textResultDelay : 1
        textRecognitionKeepsLineBreaks = defaults.bool(forKey: Key.textRecognitionKeepsLineBreaks)
        textRecognitionWrapsText = defaults.bool(forKey: Key.textRecognitionWrapsText)
        translationTarget = defaults.string(forKey: Key.translationTarget) ?? ""
    }

    /// A recording's choice: its own once it has one, else the choice for screenshots as it stands now, kept from then
    /// on. It is not registered as a default, since a default would stand in for the screenshots' value.
    private static func recordingChoice(_ key: String, startingAs screenshotKey: String, in defaults: UserDefaults) -> Bool {
        if let own = defaults.object(forKey: key) as? Bool { return own }
        let value = defaults.bool(forKey: screenshotKey)
        defaults.set(value, forKey: key)
        return value
    }

    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let playSounds = "playSounds"
        static let automationEnabled = "automationEnabled"
        static let approvedAutomationCallers = "approvedAutomationCallers"
        static let exportDirectory = "exportDirectory"
        static let freezeScreen = "freezeScreen"
        static let screenshotShowsCursor = "screenshotShowsCursor"
        static let captureLoupeSize = "captureLoupeSize"
        static let captureLoupeMagnification = "captureLoupeMagnification"
        static let areaShape = "areaShape"
        static let snapSelectionToText = "snapSelectionToText"
        static let selfTimerDelay = "selfTimerDelay"
        static let pinCornerRadius = "pinCornerRadius"
        static let pinShadow = "pinShadow"
        static let pinBorder = "pinBorder"
        static let pinsAppearInCaptures = "pinsAppearInCaptures"
        static let colorFormat = "colorFormat"
        static let colorCopyGesture = "colorCopyGesture"
        static let measureUnit = "measureUnit"
        static let measureTolerance = "measureTolerance"
        static let measureSnapsToContent = "measureSnapsToContent"
        static let recordingFrameRate = "recordingFrameRate"
        static let recordingPrefersHEVC = "recordingPrefersHEVC"
        static let recordingCountdown = "recordingCountdown"
        static let recordingHighlight = "recordingHighlight"
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
        static let recordingKeepsKeysForStudio = "recordingKeepsKeysForStudio"
        static let recordingOutput = "recordingOutput"
        static let recordingGIFFrameRate = "recordingGIFFrameRate"
        static let replaySound = "replaySound"
        static let copyAfterCapture = "copyAfterCapture"
        static let hidesDesktopIcons = "hidesDesktopIcons"
        static let allInOneRemembersArea = "allInOneRemembersArea"
        static let windowShadow = "windowShadow"
        static let windowBackground = "windowBackground"
        static let allInOneArea = "allInOneArea"
        static let quickAccessCorner = "quickAccessCorner"
        static let quickAccessSize = "quickAccessSize"
        static let quickAccessOnPointerDisplay = "quickAccessOnPointerDisplay"
        static let quickAccessCloseAfter = "quickAccessCloseAfter"
        static let quickAccessCloseAction = "quickAccessCloseAction"
        static let uploadAfterCapture = "uploadAfterCapture"
        static let copyLinkAfterUpload = "copyLinkAfterUpload"
        static let saveAfterCapture = "saveAfterCapture"
        static let screenshotFormat = "screenshotFormat"
        static let screenshotQuality = "screenshotQuality"
        static let savesRetinaAtOneX = "savesRetinaAtOneX"
        static let convertsToSRGB = "convertsToSRGB"
        static let addsBorder = "addsBorder"
        static let fileNamePattern = "fileNamePattern"
        static let nextFileNumber = "nextFileNumber"
        static let asksForFileName = "asksForFileName"
        static let clipboardFormat = "clipboardFormat"
        static let showQuickAccess = "showQuickAccess"
        static let copyAfterRecording = "copyAfterRecording"
        static let showRecordingQuickAccess = "showRecordingQuickAccess"
        static let saveAfterRecording = "saveAfterRecording"
        static let uploadAfterRecording = "uploadAfterRecording"
        static let historyRetention = "historyRetention"
        static let showTextResult = "showTextResult"
        static let textResultPosition = "textResultPosition"
        static let textResultCloseAfter = "textResultCloseAfter"
        static let textRecognitionKeepsLineBreaks = "textRecognitionKeepsLineBreaks"
        static let textRecognitionWrapsText = "textRecognitionWrapsText"
        static let translationTarget = "translationTarget"
    }
}
