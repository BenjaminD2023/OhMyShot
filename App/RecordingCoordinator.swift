import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import OMSCapture
import OMSCore
import OMSRecording
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
        case idle
    }

    /// Receives every finished recording, already in the history; the composition root shows its card.
    var onRecorded: ((QuickAccessItem) -> Void)?
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
    }

    /// The keys pressed, shown over what is recorded while it records.
    private var keyMonitor: KeyMonitor?
    private var keystrokes: KeystrokeDisplay?
    /// The camera in its bubble, from the moment it is chosen on the bar until the recording ends.
    private let camera = CameraBubble()

    private var session: Session?
    /// Counting down to a recording.
    private var pending: Plan?
    private var ticker: Task<Void, Never>?
    private var tickerLease: ActiveResources.Lease?
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
    func recordScreen() {
        if session != nil { return stop() }
        if pending != nil { return cancelCountdown() }
        guard !overlay.isActive else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        overlay.freezesScreen = false
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
        overlay.begin(mode: .area, purpose: .record) { [weak self] outcome in
            guard case .record(let target, let display, let choices) = outcome else {
                self?.camera.hide()
                return
            }
            self?.prepare(Plan(target: target, display: display, choices: choices, appName: app))
        }
    }

    /// Records `target` on `display` without the overlay: for scripted checks, and for Restart.
    func record(_ target: RecordingTarget, on display: DisplayInfo, choices: RecordingChoices, appName: String?) {
        guard session == nil, pending == nil else { return }
        prepare(Plan(target: target, display: display, choices: choices, appName: appName))
    }

    /// Asks for the microphone if it is wanted, then counts down (or not) and starts.
    private func prepare(_ plan: Plan) {
        pending = plan
        Task {
            var plan = plan
            if plan.choices.recordsMicrophone, !(await microphoneAllowed()) {
                Log.recording.notice("Recording without the microphone: access is off")
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
            if case .area = plan.target { outline.show(area, layout: displays.layout) }
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
            // The keystroke display's window is on screen before the filter is made, so the filter takes it in.
            let keys = Self.showsKeystrokes(plan) ? KeystrokeDisplay(mode: settings.recordingKeystrokeMode) : nil
            keys?.show(in: Self.area(of: plan))
            keystrokes = keys
            let shown = Set([keys?.windowID, camera.windowID].compactMap(\.self))
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
            let recorder = try ScreenRecorder(ScreenRecorder.Request(
                filter: source.filter, sourceRect: source.sourceRect, format: format,
                audio: RecordingAudio(system: plan.choices.recordsSystemAudio, microphone: microphone(for: plan.choices)),
                showsCursor: settings.recordingShowsCursor, showsClicks: plan.choices.showsClicks, movieURL: created.movieURL
            ))
            recorder.onStreamStopped = { [weak self] error in self?.streamStopped(error) }
            try await recorder.start()
            probe.end()
            session = Session(plan: plan, draft: created, recorder: recorder, source: source, startedAt: .now)
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
            camera.hide()
            showStatusAfterRecording()
            NSSound.beep()
            announce(String(localized: "The recording couldn’t start."))
        }
    }

    /// Shows the camera's bubble at the corner of what `plan` records when the camera is chosen, or hides
    /// it. A window is recorded alone, so it never has the camera.
    private func showCamera(for plan: Plan) {
        if case .window = plan.target {
            return camera.hide()
        }
        // Without access or a camera, nothing shows: a bubble with no picture would be recorded as a blank disc.
        guard plan.choices.camera, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return camera.hide() }
        if !camera.isShowing, Cameras.available().devices.isEmpty {
            Log.recording.notice("No camera to show")
            return camera.hide()
        }
        camera.show(camera: plan.choices.cameraID, style: plan.choices.cameraStyle, in: Self.area(of: plan))
    }

    /// Whether a recording shows the keys pressed: chosen, and not of a window, which is recorded alone.
    private static func showsKeystrokes(_ plan: Plan) -> Bool {
        guard plan.choices.showsKeystrokes else { return false }
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
        tick()
        announce(String(localized: "Recording paused."))
    }

    func resume() {
        guard let session, session.recorder.state == .paused else { return }
        session.recorder.resume()
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
        Task {
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
            do {
                let statistics = try await session.recorder.stop()
                await keep(session.draft, plan: session.plan, displayID: session.plan.display.id, writer: statistics)
            } catch RecordingWriter.WriterError.noFrames {
                Log.recording.notice("Nothing was recorded")
                drafts.remove(session.draft)
            } catch {
                // The movie may still be readable up to its last fragment.
                Log.recording.error("Stopping the recording failed: \(String(describing: error), privacy: .public)")
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
    private func keep(_ draft: RecordingDrafts.Draft, plan: Plan?, displayID: CGDirectDisplayID, writer: RecordingWriter.Statistics?) async {
        let probe = LatencyProbe("recording.keep")
        let output = draft.info?.output ?? .video
        let destination = draft.movieURL.deletingPathExtension().appendingPathExtension(output == .gif ? "gif" : "mp4")
        do {
            let file = try await makeFile(of: draft, as: output, at: destination)
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

    /// Moves a made file into the history and hands it on as a capture is: copied, saved when Settings
    /// says so, and given a card.
    private func deliver(
        _ file: KeptFile, startedAt: Date, appName: String?, pixelsPerPoint: Double?, displayID: CGDirectDisplayID
    ) async throws -> HistoryItem {
        let name = FilenameTemplate.standard.name(date: startedAt, appName: appName)
        let entry = try history.add(
            movingFileAt: file.url, name: name, kind: .recording, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight,
            appName: appName, duration: file.duration, pixelsPerPoint: pixelsPerPoint
        )
        let url = history.fileURL(for: entry)
        if settings.copyAfterCapture, !leavesClipboard { PasteboardWriter.write(fileURL: url) }
        let thumbnail = await HistoryStore.thumbnail(of: url, maxPixels: 560) ?? Self.blankThumbnail
        var item = QuickAccessItem(
            id: entry.id, kind: .recording, fileURL: url, thumbnail: thumbnail, pixelWidth: file.pixelWidth,
            pixelHeight: file.pixelHeight, displayID: displayID, createdAt: entry.createdAt, duration: file.duration
        )
        if settings.saveAfterCapture { item.savedURL = save?(url) }
        onRecorded?(item)
        return entry
    }

    private func makeFile(of draft: RecordingDrafts.Draft, as output: RecordingOutput, at destination: URL) async throws -> KeptFile {
        switch output {
        case .video:
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
    /// A kept recording changed (edited, or put back as it was made): the composition root refreshes its
    /// card and Capture History.
    var onChanged: ((HistoryItem) -> Void)?
    /// Copies a recording's file, as Copy on its card does.
    var copyFile: ((URL) -> Void)?

    /// Opens a kept recording in the recording window: to play, trim, leave the sound out, make smaller, or
    /// make a GIF of; a GIF only plays.
    func open(_ entry: HistoryItem) {
        if let window = windows[entry.id] { return window.show() }
        makeWindow(for: entry).show()
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
        RecordingFinisher.Edits(timeRange: edit.timeRange, keepsAudio: edit.keepsAudio, scale: edit.scale)
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

    /// Closes the demo's window without keeping edits and removes the demo from the history.
    func debugRemoveDemo() {
        guard let id = debugDemoID else { return }
        debugDemoID = nil
        windows[id]?.debugDiscardAndClose()
        if let entry = history.item(id: id) { history.delete(entry) }
    }
    #endif

    // MARK: Chrome

    /// The outline (areas only: a window moves, a display needs none), the control bar, and the clock.
    private func showChrome(for plan: Plan, source: ScreenCapturer.RecordingSource) {
        let area = Self.area(of: plan, recorded: source.frame)
        // The countdown's outline stays up; it is shown here only when there was no countdown.
        if case .area = plan.target {
            if !outline.isShowing { outline.show(area, layout: displays.layout) }
        } else {
            outline.hide()
        }
        if settings.recordingShowsControls {
            // Inside a whole display, the bar keeps clear of the keys shown at its foot.
            controls.show(by: area, displays: displays.layout.displays.map(\.frame), clearing: keystrokes == nil ? 0 : KeystrokeDisplay.reservedHeight)
        }
        startTicking()
    }

    private func endChrome() {
        ticker?.cancel()
        ticker = nil
        tickerLease = nil
        outline.hide()
        controls.hide()
        keyMonitor?.stop()
        keyMonitor = nil
        keystrokes?.hide()
        keystrokes = nil
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
