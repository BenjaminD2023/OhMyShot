import AppKit
import AVFoundation
import Foundation
import OMSCapture
import OMSCore
import OMSRecording
import OSLog
import ScreenCaptureKit

/// The replay: the last 15 seconds of each display the user chose, kept from the moment they turn it on in
/// the menu bar until they turn it off or quit, and saved, when asked, as recordings are kept (history,
/// clipboard, card). macOS 27.
///
/// Each display has a buffer of its own; saving keeps one clip per display. The system's sound and the
/// microphone are both buffered (the microphone when access is on), and each clip keeps what Settings'
/// replay sound says. Nothing of it outlives the app: the next launch starts with it off.
@available(macOS 27, *)
@MainActor
final class ReplayCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let permissions: PermissionCenter
    private let recordings: RecordingCoordinator
    /// The buffers running, by display.
    private var buffers: [CGDirectDisplayID: ReplayBuffer] = [:]
    /// Displays whose buffer is starting, so a second click meanwhile starts nothing twice.
    private var starting: Set<CGDirectDisplayID> = []
    /// Displays unchecked while they were starting: stopped as soon as they have started.
    private var cancelled: Set<CGDirectDisplayID> = []
    /// Saves under way; the app waits for them before quitting.
    private var saving = 0
    private var savingDone: [() -> Void] = []

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, permissions: PermissionCenter, recordings: RecordingCoordinator) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.permissions = permissions
        self.recordings = recordings
    }

    /// Whether any display's last seconds are kept.
    var isOn: Bool {
        !buffers.isEmpty
    }

    /// Whether `display`'s last seconds are kept, or about to be.
    func isKeeping(_ display: CGDirectDisplayID) -> Bool {
        buffers[display] != nil || (starting.contains(display) && !cancelled.contains(display))
    }

    /// Whether Save can run now: something is kept, and no save is under way.
    var canSave: Bool {
        isOn && saving == 0
    }

    /// Starts keeping `display`'s last seconds, or stops.
    func toggle(_ display: DisplayInfo) {
        if let buffer = buffers.removeValue(forKey: display.id) {
            // A save under way may be exporting from it: it stops once the save is kept.
            if saving > 0 {
                savingDone.append { Task { await buffer.stop() } }
            } else {
                Task { await buffer.stop() }
            }
            announce(String(localized: "Stopped keeping the last 15 seconds of \(display.name)."))
            return
        }
        if starting.contains(display.id) {
            // Still starting (perhaps asking for the microphone): stopped as soon as it has, or kept after all.
            if cancelled.remove(display.id) == nil { cancelled.insert(display.id) }
            return
        }
        starting.insert(display.id)
        Task {
            await start(display)
            starting.remove(display.id)
        }
    }

    private func start(_ display: DisplayInfo) async {
        do {
            let microphone = await microphone()
            let source = try await capturer.recordingSource(for: .display, on: display)
            let size = ReplayBuffer.size(fitting: source.pixelWidth, source.pixelHeight)
            let framesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : settings.recordingFrameRate
            let buffer = ReplayBuffer(.init(
                filter: source.filter, width: size.width, height: size.height, framesPerSecond: framesPerSecond,
                showsCursor: settings.recordingShowsCursor, microphone: microphone
            ))
            buffer.onStopped = { [weak self] ending in self?.stopped(display, ending) }
            try await buffer.start()
            if cancelled.remove(display.id) != nil {
                await buffer.stop()
                announce(String(localized: "Stopped keeping the last 15 seconds of \(display.name)."))
                return
            }
            buffers[display.id] = buffer
            announce(String(localized: "Keeping the last 15 seconds of \(display.name)."))
        } catch {
            cancelled.remove(display.id)
            Log.recording.error("The replay couldn't start on a display: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            announce(String(localized: "Couldn’t keep the last 15 seconds of \(display.name)."))
        }
    }

    /// The microphone buffered with the system's sound, asked for the first time; nil when access is off.
    /// Asked before buffering begins, so the question is never part of what is kept.
    private func microphone() async -> RecordingAudio.Microphone? {
        permissions.refresh([.microphone])
        switch permissions.status(of: .microphone) {
        case .granted:
            break
        case .denied:
            return nil
        case .notGranted:
            await permissions.request(.microphone)
            guard permissions.status(of: .microphone) == .granted else { return nil }
        }
        let id = settings.recordingMicrophoneID
        guard !id.isEmpty, Microphones.available().devices.contains(where: { $0.id == id }) else { return .systemDefault }
        return .device(id)
    }

    /// A display's buffer stopped on its own: the display went away or Screen Recording was turned off
    /// (quietly), or the buffer failed (with a beep).
    private func stopped(_ display: DisplayInfo, _ ending: ReplayBuffer.Ending) {
        guard buffers.removeValue(forKey: display.id) != nil else { return }
        if ending == .bufferFailed { NSSound.beep() }
        announce(String(localized: "Stopped keeping the last 15 seconds of \(display.name)."))
    }

    /// How saving one display's clip went.
    private enum Saved {
        case saved
        /// Nothing changed there in the last 15 seconds: the display's name, when it is still connected.
        case nothingChanged(String?)
        case failed
    }

    /// Saves the last 15 seconds of every display kept, one clip each, as a stopped recording is kept. One
    /// save at a time: a second would export from the same buffers at once.
    func save() {
        guard saving == 0 else { return NSSound.beep() }
        guard !buffers.isEmpty else {
            NSSound.beep()
            announce(String(localized: "Nothing is being kept. Choose a display in Keep Last 15 Seconds in the menu bar."))
            return
        }
        let kept = buffers.sorted { $0.key < $1.key }
        let savedAt = Date.now
        saving += 1
        Task {
            var outcomes: [Saved] = []
            // A buffer that stopped on its own meanwhile has nothing to save, and said so already.
            for (id, buffer) in kept where buffer.isRunning {
                outcomes.append(await save(buffer, of: id, at: savedAt))
            }
            report(outcomes)
            saving -= 1
            if saving == 0 {
                let done = savingDone
                savingDone = []
                done.forEach { $0() }
            }
        }
    }

    /// Says how a save went, once for all its displays, with one beep when any had nothing or failed.
    private func report(_ outcomes: [Saved]) {
        var sentences: [String] = []
        let saved = outcomes.filter { if case .saved = $0 { true } else { false } }.count
        if saved == 1 {
            sentences.append(String(localized: "Saved the last 15 seconds."))
        } else if saved > 1 {
            sentences.append(String(localized: "Saved the last 15 seconds of \(saved) displays."))
        }
        for outcome in outcomes {
            guard case .nothingChanged(let name) = outcome else { continue }
            sentences.append(name.map { String(localized: "Nothing changed on \($0) in the last 15 seconds.") }
                ?? String(localized: "Nothing changed on the display in the last 15 seconds."))
        }
        if outcomes.contains(where: { if case .failed = $0 { true } else { false } }) {
            sentences.append(String(localized: "The last 15 seconds couldn’t be saved."))
        }
        if saved < outcomes.count { NSSound.beep() }
        if !sentences.isEmpty { announce(sentences.joined(separator: " ")) }
    }

    private func save(_ buffer: ReplayBuffer, of displayID: CGDirectDisplayID, at savedAt: Date) async -> Saved {
        let display = displays.layout.displays.first { $0.id == displayID }
        let folder = FileManager.default.temporaryDirectory
        let clip = folder.appending(path: "Replay \(UUID().uuidString).mov")
        let movie = folder.appending(path: "Replay \(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: clip) }
        let probe = LatencyProbe("replay.save")
        do {
            try await buffer.save(to: clip)
            let finished = try await RecordingFinisher.finish(clip, to: movie, audio: .keeping(settings.replaySound, of: buffer.audioTracks))
            #if DEBUG
            if let folder = debugSaveFolder {
                let kept = folder.appending(path: "replay-saved.mp4")
                try? FileManager.default.removeItem(at: kept)
                try FileManager.default.moveItem(at: finished.url, to: kept)
                let audio = try await AVURLAsset(url: kept).loadTracks(withMediaType: .audio).count
                probe.end()
                Log.app.notice("debug.replay saved \(finished.duration, format: .fixed(precision: 2), privacy: .public) s, \(finished.pixelWidth, privacy: .public)x\(finished.pixelHeight, privacy: .public), \(audio, privacy: .public) audio track(s) for sound \(self.settings.replaySound.rawValue, privacy: .public), to replay-saved.mp4")
                return .saved
            }
            #endif
            // As many of the clip's pixels as there were points on the display: the clip may be scaled to fit.
            let pixelsPerPoint = display.flatMap { $0.frame.width > 0 ? Double(finished.pixelWidth) / Double($0.frame.width) : nil }
            let entry = try await recordings.keepReplay(finished, savedAt: savedAt, displayID: displayID, pixelsPerPoint: pixelsPerPoint)
            probe.end()
            Log.recording.notice("Saved the replay of a display: \(finished.duration, format: .fixed(precision: 2), privacy: .public) s, \(finished.pixelWidth, privacy: .public)x\(finished.pixelHeight, privacy: .public), sound \(self.settings.replaySound.rawValue, privacy: .public), as \(entry.fileName, privacy: .public)")
            return .saved
        } catch ReplayBuffer.ReplayError.nothingChanged {
            try? FileManager.default.removeItem(at: movie)
            Log.recording.notice("Nothing changed on a display in the last 15 seconds")
            return .nothingChanged(display?.name)
        } catch {
            try? FileManager.default.removeItem(at: movie)
            Log.recording.error("Saving the replay failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// Stops every buffer before the app quits; `done` runs once the saves under way are kept. False when
    /// nothing needed waiting for.
    func finishBeforeQuitting(_ done: @escaping () -> Void) -> Bool {
        // A save under way exports from its buffer: the buffers stop once it is kept.
        let stopAll = { [self] in
            let running = Array(buffers.values)
            buffers.removeAll()
            Task {
                for buffer in running { await buffer.stop() }
            }
        }
        guard saving > 0 else {
            stopAll()
            return false
        }
        savingDone.append {
            stopAll()
            done()
        }
        return true
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    #if DEBUG
    /// Where saved clips go instead of the history, for scripted checks; nil keeps them as the user's are.
    var debugSaveFolder: URL?

    /// Keeps a window the app draws (its `filter`) as if it were display `id`, for scripted checks: nothing
    /// of the user's is read. The system's sound only (a window's stream hears only this app).
    func debugKeep(filter: SCContentFilter, width: Int, height: Int, as id: CGDirectDisplayID) async throws {
        let size = ReplayBuffer.size(fitting: width, height)
        let buffer = ReplayBuffer(.init(
            filter: filter, width: size.width, height: size.height, framesPerSecond: 60, showsCursor: false, microphone: nil, excludesOwnSound: false
        ))
        try await buffer.start()
        buffers[id] = buffer
    }

    func debugStopAll() async {
        let running = Array(buffers.values)
        buffers.removeAll()
        for buffer in running { await buffer.stop() }
    }

    /// The displays kept now, for scripted checks.
    var debugState: String {
        buffers.isEmpty ? "off" : buffers.keys.sorted().map { id in
            let request = buffers[id]?.request
            return "\(id): \(request?.width ?? 0)x\(request?.height ?? 0) at \(request?.framesPerSecond ?? 0) fps, microphone \(request?.microphone != nil)"
        }.joined(separator: "; ")
    }
    #endif
}
