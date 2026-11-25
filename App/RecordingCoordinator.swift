import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSDesign
import OMSRecording
import OMSStudio
import OMSUI
import OSLog

/// Turns Record Screen into a recording kept in the history.
///
/// The overlay chooses what to record (an area, a window, or a display), what it is kept as, and what it
/// takes along (on the recording bar); a countdown gives a moment to get ready; while recording, the area
/// is outlined, the control bar sits beside it, and the menu bar shows the time. Stopped, the movie is
/// finished into an MP4 or made into a GIF (the menu bar showing how far along), kept in the history,
/// copied, and given a Quick Access card. The movie is written in fragments in the drafts folder while it
/// records, so a recording cut short by a crash is finished at the next launch.
final class RecordingCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let overlay: OverlayController
    private let history: HistoryStore
    private let permissions: PermissionCenter
    /// Saves and copies kept recordings, as their cards do.
    private let files: ScreenshotFiles
    private let drafts = RecordingDrafts.standard()
    private let countdown = SelfTimerCountdown()
    private let outline = AreaOutline()
    private lazy var controls = RecordingControlBar(actions: .init(
        pause: { [weak self] in self?.pause() },
        resume: { [weak self] in self?.resume() },
        restart: { [weak self] in self?.restart() },
        delete: { [weak self] in self?.delete() },
        stop: { [weak self] in self?.stop() },
        toggleMicrophoneMute: { [weak self] in self?.toggleMicrophoneMute() },
        drawOnScreen: onDrawOnScreen
    ))

    /// What the menu bar shows of recordings.
    enum Status: Equatable {
        /// The time recorded, each second, and whether it is paused.
        case recording(time: String, paused: Bool)
        /// A stopped recording being made into a GIF, from 0 to 1.
        case makingGIF(progress: Double)
        /// A Studio movie being exported after its window closed, from 0 to 1.
        case exportingStudio(progress: Double)
        case idle
    }

    /// Receives every finished recording, already in the history; the composition root shows its card.
    var onRecorded: ((QuickAccessItem) -> Void)?
    /// Every recording kept in the history, a Studio recording too, which has no card yet.
    var onKept: ((HistoryItem) -> Void)?
    var onRecordingCompleted: (() -> Void)?
    /// A recording was kept and Settings says to upload it.
    var uploadKept: ((HistoryItem) -> Void)?
    /// Saving a copy of a recording failed: why, and the recording, to say it on its card when it has one.
    var saveFailed: ((ExportFailure, UUID?) -> Void)?
    /// A recording's file was just put on the clipboard, which refers to the file in the history and holds nothing else.
    var copiedToClipboard: ((UUID) -> Void)?
    /// The composition root shows it in the menu bar.
    var onStatus: ((Status) -> Void)?
    /// The keys of Record Screen, told to VoiceOver as the way to stop; nil when it has none.
    var shortcutKeys: (() -> String?)?
    /// Toggles Draw on Screen mid-recording when the control bar's Draw chip is pressed.
    var onDrawOnScreen: (() -> Void)? {
        didSet { controls.onDrawOnScreen = onDrawOnScreen }
    }
    /// Ephemeral desktop icon cover used when "Hide desktop icons while capturing" is turned on.
    var desktopIcons: DesktopCover?
    private var hidesDesktopForRecording = false

    /// What one recording is of, kept so Restart can record it again.
    private struct Plan {
        let target: RecordingTarget
        let display: DisplayInfo
        let choices: RecordingChoices
        let appName: String?

        init(target: RecordingTarget, display: DisplayInfo, choices: RecordingChoices, appName: String?) {
            self.target = target
            self.display = display
            self.choices = choices
            if case .window(let window) = target {
                self.appName = window.ownerName
            } else {
                self.appName = appName
            }
        }
    }

    private struct Session {
        let plan: Plan
        let draft: RecordingDrafts.Draft
        let recorder: ScreenRecorder
        let source: ScreenCapturer.RecordingSource
        let startedAt: Date
        /// For a Studio recording: what the pointer and the keyboard do meanwhile.
        let telemetry: TelemetryRecorder?
        /// Writes periodic Studio telemetry checkpoints off the main actor.
        let checkpointer: StudioDraftCheckpointer?
        /// For a Studio recording with the camera: the camera, in a movie of its own.
        let camera: CameraRecorder?
        /// The camera's bubble showed when a Studio recording began: if no movie of it comes, Studio says so.
        let cameraWanted: Bool
    }

    /// Why a recording stopped early on its own (writer error or low disk space).
    private enum Interruption {
        case writerFailed(stoppedAt: Duration, writtenDuration: Duration)
        case lowDiskSpace(stoppedAt: Duration)
    }

    /// The keys pressed, shown over what is recorded while it records.
    private var keyMonitor: KeyMonitor?
    private var keystrokes: KeystrokeDisplay?
    /// Clicks drawn as accent rings over what is recorded, when Settings says so.
    private var clickRings: ClickHighlights?
    /// The camera in its bubble, from the moment it is chosen on the bar until the recording ends.
    private let camera = CameraBubble()
    /// While a Studio recording records the camera: each change between filling what is recorded and the
    /// bubble (host seconds), the first the state it began in, and the bubble's look then.
    private var cameraFills: [(time: Double, fills: Bool)] = []
    private var cameraBubble = StudioProject.Camera()
    /// Host-clock timestamps captured while recording so incremental telemetry checkpoints stay aligned to
    /// the movie and its pauses even if the app crashes before stopping.
    private var movieStartHostTime: Double?
    private var cameraStartHostTime: Double?
    private var recordingPauses: [StudioDraftTelemetry.Pause] = []
    /// Counts one-second ticks of the active recording for periodic telemetry checkpoints and disk checks.
    private var tickCount = 0

    /// Where Record Screen is: nothing under way, a countdown, a recording starting, or one recording.
    private enum Phase {
        case idle
        /// Asking for the microphone, then counting down: Record Screen again cancels it.
        case countingDown(Plan)
        /// The countdown is over and the recorder starting. `stops` once Stop came meanwhile (Record Screen again, or the
        /// app quitting): it stops as soon as it has started.
        case starting(Plan, stops: Bool)
        case recording(Session)
    }

    private var phase = Phase.idle
    /// The recording under way, once it has started.
    private var session: Session? {
        if case .recording(let session) = phase { session } else { nil }
    }
    /// The microphone was asked for and left out, access to it being off: the control bar says so.
    private var microphoneDenied = false
    /// What could not be done, by the pointer: the recording that couldn't start.
    private let notice = CopiedHUD()
    private var ticker: Task<Void, Never>?
    private var tickerLease: ActiveResources.Lease?
    /// Ten times a second while the microphone or the Mac's sound is recorded: the control bar's meter, and a
    /// look at whether either has stopped sending sound.
    private var meter: Task<Void, Never>?
    private var meterLease: ActiveResources.Lease?
    /// Which of them the meter found stopped when it last looked.
    private var microphoneStalled = false
    private var systemAudioStalled = false
    /// Recordings starting or being finished; the app waits for them before quitting.
    private var finishing = 0
    private var finishingDone: [(Bool) -> Void] = []
    private var finishingMayQuit = true
    /// Recordings being made into GIFs, and how far along the newest is: the menu bar shows it.
    private var makingGIFs = 0
    private var gifProgress = 0.0

    init(
        settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController, history: HistoryStore,
        permissions: PermissionCenter, files: ScreenshotFiles
    ) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        self.history = history
        self.permissions = permissions
        self.files = files
        // All-In-One sets up a recording in its own session: the bar starts with the choices it has here.
        overlay.onWillSetUpRecording = { [weak self] in self?.configureOverlayForRecording() }
    }

    /// Whether a recording is under way or starting: Record Screen stops it.
    var isRecording: Bool {
        switch phase {
        case .starting, .recording: true
        case .idle, .countingDown: false
        }
    }

    var isCountingDown: Bool {
        if case .countingDown = phase { true } else { false }
    }

    #if DEBUG
    /// The recorder running now, for scripted checks.
    var debugRecorder: ScreenRecorder? { session?.recorder }
    /// Keeps recordings off the clipboard, for scripted checks.
    var debugLeavesClipboard = false
    /// Whether a recording is still starting, being finished, made into a GIF, or kept.
    var debugIsKeeping: Bool { finishing > 0 || makingGIFs > 0 }
    private var debugStatusKind: String?
    #endif

    // MARK: Starting

    /// Record Screen: choose what to record; while recording, stop; while counting down, cancel.
    /// - Parameter area: chosen already, in global points (the URL API's `record-screen` with an area): framed with
    ///   the recording bar at once.
    func recordScreen(area: CGRect? = nil) {
        switch phase {
        case .starting, .recording: return stop()
        case .countingDown: return cancelCountdown()
        case .idle: break
        }
        guard !overlay.isActive else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        overlay.freezesScreen = false
        overlay.lastArea = overlay.lastArea ?? settings.allInOneArea?.area(in: displays.layout)
        configureOverlayForRecording()
        overlay.begin(mode: .area, purpose: .record, choosing: area) { [weak self] outcome in
            guard case .record(let target, let display, let choices) = outcome else {
                self?.camera.hide()
                return
            }
            self?.prepare(Plan(target: target, display: display, choices: choices, appName: app))
        }
    }

    /// The recording bar's choices as Settings have them, and what remembers a change to them and shows the camera:
    /// for Record Screen, and for a recording All-In-One sets up.
    private func configureOverlayForRecording() {
        overlay.recordingChoices = RecordingChoices(
            output: settings.recordingOutput, systemAudio: settings.recordingSystemAudio, microphone: settings.recordingMicrophone,
            microphoneID: settings.recordingMicrophoneID, showsClicks: settings.recordingShowsClicks,
            showsKeystrokes: settings.recordingShowsKeystrokes, camera: settings.recordingCamera, cameraID: settings.recordingCameraID,
            cameraStyle: settings.recordingCameraStyle
        )
        overlay.onRecordingSetupChange = { [weak self] target, display, choices in
            guard let self else { return }
            showCamera(for: Plan(target: target, display: display, choices: choices, appName: nil))
            settings.recordingOutput = choices.output
            settings.recordingSystemAudio = choices.systemAudio
            settings.recordingMicrophone = choices.microphone
            settings.recordingMicrophoneID = choices.microphoneID
            settings.recordingShowsKeystrokes = choices.showsKeystrokes
            settings.recordingCamera = choices.camera
            settings.recordingCameraID = choices.cameraID
            settings.recordingCameraStyle = choices.cameraStyle
            settings.recordingShowsClicks = choices.showsClicks
        }
        overlay.onRecordingCameraCommand = { [weak self] command in self?.camera.perform(command) }
        overlay.recordingCameraFills = { [weak self] in self?.camera.isFilling ?? false }
    }

    /// A recording All-In-One set up was cancelled: the camera's preview goes.
    func recordingSetupCancelled() {
        camera.hide()
    }

    /// Records `target` on `display` without the overlay: for scripted checks, and for Restart.
    func record(_ target: RecordingTarget, on display: DisplayInfo, choices: RecordingChoices, appName: String?) {
        guard case .idle = phase else { return }
        prepare(Plan(target: target, display: display, choices: choices, appName: appName))
    }

    /// Asks for the microphone if it is wanted, then counts down (or not) and starts.
    private func prepare(_ plan: Plan) {
        guard ensureDiskSpaceToStart() else {
            camera.hide()
            showStatusAfterRecording()
            return
        }
        phase = .countingDown(plan)
        microphoneDenied = false
        Task { [weak self] in
            guard let self else { return }
            var plan = plan
            // Reading the microphone's access starts the system's capture machinery: only when the recording wants it.
            if plan.choices.recordsMicrophone, !(await permissions.requestIfNeeded(.microphone)) {
                Log.recording.notice("Recording without the microphone: access is off")
                microphoneDenied = true
                VoiceOver.announce(String(localized: "Microphone access is off in System Settings. Recording without it."))
                var choices = plan.choices
                choices.microphone = false
                plan = Plan(target: plan.target, display: plan.display, choices: choices, appName: plan.appName)
            }
            if Self.showsKeystrokes(plan), !KeyMonitor.isAllowed {
                // The bar asked for access and shows it is off; the system is never asked from here, where its
                // prompt could be recorded.
                Log.recording.notice("Recording without keystrokes: Input Monitoring is off")
                var choices = plan.choices
                choices.showsKeystrokes = false
                plan = Plan(target: plan.target, display: plan.display, choices: choices, appName: plan.appName)
            }
            guard case .countingDown = phase else { return }
            phase = .countingDown(plan)
            // Restarting brings the camera back; choosing on the bar showed it already.
            showCamera(for: plan)
            let seconds = settings.recordingCountdown
            let area = Self.area(of: plan)
            if case .area = plan.target { outline.show(area, layout: displays.layout, style: settings.recordingHighlight) }
            guard seconds > 0 else { return await start(plan) }
            let keys = shortcutKeys?()
            VoiceOver.announce(keys.map { String(localized: "Recording in \(seconds) seconds. Press \($0) to cancel.") }
                ?? String(localized: "Recording in \(seconds) seconds."))
            countdown.start(
                seconds: seconds, area: area, layout: displays.layout, outlinesArea: false,
                onCancel: { [weak self] in self?.cancelCountdown() }
            ) { [weak self] in
                Task { await self?.start(plan) }
            }
        }
    }

    private func cancelCountdown() {
        guard case .countingDown = phase else { return }
        phase = .idle
        countdown.cancel()
        outline.hide()
        camera.hide()
        showStatusAfterRecording()
        VoiceOver.announce(String(localized: "Recording cancelled."))
    }

    private func start(_ plan: Plan) async {
        guard case .countingDown = phase else { return }
        phase = .starting(plan, stops: false)
        // Quitting meanwhile waits for it to start, and then for it to be kept.
        finishing += 1
        defer { finished() }
        let probe = LatencyProbe("recording.start")
        var draft: RecordingDrafts.Draft?
        do {
            // The keystrokes' and the click rings' windows are on screen before the filter is made, so the
            // filter takes them in.
            let keys = Self.showsKeystrokes(plan) ? KeystrokeDisplay(mode: settings.recordingKeystrokeMode) : nil
            keys?.show(in: Self.area(of: plan))
            keystrokes = keys
            let rings = drawsClickRings(plan) ? ClickHighlights() : nil
            rings?.show(over: Self.area(of: plan))
            clickRings = rings
            // Studio films the camera from a movie of its own, so its bubble stays out of the picture.
            let studio = plan.choices.output == .studio
            if settings.hidesDesktopIconsWhileCapturing, let desktopIcons, !hidesDesktopForRecording {
                desktopIcons.beginTemporaryHide()
                hidesDesktopForRecording = true
                await desktopIcons.waitForRefresh()
            }
            let shown = Set([keys?.windowID, rings?.windowID, studio ? nil : camera.windowID].compactMap(\.self))
            let source = try await capturer.recordingSource(for: plan.target, on: plan.display, including: shown)
            let format = RecordingFormat.choose(
                width: source.pixelWidth, height: source.pixelHeight,
                framesPerSecond: settings.recordingFramesPerSecond, prefersHEVC: settings.recordingPrefersHEVC
            )
            guard ensureDiskSpaceToStart() else {
                phase = .idle
                outline.hide()
                keystrokes?.hide()
                keystrokes = nil
                clickRings?.hide()
                clickRings = nil
                camera.hide()
                endTemporaryDesktopHide()
                showStatusAfterRecording()
                return
            }
            let created = try drafts.create(.init(
                startedAt: .now, appName: plan.appName, output: plan.choices.output,
                pixelsPerPoint: source.frame.width > 0 ? Double(source.pixelWidth) / source.frame.width : nil
            ))
            draft = created
            movieStartHostTime = nil
            cameraStartHostTime = nil
            recordingPauses = []
            cameraFills = []
            cameraBubble = StudioProject.Camera()
            tickCount = 0
            // Studio draws the cursor and the clicks again from what the pointer did, so neither is in the picture.
            let resolvedMic = plan.choices.recordsMicrophone ? RecordingAudio.Microphone.resolve(plan.choices.microphoneID) : nil
            let recorder = try ScreenRecorder(ScreenRecorder.Request(
                filter: source.filter, sourceRect: source.sourceRect, format: format,
                audio: RecordingAudio(system: plan.choices.recordsSystemAudio, microphone: resolvedMic?.microphone),
                // Rings in place of the system's circles, never both.
                showsCursor: settings.recordingShowsCursor && !studio, showsClicks: plan.choices.showsClicks && rings == nil && !studio,
                movieURL: created.movieURL
            ))
            recorder.onStreamStopped = { [weak self] error in self?.streamStopped(error) }
            recorder.onWriterFailed = { [weak self] failure in self?.writerFailed(failure) }
            recorder.onFirstFrame = { [weak self] time in
                guard let self else { return }
                self.movieStartHostTime = time.seconds
                self.checkpointTelemetry()
            }
            // The pointer is written down from before the first frame, so the movie begins with its place.
            let telemetry = studio ? TelemetryRecorder() : nil
            let checkpointer = studio ? StudioDraftCheckpointer() : nil
            // Keys as Settings › Recording › Keystrokes chose: under Shortcuts only, no typing is written down. They
            // are written down with Show Keystrokes off too, for Studio to show afterwards, unless Settings says not
            // or a window is recorded on its own.
            let recordsWindow = switch plan.target {
            case .window: true
            case .area, .display: false
            }
            telemetry?.start(
                area: source.frame, pixelsPerPoint: source.frame.width > 0 ? Double(source.pixelWidth) / source.frame.width : 1,
                keys: TelemetryRecorder.keystrokeMode(
                    showsKeystrokes: plan.choices.showsKeystrokes, keepsForStudio: settings.recordingKeepsKeysForStudio,
                    recordsWindow: recordsWindow, inputMonitoringAllowed: KeyMonitor.isAllowed, mode: settings.recordingKeystrokeMode
                )
            )
            // The camera's frames are taken before the screen's begin, so its movie covers the first frame.
            let cameraWanted = studio && camera.isShowing
            let cameraRecorder = cameraWanted ? await recordCamera(for: plan, into: created) : nil
            do {
                try await recorder.start()
            } catch {
                telemetry?.stop()
                await checkpointer?.cancel()
                await endCameraRecording(cameraRecorder)
                throw error
            }
            probe.end()
            let stops = if case .starting(_, stops: true) = phase { true } else { false }
            phase = .recording(Session(
                plan: plan, draft: created, recorder: recorder, source: source, startedAt: .now, telemetry: telemetry,
                checkpointer: checkpointer, camera: cameraRecorder, cameraWanted: cameraWanted
            ))
            if let failure = recorder.takePendingWriterFailure() {
                writerFailed(failure)
                return
            }
            checkpointTelemetry()
            // Stop came while it started: kept as a recording stopped now is.
            if stops { return stop() }
            showChrome(for: plan, source: source)
            if resolvedMic?.fellBack == true {
                notice.show(String(localized: "Selected microphone unavailable. Using default microphone."), near: NSEvent.mouseLocation)
            }
            camera.setRecording(true)
            if let keys {
                let monitor = KeyMonitor()
                monitor.onPress = { [weak keys] key in keys?.take(key) }
                if !monitor.start() { Log.recording.error("The keystroke monitor could not start") }
                keyMonitor = monitor
            }
            let stopKeys = shortcutKeys?()
            VoiceOver.announce(stopKeys.map { String(localized: "Recording. Press \($0) again to stop.") }
                ?? String(localized: "Recording. Click the time in the menu bar to stop."))
        } catch {
            Log.recording.error("Recording could not start: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            phase = .idle
            if let draft { drafts.remove(draft) }
            outline.hide()
            keystrokes?.hide()
            keystrokes = nil
            clickRings?.hide()
            clickRings = nil
            camera.hide()
            endTemporaryDesktopHide()
            showStatusAfterRecording()
            NSSound.beep()
            VoiceOver.announce(String(localized: "The recording couldn’t start."))
            // Said where the person is looking too: a beep alone says nothing of what went wrong.
            notice.show(String(localized: "The recording couldn’t start."), near: NSEvent.mouseLocation)
        }
    }

    /// For a Studio recording with the camera showing: starts recording the camera into a movie beside the
    /// draft's, and notes how its bubble looks and whether it fills what is recorded. Nil when the camera
    /// isn't showing or can't be recorded; the recording goes on without it.
    private func recordCamera(for plan: Plan, into draft: RecordingDrafts.Draft) async -> CameraRecorder? {
        guard camera.isShowing, let dimensions = camera.cameraDimensions, dimensions.width > 0, dimensions.height > 0 else { return nil }
        do {
            let recorder = try CameraRecorder(
                url: draft.cameraURL, width: Int(dimensions.width), height: Int(dimensions.height), clock: camera.cameraClock,
                onFirstFrame: { [weak self] time in
                    Task { @MainActor [weak self] in
                        self?.cameraStartHostTime = time.seconds
                        self?.checkpointTelemetry()
                    }
                }
            )
            guard await camera.attach(recorder.output) else {
                Log.recording.error("The camera's frames couldn't be taken; recording without it")
                await recorder.cancel()
                return nil
            }
            recorder.unmirror()
            let style = plan.choices.cameraStyle
            let area = Self.area(of: plan)
            let bubble = camera.bubbleFrame ?? area
            cameraBubble = StudioProject.Camera(
                shape: style.shape == .circle ? .circle : .roundedSquare, size: Double(style.size.points),
                corner: Self.cameraCorner(of: bubble, in: area), mirrored: style.mirrored
            )
            cameraFills = [(Self.hostSeconds(), camera.isFilling)]
            camera.onFillChange = { [weak self] fills in
                guard let self else { return }
                self.cameraFills.append((Self.hostSeconds(), fills))
                if let session = self.session {
                    self.syncCameraBubbleCorner(for: session.plan, recorded: session.source.frame)
                }
                self.checkpointTelemetry()
            }
            return recorder
        } catch {
            Log.recording.error("The camera couldn't be recorded: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private static func cameraCorner(of bubble: CGRect, in area: CGRect) -> StudioProject.Camera.Corner {
        let left = bubble.midX < area.midX
        let bottom = bubble.midY < area.midY
        return bottom ? (left ? .bottomLeft : .bottomRight) : (left ? .topLeft : .topRight)
    }

    /// Updates `cameraBubble.corner` from the live camera bubble's current position so dragging the bubble
    /// during a Studio recording is reflected in the Studio project (and in crash-recovery checkpoints).
    @discardableResult
    private func syncCameraBubbleCorner(for plan: Plan, recorded: CGRect?) -> Bool {
        guard !camera.isFilling, let bubble = camera.bubbleFrame else { return false }
        let corner = Self.cameraCorner(of: bubble, in: Self.area(of: plan, recorded: recorded))
        guard corner != cameraBubble.corner else { return false }
        cameraBubble.corner = corner
        return true
    }

    /// Stops listening to the camera and throws its movie away.
    private func endCameraRecording(_ recorder: CameraRecorder?) async {
        guard let recorder else { return }
        camera.onFillChange = nil
        camera.detach(recorder.output)
        await recorder.cancel()
    }

    /// Finishes the camera's movie where the screen's ended, and says where it begins and when it filled
    /// what was recorded, in host seconds; nil when the camera sent nothing.
    private func finishCamera(_ recorder: CameraRecorder, screen: RecordingWriter.Statistics) async -> StudioTelemetry.Camera? {
        camera.onFillChange = nil
        camera.detach(recorder.output)
        let start = screen.start ?? .zero
        let paused = screen.pauses.reduce(CMTime.zero) { $0 + $1.duration }
        let end = start + screen.duration + paused
        guard let statistics = try? await recorder.finish(at: end), let cameraStart = statistics.start else { return nil }
        var fills: [ClosedRange<Double>] = []
        var since: Double?
        for change in cameraFills {
            if change.fills, since == nil { since = change.time }
            if !change.fills, let began = since {
                if change.time > began { fills.append(began...change.time) }
                since = nil
            }
        }
        if let began = since, end.seconds > began { fills.append(began...end.seconds) }
        return StudioTelemetry.Camera(start: cameraStart.seconds, fills: fills, bubble: cameraBubble)
    }

    /// The host clock's time now, in seconds: the clock recordings' samples are stamped with.
    private static func hostSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// Shows the camera's bubble at the corner of what `plan` records when the camera is chosen, or hides
    /// it. Plain window recordings exclude the camera, while Studio window recordings composite `camera.mov`
    /// independently of ScreenCaptureKit's window filter.
    private func showCamera(for plan: Plan) {
        if case .window = plan.target, plan.choices.output != .studio {
            return camera.hide()
        }
        // Without access or a camera, nothing shows: a bubble with no picture would be recorded as a blank disc.
        guard plan.choices.camera, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return camera.hide()
        }
        if !camera.isShowing, Cameras.available().devices.isEmpty {
            Log.recording.notice("No camera to show")
            return camera.hide()
        }
        camera.show(camera: plan.choices.cameraID, style: plan.choices.cameraStyle, in: Self.area(of: plan))
    }

    /// Takes the windows put on screen since the recording began (Draw on Screen's canvases) into it, as the ones there
    /// when it began were: the stream is given the filter it would be given now. Single-window recordings stay on their
    /// window; non-window Studio recordings also pick up Draw on Screen canvases while keeping camera/keystrokes/click
    /// rings excluded.
    func includeWindowsShownSince() async {
        guard let session else { return }
        if case .window = session.plan.target { return }
        let studio = session.plan.choices.output == .studio
        let shown: Set<CGWindowID> = studio ? [] : Set([keystrokes?.windowID, clickRings?.windowID, camera.windowID].compactMap(\.self))
        do {
            let source = try await capturer.recordingSource(for: session.plan.target, on: session.plan.display, including: shown)
            try await session.recorder.updateFilter(source.filter)
            Log.capture.notice("Recording takes in the windows shown since it began")
        } catch {
            Log.capture.error("Recording could not take in new windows: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Whether clicks are drawn as rings: shown, rings chosen in Settings, and not of a window, which is
    /// recorded alone and so keeps the system's circles.
    private func drawsClickRings(_ plan: Plan) -> Bool {
        guard plan.choices.showsClicks, settings.recordingClickStyle == .ring, plan.choices.output != .studio else { return false }
        if case .window = plan.target { return false }
        return true
    }

    /// Whether a recording shows the keys pressed: chosen, and not of a window, which is recorded alone.
    private static func showsKeystrokes(_ plan: Plan) -> Bool {
        // Studio draws the keys itself, from what it wrote down.
        guard plan.choices.showsKeystrokes, plan.choices.output != .studio else { return false }
        if case .window = plan.target { return false }
        return true
    }

    // MARK: While recording

    var isPaused: Bool {
        session?.recorder.state == .paused
    }

    var isMicrophoneMuted: Bool {
        session?.recorder.isMicrophoneMuted ?? false
    }

    var recordsMicrophone: Bool {
        session?.plan.choices.recordsMicrophone ?? false
    }

    /// Updates the Draw on Screen button's active appearance in the floating recording control bar.
    func setDrawing(_ active: Bool) {
        controls.update(drawing: active)
    }

    /// Pauses or resumes the active recording.
    func togglePause() {
        guard let session else { return }
        switch session.recorder.state {
        case .recording: pause()
        case .paused: resume()
        default: break
        }
    }

    /// Toggles live microphone mute during an active recording without stopping the capture stream.
    func toggleMicrophoneMute() {
        guard let session, session.plan.choices.recordsMicrophone else {
            NSSound.beep()
            return
        }
        let muted = !session.recorder.isMicrophoneMuted
        session.recorder.isMicrophoneMuted = muted
        controls.update(microphoneMuted: muted)
        report(.recording(time: RecordingControlBar.format(session.recorder.elapsed), paused: session.recorder.state == .paused))
        notice.show(muted ? String(localized: "Microphone muted") : String(localized: "Microphone unmuted"), near: NSEvent.mouseLocation)
    }

    func pause() {
        guard let session, session.recorder.state == .recording else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        session.recorder.pause()
        session.camera?.pause(at: now)
        recordingPauses.append(.init(start: now.seconds))
        checkpointTelemetry()
        tick()
        VoiceOver.announce(String(localized: "Recording paused."))
    }

    func resume() {
        guard let session, session.recorder.state == .paused else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        session.recorder.resume()
        session.camera?.resume(at: now)
        if !recordingPauses.isEmpty {
            let last = recordingPauses.count - 1
            recordingPauses[last].end = max(now.seconds, recordingPauses[last].start)
        }
        checkpointTelemetry()
        tick()
        VoiceOver.announce(String(localized: "Recording resumed."))
    }

    /// Throws the recording so far away and records the same thing again, after the countdown.
    /// Checks startup disk space before discarding so a refused replacement never loses the current recording.
    func restart() {
        guard let session else { return }
        switch drafts.restartDecision() {
        case .restart:
            phase = .idle
            endChrome()
            discard(session)
            prepare(session.plan)
        case .keepCurrent(let available, let required):
            presentInsufficientDiskSpaceToStart(available: available, required: required)
        }
    }

    /// Stops and throws the recording away.
    func delete() {
        guard let session else { return }
        phase = .idle
        endChrome()
        discard(session)
        VoiceOver.announce(String(localized: "Recording deleted."))
    }

    private func discard(_ session: Session) {
        session.telemetry?.stop()
        Task {
            await session.checkpointer?.cancel()
            await endCameraRecording(session.camera)
            await session.recorder.cancel()
            drafts.remove(session.draft)
        }
    }

    /// Stops, then finishes and keeps the recording; one still starting, as soon as it has started.
    func stop() {
        stop(interruption: nil)
    }

    private func stop(interruption: Interruption?) {
        if case .starting(let plan, _) = phase { phase = .starting(plan, stops: true) }
        guard let session else { return }
        phase = .idle
        let makesGIF = session.plan.choices.output == .gif
        if makesGIF { makingGIFs += 1 }
        // Capture the bubble's latest dragged corner before `endChrome()` hides the bubble panel.
        if session.camera != nil {
            syncCameraBubbleCorner(for: session.plan, recorded: session.source.frame)
            checkpointTelemetry()
        }
        endChrome()
        finishing += 1
        let movieStartSnapshot = movieStartHostTime
        let cameraStartSnapshot = cameraStartHostTime
        let pausesSnapshot = recordingPauses
        let fillsSnapshot = cameraFills.map { StudioDraftTelemetry.CameraFillChange(time: $0.time, fills: $0.fills) }
        let bubbleSnapshot = cameraBubble
        Task {
            defer {
                if makesGIF { madeGIF() }
                finished()
            }
            var raw = session.telemetry?.stop()
            do {
                let statistics = try await session.recorder.stop()
                if let recorder = session.camera {
                    raw?.camera = await finishCamera(recorder, screen: statistics)
                }
                if session.cameraWanted, raw?.camera == nil {
                    Log.recording.error("The camera showed but wasn't recorded")
                    raw?.cameraFailed = true
                }
                // What the pointer did, moved onto the movie's timeline: from its first frame, pauses cut out.
                let telemetry = raw.map { raw in
                    raw.retimed(start: statistics.start?.seconds ?? 0, pauses: statistics.pauses.map { $0.start.seconds...$0.end.seconds })
                }
                if let telemetry, let checkpointer = session.checkpointer {
                    let finalDraft = StudioDraftTelemetry(
                        telemetry: telemetry, isRetimed: true,
                        movieStart: statistics.start?.seconds ?? movieStartSnapshot,
                        pauses: statistics.pauses.map { .init(start: $0.start.seconds, end: $0.end.seconds) },
                        cameraStart: cameraStartSnapshot, cameraFills: fillsSnapshot, cameraBubble: bubbleSnapshot,
                        cameraWanted: session.cameraWanted, showsClicks: session.plan.choices.showsClicks,
                        showsKeystrokes: session.plan.choices.showsKeystrokes
                    )
                    try? await checkpointer.saveFinal(finalDraft, to: session.draft.telemetryURL)
                }
                await keep(
                    session.draft, plan: session.plan, displayID: session.plan.display.id, writer: statistics,
                    telemetry: telemetry, interruption: interruption
                )
            } catch RecordingWriter.WriterError.noFrames {
                Log.recording.notice("Nothing was recorded")
                await session.checkpointer?.cancel()
                await endCameraRecording(session.camera)
                drafts.remove(session.draft)
                if let interruption { presentInterruptionNoFrames(interruption) }
            } catch {
                // The movie may still be readable up to its last fragment.
                Log.recording.error("Stopping the recording failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
                let partial = await session.recorder.currentStatistics()
                var salvagedTelemetry: StudioTelemetry?
                if var raw {
                    if let recorder = session.camera {
                        if partial.start != nil {
                            raw.camera = await finishCamera(recorder, screen: partial)
                        } else {
                            await endCameraRecording(recorder)
                        }
                    }
                    if session.cameraWanted, raw.camera == nil {
                        raw.cameraFailed = true
                    }
                    let partialPauses = partial.pauses.isEmpty
                        ? pausesSnapshot
                        : partial.pauses.map { StudioDraftTelemetry.Pause(start: $0.start.seconds, end: $0.end.seconds) }
                    let hasCamera = raw.camera != nil && FileManager.default.fileExists(atPath: session.draft.cameraURL.path(percentEncoded: false))
                    let draftTelemetry = StudioDraftTelemetry(
                        telemetry: raw, isRetimed: false,
                        movieStart: partial.start?.seconds ?? movieStartSnapshot,
                        pauses: partialPauses,
                        cameraStart: raw.camera?.start ?? cameraStartSnapshot,
                        cameraFills: fillsSnapshot, cameraBubble: bubbleSnapshot,
                        cameraWanted: session.cameraWanted, showsClicks: session.plan.choices.showsClicks,
                        showsKeystrokes: session.plan.choices.showsKeystrokes
                    )
                    let retimed = draftTelemetry.resolvedTelemetry(movieDuration: partial.duration.seconds, hasCameraFile: hasCamera)
                    salvagedTelemetry = retimed
                    if let checkpointer = session.checkpointer {
                        var persisted = draftTelemetry
                        persisted.telemetry = retimed
                        persisted.isRetimed = true
                        try? await checkpointer.saveFinal(persisted, to: session.draft.telemetryURL)
                    }
                } else {
                    await endCameraRecording(session.camera)
                }
                await keep(
                    session.draft, plan: session.plan, displayID: session.plan.display.id, writer: nil,
                    telemetry: salvagedTelemetry, interruption: interruption
                )
            }
        }
    }

    /// The stream ended on its own: a display went away, Screen Recording was turned off, or the system's
    /// own control stopped sharing. What was recorded is kept.
    private func streamStopped(_ error: any Error) {
        guard session != nil else { return }
        Log.recording.notice("Recording stopped by the system; keeping what was recorded")
        stop()
    }

    /// The movie writer failed while recording (e.g. disk full or encoder error): stop at once and salvage
    /// everything committed so far, then tell the user visibly when it stopped and up to where was kept.
    private func writerFailed(_ failure: RecordingWriter.Failure) {
        guard let session else { return }
        let stoppedAt = session.recorder.elapsed
        let written = Duration.seconds(max(0, failure.writtenDuration.seconds))
        Log.recording.error("Recording writer failed at \(RecordingControlBar.format(stoppedAt), privacy: .public) (written \(RecordingControlBar.format(written), privacy: .public)): \(failure.message, privacy: .public)")
        stop(interruption: .writerFailed(stoppedAt: stoppedAt, writtenDuration: written))
    }

    /// Writes a non-blocking Studio telemetry checkpoint to the active draft off the main actor.
    private func checkpointTelemetry() {
        guard let session, let telemetry = session.telemetry, let checkpointer = session.checkpointer else { return }
        let snapshot = StudioDraftTelemetry(
            telemetry: telemetry.snapshot(), isRetimed: false,
            movieStart: movieStartHostTime, pauses: recordingPauses,
            cameraStart: cameraStartHostTime,
            cameraFills: cameraFills.map { .init(time: $0.time, fills: $0.fills) },
            cameraBubble: cameraBubble, cameraWanted: session.cameraWanted,
            showsClicks: session.plan.choices.showsClicks, showsKeystrokes: session.plan.choices.showsKeystrokes
        )
        let url = session.draft.telemetryURL
        Task { await checkpointer.checkpoint(snapshot, to: url) }
    }

    // MARK: Keeping

    /// A recording's file, ready for the history: an MP4 or a GIF.
    private struct KeptFile {
        let url: URL
        let pixelWidth: Int
        let pixelHeight: Int
        let duration: TimeInterval
        let byteCount: Int
    }

    /// How `keep(_:...)` finished a draft, for launch recovery notices.
    private enum KeepOutcome {
        case studio
        case studioWithoutTelemetry
        case plain
        case failed
    }

    /// Finishes a draft into an MP4, or makes it into a GIF, and keeps it: history, clipboard, card. A draft
    /// that cannot be finished — or whose Studio sidecar assets only partly saved — stays in the drafts folder,
    /// where the next launch tries again.
    @discardableResult
    private func keep(
        _ draft: RecordingDrafts.Draft, plan: Plan?, displayID: CGDirectDisplayID, writer: RecordingWriter.Statistics?,
        telemetry: StudioTelemetry? = nil, interruption: Interruption? = nil,
        copiesToClipboard: Bool = true, isRecovery: Bool = false
    ) async -> KeepOutcome {
        let probe = LatencyProbe("recording.keep")
        let output = draft.info?.output ?? .video
        let destination = draft.movieURL.deletingPathExtension().appendingPathExtension(output == .gif ? "gif" : "mp4")
        do {
            let file = try await makeFile(of: draft, as: output, at: destination)
            var resolvedTelemetry = telemetry
            var recoveredDraftTelemetry: StudioDraftTelemetry?
            if resolvedTelemetry == nil, output == .studio,
               let data = try? Data(contentsOf: draft.telemetryURL),
               let savedDraft = try? JSONDecoder().decode(StudioDraftTelemetry.self, from: data) {
                let hasCamera = await RecordingDrafts.hasReadableVideo(at: draft.cameraURL)
                resolvedTelemetry = savedDraft.resolvedTelemetry(movieDuration: file.duration, hasCameraFile: hasCamera)
                recoveredDraftTelemetry = savedDraft
            }
            if let resolvedTelemetry {
                // Studio: no card or clipboard yet; they come with the first movie exported from its window.
                let entry = try history.add(
                    movingFileAt: file.url, name: fileName(startedAt: draft.info?.startedAt ?? .now, appName: draft.info?.appName ?? plan?.appName),
                    kind: .recording, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, appName: draft.info?.appName ?? plan?.appName,
                    duration: file.duration, pixelsPerPoint: draft.info?.pixelsPerPoint
                )
                let keptMovie = RecordingDrafts.Info.KeptMovie.measure(at: history.fileURL(for: entry))
                var keptDraft = draft
                do {
                    // The draft's movie stays until its sounds are kept apart: it is the only copy with them in tracks of their own.
                    keptDraft = try drafts.markKeptInHistory(draft, historyID: entry.id, keptMovie: keptMovie, removingMovie: false)
                } catch {
                    Log.recording.error("Recording kept history id on draft \(draft.id.uuidString, privacy: .public) failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
                }
                var project = StudioProject(zooms: AutoZoom.zooms(for: resolvedTelemetry, duration: file.duration))
                project.cursor.showsClicks = plan?.choices.showsClicks ?? recoveredDraftTelemetry?.showsClicks ?? true
                project.showsKeys = plan?.choices.showsKeystrokes ?? recoveredDraftTelemetry?.showsKeystrokes ?? true
                project.keystrokeMode = resolvedTelemetry.keystrokeMode ?? .all
                project.camera = resolvedTelemetry.camera?.bubble ?? StudioProject.Camera()
                await keepStudioSounds(from: keptDraft.movieURL, for: entry)
                // Linked to the history, the draft needs its movie no longer; unlinked, recovery keeps it again from the movie.
                if keptDraft.info?.keptHistoryID != nil { try? FileManager.default.removeItem(at: keptDraft.movieURL) }
                let saveResult = saveStudioProject(resolvedTelemetry, project: project, camera: keptDraft.cameraURL, for: entry)
                if saveResult.isComplete {
                    drafts.remove(keptDraft)
                } else {
                    let hasRetimedDraft: Bool = {
                        guard let data = try? Data(contentsOf: keptDraft.telemetryURL),
                              let existing = try? JSONDecoder().decode(StudioDraftTelemetry.self, from: data)
                        else { return false }
                        return existing.isRetimed
                    }()
                    if !hasRetimedDraft {
                        let fallback = StudioDraftTelemetry(
                            telemetry: resolvedTelemetry, isRetimed: true,
                            cameraBubble: project.camera,
                            cameraWanted: saveResult.expectedCamera || resolvedTelemetry.cameraFailed == true,
                            showsClicks: project.cursor.showsClicks, showsKeystrokes: project.showsKeys
                        )
                        try? JSONEncoder().encode(fallback).write(to: keptDraft.telemetryURL, options: .atomic)
                    }
                    Log.recording.error("Studio project only partly saved (camera \(saveResult.savedCamera, privacy: .public)/\(saveResult.expectedCamera, privacy: .public), telemetry \(saveResult.savedTelemetry, privacy: .public), project \(saveResult.savedProject, privacy: .public)); keeping draft \(keptDraft.id.uuidString, privacy: .public) for recovery into history \(entry.id.uuidString, privacy: .public)")
                }
                studioDisplays[entry.id] = displayID
                if plan != nil { onRecordingCompleted?() }
                onKept?(entry)
                probe.end()
                if let interruption {
                    presentInterruptionKept(interruption, keptDuration: file.duration)
                }
                if !saveResult.isComplete {
                    presentPartialStudioSaveAlert(saveResult)
                }
                if saveResult.savedTelemetry {
                    if !isRecovery {
                        VoiceOver.announce(String(localized: "Recording stopped. Opening Studio."))
                    }
                    await openStudio(entry)
                }
                return .studio
            }
            let entry = try await deliver(
                file, startedAt: draft.info?.startedAt ?? .now, appName: draft.info?.appName ?? plan?.appName,
                pixelsPerPoint: draft.info?.pixelsPerPoint, displayID: displayID, countsAsRecording: plan != nil,
                copiesToClipboard: copiesToClipboard
            )
            drafts.remove(draft)
            probe.end()
            Log.recording.notice("Kept a recording of \(file.duration, format: .fixed(precision: 2), privacy: .public) s, \(file.pixelWidth, privacy: .public)x\(file.pixelHeight, privacy: .public), \(file.byteCount, privacy: .public) bytes as \(entry.fileName, privacy: .private)\(writer.map { ", \($0.framesWritten) frames written, \($0.framesDropped) dropped" } ?? "", privacy: .public)")
            if let interruption {
                presentInterruptionKept(interruption, keptDuration: file.duration)
            } else if !isRecovery {
                VoiceOver.announce(output == .gif ? String(localized: "GIF made.") : String(localized: "Recording stopped."))
            }
            return output == .studio ? .studioWithoutTelemetry : .plain
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Log.recording.error("Keeping the recording failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            if let interruption {
                presentInterruptionKeepFailed(interruption)
            } else if plan != nil {
                presentWarning(
                    title: String(localized: "Recording Couldn’t Be Kept"),
                    message: String(localized: "The recording couldn’t be kept. OhMyShot will try again next time it starts.")
                )
            } else if !isRecovery {
                NSSound.beep()
                let message = String(localized: "The recording couldn’t be kept. OhMyShot will try again next time it starts.")
                notice.show(message, near: NSEvent.mouseLocation)
            }
            return .failed
        }
    }

    /// Keeps what the pointer did beside a Studio recording, in its project folder, for the Studio window,
    /// and the camera's movie when there is one. Returns per-asset outcomes so the caller keeps the draft
    /// intact whenever any asset fails to save.
    private func saveStudioProject(
        _ telemetry: StudioTelemetry, project: StudioProject, camera: URL? = nil, for entry: HistoryItem
    ) -> StudioProjectSaveResult {
        let folder = history.studioURL(for: entry)
        let result = StudioProjectStorage.save(telemetry: telemetry, project: project, cameraURL: camera, to: folder)
        if result.isComplete {
            Log.recording.notice("Kept a Studio project: \(telemetry.samples.count, privacy: .public) pointer readings, \(telemetry.cursors.count, privacy: .public) cursor(s), \(telemetry.clicks.count, privacy: .public) click(s), \(telemetry.keys.count, privacy: .public) key(s)\(telemetry.camera.map { String(format: ", the camera from %.2f s, filling %d time(s)", $0.start, $0.fills.count) } ?? "", privacy: .public)")
        } else {
            Log.recording.error("Keeping the Studio project failed: \(result.errorDescription ?? "unknown error", privacy: .private)")
        }
        return result
    }

    /// Keeps the system's sound and the microphone of a Studio recording, from `movie` (its draft, where they are
    /// tracks of their own), each in a file of its own in its project folder, so Studio sets how loud each plays. The
    /// history's movie has them mixed into one, which every player plays; without these files Studio plays that.
    private func keepStudioSounds(from movie: URL, for entry: HistoryItem) async {
        do {
            let kept = try await StudioSound.keep(from: movie, in: history.studioURL(for: entry))
            Log.recording.notice("Kept \(kept.count, privacy: .public) Studio sound(s) apart")
        } catch {
            Log.recording.error("Keeping a Studio recording's sounds apart failed; Studio plays them as one: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Disk space and interruption alerts

    private func ensureDiskSpaceToStart() -> Bool {
        guard case .insufficient(let available, let required) = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesToStart) else {
            return true
        }
        presentInsufficientDiskSpaceToStart(available: available, required: required)
        return false
    }

    private func presentInsufficientDiskSpaceToStart(available: Int64, required: Int64) {
        Log.recording.error("Not enough disk space to start recording: \(available, privacy: .public) bytes available, \(required, privacy: .public) required")
        let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        let requiredText = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
        presentWarning(
            title: String(localized: "Not Enough Disk Space to Record"),
            message: String(localized: "Recording needs at least \(requiredText) of free disk space, and only \(availableText) is available. Free up space and try again.")
        )
    }

    private func presentInterruptionKept(_ interruption: Interruption, keptDuration: TimeInterval) {
        let keptTime = RecordingControlBar.format(.seconds(max(0, keptDuration)))
        switch interruption {
        case .writerFailed(let stoppedAt, _):
            let stoppedTime = RecordingControlBar.format(stoppedAt)
            presentWarning(
                title: String(localized: "Recording Stopped Unexpectedly"),
                message: String(localized: "Writing the recording failed at \(stoppedTime). The recording up to \(keptTime) was kept.")
            )
        case .lowDiskSpace(let stoppedAt):
            let stoppedTime = RecordingControlBar.format(stoppedAt)
            presentWarning(
                title: String(localized: "Recording Stopped — Disk Space Low"),
                message: String(localized: "Recording stopped at \(stoppedTime) because disk space ran low. The recording up to \(keptTime) was kept.")
            )
        }
    }

    private func presentInterruptionNoFrames(_ interruption: Interruption) {
        switch interruption {
        case .writerFailed(let stoppedAt, _):
            let stoppedTime = RecordingControlBar.format(stoppedAt)
            presentWarning(
                title: String(localized: "Recording Stopped Unexpectedly"),
                message: String(localized: "Writing the recording failed at \(stoppedTime) before any frames were saved.")
            )
        case .lowDiskSpace(let stoppedAt):
            let stoppedTime = RecordingControlBar.format(stoppedAt)
            presentWarning(
                title: String(localized: "Recording Stopped — Disk Space Low"),
                message: String(localized: "Recording stopped at \(stoppedTime) because disk space ran low before any frames were saved.")
            )
        }
    }

    private func presentInterruptionKeepFailed(_ interruption: Interruption) {
        switch interruption {
        case .writerFailed(let stoppedAt, _):
            let stoppedTime = RecordingControlBar.format(stoppedAt)
            presentWarning(
                title: String(localized: "Recording Stopped Unexpectedly"),
                message: String(localized: "Writing the recording failed at \(stoppedTime), and the recording couldn’t be finished yet. OhMyShot kept the draft and will try again next time it starts.")
            )
        case .lowDiskSpace(let stoppedAt):
            let stoppedTime = RecordingControlBar.format(stoppedAt)
            presentWarning(
                title: String(localized: "Recording Stopped — Disk Space Low"),
                message: String(localized: "Recording stopped at \(stoppedTime) because disk space ran low, and the recording couldn’t be finished yet. Free up space — OhMyShot kept the draft and will try again next time it starts.")
            )
        }
    }

    private func presentPartialStudioSaveAlert(_ result: StudioProjectSaveResult) {
        var kept = [String(localized: "screen recording")]
        var missing: [String] = []
        if result.expectedCamera {
            if result.savedCamera { kept.append(String(localized: "camera video")) }
            else { missing.append(String(localized: "camera video")) }
        }
        if result.savedTelemetry { kept.append(String(localized: "pointer and zoom data")) }
        else { missing.append(String(localized: "pointer and zoom data")) }
        if result.savedProject { kept.append(String(localized: "Studio project settings")) }
        else { missing.append(String(localized: "Studio project settings")) }
        let keptList = ListFormatter.localizedString(byJoining: kept)
        let missingList = ListFormatter.localizedString(byJoining: missing)
        presentWarning(
            title: String(localized: "Studio Recording Partially Saved"),
            message: String(localized: "Kept: \(keptList)\nNot saved: \(missingList)\n\nOhMyShot kept the recording draft and will try again next time it starts.")
        )
    }

    private func presentWarning(title: String, message: String) {
        NSSound.beep()
        VoiceOver.announce("\(title) \(message)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Keeps a clip saved from the replay as a stopped recording is kept: history, clipboard, card. Named for
    /// when it began and the app in front now. A replay has no draft to be kept from again, and its seconds are gone from
    /// the buffer, so a clip History can't take goes to the export folder under that name instead, as Save would save it
    /// (`.folder`); one that can't go there either stays where it is, and the error is thrown.
    func keepReplay(_ movie: RecordingFinisher.Movie, savedAt: Date, displayID: CGDirectDisplayID, pixelsPerPoint: Double?) async throws -> HistoryStore.Moved {
        let startedAt = savedAt.addingTimeInterval(-movie.duration)
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        let moved = try history.add(
            movingFileAt: movie.url, name: fileName(startedAt: startedAt, appName: appName), kind: .recording, pixelWidth: movie.pixelWidth,
            pixelHeight: movie.pixelHeight, appName: appName, duration: movie.duration, pixelsPerPoint: pixelsPerPoint,
            orSavingInto: settings.exportDirectory
        )
        guard case .history(let entry) = moved else { return moved }
        onRecordingCompleted?()
        await present(entry, displayID: displayID)
        onKept?(entry)
        return moved
    }

    /// A recording's name, from the file name pattern. A recording is the one file it will ever be, so it takes its
    /// number now (a screenshot takes one when a copy is saved), and its saved copy keeps the name.
    private func fileName(startedAt: Date, appName: String?) -> String {
        settings.reserveFileName(date: startedAt, appName: appName, windowTitle: nil).name
    }

    /// Moves a made file into the history and hands it on as a capture is: copied, saved when Settings
    /// says so, and given a card.
    private func deliver(
        _ file: KeptFile, startedAt: Date, appName: String?, pixelsPerPoint: Double?, displayID: CGDirectDisplayID,
        countsAsRecording: Bool = false, copiesToClipboard: Bool = true
    ) async throws -> HistoryItem {
        let name = fileName(startedAt: startedAt, appName: appName)
        let entry = try history.add(
            movingFileAt: file.url, name: name, kind: .recording, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight,
            appName: appName, duration: file.duration, pixelsPerPoint: pixelsPerPoint
        )
        if countsAsRecording { onRecordingCompleted?() }
        await present(entry, displayID: displayID, copiesToClipboard: copiesToClipboard)
        onKept?(entry)
        return entry
    }

    /// Hands a kept recording on as a capture is: copied, saved, uploaded, and given a card as the choices Settings has
    /// for recordings say.
    private func present(_ entry: HistoryItem, displayID: CGDirectDisplayID, copiesToClipboard: Bool = true) async {
        let url = history.fileURL(for: entry)
        let after = settings.afterCapture(for: .recording)
        if copiesToClipboard, after.copies, !leavesClipboard {
            PasteboardWriter.write(fileURL: url)
            copiedToClipboard?(entry.id)
        }
        let thumbnail = await HistoryStore.thumbnail(of: url, maxPixels: QuickAccessItem.thumbnailPixels) ?? Self.blankThumbnail
        var item = QuickAccessItem(entry, fileURL: url, thumbnail: thumbnail, displayID: displayID)
        let saved = after.saves ? files.saveRecording(fileAt: url) : nil
        item.savedURL = saved?.url
        item.ownSavedURL = saved?.url
        if after.uploads { uploadKept?(entry) }
        onRecorded?(item)
        if let failure = saved?.failure { saveFailed?(failure, entry.id) }
    }

    /// Saves a copy of a recording from its window or Studio, which beep when it is not saved; why is said by the pointer.
    private func saveCopy(of url: URL) -> URL? {
        let saved = files.saveRecording(fileAt: url)
        if let failure = saved.failure { saveFailed?(failure, nil) }
        return saved.url
    }

    private func makeFile(of draft: RecordingDrafts.Draft, as output: RecordingOutput, at destination: URL) async throws -> KeptFile {
        switch output {
        case .video, .studio:
            let movie = try await RecordingFinisher.finish(draft.movieURL, to: destination)
            return KeptFile(url: movie.url, pixelWidth: movie.pixelWidth, pixelHeight: movie.pixelHeight, duration: movie.duration, byteCount: movie.byteCount)
        case .gif:
            VoiceOver.announce(String(localized: "Making the GIF."))
            // As large as things were on screen: half the pixels of a Retina recording.
            let options = GIFMaker.Options(framesPerSecond: settings.recordingGIFFrameRate, scale: 1 / max(draft.info?.pixelsPerPoint ?? 1, 1))
            let probe = LatencyProbe("recording.gif")
            let gif = try await GIFMaker.make(from: draft.movieURL, to: destination, options: options) { [weak self] fraction in
                Task { @MainActor in self?.showMaking(fraction) }
            }
            probe.end()
            Log.recording.notice("Made a GIF of \(gif.frameCount, privacy: .public) frames at \(options.framesPerSecond, privacy: .public) fps")
            return KeptFile(url: gif.url, pixelWidth: gif.pixelWidth, pixelHeight: gif.pixelHeight, duration: gif.duration, byteCount: gif.byteCount)
        }
    }

    /// Finishes what a crash or a forced quit left in the drafts folder: Studio drafts with saved telemetry
    /// restore as Studio projects; plain recordings restore without overwriting the user's clipboard on launch.
    /// A partial Studio draft whose movie is already in History retries only its missing Studio assets into
    /// that entry. A leftover movie verified as unreadable is removed once it is a week old.
    func recoverLeftovers() {
        let leftovers = drafts.leftovers(excluding: Set([session?.draft.id].compactMap(\.self)))
        guard !leftovers.isEmpty else { return }
        Log.recording.notice("Finishing \(leftovers.count, privacy: .public) recording(s) left from before")
        let displayID = displays.layout.primary?.id ?? 0
        Task {
            var recoveredStudio = 0
            var recoveredWithoutTelemetry = 0
            var recoveredPlain = 0
            for draft in leftovers {
                if let historyID = draft.info?.keptHistoryID {
                    if await recoverPartialStudioDraft(draft, historyID: historyID) {
                        recoveredStudio += 1
                    }
                    continue
                }
                let makesGIF = draft.info?.output == .gif
                if makesGIF {
                    makingGIFs += 1
                    showStatusAfterRecording()
                }
                let outcome = await keep(
                    draft, plan: nil, displayID: displayID, writer: nil,
                    copiesToClipboard: false, isRecovery: true
                )
                switch outcome {
                case .studio: recoveredStudio += 1
                case .studioWithoutTelemetry: recoveredWithoutTelemetry += 1
                case .plain: recoveredPlain += 1
                case .failed: break
                }
                if makesGIF { madeGIF() }
                if await drafts.pruneIfExpiredAndUnreadable(draft) {
                    Log.recording.notice("Removed unreadable draft \(draft.id.uuidString, privacy: .public) older than a week")
                }
            }
            if recoveredWithoutTelemetry > 0 {
                notice.show(String(localized: "Recovered recording restored without Studio pointer data."), near: NSEvent.mouseLocation)
            } else if recoveredStudio > 0, recoveredPlain == 0 {
                notice.show(String(localized: "Recovered Studio recording restored."), near: NSEvent.mouseLocation)
            } else if recoveredStudio + recoveredPlain > 0 {
                notice.show(String(localized: "Recovered recording restored."), near: NSEvent.mouseLocation)
            }
        }
    }

    @discardableResult
    private func recoverPartialStudioDraft(_ draft: RecordingDrafts.Draft, historyID: UUID) async -> Bool {
        let outcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: historyID,
            telemetryURL: draft.telemetryURL,
            cameraURL: draft.cameraURL,
            in: history,
            expectedMovieByteCount: draft.info?.keptMovie?.byteCount,
            expectedMovieModifiedAt: draft.info?.keptMovie?.modifiedAt,
            hasReadableVideo: RecordingDrafts.hasReadableVideo(at:)
        )
        switch outcome {
        case .completed:
            if let entry = history.item(id: historyID), !StudioSound.areKept(in: history.studioURL(for: entry)) {
                await keepStudioSounds(from: draft.movieURL, for: entry)
            }
            drafts.remove(draft)
            Log.recording.notice("Finished recovering Studio assets for history \(historyID.uuidString, privacy: .public)")
            return true
        case .incomplete(let result):
            Log.recording.error("Recovering Studio assets for history \(historyID.uuidString, privacy: .public) still incomplete: \(result.errorDescription ?? "unknown error", privacy: .private)")
            return false
        case .movieReplaced:
            drafts.remove(draft)
            Log.recording.notice("Dropped Studio draft \(draft.id.uuidString, privacy: .public) for history \(historyID.uuidString, privacy: .public) because the kept movie was replaced")
            return false
        case .discarded:
            drafts.remove(draft)
            Log.recording.notice("Removed orphaned Studio draft \(draft.id.uuidString, privacy: .public) for history \(historyID.uuidString, privacy: .public)")
            return false
        }
    }

    /// Stops a recording before the app quits, and keeps the edits in open recording windows; `done` runs
    /// once every recording is kept. Returns false when there was nothing to wait for.
    func finishBeforeQuitting(_ done: @escaping (Bool) -> Void) -> Bool {
        switch phase {
        case .countingDown: cancelCountdown()
        case .starting, .recording: stop()
        case .idle: break
        }
        // Edits in an open recording window are kept as its closing keeps them.
        for window in windows.values where window.hasUnkeptEdits {
            finishing += 1
            window.close { [weak self] in self?.finished() }
        }
        // A GIF being made in Studio is stopped as its window closes, and its files removed before the app quits.
        for window in studioWindows.values where window.hasUnexportedChanges || window.hasPendingProjectSave || window.isMakingGIF {
            finishing += 1
            window.closeIfSaved { [weak self] saved in self?.finished(permitsQuit: saved) }
        }
        guard finishing > 0 else { return false }
        finishingDone.append(done)
        return true
    }

    private func finished(permitsQuit: Bool = true) {
        finishingMayQuit = finishingMayQuit && permitsQuit
        finishing -= 1
        guard finishing == 0 else { return }
        let done = finishingDone
        finishingDone = []
        let mayQuit = finishingMayQuit
        finishingMayQuit = true
        done.forEach { $0(mayQuit) }
    }

    // MARK: Editing

    /// Open recording windows, by the recording's place in the history.
    private var windows: [UUID: RecordingWindowController] = [:]
    /// The recordings with a window open (a recording window, or a Studio window that is open or still exporting
    /// after it closed): they hold their files, which the windows keep edits in.
    var openRecordingIDs: Set<UUID> { Set(windows.keys).union(studioWindows.keys) }
    /// A recording's window closed for good, and no longer holds the recording.
    var windowClosed: ((UUID) -> Void)?
    /// A kept recording changed (edited, or put back as it was made): the composition root refreshes its
    /// card and Capture History.
    var onChanged: ((HistoryItem) -> Void)?
    var onSaved: ((UUID, URL, Bool) -> Void)?

    /// Opens a kept recording in the recording window: to play, trim, leave the sound out, make smaller, or
    /// make a GIF of; a GIF only plays.
    func open(_ entry: HistoryItem) {
        // A Studio recording opens in the Studio window, to be filmed again.
        if history.hasStudioProject(entry) {
            Task { await openStudio(entry) }
            return
        }
        if let window = windows[entry.id] { return window.show() }
        makeWindow(for: entry).show()
    }

    // MARK: Studio

    /// Open Studio windows, by the recording's place in the history.
    private var studioWindows: [UUID: StudioWindowController] = [:]
    /// The display each Studio recording was made on, for the card its first movie brings.
    private var studioDisplays: [UUID: CGDirectDisplayID] = [:]

    /// Opens a Studio recording in the Studio window: its telemetry and project from beside it, the recording
    /// as it was made (in the project once a movie has taken its place in the history). `shows` false makes
    /// the window without showing it, for scripted checks.
    func openStudio(_ entry: HistoryItem, shows: Bool = true) async {
        if let window = studioWindows[entry.id] {
            if shows { window.show() }
            return
        }
        let folder = history.studioURL(for: entry)
        guard
            let data = try? Data(contentsOf: folder.appending(path: StudioFiles.telemetry)),
            let telemetry = try? JSONDecoder().decode(StudioTelemetry.self, from: data)
        else {
            Log.recording.error("The Studio project has no telemetry; opening the recording window")
            return makeWindow(for: entry).show()
        }
        let saved = (try? Data(contentsOf: folder.appending(path: StudioFiles.project))).flatMap { try? JSONDecoder().decode(StudioProject.self, from: $0) }
        let source: URL
        do {
            source = try history.studioSource(for: entry)
        } catch {
            Log.recording.error("The Studio project has lost the recording as it was made; opening the recording window: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            return makeWindow(for: entry).show()
        }
        let asset = AVURLAsset(url: source)
        guard
            let duration = try? await asset.load(.duration).seconds,
            let size = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        else {
            NSSound.beep()
            return
        }
        let project = saved ?? StudioProject(zooms: AutoZoom.zooms(for: telemetry, duration: duration))
        // The movie in the history is the project's own while it was made with the project as it is: a change
        // made while the last one was being made, then closed on, isn't in it.
        let made = history.studioMovieProject(of: entry).flatMap { try? JSONDecoder().decode(StudioProject.self, from: $0) }
        // Compared as Studio opens them: the times the camera filled what was recorded are stretches by then.
        let hasBeenExported = made?.opened(for: telemetry, duration: duration) == project.opened(for: telemetry, duration: duration)
        let document = StudioDocument(
            source: source, telemetry: telemetry, project: project, duration: duration, recordingSize: size, folder: folder,
            hasBeenExported: hasBeenExported,
            background: { name, size in BackdropGradient(rawValue: name)?.image(width: Int(size.width), height: Int(size.height)) }
        )
        let swatches = BackdropGradient.allCases.compactMap { gradient in
            gradient.image(width: 88, height: 60).map { StudioWindowController.Swatch(name: gradient.rawValue, title: gradient.title, picture: $0) }
        }
        let id = entry.id
        let controller = StudioWindowController(
            document: document, title: (entry.fileName as NSString).deletingPathExtension, swatches: swatches,
            movie: hasBeenExported ? history.fileURL(for: entry) : nil,
            actions: .init(
                keep: { [weak self] movie, project in
                    guard let self else { throw CocoaError(.userCancelled) }
                    return try keepStudioMovie(movie, madeWith: project, of: id)
                },
                copy: { [weak self] url in self?.files.copy(fileAt: url) },
                save: { [weak self] url in self?.saveCopy(of: url) },
                progress: { [weak self] fraction in self?.showStudioExport(fraction) },
                makeGIF: { [weak self] movie, progress in
                    guard let self, let entry = history.item(id: id) else { throw CocoaError(.userCancelled) }
                    // As large as things were on screen, as a GIF recorded is: the movie is filmed at the recording's pixels.
                    let options = GIFMaker.Options(framesPerSecond: settings.recordingGIFFrameRate, scale: 1 / max(entry.pixelsPerPoint ?? 1, 1))
                    try await keepGIF(of: movie, as: options, madeFrom: entry, displayID: studioDisplays[id], progress: progress)
                }
            )
        )
        controller.onSaved = { [weak self] destination, isCurrent in self?.onSaved?(id, destination, isCurrent) }
        controller.onClose = { [weak self] in
            self?.studioWindows[id] = nil
            self?.windowClosed?(id)
            MemoryRelief.returnFreedPages()
        }
        studioWindows[id] = controller
        if shows { controller.show() }
    }

    /// Keeps a movie exported from Studio in the recording's place. The first one brings the recording's
    /// card and goes to the clipboard, as a stopped recording would; later ones refresh the card.
    private func keepStudioMovie(_ movie: StudioExporter.Movie, madeWith project: StudioProject, of id: UUID) throws -> URL {
        guard let entry = history.item(id: id) else { throw CocoaError(.fileNoSuchFile) }
        var first = !history.hasStudioMovie(entry)
        #if DEBUG
        // The demo's movie brings no card, and so nothing on the clipboard and no saved copy.
        if id == debugStudioDemoID { first = false }
        #endif
        let updated = try history.replaceStudioMovie(
            of: entry, withFileAt: movie.url, pixelWidth: movie.pixelWidth, pixelHeight: movie.pixelHeight, duration: movie.duration,
            project: try JSONEncoder().encode(project)
        )
        Log.recording.notice("Kept a Studio movie: \(movie.duration, format: .fixed(precision: 2), privacy: .public) s, \(movie.pixelWidth, privacy: .public)x\(movie.pixelHeight, privacy: .public), \(movie.byteCount, privacy: .public) bytes")
        if first {
            let displayID = studioDisplays[id] ?? displays.layout.pointerDisplay?.id ?? 0
            Task { await present(updated, displayID: displayID) }
        } else {
            onChanged?(updated)
        }
        return history.fileURL(for: updated)
    }

    /// Whether a Studio movie is being exported after its window closed.
    var isExportingStudio: Bool {
        studioWindows.values.contains { $0.isExportingAfterClosing }
    }

    /// Stops the Studio exports running after their windows closed: the history keeps the movies it had.
    func cancelStudioExports() {
        for window in studioWindows.values where window.isExportingAfterClosing {
            window.cancelExport()
        }
        VoiceOver.announce(String(localized: "Studio export cancelled."))
    }

    /// How far along a Studio export is while its window is gone, in the menu bar; nil when it is done.
    private func showStudioExport(_ fraction: Double?) {
        guard case .idle = phase else { return }
        guard let fraction else { return showStatusAfterRecording() }
        report(.exportingStudio(progress: fraction))
    }

    /// Imports a standalone `.omsstudio` project package into Capture History and opens it in Studio.
    func importStudioPackage(at packageURL: URL) async {
        let staging = FileManager.default.temporaryDirectory.appending(path: "omsstudio-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stagedMovie = staging.appending(path: "movie.mp4")
        let stagedStudio = staging.appending(path: "studio", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let imported = try await Self.stageStudioPackageImport(from: packageURL, movieURL: stagedMovie, studioFolder: stagedStudio)
            let asset = AVURLAsset(url: stagedMovie)
            let duration = try await asset.load(.duration).seconds
            let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
            let pixelWidth = max(2, Int(size.width.rounded()))
            let pixelHeight = max(2, Int(size.height.rounded()))
            let name = packageURL.deletingPathExtension().lastPathComponent
            let entry = try history.add(
                movingFileAt: stagedMovie, name: name.isEmpty ? "Studio Recording" : name, kind: .recording,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, appName: nil, duration: duration,
                pixelsPerPoint: imported.telemetry.pixelsPerPoint
            )
            let studioDestination = history.studioURL(for: entry)
            if FileManager.default.fileExists(atPath: studioDestination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: studioDestination)
            }
            try FileManager.default.moveItem(at: stagedStudio, to: studioDestination)
            onKept?(entry)
            await openStudio(entry)
        } catch {
            Log.recording.error("Importing Studio package \(packageURL.lastPathComponent, privacy: .private) failed: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "The Studio project couldn’t be opened")
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @concurrent
    private nonisolated static func stageStudioPackageImport(
        from packageURL: URL, movieURL: URL, studioFolder: URL
    ) async throws -> (telemetry: StudioTelemetry, project: StudioProject) {
        try StudioPackage.importPackage(at: packageURL, toMovieURL: movieURL, studioFolder: studioFolder)
    }

    private func makeWindow(for entry: HistoryItem) -> RecordingWindowController {
        let id = entry.id
        let controller = RecordingWindowController(
            fileURL: history.fileURL(for: entry), title: (entry.fileName as NSString).deletingPathExtension,
            pixelWidth: entry.pixelWidth, pixelHeight: entry.pixelHeight, pixelsPerPoint: entry.pixelsPerPoint,
            hasOriginal: history.hasOriginal(entry),
            defaultGIFFrameRate: settings.recordingGIFFrameRate,
            actions: .init(
                keep: { [weak self] edit, progress in
                    guard let self else { throw CocoaError(.userCancelled) }
                    return try await keepEdit(edit, of: id, progress: progress)
                },
                revert: { [weak self] in
                    guard let self, let entry = history.item(id: id) else { throw CocoaError(.fileNoSuchFile) }
                    let restored = try await history.restoreRecording(of: entry)
                    onChanged?(restored)
                    return history.fileURL(for: restored)
                },
                makeGIF: { [weak self] edit, progress in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await makeGIF(of: id, edit: edit, progress: progress)
                },
                save: { [weak self] url in self?.saveCopy(of: url) },
                copy: { [weak self] url in self?.files.copy(fileAt: url) }
            )
        )
        controller.onSaved = { [weak self] destination, isCurrent in self?.onSaved?(id, destination, isCurrent) }
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in
            self?.windows[id] = nil
            self?.windowClosed?(id)
        }
        windows[id] = controller
        return controller
    }

    /// Makes the recording with `edit` and keeps it in place of the recording.
    private func keepEdit(_ edit: RecordingEdit, of id: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let entry = history.item(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let probe = LatencyProbe("recording.edit")
        // Written in the recording's own container: a MOV opened from Finder stays a QuickTime movie.
        let edited = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\((entry.fileName as NSString).pathExtension)")
        do {
            try Task.checkCancellation()
            let movie = try await RecordingFinisher.export(history.fileURL(for: entry), to: edited, edits: Self.edits(edit), progress: progress)
            try Task.checkCancellation()
            let updated = try history.replaceRecording(
                of: entry, withFileAt: movie.url, pixelWidth: movie.pixelWidth, pixelHeight: movie.pixelHeight, duration: movie.duration
            )
            probe.end()
            Log.recording.notice("Edited a recording: \(movie.duration, format: .fixed(precision: 2), privacy: .public) s, \(movie.pixelWidth, privacy: .public)x\(movie.pixelHeight, privacy: .public), audio \(movie.hasAudio, privacy: .public), \(movie.byteCount, privacy: .public) bytes")
            onChanged?(updated)
            return history.fileURL(for: updated)
        } catch {
            try? FileManager.default.removeItem(at: edited)
            if !(error is CancellationError), !Task.isCancelled {
                Log.recording.error("Editing the recording failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            }
            throw error
        }
    }

    /// Makes a GIF of the recording with `edit` (its part and size; a GIF has no sound) and keeps it as a
    /// recording of its own, with a card. The GIF is never larger than things were on screen.
    private func makeGIF(of id: UUID, edit: RecordingEdit, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let entry = history.item(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let onScreen = 1 / max(entry.pixelsPerPoint ?? 1, 1)
        let gifFrameRate = edit.gifOptions?.framesPerSecond ?? settings.recordingGIFFrameRate
        let gifScale = min(edit.scale, onScreen) * (edit.gifOptions?.scale ?? 1.0)
        let options = GIFMaker.Options(
            framesPerSecond: gifFrameRate, scale: gifScale, timeRange: edit.timeRange
        )
        try await keepGIF(of: history.fileURL(for: entry), as: options, madeFrom: entry, progress: progress)
    }

    /// Makes a GIF of `movie` with `options` and keeps it as a recording of its own beside `entry`, the recording it was
    /// made from, with a card on `displayID` (the pointer's display when nil).
    private func keepGIF(
        of movie: URL, as options: GIFMaker.Options, madeFrom entry: HistoryItem, displayID: CGDirectDisplayID? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        do {
            try Task.checkCancellation()
            let gif = try await GIFMaker.make(from: movie, to: destination, options: options, progress: progress)
            // Cancelled as it was finished: nothing is kept.
            try Task.checkCancellation()
            let displayID = displayID ?? displays.layout.pointerDisplay?.id ?? 0
            let file = KeptFile(url: gif.url, pixelWidth: gif.pixelWidth, pixelHeight: gif.pixelHeight, duration: gif.duration, byteCount: gif.byteCount)
            let made = try await deliver(file, startedAt: entry.createdAt, appName: entry.appName, pixelsPerPoint: entry.pixelsPerPoint, displayID: displayID)
            Log.recording.notice("Made a GIF of a recording: \(gif.frameCount, privacy: .public) frames, \(gif.pixelWidth, privacy: .public)x\(gif.pixelHeight, privacy: .public), \(gif.byteCount, privacy: .public) bytes as \(made.fileName, privacy: .private)")
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func edits(_ edit: RecordingEdit) -> RecordingFinisher.Edits {
        RecordingFinisher.Edits(timeRange: edit.timeRange, keepsAudio: edit.keepsAudio, scale: edit.scale, volume: edit.volume, quality: edit.quality)
    }

    #if DEBUG
    /// The demo recording in the history while the recording window is checked.
    private var debugDemoID: UUID?

    /// Puts a copy of `movie` in the history as a recording and opens it in the recording window behind the
    /// desktop picture, nothing shown. Returns the window.
    func debugOpenDemo(movie: URL, dark: Bool) async -> NSWindow? {
        debugRemoveDemo()
        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(movie.pathExtension)")
        do {
            try FileManager.default.copyItem(at: movie, to: copy)
            let asset = AVURLAsset(url: copy)
            let duration = try await asset.load(.duration).seconds
            let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
            let entry = try history.add(
                movingFileAt: copy, name: "Demo Recording", kind: .recording, pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                appName: "Demo", duration: duration, pixelsPerPoint: 2
            )
            debugDemoID = entry.id
            let controller = makeWindow(for: entry)
            controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.showBehindWallpaper()
            return controller.window
        } catch {
            Log.app.error("debug.record-window could not open the demo: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Opens the demo in the recording window again, behind the desktop picture.
    func debugReopenDemo() -> NSWindow? {
        guard let id = debugDemoID, let entry = history.item(id: id) else { return nil }
        let controller = windows[id] ?? makeWindow(for: entry)
        controller.showBehindWallpaper()
        return controller.window
    }

    /// The recording window on the demo, while it is open.
    var debugDemoWindow: RecordingWindowController? {
        debugDemoID.flatMap { windows[$0] }
    }

    /// The demo's record as the history has it now.
    var debugDemoState: String {
        guard let id = debugDemoID, let entry = history.item(id: id) else { return "no demo" }
        return "\(entry.pixelWidth)x\(entry.pixelHeight), \(String(format: "%.2f", entry.duration ?? 0)) s, original kept \(history.hasOriginal(entry)), window open \(windows[id] != nil)"
    }

    /// The Studio demo in the history while the Studio window is checked.
    private var debugStudioDemoID: UUID?

    /// Puts a copy of `movie` in the history as a Studio recording with `telemetry` and opens it in the Studio
    /// window behind the desktop picture, nothing shown. Returns the window.
    func debugOpenStudioDemo(movie: URL, telemetry: StudioTelemetry, dark: Bool, camera: URL? = nil) async -> NSWindow? {
        debugRemoveStudioDemo()
        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        do {
            try FileManager.default.copyItem(at: movie, to: copy)
            let asset = AVURLAsset(url: copy)
            let duration = try await asset.load(.duration).seconds
            let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
            let entry = try history.add(
                movingFileAt: copy, name: "Demo Studio Recording", kind: .recording, pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                appName: "Demo", duration: duration, pixelsPerPoint: 2
            )
            debugStudioDemoID = entry.id
            var project = StudioProject(zooms: AutoZoom.zooms(for: telemetry, duration: duration))
            project.camera = telemetry.camera?.bubble ?? StudioProject.Camera()
            _ = saveStudioProject(telemetry, project: project, camera: camera, for: entry)
            await openStudio(entry, shows: false)
            guard let controller = studioWindows[entry.id] else { return nil }
            controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.showBehindWallpaper()
            return controller.window
        } catch {
            Log.app.error("debug.studio-window could not open the demo: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Closes the Studio demo's window without exporting and opens the demo again, as Edit… on its card
    /// would, behind the desktop picture. Returns the window.
    func debugReopenStudioDemo(dark: Bool) async -> NSWindow? {
        guard let id = debugStudioDemoID, let entry = history.item(id: id) else { return nil }
        studioWindows[id]?.debugCloseWithoutExporting()
        studioWindows[id] = nil
        await openStudio(entry, shows: false)
        guard let controller = studioWindows[id] else { return nil }
        controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.showBehindWallpaper()
        return controller.window
    }

    var debugStudioDemoWindow: StudioWindowController? {
        debugStudioDemoID.flatMap { studioWindows[$0] }
    }

    var debugStudioDemoState: String {
        guard let id = debugStudioDemoID, let entry = history.item(id: id) else { return "no demo" }
        return "\(entry.pixelWidth)x\(entry.pixelHeight), \(String(format: "%.2f", entry.duration ?? 0)) s, movie kept \(history.hasStudioMovie(entry)), source kept \(FileManager.default.fileExists(atPath: history.studioSourceURL(for: entry).path(percentEncoded: false))), window open \(studioWindows[id] != nil), preview \(studioWindows[id]?.studio.composition.map { "\(Int($0.renderer.layout.canvas.width))x\(Int($0.renderer.layout.canvas.height))" } ?? "none"), player \(studioWindows[id]?.debugPlayerState ?? "none"), frames asked \(StudioComposition.debugCompositorCounts.asked) drawn \(StudioComposition.debugCompositorCounts.drawn)"
    }

    /// Closes the Studio demo's window and removes the demo, its project too, from the history.
    func debugRemoveStudioDemo() {
        guard let id = debugStudioDemoID else { return }
        debugStudioDemoID = nil
        studioWindows[id]?.debugCloseWithoutExporting()
        studioWindows[id] = nil
        if let entry = history.item(id: id) { history.delete(entry) }
    }

    /// Closes the demo's window without keeping edits and removes the demo from the history.
    func debugRemoveDemo() {
        guard let id = debugDemoID else { return }
        debugDemoID = nil
        windows[id]?.debugDiscardAndClose()
        if let entry = history.item(id: id) { history.delete(entry) }
    }
    #endif

    // MARK: Chrome

    /// The area's highlight (areas only: a window moves, a display needs none), the control bar, and the clock.
    private func showChrome(for plan: Plan, source: ScreenCapturer.RecordingSource) {
        let area = Self.area(of: plan, recorded: source.frame)
        // The countdown's outline stays up; it is shown here only when there was no countdown.
        if case .area = plan.target {
            if !outline.isShowing { outline.show(area, layout: displays.layout, style: settings.recordingHighlight) }
        } else {
            outline.hide()
        }
        if settings.recordingShowsControls {
            // Inside a whole display, the bar keeps clear of the keys shown at its foot.
            controls.show(
                by: area, displays: displays.layout.displays.map(\.frame), clearing: keystrokes == nil ? 0 : KeystrokeDisplay.reservedHeight,
                microphone: plan.choices.recordsMicrophone ? .metered : microphoneDenied ? .denied : .none
            )
        }
        if plan.choices.recordsMicrophone || plan.choices.recordsSystemAudio { startMeter() }
        startTicking()
    }

    private func endChrome() {
        ticker?.cancel()
        ticker = nil
        tickerLease = nil
        meter?.cancel()
        meter = nil
        meterLease = nil
        outline.hide()
        controls.hide()
        keyMonitor?.stop()
        keyMonitor = nil
        keystrokes?.hide()
        keystrokes = nil
        clickRings?.hide()
        clickRings = nil
        camera.hide()
        endTemporaryDesktopHide()
        showStatusAfterRecording()
    }

    private func endTemporaryDesktopHide() {
        guard hidesDesktopForRecording else { return }
        hidesDesktopForRecording = false
        desktopIcons?.endTemporaryHide()
    }

    /// The menu bar once nothing is recording: how far along a GIF is, or the icon. A recording counting
    /// down or running has the menu bar to itself.
    private func showStatusAfterRecording() {
        guard case .idle = phase else { return }
        report(makingGIFs > 0 ? .makingGIF(progress: gifProgress) : .idle)
    }

    private func report(_ status: Status) {
        #if DEBUG
        // What the menu bar is shown, each time it turns to another kind, for scripted checks.
        let kind = switch status {
        case .recording: "recording"
        case .makingGIF: "making a GIF"
        case .exportingStudio: "exporting a Studio movie"
        case .idle: "idle"
        }
        if kind != debugStatusKind {
            debugStatusKind = kind
            Log.recording.notice("Menu bar: \(kind, privacy: .public)")
        }
        #endif
        onStatus?(status)
    }

    private func showMaking(_ fraction: Double) {
        guard makingGIFs > 0 else { return }
        gifProgress = fraction
        showStatusAfterRecording()
    }

    private func madeGIF() {
        makingGIFs -= 1
        if makingGIFs == 0 { gifProgress = 0 }
        showStatusAfterRecording()
    }

    /// Once a second, on whole seconds of the recording: the control bar's time and the menu bar's.
    private func startTicking() {
        ticker?.cancel()
        tickerLease = ActiveResources.shared.acquire(.timer)
        tick()
        ticker = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                next = next.advanced(by: .seconds(1))
                do {
                    try await clock.sleep(until: next, tolerance: .milliseconds(100))
                } catch {
                    return
                }
                self?.tick()
            }
        }
    }

    /// The control bar's microphone meter, read ten times a second from the stream; still while paused. The
    /// same pass notices a microphone that stops sending sound, as a headset that was switched off does.
    private func startMeter() {
        meter?.cancel()
        meterLease = ActiveResources.shared.acquire(.timer)
        microphoneStalled = false
        systemAudioStalled = false
        meter = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100), tolerance: .milliseconds(20))
                } catch {
                    return
                }
                guard let self, let recorder = session?.recorder else { return }
                watchSound(of: recorder)
                let level = recorder.takeMicrophoneLevel() ?? 0
                controls.update(microphoneLevel: recorder.state == .recording ? level : 0)
            }
        }
    }

    /// Shows a visible notice, logs, and announces when the microphone or system audio stops arriving, once per stall,
    /// and clears the warning when sound resumes. Pausing clears both, and resuming counts the seconds again.
    private func watchSound(of recorder: ScreenRecorder) {
        let microphone = recorder.isMicrophoneStalled
        if microphone != microphoneStalled {
            microphoneStalled = microphone
            controls.update(microphoneStalled: microphone)
            if microphone {
                Log.recording.error("The microphone stopped sending sound")
                notice.show(String(localized: "The microphone stopped sending sound. It may have been disconnected."), near: NSEvent.mouseLocation)
            } else if recorder.state == .recording {
                Log.recording.notice("The microphone is sending sound again")
            }
        }
        let system = recorder.isSystemAudioStalled
        if system != systemAudioStalled {
            systemAudioStalled = system
            if system {
                Log.recording.notice("The Mac's sound stopped arriving")
                notice.show(String(localized: "System audio stopped arriving."), near: NSEvent.mouseLocation)
            } else if recorder.state == .recording {
                Log.recording.notice("The Mac's sound is arriving again")
            }
        }
    }

    private func tick() {
        guard let session else { return }
        if session.camera != nil, syncCameraBubbleCorner(for: session.plan, recorded: session.source.frame) {
            checkpointTelemetry()
        }
        let elapsed = session.recorder.elapsed
        let paused = session.recorder.state == .paused
        controls.update(elapsed: elapsed, paused: paused)
        report(.recording(time: RecordingControlBar.format(elapsed), paused: paused))
        tickCount += 1
        let recorder = session.recorder
        Task { await recorder.checkWriterHealth() }
        if !paused, tickCount.isMultiple(of: 2) {
            checkpointTelemetry()
        }
        if !paused, tickCount.isMultiple(of: 5),
           case .insufficient(let available, let required) = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesWhileRecording) {
            Log.recording.error("Disk space ran low during recording at \(RecordingControlBar.format(elapsed), privacy: .public): \(available, privacy: .public) bytes available, \(required, privacy: .public) required")
            stop(interruption: .lowDiskSpace(stoppedAt: elapsed))
        }
    }

    /// The part of the screen a plan records, in global points: the area, the window's frame, the display.
    private static func area(of plan: Plan, recorded: CGRect? = nil) -> CGRect {
        switch plan.target {
        case .area(let rect): recorded ?? rect
        case .window(let window): window.frame
        case .display: plan.display.frame
        }
    }

    private static let blankThumbnail: CGImage = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }()

    private var leavesClipboard: Bool {
        #if DEBUG
        debugLeavesClipboard
        #else
        false
        #endif
    }
}

extension SettingsStore {
    /// The frames a second a recording and the replay take: Settings' choice, but 30 in Low Power Mode.
    var recordingFramesPerSecond: Int {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : recordingFrameRate
    }
}
