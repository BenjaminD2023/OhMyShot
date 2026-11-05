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

    /// Whether a release build looks for a newer version by itself, about once a day.
    public var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Key.checksForUpdates) }
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

    /// The small copied-text/formula card stands by its selection, or in the bottom-left corner of that display.
    public var textResultPosition: TextResultPosition {
        didSet { defaults.set(textResultPosition.rawValue, forKey: Key.textResultPosition) }
    }

    /// Seconds a copied-text/formula card the user asked for (Show the copied text) stays before closing; 0 keeps
    /// it open until closed. Cards that say something went wrong keep at least their own time.
    public var textResultCloseAfter: Int {
        didSet { defaults.set(textResultCloseAfter, forKey: Key.textResultCloseAfter) }
    }

    /// The delays Settings offers for closing the text card, in seconds; 0 is never. Separate from Quick Access's.
    public static let textResultCloseDelays = [0, 1, 2, 3, 4, 5, 10, 20, 30, 60]

    /// What the card has always stayed: the default of `textResultCloseAfter`.
    public static let defaultTextResultCloseAfter = 4

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

    /// Capture Text and the Recognized Text window take the characters the app under the selection shows, through
    /// Accessibility, for the lines it shows alike (L0, Docs/ocr.md › Text from apps). Off by default: it needs
    /// Accessibility, asked for when it is turned on.
    public var readsAppText: Bool {
        didSet { defaults.set(readsAppText, forKey: Key.readsAppText) }
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

    /// How the capture overlay's magnifier shows the pixels at the pointer: magnified (the default) or at their own size.
    public var captureLoupeStyle: CaptureLoupeStyle {
        didSet { defaults.set(captureLoupeStyle.rawValue, forKey: Key.captureLoupeStyle) }
    }

    /// The actual-size lens's size; Small leaves more of the screen visible.
    public var captureLoupeSize: CaptureLoupeSize {
        didSet { defaults.set(captureLoupeSize.rawValue, forKey: Key.captureLoupeSize) }
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

    /// What the recording bar opens with: the last of Video and GIF chosen on it. Studio is never kept, so a take for
    /// Studio, which leaves the pointer and the camera out for Studio to draw, is never followed by another by mistake.
    public var recordingOutput: RecordingOutput {
        didSet {
            if recordingOutput == .studio {
                recordingOutput = oldValue
            } else {
                defaults.set(recordingOutput.rawValue, forKey: Key.recordingOutput)
            }
        }
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

    /// Seconds a Quick Access card stays before it closes by itself; 0, the default, keeps cards until they
    /// are closed.
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
        let registered: [Key: Any] = [
            .showMenuBarIcon: true,
            .playSounds: true,
            .checksForUpdates: true,
            .automationEnabled: true,
            .copyAfterCapture: true,
            .uploadAfterCapture: false,
            .copyLinkAfterUpload: true,
            .saveAfterCapture: false,
            .screenshotFormat: Default.screenshotFormat.rawValue,
            .screenshotQuality: ScreenshotOutput.standardQuality,
            .savesRetinaAtOneX: false,
            .convertsToSRGB: false,
            .addsBorder: false,
            .fileNamePattern: Default.fileNamePattern,
            .nextFileNumber: Default.nextFileNumber,
            .asksForFileName: false,
            .clipboardFormat: Default.clipboardFormat.rawValue,
            .showQuickAccess: true,
            .historyRetention: Default.historyRetention.rawValue,
            .showTextResult: false,
            .textResultPosition: Default.textResultPosition.rawValue,
            .textResultCloseAfter: Self.defaultTextResultCloseAfter,
            .textRecognitionKeepsLineBreaks: true,
            .textRecognitionWrapsText: true,
            .readsAppText: false,
            .translationTarget: Default.translationTarget,
            // Frozen by default: a hover card or menu that closes as the pointer leaves it can still be
            // captured, since the screen is taken the moment the shortcut is pressed.
            .freezeScreen: true,
            .screenshotShowsCursor: false,
            .captureLoupeStyle: Default.captureLoupeStyle.rawValue,
            .captureLoupeSize: Default.captureLoupeSize.rawValue,
            .areaShape: Default.areaShape,
            .snapSelectionToText: false,
            .allInOneRemembersArea: true,
            .windowShadow: true,
            .selfTimerDelay: Default.selfTimerDelay,
            .pinCornerRadius: 12.0,
            .pinShadow: true,
            .pinBorder: true,
            .pinsAppearInCaptures: true,
            .colorFormat: Default.colorFormat.rawValue,
            .measureUnit: Default.measureUnit.rawValue,
            .measureTolerance: Default.measureTolerance.rawValue,
            .measureSnapsToContent: true,
            .recordingFrameRate: Default.recordingFrameRate,
            .recordingPrefersHEVC: false,
            .recordingCountdown: Default.recordingCountdown,
            .recordingHighlight: Default.recordingHighlight.rawValue,
            .recordingShowsCursor: true,
            .recordingShowsClicks: false,
            .recordingClickStyle: Default.recordingClickStyle.rawValue,
            .recordingSystemAudio: false,
            .recordingMicrophone: false,
            .recordingMicrophoneID: Default.recordingMicrophoneID,
            .recordingShowsControls: true,
            .recordingCamera: false,
            .recordingCameraID: Default.recordingCameraID,
            .recordingCameraShape: Default.recordingCameraStyle.shape.rawValue,
            .recordingCameraSize: Default.recordingCameraStyle.size.rawValue,
            .recordingCameraMirrored: Default.recordingCameraStyle.mirrored,
            .recordingShowsKeystrokes: false,
            .recordingKeystrokeMode: Default.recordingKeystrokeMode.rawValue,
            // Off: what is typed is kept only when asked for.
            .recordingKeepsKeysForStudio: false,
            .recordingOutput: Default.recordingOutput.rawValue,
            .recordingGIFFrameRate: Default.recordingGIFFrameRate,
            .replaySound: Default.replaySound.rawValue,
            .quickAccessCorner: Default.quickAccessCorner.rawValue,
            .quickAccessSize: Default.quickAccessSize.rawValue,
            .quickAccessOnPointerDisplay: false,
            .quickAccessCloseAfter: Default.quickAccessCloseAfter,
            .quickAccessCloseAction: Default.quickAccessCloseAction.rawValue,
        ]
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: registered.map { ($0.key.rawValue, $0.value) }))
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        playSounds = defaults.bool(forKey: Key.playSounds)
        checksForUpdates = defaults.bool(forKey: Key.checksForUpdates)
        automationEnabled = defaults.bool(forKey: Key.automationEnabled)
        approvedAutomationCallers = defaults.stringArray(forKey: Key.approvedAutomationCallers) ?? []
        exportDirectory = defaults.string(forKey: Key.exportDirectory).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.desktopDirectory
        freezeScreen = defaults.bool(forKey: Key.freezeScreen)
        screenshotShowsCursor = defaults.bool(forKey: Key.screenshotShowsCursor)
        captureLoupeStyle = defaults.string(forKey: Key.captureLoupeStyle).flatMap(CaptureLoupeStyle.init(rawValue:)) ?? Default.captureLoupeStyle
        captureLoupeSize = defaults.string(forKey: Key.captureLoupeSize).flatMap(CaptureLoupeSize.init(rawValue:)) ?? Default.captureLoupeSize
        // Only a shape the picker lists is kept; anything else, a square included, is a square.
        let shape = defaults.string(forKey: Key.areaShape) ?? Default.areaShape
        areaShape = AspectRatio.presets.dropFirst().contains { $0.label == shape } ? shape : Default.areaShape
        snapSelectionToText = defaults.bool(forKey: Key.snapSelectionToText)
        let delay = defaults.integer(forKey: Key.selfTimerDelay)
        selfTimerDelay = Self.selfTimerDelays.contains(delay) ? delay : Default.selfTimerDelay
        pinCornerRadius = min(max(defaults.double(forKey: Key.pinCornerRadius), Self.pinCornerRadii.lowerBound), Self.pinCornerRadii.upperBound)
        pinShadow = defaults.bool(forKey: Key.pinShadow)
        pinBorder = defaults.bool(forKey: Key.pinBorder)
        pinsAppearInCaptures = defaults.bool(forKey: Key.pinsAppearInCaptures)
        colorFormat = defaults.string(forKey: Key.colorFormat).flatMap(ColorFormat.init(rawValue:)) ?? Default.colorFormat
        measureUnit = defaults.string(forKey: Key.measureUnit).flatMap(MeasureUnit.init(rawValue:)) ?? Default.measureUnit
        measureTolerance = defaults.string(forKey: Key.measureTolerance).flatMap(MeasureTolerance.init(rawValue:)) ?? Default.measureTolerance
        measureSnapsToContent = defaults.bool(forKey: Key.measureSnapsToContent)
        let frameRate = defaults.integer(forKey: Key.recordingFrameRate)
        recordingFrameRate = Self.recordingFrameRates.contains(frameRate) ? frameRate : Default.recordingFrameRate
        recordingPrefersHEVC = defaults.bool(forKey: Key.recordingPrefersHEVC)
        let countdown = defaults.integer(forKey: Key.recordingCountdown)
        recordingCountdown = Self.recordingCountdowns.contains(countdown) ? countdown : Default.recordingCountdown
        recordingHighlight = defaults.string(forKey: Key.recordingHighlight).flatMap(RecordingHighlight.init(rawValue:)) ?? Default.recordingHighlight
        recordingShowsCursor = defaults.bool(forKey: Key.recordingShowsCursor)
        recordingShowsClicks = defaults.bool(forKey: Key.recordingShowsClicks)
        recordingClickStyle = defaults.string(forKey: Key.recordingClickStyle).flatMap(ClickStyle.init(rawValue:)) ?? Default.recordingClickStyle
        recordingSystemAudio = defaults.bool(forKey: Key.recordingSystemAudio)
        recordingMicrophone = defaults.bool(forKey: Key.recordingMicrophone)
        recordingMicrophoneID = defaults.string(forKey: Key.recordingMicrophoneID) ?? Default.recordingMicrophoneID
        recordingShowsControls = defaults.bool(forKey: Key.recordingShowsControls)
        recordingCamera = defaults.bool(forKey: Key.recordingCamera)
        recordingCameraID = defaults.string(forKey: Key.recordingCameraID) ?? Default.recordingCameraID
        recordingCameraStyle = CameraStyle(
            shape: defaults.string(forKey: Key.recordingCameraShape).flatMap(CameraStyle.Shape.init(rawValue:)) ?? Default.recordingCameraStyle.shape,
            size: defaults.string(forKey: Key.recordingCameraSize).flatMap(CameraStyle.Size.init(rawValue:)) ?? Default.recordingCameraStyle.size,
            mirrored: defaults.bool(forKey: Key.recordingCameraMirrored)
        )
        recordingShowsKeystrokes = defaults.bool(forKey: Key.recordingShowsKeystrokes)
        recordingKeystrokeMode = defaults.string(forKey: Key.recordingKeystrokeMode).flatMap(KeystrokeMode.init(rawValue:)) ?? Default.recordingKeystrokeMode
        recordingKeepsKeysForStudio = defaults.bool(forKey: Key.recordingKeepsKeysForStudio)
        // Studio, kept before it was left out, opens as Video.
        recordingOutput = defaults.string(forKey: Key.recordingOutput).flatMap(RecordingOutput.init(rawValue:)).flatMap { $0 == .studio ? nil : $0 } ?? Default.recordingOutput
        let gifFrameRate = defaults.integer(forKey: Key.recordingGIFFrameRate)
        recordingGIFFrameRate = Self.recordingGIFFrameRates.contains(gifFrameRate) ? gifFrameRate : Default.recordingGIFFrameRate
        replaySound = defaults.string(forKey: Key.replaySound).flatMap(ReplaySound.init(rawValue:)) ?? Default.replaySound
        hidesDesktopIcons = defaults.bool(forKey: Key.hidesDesktopIcons)
        allInOneRemembersArea = defaults.bool(forKey: Key.allInOneRemembersArea)
        windowShadow = defaults.bool(forKey: Key.windowShadow)
        windowBackground = defaults.string(forKey: Key.windowBackground).flatMap(WindowBackground.init(rawValue:)) ?? .asScreenshots
        allInOneArea = defaults.data(forKey: Key.allInOneArea).flatMap { try? JSONDecoder().decode(RememberedArea.self, from: $0) }
        quickAccessCorner = defaults.string(forKey: Key.quickAccessCorner).flatMap(QuickAccessCorner.init(rawValue:)) ?? Default.quickAccessCorner
        quickAccessSize = defaults.string(forKey: Key.quickAccessSize).flatMap(QuickAccessSize.init(rawValue:)) ?? Default.quickAccessSize
        quickAccessOnPointerDisplay = defaults.bool(forKey: Key.quickAccessOnPointerDisplay)
        let closeAfter = defaults.integer(forKey: Key.quickAccessCloseAfter)
        quickAccessCloseAfter = Self.quickAccessCloseDelays.contains(closeAfter) ? closeAfter : Default.quickAccessCloseAfter
        quickAccessCloseAction = defaults.string(forKey: Key.quickAccessCloseAction).flatMap(QuickAccessCloseAction.init(rawValue:)) ?? Default.quickAccessCloseAction
        copyAfterCapture = defaults.bool(forKey: Key.copyAfterCapture)
        uploadAfterCapture = defaults.bool(forKey: Key.uploadAfterCapture)
        copyLinkAfterUpload = defaults.bool(forKey: Key.copyLinkAfterUpload)
        saveAfterCapture = defaults.bool(forKey: Key.saveAfterCapture)
        screenshotFormat = defaults.string(forKey: Key.screenshotFormat).flatMap(ImageExporter.Format.init(rawValue:)) ?? Default.screenshotFormat
        let quality = defaults.double(forKey: Key.screenshotQuality)
        screenshotQuality = min(max(quality, ScreenshotOutput.qualities.lowerBound), ScreenshotOutput.qualities.upperBound)
        savesRetinaAtOneX = defaults.bool(forKey: Key.savesRetinaAtOneX)
        convertsToSRGB = defaults.bool(forKey: Key.convertsToSRGB)
        addsBorder = defaults.bool(forKey: Key.addsBorder)
        fileNamePattern = defaults.string(forKey: Key.fileNamePattern) ?? Default.fileNamePattern
        nextFileNumber = max(defaults.integer(forKey: Key.nextFileNumber), Default.nextFileNumber)
        asksForFileName = defaults.bool(forKey: Key.asksForFileName)
        clipboardFormat = defaults.string(forKey: Key.clipboardFormat).flatMap(ClipboardFormat.init(rawValue:)) ?? Default.clipboardFormat
        showQuickAccess = defaults.bool(forKey: Key.showQuickAccess)
        copyAfterRecording = Self.recordingChoice(Key.copyAfterRecording, startingAs: Key.copyAfterCapture, in: defaults)
        showRecordingQuickAccess = Self.recordingChoice(Key.showRecordingQuickAccess, startingAs: Key.showQuickAccess, in: defaults)
        saveAfterRecording = Self.recordingChoice(Key.saveAfterRecording, startingAs: Key.saveAfterCapture, in: defaults)
        uploadAfterRecording = Self.recordingChoice(Key.uploadAfterRecording, startingAs: Key.uploadAfterCapture, in: defaults)
        historyRetention = defaults.string(forKey: Key.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? Default.historyRetention
        showTextResult = defaults.bool(forKey: Key.showTextResult)
        textResultPosition = defaults.string(forKey: Key.textResultPosition).flatMap(TextResultPosition.init(rawValue:)) ?? Default.textResultPosition
        // Invalid types must not become 0 (Never), as integer(forKey:) would make an unreadable string.
        let storedTextResultCloseAfter = defaults.object(forKey: Key.textResultCloseAfter) as? NSNumber
        let textResultDelay = storedTextResultCloseAfter.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 as? Int } ?? Self.defaultTextResultCloseAfter
        textResultCloseAfter = Self.textResultCloseDelays.contains(textResultDelay) ? textResultDelay : Self.defaultTextResultCloseAfter
        textRecognitionKeepsLineBreaks = defaults.bool(forKey: Key.textRecognitionKeepsLineBreaks)
        textRecognitionWrapsText = defaults.bool(forKey: Key.textRecognitionWrapsText)
        readsAppText = defaults.bool(forKey: Key.readsAppText)
        translationTarget = defaults.string(forKey: Key.translationTarget) ?? Default.translationTarget
    }

    /// Puts every choice back as a new install has it, as Settings › General › Reset does. What the app keeps rather
    /// than chooses stays: the next `{counter}` number (a file saved under a number already taken would replace
    /// it), the area All-In-One last took, whether the desktop icons are hidden (a cover window shows that, which the
    /// menu bar's toggle shows and hides together with it), and the apps allowed to send commands, which the
    /// Automation pane manages one by one. Shortcuts, destinations, the cloud model, and the language are kept
    /// elsewhere and stay too.
    public func resetToDefaults() {
        let kept: Set<Key> = [.nextFileNumber, .allInOneArea, .hidesDesktopIcons, .approvedAutomationCallers]
        for key in Key.allCases where !kept.contains(key) {
            defaults.removeObject(forKey: key)
        }
        // Read back as a launch reads them; each value is set here so whatever observes it hears the change.
        let fresh = SettingsStore(defaults: defaults)
        showMenuBarIcon = fresh.showMenuBarIcon
        playSounds = fresh.playSounds
        checksForUpdates = fresh.checksForUpdates
        automationEnabled = fresh.automationEnabled
        copyAfterCapture = fresh.copyAfterCapture
        uploadAfterCapture = fresh.uploadAfterCapture
        copyLinkAfterUpload = fresh.copyLinkAfterUpload
        saveAfterCapture = fresh.saveAfterCapture
        showQuickAccess = fresh.showQuickAccess
        copyAfterRecording = fresh.copyAfterRecording
        showRecordingQuickAccess = fresh.showRecordingQuickAccess
        saveAfterRecording = fresh.saveAfterRecording
        uploadAfterRecording = fresh.uploadAfterRecording
        historyRetention = fresh.historyRetention
        exportDirectory = fresh.exportDirectory
        screenshotFormat = fresh.screenshotFormat
        screenshotQuality = fresh.screenshotQuality
        savesRetinaAtOneX = fresh.savesRetinaAtOneX
        convertsToSRGB = fresh.convertsToSRGB
        addsBorder = fresh.addsBorder
        fileNamePattern = fresh.fileNamePattern
        asksForFileName = fresh.asksForFileName
        clipboardFormat = fresh.clipboardFormat
        showTextResult = fresh.showTextResult
        textResultPosition = fresh.textResultPosition
        textResultCloseAfter = fresh.textResultCloseAfter
        textRecognitionKeepsLineBreaks = fresh.textRecognitionKeepsLineBreaks
        textRecognitionWrapsText = fresh.textRecognitionWrapsText
        readsAppText = fresh.readsAppText
        translationTarget = fresh.translationTarget
        freezeScreen = fresh.freezeScreen
        screenshotShowsCursor = fresh.screenshotShowsCursor
        captureLoupeStyle = fresh.captureLoupeStyle
        captureLoupeSize = fresh.captureLoupeSize
        areaShape = fresh.areaShape
        snapSelectionToText = fresh.snapSelectionToText
        selfTimerDelay = fresh.selfTimerDelay
        pinCornerRadius = fresh.pinCornerRadius
        pinShadow = fresh.pinShadow
        pinBorder = fresh.pinBorder
        pinsAppearInCaptures = fresh.pinsAppearInCaptures
        colorFormat = fresh.colorFormat
        measureUnit = fresh.measureUnit
        measureTolerance = fresh.measureTolerance
        measureSnapsToContent = fresh.measureSnapsToContent
        recordingFrameRate = fresh.recordingFrameRate
        recordingPrefersHEVC = fresh.recordingPrefersHEVC
        recordingCountdown = fresh.recordingCountdown
        recordingHighlight = fresh.recordingHighlight
        recordingShowsCursor = fresh.recordingShowsCursor
        recordingShowsClicks = fresh.recordingShowsClicks
        recordingClickStyle = fresh.recordingClickStyle
        recordingSystemAudio = fresh.recordingSystemAudio
        recordingMicrophone = fresh.recordingMicrophone
        recordingMicrophoneID = fresh.recordingMicrophoneID
        recordingShowsControls = fresh.recordingShowsControls
        recordingShowsKeystrokes = fresh.recordingShowsKeystrokes
        recordingKeystrokeMode = fresh.recordingKeystrokeMode
        recordingKeepsKeysForStudio = fresh.recordingKeepsKeysForStudio
        recordingCamera = fresh.recordingCamera
        recordingCameraID = fresh.recordingCameraID
        recordingCameraStyle = fresh.recordingCameraStyle
        recordingOutput = fresh.recordingOutput
        recordingGIFFrameRate = fresh.recordingGIFFrameRate
        replaySound = fresh.replaySound
        windowShadow = fresh.windowShadow
        windowBackground = fresh.windowBackground
        allInOneRemembersArea = fresh.allInOneRemembersArea
        quickAccessCorner = fresh.quickAccessCorner
        quickAccessSize = fresh.quickAccessSize
        quickAccessOnPointerDisplay = fresh.quickAccessOnPointerDisplay
        quickAccessCloseAfter = fresh.quickAccessCloseAfter
        quickAccessCloseAction = fresh.quickAccessCloseAction
    }

    /// A recording's choice: its own once it has one, else the choice for screenshots as it stands now, kept from then
    /// on. It is not registered as a default, since a default would stand in for the screenshots' value.
    private static func recordingChoice(_ key: Key, startingAs screenshotKey: Key, in defaults: UserDefaults) -> Bool {
        if let own = defaults.object(forKey: key) as? Bool { return own }
        let value = defaults.bool(forKey: screenshotKey)
        defaults.set(value, forKey: key)
        return value
    }

    /// What a new install has, for the settings whose default is read in two places: registered, as what the defaults
    /// answer while nothing is stored, and stood in for a stored value the app doesn't offer (any longer). The rest are
    /// registered alone, where they are read.
    private enum Default {
        static let screenshotFormat = ImageExporter.Format.png
        static let fileNamePattern = FilenameTemplate.standard.pattern
        static let nextFileNumber = 1
        static let clipboardFormat = ClipboardFormat.pictureOnly
        static let historyRetention = HistoryRetention.oneWeek
        static let textResultPosition = TextResultPosition.belowSelection
        /// Automatic.
        static let translationTarget = ""
        static let captureLoupeStyle = CaptureLoupeStyle.magnified
        static let captureLoupeSize = CaptureLoupeSize.small
        /// A square.
        static let areaShape = ""
        static let selfTimerDelay = 5
        static let colorFormat = ColorFormat.hex
        static let measureUnit = MeasureUnit.points
        static let measureTolerance = MeasureTolerance.medium
        static let recordingFrameRate = 60
        static let recordingCountdown = 3
        static let recordingHighlight = RecordingHighlight.outline
        static let recordingClickStyle = ClickStyle.system
        /// The system's default input.
        static let recordingMicrophoneID = ""
        /// The system's default camera.
        static let recordingCameraID = ""
        static let recordingCameraStyle = CameraStyle(shape: .circle, size: .medium, mirrored: true)
        static let recordingKeystrokeMode = KeystrokeMode.all
        static let recordingOutput = RecordingOutput.video
        static let recordingGIFFrameRate = 15
        static let replaySound = ReplaySound.all
        static let quickAccessCorner = QuickAccessCorner.bottomLeft
        static let quickAccessSize = QuickAccessSize.medium
        static let quickAccessCloseAfter = 0
        static let quickAccessCloseAction = QuickAccessCloseAction.close
    }

    /// Every key the store keeps, each spelled as the setting it holds; `resetToDefaults` goes through them all.
    fileprivate enum Key: String, CaseIterable {
        case showMenuBarIcon
        case playSounds
        case checksForUpdates
        case automationEnabled
        case approvedAutomationCallers
        case exportDirectory
        case freezeScreen
        case screenshotShowsCursor
        case captureLoupeStyle
        case captureLoupeSize
        case areaShape
        case snapSelectionToText
        case selfTimerDelay
        case pinCornerRadius
        case pinShadow
        case pinBorder
        case pinsAppearInCaptures
        case colorFormat
        case measureUnit
        case measureTolerance
        case measureSnapsToContent
        case recordingFrameRate
        case recordingPrefersHEVC
        case recordingCountdown
        case recordingHighlight
        case recordingShowsCursor
        case recordingShowsClicks
        case recordingClickStyle
        case recordingSystemAudio
        case recordingMicrophone
        case recordingMicrophoneID
        case recordingShowsControls
        case recordingCamera
        case recordingCameraID
        case recordingCameraShape
        case recordingCameraSize
        case recordingCameraMirrored
        case recordingShowsKeystrokes
        case recordingKeystrokeMode
        case recordingKeepsKeysForStudio
        case recordingOutput
        case recordingGIFFrameRate
        case replaySound
        case copyAfterCapture
        case hidesDesktopIcons
        case allInOneRemembersArea
        case windowShadow
        case windowBackground
        case allInOneArea
        case quickAccessCorner
        case quickAccessSize
        case quickAccessOnPointerDisplay
        case quickAccessCloseAfter
        case quickAccessCloseAction
        case uploadAfterCapture
        case copyLinkAfterUpload
        case saveAfterCapture
        case screenshotFormat
        case screenshotQuality
        case savesRetinaAtOneX
        case convertsToSRGB
        case addsBorder
        case fileNamePattern
        case nextFileNumber
        case asksForFileName
        case clipboardFormat
        case showQuickAccess
        case copyAfterRecording
        case showRecordingQuickAccess
        case saveAfterRecording
        case uploadAfterRecording
        case historyRetention
        case showTextResult
        case textResultPosition
        case textResultCloseAfter
        case textRecognitionKeepsLineBreaks
        case textRecognitionWrapsText
        case readsAppText
        case translationTarget
    }
}

/// The store's reads and writes, by its own keys: a setting is stored under the one spelling its `Key` gives it.
fileprivate extension UserDefaults {
    func set(_ value: Any?, forKey key: SettingsStore.Key) { set(value, forKey: key.rawValue) }
    func removeObject(forKey key: SettingsStore.Key) { removeObject(forKey: key.rawValue) }
    func object(forKey key: SettingsStore.Key) -> Any? { object(forKey: key.rawValue) }
    func bool(forKey key: SettingsStore.Key) -> Bool { bool(forKey: key.rawValue) }
    func integer(forKey key: SettingsStore.Key) -> Int { integer(forKey: key.rawValue) }
    func double(forKey key: SettingsStore.Key) -> Double { double(forKey: key.rawValue) }
    func string(forKey key: SettingsStore.Key) -> String? { string(forKey: key.rawValue) }
    func stringArray(forKey key: SettingsStore.Key) -> [String]? { stringArray(forKey: key.rawValue) }
    func data(forKey key: SettingsStore.Key) -> Data? { data(forKey: key.rawValue) }
}
