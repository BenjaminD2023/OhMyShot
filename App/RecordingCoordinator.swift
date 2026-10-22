import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import OMSAnnotate
import OMSCapture
import OMSCore
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
    private let drafts = RecordingDrafts.standard()
    private let countdown = SelfTimerCountdown()
    private let outline = AreaOutline()
    private lazy var controls = RecordingControlBar(actions: .init(
        pause: { [weak self] in self?.pause() },
        resume: { [weak self] in self?.resume() },
        restart: { [weak self] in self?.restart() },
        delete: { [weak self] in self?.delete() },
        stop: { [weak self] in self?.stop() }
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
    /// A recording was kept and Settings says to upload it.
    var uploadKept: ((HistoryItem) -> Void)?
    /// A recording's file was just put on the clipboard, which refers to the file in the history and holds nothing else.
    var copiedToClipboard: ((UUID) -> Void)?
    /// The composition root shows it in the menu bar.
    var onStatus: ((Status) -> Void)?
    /// Saves a copy of a kept recording to the export folder, as Save on its card does.
    var save: ((URL) -> URL?)?
    /// The keys of Record Screen, told to VoiceOver as the way to stop; nil when it has none.
    var shortcutKeys: (() -> String?)?

    /// What one recording is of, kept so Restart can record it again.
    private struct Plan {
        let target: RecordingTarget
        let display: DisplayInfo
        let choices: RecordingChoices
        let appName: String?
    }

    private struct Session {
        let plan: Plan
        let draft: RecordingDrafts.Draft
        let recorder: ScreenRecorder
        let source: ScreenCapturer.RecordingSource
        let startedAt: Date
        /// For a Studio recording: what the pointer and the keyboard do meanwhile.
        let telemetry: TelemetryRecorder?
        /// For a Studio recording with the camera: the camera, in a movie of its own.
        let camera: CameraRecorder?
        /// The camera's bubble showed when a Studio recording began: if no movie of it comes, Studio says so.
        let cameraWanted: Bool
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

    private var session: Session?
    /// Counting down to a recording.
    private var pending: Plan?
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
    /// Recordings being finished; the app waits for them before quitting.
    private var finishing = 0
    private var finishingDone: [() -> Void] = []
    /// Recordings being made into GIFs, and how far along the newest is: the menu bar shows it.
    private var makingGIFs = 0
    private var gifProgress = 0.0

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController, history: HistoryStore, permissions: PermissionCenter) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        self.history = history
        self.permissions = permissions
        // All-In-One sets up a recording in its own session: the bar starts with the choices it has here.
        overlay.onWillSetUpRecording = { [weak self] in self?.configureOverlayForRecording() }
    }

    var isRecording: Bool { session != nil }
    var isCountingDown: Bool { pending != nil }

    #if DEBUG
    /// The recorder running now, for scripted checks.
    var debugRecorder: ScreenRecorder? { session?.recorder }
    /// Keeps recordings off the clipboard, for scripted checks.
    var debugLeavesClipboard = false
    /// Whether a recording is still being finished, made into a GIF, or kept.
    var debugIsKeeping: Bool { finishing > 0 || makingGIFs > 0 }
    private var debugStatusKind: String?
    #endif

    // MARK: Starting

    /// Record Screen: choose what to record; while recording, stop; while counting down, cancel.
    /// - Parameter area: chosen already, in global points (the URL API's `record-screen` with an area): framed with
    ///   the recording bar at once.
    func recordScreen(area: CGRect? = nil) {
        if session != nil { return stop() }
        if pending != nil { return cancelCountdown() }
        guard !overlay.isActive else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        overlay.freezesScreen = false
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
    }

    /// A recording All-In-One set up was cancelled: the camera's preview goes.
    func recordingSetupCancelled() {
        camera.hide()
    }

    /// Records `target` on `display` without the overlay: for scripted checks, and for Restart.
    func record(_ target: RecordingTarget, on display: DisplayInfo, choices: RecordingChoices, appName: String?) {
        guard session == nil, pending == nil else { return }
        prepare(Plan(target: target, display: display, choices: choices, appName: appName))
    }

    /// Asks for the microphone if it is wanted, then counts down (or not) and starts.
    private func prepare(_ plan: Plan) {
        pending = plan
        microphoneDenied = false
        Task { [weak self] in
            guard let self else { return }
            var plan = plan
            if plan.choices.recordsMicrophone, !(await microphoneAllowed()) {
                Log.recording.notice("Recording without the microphone: access is off")
                microphoneDenied = true
                announce(String(localized: "Microphone access is off in System Settings. Recording without it."))
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
            guard pending != nil else { return }
            pending = plan
            // Restarting brings the camera back; choosing on the bar showed it already.
            showCamera(for: plan)
            let seconds = settings.recordingCountdown
            let area = Self.area(of: plan)
            if case .area = plan.target { outline.show(area, layout: displays.layout, style: settings.recordingHighlight) }
            guard seconds > 0 else { return await start(plan) }
            let keys = shortcutKeys?()
            announce(keys.map { String(localized: "Recording in \(seconds) seconds. Press \($0) to cancel.") }
                ?? String(localized: "Recording in \(seconds) seconds."))
            countdown.start(seconds: seconds, area: area, layout: displays.layout, outlinesArea: false) { [weak self] in
                Task { await self?.start(plan) }
            }
        }
    }

    private func cancelCountdown() {
        pending = nil
        countdown.cancel()
        outline.hide()
        camera.hide()
        showStatusAfterRecording()
        announce(String(localized: "Recording cancelled."))
    }

    /// Whether the microphone may be recorded, asking the first time. Reading its status starts the
    /// system's capture machinery, so it is read only when a recording wants the microphone.
    private func microphoneAllowed() async -> Bool {
        permissions.refresh([.microphone])
        switch permissions.status(of: .microphone) {
        case .granted:
            return true
        case .denied:
            return false
        case .notGranted:
            await permissions.request(.microphone)
            return permissions.status(of: .microphone) == .granted
        }
    }

    private func start(_ plan: Plan) async {
        guard pending != nil else { return }
        pending = nil
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
            let shown = Set([keys?.windowID, rings?.windowID, studio ? nil : camera.windowID].compactMap(\.self))
            let source = try await capturer.recordingSource(for: plan.target, on: plan.display, including: shown)
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            let format = RecordingFormat.choose(
                width: source.pixelWidth, height: source.pixelHeight,
                framesPerSecond: lowPower ? 30 : settings.recordingFrameRate, prefersHEVC: settings.recordingPrefersHEVC
            )
            let created = try drafts.create(.init(
                startedAt: .now, appName: plan.appName, output: plan.choices.output,
                pixelsPerPoint: source.frame.width > 0 ? Double(source.pixelWidth) / source.frame.width : nil
            ))
            draft = created
            // Studio draws the cursor and the clicks again from what the pointer did, so neither is in the picture.
            let recorder = try ScreenRecorder(ScreenRecorder.Request(
                filter: source.filter, sourceRect: source.sourceRect, format: format,
                audio: RecordingAudio(system: plan.choices.recordsSystemAudio, microphone: microphone(for: plan.choices)),
                // Rings in place of the system's circles, never both.
                showsCursor: settings.recordingShowsCursor && !studio, showsClicks: plan.choices.showsClicks && rings == nil && !studio,
                movieURL: created.movieURL
            ))
            recorder.onStreamStopped = { [weak self] error in self?.streamStopped(error) }
            // The pointer is written down from before the first frame, so the movie begins with its place.
            let telemetry = studio ? TelemetryRecorder() : nil
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
                await endCameraRecording(cameraRecorder)
                throw error
            }
            probe.end()
            session = Session(
                plan: plan, draft: created, recorder: recorder, source: source, startedAt: .now, telemetry: telemetry, camera: cameraRecorder,
                cameraWanted: cameraWanted
            )
            showChrome(for: plan, source: source)
            camera.setRecording(true)
            if let keys {
                let monitor = KeyMonitor()
                monitor.onPress = { [weak keys] key in keys?.take(key) }
                if !monitor.start() { Log.recording.error("The keystroke monitor could not start") }
                keyMonitor = monitor
            }
            let stopKeys = shortcutKeys?()
            announce(stopKeys.map { String(localized: "Recording. Press \($0) again to stop.") }
                ?? String(localized: "Recording. Click the time in the menu bar to stop."))
        } catch {
            Log.recording.error("Recording could not start: \(String(describing: error), privacy: .public)")
            if let draft { drafts.remove(draft) }
            outline.hide()
            keystrokes?.hide()
            keystrokes = nil
            clickRings?.hide()
            clickRings = nil
            camera.hide()
            showStatusAfterRecording()
            NSSound.beep()
            announce(String(localized: "The recording couldn’t start."))
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
                url: draft.cameraURL, width: Int(dimensions.width), height: Int(dimensions.height), clock: camera.cameraClock
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
            let left = bubble.midX < area.midX, bottom = bubble.midY < area.midY
            cameraBubble = StudioProject.Camera(
                shape: style.shape == .circle ? .circle : .roundedSquare, size: Double(style.size.points),
                corner: bottom ? (left ? .bottomLeft : .bottomRight) : (left ? .topLeft : .topRight), mirrored: style.mirrored
            )
            cameraFills = [(Self.hostSeconds(), camera.isFilling)]
            camera.onFillChange = { [weak self] fills in self?.cameraFills.append((Self.hostSeconds(), fills)) }
            return recorder
        } catch {
            Log.recording.error("The camera couldn't be recorded: \(String(describing: error), privacy: .public)")
            return nil
        }
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
    /// it. A window is recorded alone, so it never has the camera.
    private func showCamera(for plan: Plan) {
        if case .window = plan.target {
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

    /// The microphone a recording takes: the one chosen while it is attached, else the system's default.
    private func microphone(for choices: RecordingChoices) -> RecordingAudio.Microphone? {
        guard choices.recordsMicrophone else { return nil }
        guard !choices.microphoneID.isEmpty else { return .systemDefault }
        guard Microphones.available().devices.contains(where: { $0.id == choices.microphoneID }) else {
            Log.recording.notice("The chosen microphone is not attached; recording the default one")
            return .systemDefault
        }
        return .device(choices.microphoneID)
    }

    // MARK: While recording

    func pause() {
        guard let session, session.recorder.state == .recording else { return }
        session.recorder.pause()
        session.camera?.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
        tick()
        announce(String(localized: "Recording paused."))
    }

    func resume() {
        guard let session, session.recorder.state == .paused else { return }
        session.recorder.resume()
        session.camera?.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
        tick()
        announce(String(localized: "Recording resumed."))
    }

    /// Throws the recording so far away and records the same thing again, after the countdown.
    func restart() {
        guard let session else { return }
        self.session = nil
        endChrome()
        discard(session)
        prepare(session.plan)
    }

    /// Stops and throws the recording away.
    func delete() {
        guard let session else { return }
        self.session = nil
        endChrome()
        discard(session)
        announce(String(localized: "Recording deleted."))
    }

    private func discard(_ session: Session) {
        session.telemetry?.stop()
        Task {
            await endCameraRecording(session.camera)
            await session.recorder.cancel()
            drafts.remove(session.draft)
        }
    }

    /// Stops, then finishes and keeps the recording.
    func stop() {
        guard let session else { return }
        self.session = nil
        let makesGIF = session.plan.choices.output == .gif
        if makesGIF { makingGIFs += 1 }
        endChrome()
        finishing += 1
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
                await keep(session.draft, plan: session.plan, displayID: session.plan.display.id, writer: statistics, telemetry: telemetry)
            } catch RecordingWriter.WriterError.noFrames {
                Log.recording.notice("Nothing was recorded")
                await endCameraRecording(session.camera)
                drafts.remove(session.draft)
            } catch {
                // The movie may still be readable up to its last fragment.
                Log.recording.error("Stopping the recording failed: \(String(describing: error), privacy: .public)")
                await endCameraRecording(session.camera)
                await keep(session.draft, plan: session.plan, displayID: session.plan.display.id, writer: nil)
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

    // MARK: Keeping

    /// A recording's file, ready for the history: an MP4 or a GIF.
    private struct KeptFile {
        let url: URL
        let pixelWidth: Int
        let pixelHeight: Int
        let duration: TimeInterval
        let byteCount: Int
    }

    /// Finishes a draft into an MP4, or makes it into a GIF, and keeps it: history, clipboard, card. A draft
    /// that cannot be finished stays in the drafts folder, where the next launch tries again.
    private func keep(
        _ draft: RecordingDrafts.Draft, plan: Plan?, displayID: CGDirectDisplayID, writer: RecordingWriter.Statistics?,
        telemetry: StudioTelemetry? = nil
    ) async {
        let probe = LatencyProbe("recording.keep")
        let output = draft.info?.output ?? .video
        let destination = draft.movieURL.deletingPathExtension().appendingPathExtension(output == .gif ? "gif" : "mp4")
        do {
            let file = try await makeFile(of: draft, as: output, at: destination)
            if let telemetry {
                // Studio: no card or clipboard yet; they come with the first movie exported from its window.
                let entry = try history.add(
                    movingFileAt: file.url, name: fileName(startedAt: draft.info?.startedAt ?? .now, appName: draft.info?.appName ?? plan?.appName),
                    kind: .recording, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, appName: draft.info?.appName ?? plan?.appName,
                    duration: file.duration, pixelsPerPoint: draft.info?.pixelsPerPoint
                )
                var project = StudioProject(zooms: AutoZoom.zooms(for: telemetry, duration: file.duration))
                project.cursor.showsClicks = plan?.choices.showsClicks ?? true
                project.showsKeys = plan?.choices.showsKeystrokes ?? true
                project.keystrokeMode = telemetry.keystrokeMode ?? .all
                project.camera = telemetry.camera?.bubble ?? StudioProject.Camera()
                saveStudioProject(telemetry, project: project, camera: draft.cameraURL, for: entry)
                drafts.remove(draft)
                studioDisplays[entry.id] = displayID
                probe.end()
                announce(String(localized: "Recording stopped. Opening Studio."))
                await openStudio(entry)
                return
            }
            let entry = try await deliver(
                file, startedAt: draft.info?.startedAt ?? .now, appName: draft.info?.appName ?? plan?.appName,
                pixelsPerPoint: draft.info?.pixelsPerPoint, displayID: displayID
            )
            drafts.remove(draft)
            probe.end()
            Log.recording.notice("Kept a recording of \(file.duration, format: .fixed(precision: 2), privacy: .public) s, \(file.pixelWidth, privacy: .public)x\(file.pixelHeight, privacy: .public), \(file.byteCount, privacy: .public) bytes as \(entry.fileName, privacy: .public)\(writer.map { ", \($0.framesWritten) frames written, \($0.framesDropped) dropped" } ?? "", privacy: .public)")
            announce(output == .gif ? String(localized: "GIF made.") : String(localized: "Recording stopped."))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Log.recording.error("Keeping the recording failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            announce(String(localized: "The recording couldn’t be kept. OhMyShot will try again next time it starts."))
        }
    }

    /// Keeps what the pointer did beside a Studio recording, in its project folder, for the Studio window,
    /// and the camera's movie when there is one.
    private func saveStudioProject(_ telemetry: StudioTelemetry, project: StudioProject, camera: URL? = nil, for entry: HistoryItem) {
        let folder = history.studioURL(for: entry)
        var telemetry = telemetry
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if telemetry.camera != nil, let camera {
                do {
                    try FileManager.default.moveItem(at: camera, to: folder.appending(path: StudioFiles.camera))
                } catch {
                    Log.recording.error("Keeping the camera's movie failed: \(String(describing: error), privacy: .public)")
                    telemetry.camera = nil
                    telemetry.cameraFailed = true
                }
            }
            try JSONEncoder().encode(telemetry).write(to: folder.appending(path: StudioFiles.telemetry), options: .atomic)
            try JSONEncoder().encode(project).write(to: folder.appending(path: StudioFiles.project), options: .atomic)
            Log.recording.notice("Kept a Studio project: \(telemetry.samples.count, privacy: .public) pointer readings, \(telemetry.cursors.count, privacy: .public) cursor(s), \(telemetry.clicks.count, privacy: .public) click(s), \(telemetry.keys.count, privacy: .public) key(s)\(telemetry.camera.map { String(format: ", the camera from %.2f s, filling %d time(s)", $0.start, $0.fills.count) } ?? "", privacy: .public)")
        } catch {
            Log.recording.error("Keeping the Studio project failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Keeps a clip saved from the replay as a stopped recording is kept: history, clipboard, card. Named for
    /// when it began and the app in front now.
    func keepReplay(_ movie: RecordingFinisher.Movie, savedAt: Date, displayID: CGDirectDisplayID, pixelsPerPoint: Double?) async throws -> HistoryItem {
        try await deliver(
            KeptFile(url: movie.url, pixelWidth: movie.pixelWidth, pixelHeight: movie.pixelHeight, duration: movie.duration, byteCount: movie.byteCount),
            startedAt: savedAt.addingTimeInterval(-movie.duration), appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            pixelsPerPoint: pixelsPerPoint, displayID: displayID
        )
    }

    /// A recording's name, from the file name pattern. A recording is the one file it will ever be, so it takes its
    /// number now (a screenshot takes one when a copy is saved), and its saved copy keeps the name.
    private func fileName(startedAt: Date, appName: String?) -> String {
        settings.reserveFileName(date: startedAt, appName: appName, windowTitle: nil).name
    }

    /// Moves a made file into the history and hands it on as a capture is: copied, saved when Settings
    /// says so, and given a card.
    private func deliver(
        _ file: KeptFile, startedAt: Date, appName: String?, pixelsPerPoint: Double?, displayID: CGDirectDisplayID
    ) async throws -> HistoryItem {
        let name = fileName(startedAt: startedAt, appName: appName)
        let entry = try history.add(
            movingFileAt: file.url, name: name, kind: .recording, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight,
            appName: appName, duration: file.duration, pixelsPerPoint: pixelsPerPoint
        )
        await present(entry, displayID: displayID)
        return entry
    }

    /// Hands a kept recording on as a capture is: copied, saved, uploaded, and given a card as the choices Settings has
    /// for recordings say.
    private func present(_ entry: HistoryItem, displayID: CGDirectDisplayID) async {
        let url = history.fileURL(for: entry)
        let after = settings.afterCapture(for: .recording)
        if after.copies, !leavesClipboard {
            PasteboardWriter.write(fileURL: url)
            copiedToClipboard?(entry.id)
        }
        let thumbnail = await HistoryStore.thumbnail(of: url, maxPixels: 560) ?? Self.blankThumbnail
        var item = QuickAccessItem(
            id: entry.id, kind: .recording, fileURL: url, thumbnail: thumbnail, pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight, displayID: displayID, createdAt: entry.createdAt, duration: entry.duration
        )
        if after.saves { item.savedURL = save?(url) }
        if after.uploads { uploadKept?(entry) }
        onRecorded?(item)
    }

    private func makeFile(of draft: RecordingDrafts.Draft, as output: RecordingOutput, at destination: URL) async throws -> KeptFile {
        switch output {
        case .video, .studio:
            let movie = try await RecordingFinisher.finish(draft.movieURL, to: destination)
            return KeptFile(url: movie.url, pixelWidth: movie.pixelWidth, pixelHeight: movie.pixelHeight, duration: movie.duration, byteCount: movie.byteCount)
        case .gif:
            announce(String(localized: "Making the GIF."))
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

    /// Finishes what a crash or a forced quit left in the drafts folder: each is kept like a stopped
    /// recording. One that cannot be read is removed once it is a week old.
    func recoverLeftovers() {
        let leftovers = drafts.leftovers(excluding: Set([session?.draft.id].compactMap(\.self)))
        guard !leftovers.isEmpty else { return }
        Log.recording.notice("Finishing \(leftovers.count, privacy: .public) recording(s) left from before")
        let displayID = displays.layout.primary?.id ?? 0
        Task {
            for draft in leftovers {
                let modified = (try? draft.movieURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let makesGIF = draft.info?.output == .gif
                if makesGIF {
                    makingGIFs += 1
                    showStatusAfterRecording()
                }
                await keep(draft, plan: nil, displayID: displayID, writer: nil)
                if makesGIF { madeGIF() }
                if FileManager.default.fileExists(atPath: draft.movieURL.path(percentEncoded: false)), modified < .now.addingTimeInterval(-7 * 86_400) {
                    drafts.remove(draft)
                }
            }
        }
    }

    /// Stops a recording before the app quits, and keeps the edits in open recording windows; `done` runs
    /// once every recording is kept. Returns false when there was nothing to wait for.
    func finishBeforeQuitting(_ done: @escaping () -> Void) -> Bool {
        if pending != nil { cancelCountdown() }
        if session != nil { stop() }
        // Edits in an open recording window are kept as its closing keeps them.
        for window in windows.values where window.hasUnkeptEdits {
            finishing += 1
            window.close { [weak self] in self?.finished() }
        }
        for window in studioWindows.values where window.hasUnexportedChanges {
            finishing += 1
            window.close { [weak self] in self?.finished() }
        }
        guard finishing > 0 else { return false }
        finishingDone.append(done)
        return true
    }

    private func finished() {
        finishing -= 1
        guard finishing == 0 else { return }
        let done = finishingDone
        finishingDone = []
        done.forEach { $0() }
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
    /// Copies a recording's file, as Copy on its card does.
    var copyFile: ((URL) -> Void)?

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
            Log.recording.error("The Studio project has lost the recording as it was made; opening the recording window: \(String(describing: error), privacy: .public)")
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
                copy: { [weak self] url in self?.copyFile?(url) },
                save: { [weak self] url in self?.save?(url) },
                progress: { [weak self] fraction in self?.showStudioExport(fraction) }
            )
        )
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.studioWindows[id] = nil
                self?.windowClosed?(id)
                MemoryRelief.returnFreedPages()
            }
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
            let layout = displays.layout
            let displayID = studioDisplays[id] ?? layout.display(at: NSEvent.mouseLocation)?.id ?? layout.primary?.id ?? 0
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
        announce(String(localized: "Studio export cancelled."))
    }

    /// How far along a Studio export is while its window is gone, in the menu bar; nil when it is done.
    private func showStudioExport(_ fraction: Double?) {
        guard session == nil, pending == nil else { return }
        guard let fraction else { return showStatusAfterRecording() }
        report(.exportingStudio(progress: fraction))
    }

    private func makeWindow(for entry: HistoryItem) -> RecordingWindowController {
        let id = entry.id
        let controller = RecordingWindowController(
            fileURL: history.fileURL(for: entry), title: (entry.fileName as NSString).deletingPathExtension,
            pixelWidth: entry.pixelWidth, pixelHeight: entry.pixelHeight, pixelsPerPoint: entry.pixelsPerPoint,
            hasOriginal: history.hasOriginal(entry),
            actions: .init(
                keep: { [weak self] edit in
                    guard let self else { throw CocoaError(.userCancelled) }
                    return try await keepEdit(edit, of: id)
                },
                revert: { [weak self] in
                    guard let self, let entry = history.item(id: id) else { throw CocoaError(.fileNoSuchFile) }
                    let restored = try await history.restoreRecording(of: entry)
                    onChanged?(restored)
                    return history.fileURL(for: restored)
                },
                makeGIF: { [weak self] edit in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await makeGIF(of: id, edit: edit)
                },
                save: { [weak self] url in self?.save?(url) },
                copy: { [weak self] url in self?.copyFile?(url) }
            )
        )
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.windows[id] = nil
                self?.windowClosed?(id)
                MemoryRelief.returnFreedPages()
            }
        }
        windows[id] = controller
        return controller
    }

    /// Makes the recording with `edit` and keeps it in place of the recording.
    private func keepEdit(_ edit: RecordingEdit, of id: UUID) async throws -> URL {
        guard let entry = history.item(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let probe = LatencyProbe("recording.edit")
        let edited = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        do {
            let movie = try await RecordingFinisher.export(history.fileURL(for: entry), to: edited, edits: Self.edits(edit))
            let updated = try history.replaceRecording(
                of: entry, withFileAt: movie.url, pixelWidth: movie.pixelWidth, pixelHeight: movie.pixelHeight, duration: movie.duration
            )
            probe.end()
            Log.recording.notice("Edited a recording: \(movie.duration, format: .fixed(precision: 2), privacy: .public) s, \(movie.pixelWidth, privacy: .public)x\(movie.pixelHeight, privacy: .public), audio \(movie.hasAudio, privacy: .public), \(movie.byteCount, privacy: .public) bytes")
            onChanged?(updated)
            return history.fileURL(for: updated)
        } catch {
            try? FileManager.default.removeItem(at: edited)
            Log.recording.error("Editing the recording failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Makes a GIF of the recording with `edit` (its part and size; a GIF has no sound) and keeps it as a
    /// recording of its own, with a card. The GIF is never larger than things were on screen.
    private func makeGIF(of id: UUID, edit: RecordingEdit) async throws {
        guard let entry = history.item(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        let onScreen = 1 / max(entry.pixelsPerPoint ?? 1, 1)
        let options = GIFMaker.Options(
            framesPerSecond: settings.recordingGIFFrameRate, scale: min(edit.scale, onScreen), timeRange: edit.timeRange
        )
        do {
            let gif = try await GIFMaker.make(from: history.fileURL(for: entry), to: destination, options: options)
            let layout = displays.layout
            let displayID = layout.display(at: NSEvent.mouseLocation)?.id ?? layout.primary?.id ?? 0
            let file = KeptFile(url: gif.url, pixelWidth: gif.pixelWidth, pixelHeight: gif.pixelHeight, duration: gif.duration, byteCount: gif.byteCount)
            let made = try await deliver(file, startedAt: entry.createdAt, appName: entry.appName, pixelsPerPoint: entry.pixelsPerPoint, displayID: displayID)
            Log.recording.notice("Made a GIF of a recording: \(gif.frameCount, privacy: .public) frames, \(gif.pixelWidth, privacy: .public)x\(gif.pixelHeight, privacy: .public), \(gif.byteCount, privacy: .public) bytes as \(made.fileName, privacy: .public)")
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
            saveStudioProject(telemetry, project: project, camera: camera, for: entry)
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
                microphone: plan.choices.recordsMicrophone, microphoneDenied: microphoneDenied
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
        showStatusAfterRecording()
    }

    /// The menu bar once nothing is recording: how far along a GIF is, or the icon. A recording counting
    /// down or running has the menu bar to itself.
    private func showStatusAfterRecording() {
        guard session == nil, pending == nil else { return }
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

    /// Shows, logs, and announces the microphone going silent, once, and clears the warning when sound is back.
    /// What the Mac plays stopping is only logged. Pausing clears both, and resuming counts the seconds again.
    private func watchSound(of recorder: ScreenRecorder) {
        let microphone = recorder.isMicrophoneStalled
        if microphone != microphoneStalled {
            microphoneStalled = microphone
            controls.update(microphoneStalled: microphone)
            if microphone {
                Log.recording.error("The microphone stopped sending sound")
                announce(String(localized: "The microphone stopped sending sound. It may have been disconnected."))
            } else if recorder.state == .recording {
                Log.recording.notice("The microphone is sending sound again")
            }
        }
        let system = recorder.isSystemAudioStalled
        if system != systemAudioStalled {
            systemAudioStalled = system
            if system {
                Log.recording.notice("The Mac's sound stopped arriving")
            } else if recorder.state == .recording {
                Log.recording.notice("The Mac's sound is arriving again")
            }
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = session.recorder.elapsed
        let paused = session.recorder.state == .paused
        controls.update(elapsed: elapsed, paused: paused)
        report(.recording(time: RecordingControlBar.format(elapsed), paused: paused))
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

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
