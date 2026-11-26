import AppKit
import AVFoundation
import Foundation
import Observation
import OMSCapture
import OMSCore
import OMSDesign
import OMSRecording
import OMSUI
import OSLog
import ScreenCaptureKit

/// The replay: the last 15 seconds of each display the user chose, kept from the moment they turn it on in
/// the menu bar until they turn it off or quit, and saved, when asked, as recordings are kept (history,
/// clipboard, card). macOS 27.
///
/// Each display has a buffer of its own; saving keeps one clip per display. The microphone is requested and
/// buffered only when Settings' replay sound keeps it; switching to or from a microphone-including mode
/// restarts active buffers cleanly. Nothing of it outlives the app: the next launch starts with it off.
@available(macOS 27, *)
@MainActor
final class ReplayCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let permissions: PermissionCenter
    private let recordings: RecordingCoordinator
    /// Called whenever Replay transitions between active (`true`) and idle (`false`).
    var onStateChange: ((Bool) -> Void)?
    /// The buffers running, by display.
    private var buffers: [CGDirectDisplayID: ReplayBuffer] = [:]
    /// Displays whose buffer is starting, so a second click meanwhile starts nothing twice.
    private var starting: Set<CGDirectDisplayID> = []
    /// Displays whose buffer is restarting to reflect a microphone sound-setting change.
    private var restarting: Set<CGDirectDisplayID> = []
    /// Displays unchecked while they were starting or restarting: stopped as soon as ready.
    private var cancelled: Set<CGDirectDisplayID> = []
    /// Observes `settings.replaySound` only while Replay is active (zero idle wakeups when off).
    private var soundObservation: Task<Void, Never>?
    private var lastReportedActive = false
    /// Saves under way; the app waits for them before quitting.
    private var saving = 0
    private var savingDone: [() -> Void] = []
    /// Says by the pointer why Replay could not start or save, or that a clip went to the export folder.
    private lazy var notice = CopiedHUD()

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, permissions: PermissionCenter, recordings: RecordingCoordinator) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.permissions = permissions
        self.recordings = recordings
    }

    isolated deinit {
        soundObservation?.cancel()
    }

    /// Whether any display's last seconds are kept.
    var isOn: Bool {
        !buffers.isEmpty || !restarting.isEmpty
    }

    /// Whether `display`'s last seconds are kept, or about to be.
    func isKeeping(_ display: CGDirectDisplayID) -> Bool {
        buffers[display] != nil || restarting.contains(display) || (starting.contains(display) && !cancelled.contains(display))
    }

    /// Whether Save can run now: something is kept, and no save is under way.
    var canSave: Bool {
        !buffers.isEmpty && saving == 0
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
            notifyStateChange()
            VoiceOver.announce(String(localized: "Stopped keeping the last 15 seconds of \(display.name)."))
            return
        }
        if starting.contains(display.id) || restarting.contains(display.id) {
            // Still starting or restarting: stopped as soon as it has, or kept after all.
            if cancelled.remove(display.id) == nil { cancelled.insert(display.id) }
            return
        }
        starting.insert(display.id)
        Task {
            await start(display)
            starting.remove(display.id)
            notifyStateChange()
        }
    }

    private func start(_ display: DisplayInfo, announce: Bool = true) async {
        do {
            let microphone = await microphone()
            let source = try await capturer.recordingSource(for: .display, on: display)
            let size = ReplayBuffer.size(fitting: source.pixelWidth, source.pixelHeight)
            let buffer = ReplayBuffer(.init(
                filter: source.filter, width: size.width, height: size.height, framesPerSecond: settings.recordingFramesPerSecond,
                showsCursor: settings.recordingShowsCursor, microphone: microphone
            ))
            buffer.onStopped = { [weak self] ending in self?.stopped(display, ending) }
            try await buffer.start()
            if cancelled.remove(display.id) != nil {
                await buffer.stop()
                if announce { VoiceOver.announce(String(localized: "Stopped keeping the last 15 seconds of \(display.name).")) }
                return
            }
            buffers[display.id] = buffer
            notifyStateChange()
            if announce { VoiceOver.announce(String(localized: "Keeping the last 15 seconds of \(display.name).")) }
        } catch {
            cancelled.remove(display.id)
            Log.recording.error("The replay couldn't start on a display: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            NSSound.beep()
            notice.show(String(localized: "Couldn’t keep the last 15 seconds of \(display.name)."), near: NSEvent.mouseLocation)
        }
    }

    /// The microphone buffered with the system's sound, requested only when Settings' replay sound keeps it;
    /// nil when the sound mode does not use the microphone or access is off.
    private func microphone() async -> RecordingAudio.Microphone? {
        guard settings.replaySound.keepsMicrophone else { return nil }
        guard await permissions.requestIfNeeded(.microphone) else { return nil }
        return .chosen(settings.recordingMicrophoneID)
    }

    private func notifyStateChange() {
        let active = isOn
        if active {
            startObservingSoundIfNeeded()
        } else if starting.isEmpty {
            soundObservation?.cancel()
            soundObservation = nil
        }
        guard active != lastReportedActive else { return }
        lastReportedActive = active
        onStateChange?(active)
    }

    private func startObservingSoundIfNeeded() {
        guard soundObservation == nil else { return }
        let settings = settings
        soundObservation = Task { [weak self] in
            var lastKeepsMic = settings.replaySound.keepsMicrophone
            for await keepsMic in Observations({ settings.replaySound.keepsMicrophone }) {
                guard !Task.isCancelled, let self else { return }
                guard keepsMic != lastKeepsMic else { continue }
                lastKeepsMic = keepsMic
                await self.restartBuffersForSoundChange()
            }
        }
    }

    /// Cleanly restarts active replay buffers when switching between microphone-enabled and non-microphone sound modes.
    func restartBuffersForSoundChange() async {
        guard !buffers.isEmpty else { return }
        if saving > 0 {
            savingDone.append { [weak self] in
                Task { await self?.restartBuffersForSoundChange() }
            }
            return
        }
        let targetKeepsMic = settings.replaySound.keepsMicrophone
        let ids = buffers.keys.sorted()
        for id in ids {
            guard let existing = buffers[id] else { continue }
            let hasMic = existing.request.microphone != nil
            guard hasMic != targetKeepsMic else { continue }
            buffers.removeValue(forKey: id)
            restarting.insert(id)
            await existing.stop()
            restarting.remove(id)
            if cancelled.remove(id) != nil {
                notifyStateChange()
                continue
            }
            guard let display = displays.layout.displays.first(where: { $0.id == id }) else {
                notifyStateChange()
                continue
            }
            starting.insert(id)
            await start(display, announce: false)
            starting.remove(id)
            notifyStateChange()
        }
    }

    /// A display's buffer stopped on its own: the display went away or Screen Recording was turned off
    /// (quietly), or the buffer failed (with a beep and visible notice).
    private func stopped(_ display: DisplayInfo, _ ending: ReplayBuffer.Ending) {
        guard buffers.removeValue(forKey: display.id) != nil else { return }
        notifyStateChange()
        if ending == .bufferFailed {
            NSSound.beep()
            notice.show(String(localized: "Stopped keeping the last 15 seconds of \(display.name)."), near: NSEvent.mouseLocation)
        } else {
            VoiceOver.announce(String(localized: "Stopped keeping the last 15 seconds of \(display.name)."))
        }
    }

    /// How saving one display's clip went.
    private enum Saved {
        case saved
        /// History couldn't take the clip, so it went to the export folder instead: the folder it went to.
        case savedToFolder(URL)
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
            notice.show(String(localized: "Replay is off"), near: NSEvent.mouseLocation)
            VoiceOver.announce(String(localized: "Nothing is being kept. Choose a display in Keep Last 15 Seconds in the menu bar."))
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

    /// Says how a save went, once for all its displays, with a beep and visible notice when any clip fell back
    /// outside History, had nothing changed, or failed.
    private func report(_ outcomes: [Saved]) {
        var sentences: [String] = []
        let saved = outcomes.filter { if case .saved = $0 { true } else { false } }.count
        if saved == 1 {
            sentences.append(String(localized: "Saved the last 15 seconds."))
        } else if saved > 1 {
            sentences.append(String(localized: "Saved the last 15 seconds of \(saved) displays."))
        }
        // Each clip's own folder, which the export folder changed in Settings meanwhile doesn't move.
        let folders = outcomes.compactMap { if case .savedToFolder(let folder) = $0 { folder } else { nil } }
        var named: Set<URL> = []
        for folder in folders where named.insert(folder).inserted {
            let clips = folders.filter { $0 == folder }.count
            let name = FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
            sentences.append(clips == 1
                ? String(localized: "The last 15 seconds were saved to \(name) but couldn’t be added to History.")
                : String(localized: "The last 15 seconds of \(clips) displays were saved to \(name) but couldn’t be added to History."))
        }
        var hadNothingChanged = false
        for outcome in outcomes {
            guard case .nothingChanged(let name) = outcome else { continue }
            hadNothingChanged = true
            sentences.append(name.map { String(localized: "Nothing changed on \($0) in the last 15 seconds.") }
                ?? String(localized: "Nothing changed on the display in the last 15 seconds."))
        }
        let hadFailure = outcomes.contains(where: { if case .failed = $0 { true } else { false } })
        if hadFailure {
            sentences.append(String(localized: "The last 15 seconds couldn’t be saved."))
        }
        if saved < outcomes.count { NSSound.beep() }
        guard !sentences.isEmpty else { return }
        // A clip outside History has no card to show where it went, and failures / unchanged clips have no card
        // either: show a visible notice by the pointer (which also announces to VoiceOver).
        if !folders.isEmpty {
            notice.show(Sentences.joined(sentences), near: NSEvent.mouseLocation)
        } else if hadFailure {
            notice.show(String(localized: "The last 15 seconds couldn’t be saved."), near: NSEvent.mouseLocation)
            if saved > 0 || hadNothingChanged {
                VoiceOver.announce(Sentences.joined(sentences))
            }
        } else if hadNothingChanged {
            notice.show(String(localized: "Nothing changed in the last 15 seconds"), near: NSEvent.mouseLocation)
            if saved > 0 {
                VoiceOver.announce(Sentences.joined(sentences))
            }
        } else {
            VoiceOver.announce(Sentences.joined(sentences))
        }
    }

    private func save(_ buffer: ReplayBuffer, of displayID: CGDirectDisplayID, at savedAt: Date) async -> Saved {
        let display = displays.layout.displays.first { $0.id == displayID }
        let folder = FileManager.default.temporaryDirectory
        let clip = folder.appending(path: "Replay \(UUID().uuidString).mov")
        let movie = folder.appending(path: "Replay \(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: clip) }
        let probe = LatencyProbe("replay.save")
        let finished: RecordingFinisher.Movie
        do {
            try await buffer.save(to: clip)
            finished = try await RecordingFinisher.finish(clip, to: movie, audio: .keeping(settings.replaySound, of: buffer.audioTracks))
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
        } catch ReplayBuffer.ReplayError.nothingChanged {
            try? FileManager.default.removeItem(at: movie)
            Log.recording.notice("Nothing changed on a display in the last 15 seconds")
            return .nothingChanged(display?.name)
        } catch {
            try? FileManager.default.removeItem(at: movie)
            Log.recording.error("Saving the replay failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            return .failed
        }
        // The clip is finished, and nothing could make it again: from here on it is kept, in History or the export folder,
        // or left where it is, and never deleted.
        do {
            // As many of the clip's pixels as there were points on the display: the clip may be scaled to fit.
            let pixelsPerPoint = display.flatMap { $0.frame.width > 0 ? Double(finished.pixelWidth) / Double($0.frame.width) : nil }
            switch try await recordings.keepReplay(finished, savedAt: savedAt, displayID: displayID, pixelsPerPoint: pixelsPerPoint) {
            case .history(let entry):
                probe.end()
                Log.recording.notice("Saved the replay of a display: \(finished.duration, format: .fixed(precision: 2), privacy: .public) s, \(finished.pixelWidth, privacy: .public)x\(finished.pixelHeight, privacy: .public), sound \(self.settings.replaySound.rawValue, privacy: .public), as \(entry.fileName, privacy: .private)")
                return .saved
            case .folder(let file):
                Log.recording.error("Saved the replay of a display to the export folder as \(file.lastPathComponent, privacy: .private): History couldn't take it")
                return .savedToFolder(file.deletingLastPathComponent())
            }
        } catch {
            Log.recording.error("Keeping the replay failed, and its clip was not deleted (the history log says where it is): \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
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
            restarting.removeAll()
            notifyStateChange()
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
        notifyStateChange()
    }

    func debugStopAll() async {
        let running = Array(buffers.values)
        buffers.removeAll()
        restarting.removeAll()
        notifyStateChange()
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
