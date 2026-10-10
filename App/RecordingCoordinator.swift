import AppKit
import CoreGraphics
import Foundation
import OMSCapture
import OMSCore
import OMSRecording
import OMSUI
import OSLog

/// Turns Record Screen into a recording kept in the history.
///
/// The overlay chooses what to record (an area, a window, or a display) and what it takes along (on the
/// recording bar); a countdown gives a moment to get ready; while recording, the area is outlined, the
/// control bar sits beside it, and the menu bar shows the time. Stopped, the movie is finished into an
/// MP4, kept in the history, copied, and given a Quick Access card. The movie is written in fragments in
/// the drafts folder while it records, so a recording cut short by a crash is finished at the next launch.
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

    /// Receives every finished recording, already in the history; the composition root shows its card.
    var onRecorded: ((QuickAccessItem) -> Void)?
    /// The time while recording, and whether it is paused; nil once the recording has ended. The
    /// composition root shows it in the menu bar.
    var onTick: ((String?, Bool) -> Void)?
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

    private var session: Session?
    /// Counting down to a recording.
    private var pending: Plan?
    private var ticker: Task<Void, Never>?
    private var tickerLease: ActiveResources.Lease?
    /// Recordings being finished; the app waits for them before quitting.
    private var finishing = 0
    private var finishingDone: [() -> Void] = []

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
            systemAudio: settings.recordingSystemAudio, microphone: settings.recordingMicrophone, showsClicks: settings.recordingShowsClicks
        )
        overlay.onRecordingChoicesChange = { [weak self] choices in
            guard let self else { return }
            settings.recordingSystemAudio = choices.systemAudio
            settings.recordingMicrophone = choices.microphone
            settings.recordingShowsClicks = choices.showsClicks
        }
        overlay.begin(mode: .area, purpose: .record) { [weak self] outcome in
            guard case .record(let target, let display, let choices) = outcome else { return }
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
            if plan.choices.microphone, !(await microphoneAllowed()) {
                Log.recording.notice("Recording without the microphone: access is off")
                announce(String(localized: "Microphone access is off in System Settings. Recording without it."))
                plan = Plan(target: plan.target, display: plan.display, choices: RecordingChoices(
                    systemAudio: plan.choices.systemAudio, microphone: false, showsClicks: plan.choices.showsClicks
                ), appName: plan.appName)
            }
            guard pending != nil else { return }
            pending = plan
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
            let source = try await capturer.recordingSource(for: plan.target, on: plan.display)
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            let format = RecordingFormat.choose(
                width: source.pixelWidth, height: source.pixelHeight,
                framesPerSecond: lowPower ? 30 : settings.recordingFrameRate, prefersHEVC: settings.recordingPrefersHEVC
            )
            let created = try drafts.create(.init(startedAt: .now, appName: plan.appName))
            draft = created
            let recorder = try ScreenRecorder(ScreenRecorder.Request(
                filter: source.filter, sourceRect: source.sourceRect, format: format,
                audio: RecordingAudio(
                    system: plan.choices.systemAudio,
                    microphone: plan.choices.microphone ? (settings.recordingMicrophoneID.isEmpty ? .systemDefault : .device(settings.recordingMicrophoneID)) : nil
                ),
                showsCursor: settings.recordingShowsCursor, showsClicks: plan.choices.showsClicks, movieURL: created.movieURL
            ))
            recorder.onStreamStopped = { [weak self] error in self?.streamStopped(error) }
            try await recorder.start()
            probe.end()
            session = Session(plan: plan, draft: created, recorder: recorder, source: source, startedAt: .now)
            showChrome(for: plan, source: source)
            let keys = shortcutKeys?()
            announce(keys.map { String(localized: "Recording. Press \($0) again to stop.") }
                ?? String(localized: "Recording. Click the time in the menu bar to stop."))
        } catch {
            Log.recording.error("Recording could not start: \(String(describing: error), privacy: .public)")
            if let draft { drafts.remove(draft) }
            outline.hide()
            NSSound.beep()
            announce(String(localized: "The recording couldn’t start."))
        }
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
        endChrome()
        finishing += 1
        Task {
            defer { finished() }
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

    /// Finishes a draft into an MP4 and keeps it: history, clipboard, card. A draft that cannot be
    /// finished stays in the drafts folder, where the next launch tries again.
    private func keep(_ draft: RecordingDrafts.Draft, plan: Plan?, displayID: CGDirectDisplayID, writer: RecordingWriter.Statistics?) async {
        let probe = LatencyProbe("recording.keep")
        let destination = draft.movieURL.deletingPathExtension().appendingPathExtension("mp4")
        do {
            let movie = try await RecordingFinisher.finish(draft.movieURL, to: destination)
            let name = FilenameTemplate.standard.name(date: draft.info?.startedAt ?? .now, appName: draft.info?.appName ?? plan?.appName)
            let entry = try history.add(
                movingFileAt: movie.url, name: name, kind: .recording, pixelWidth: movie.pixelWidth, pixelHeight: movie.pixelHeight,
                appName: draft.info?.appName ?? plan?.appName, duration: movie.duration
            )
            drafts.remove(draft)
            let url = history.fileURL(for: entry)
            if settings.copyAfterCapture { PasteboardWriter.write(fileURL: url) }
            let thumbnail = await HistoryStore.thumbnail(of: url, maxPixels: 560) ?? Self.blankThumbnail
            var item = QuickAccessItem(
                id: entry.id, kind: .recording, fileURL: url, thumbnail: thumbnail, pixelWidth: movie.pixelWidth,
                pixelHeight: movie.pixelHeight, displayID: displayID, createdAt: entry.createdAt, duration: movie.duration
            )
            if settings.saveAfterCapture { item.savedURL = save?(url) }
            probe.end()
            Log.recording.notice("Kept a recording of \(movie.duration, format: .fixed(precision: 2), privacy: .public) s, \(movie.pixelWidth, privacy: .public)x\(movie.pixelHeight, privacy: .public), \(movie.byteCount, privacy: .public) bytes as \(entry.fileName, privacy: .public)\(writer.map { ", \($0.framesWritten) frames written, \($0.framesDropped) dropped" } ?? "", privacy: .public)")
            onRecorded?(item)
            announce(String(localized: "Recording stopped."))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Log.recording.error("Keeping the recording failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            announce(String(localized: "The recording couldn’t be kept. OhMyShot will try again next time it starts."))
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
                await keep(draft, plan: nil, displayID: displayID, writer: nil)
                if FileManager.default.fileExists(atPath: draft.movieURL.path(percentEncoded: false)), modified < .now.addingTimeInterval(-7 * 86_400) {
                    drafts.remove(draft)
                }
            }
        }
    }

    /// Stops a recording before the app quits; `done` runs once every recording is kept. Returns false when
    /// there was nothing to wait for.
    func finishBeforeQuitting(_ done: @escaping () -> Void) -> Bool {
        if pending != nil { cancelCountdown() }
        if session != nil { stop() }
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
            controls.show(by: area, displays: displays.layout.displays.map(\.frame))
        }
        startTicking()
    }

    private func endChrome() {
        ticker?.cancel()
        ticker = nil
        tickerLease = nil
        outline.hide()
        controls.hide()
        onTick?(nil, false)
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
        onTick?(RecordingControlBar.format(elapsed), paused)
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

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
