#if DEBUG
import AppIntents
import AppKit
import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ImageIO
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSRecording
import OMSStudio
import OMSUI
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Endpoints for recording: the overlay's setup and the recording bar, the recording window, Studio, GIFs, and the replay.
extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleRecordingHook(_ hook: String, _ url: URL) -> Bool {
        switch hook {
        case "record-demo":
            // Records a window of scrolling text the app draws behind the desktop picture, through the real
            // recorder, nothing shown and nothing of the user's read: seconds=, w=/h= (points), fps=, speed=
            // (points per second; 0 = still), hevc=1, audio=1 (what the Mac plays), keep=0 (else record-demo.mov
            // and .mp4 stay in the snapshot folder). Logs frames, drops, bitrate, CPU, and the finishing time.
            let seconds = Self.intParameter("seconds", in: url) ?? 5
            let size = CGSize(width: Self.intParameter("w", in: url) ?? 1280, height: Self.intParameter("h", in: url) ?? 720)
            Task {
                await DebugRecordingDemo.run(
                    seconds: seconds, size: size, framesPerSecond: Self.intParameter("fps", in: url) ?? 60,
                    speed: Double(Self.intParameter("speed", in: url) ?? 240), prefersHEVC: Self.intParameter("hevc", in: url) == 1,
                    keeps: Self.intParameter("keep", in: url) != 0, systemAudio: Self.intParameter("audio", in: url) == 1
                )
            }
        case "record-flow":
            // The whole flow on a window of scrolling text the app draws behind the desktop picture (never
            // the user's screen): countdown, recording with its control bar and menu bar time, Stop after
            // seconds=, kept in the history with a card; gif=1 keeps it as a GIF. The clipboard is left alone.
            // The countdown and bar show on screen: ask first. Clean up with qa-dismiss-all and
            // history-delete-latest.
            let seconds = Self.intParameter("seconds", in: url) ?? 3
            Task {
                await DebugRecordingDemo.runFlow(
                    recordings: recordings, displays: displays, seconds: seconds, countdown: settings.recordingCountdown,
                    size: CGSize(width: Self.intParameter("w", in: url) ?? 800, height: Self.intParameter("h", in: url) ?? 500),
                    output: Self.intParameter("gif", in: url) == 1 ? .gif : .video
                )
            }
        case "record-act":
            // action=pause|resume|restart|delete|stop drives the running recording; anything else logs its state.
            let action = Self.parameter("action", in: url)
            switch action {
            case "pause": recordings.pause()
            case "resume": recordings.resume()
            case "restart": recordings.restart()
            case "delete": recordings.delete()
            case "stop": recordings.stop()
            default: break
            }
            let recorder = recordings.debugRecorder
            Log.app.notice("debug.record-act \(action ?? "state", privacy: .public): recording=\(recordings.isRecording, privacy: .public) countingDown=\(recordings.isCountingDown, privacy: .public) state=\(recorder.map { String(describing: $0.state) } ?? "none", privacy: .public) elapsed=\(recorder.map { $0.elapsed.description } ?? "-", privacy: .public) frames=\(recorder.map { "\($0.frameCounts.complete)" } ?? "-", privacy: .public)")
        case "record-setup-demo":
            // Choosing what to record over drawn screens (never the real one), with an area selected and the
            // recording bar under it: x=, y=, w=, h= in display points from the top-left. Record only logs
            // what it would record. Covers a display until record-setup-act?action=cancel: ask first.
            let number = { (name: String, fallback: Int) in Self.intParameter(name, in: url) ?? fallback }
            Task { await runRecordingSetupDemo(CGRect(x: number("x", 240), y: number("y", 200), width: number("w", 800), height: number("h", 500))) }
        case "record-setup-act":
            // action=record|cancel|video|gif|systemAudio|microphone|clicks, or none to log what is framed.
            let action = Self.parameter("action", in: url)
            Log.app.notice("debug.record-setup \(action ?? "state", privacy: .public): \(overlay.debugRecordingSetup(action) ?? "nothing framed", privacy: .public)")
        case "record-choices-render":
            // The recording bar (before recording) alone behind the desktop picture, captured without showing
            // anything: output=video|gif, audio=1, mic=1, clicks=1, mode=light|dark. Writes
            // record-choices-<mode>-<output>.png.
            let value = { (name: String) in Self.parameter(name, in: url) }
            let output = RecordingOutput(rawValue: value("output") ?? "video") ?? .video
            let dark = value("mode") == "dark"
            let window = RecordingBarDemo.hiddenWindow(choices: RecordingChoices(
                output: output, systemAudio: value("audio") == "1", microphone: value("mic") == "1", showsClicks: value("clicks") == "1",
                showsKeystrokes: value("keys") == "1", camera: value("camera") == "1"
            ), recordsWindow: value("window") == "1", dark: dark)
            Task {
                await captureHiddenWindow(window, name: "record-choices-\(dark ? "dark" : "light")-\(output.rawValue)\(value("window") == "1" ? "-window" : "")")
                window.orderOut(nil)
            }
        case "camera-render":
            // The camera's bubble without its camera, behind the desktop picture: shape=circle|roundedSquare,
            // size=small|medium|large. Writes camera-<shape>-<size>.png.
            let value = { (name: String) in Self.parameter(name, in: url) }
            let style = CameraStyle(
                shape: value("shape").flatMap(CameraStyle.Shape.init(rawValue:)) ?? .circle,
                size: value("size").flatMap(CameraStyle.Size.init(rawValue:)) ?? .medium
            )
            let window = CameraBubble.debugHiddenWindow(style: style)
            Task {
                await captureHiddenWindow(window, name: "camera-\(style.shape.rawValue)-\(style.size.rawValue)")
                window.orderOut(nil)
            }
        case "click-render":
            // A click ring held at its middle, behind the desktop picture: writes click-ring.png.
            let rings = ClickHighlights()
            let screen = NSScreen.screens.first?.frame ?? .zero
            let area = CGRect(x: screen.midX - 60, y: screen.midY - 60, width: 120, height: 120)
            if let window = rings.debugShowBehindWallpaper(over: area) {
                rings.debugRing(at: CGPoint(x: area.midX, y: area.midY), hold: true)
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    await captureHiddenWindow(window, name: "click-ring")
                    rings.hide()
                }
            }
        case "keystroke-render":
            // The keystroke display behind the desktop picture, captured without showing anything:
            // keys=shortcut (⇧⌘4), keys=typing ("Hello↩"), or keys=long. Writes keystroke-<keys>.png.
            let kind = Self.parameter("keys", in: url) ?? "shortcut"
            let keys: [Keystroke] = switch kind {
            case "typing":
                [Keystroke(keyCode: 4, modifiers: .shift, characters: "H", keyCharacters: "h")]
                    + "ello".map { Keystroke(keyCode: 0, modifiers: [], characters: String($0), keyCharacters: String($0)) }
                    + [Keystroke(keyCode: 36, modifiers: [], characters: "\r", keyCharacters: "\r")]
            case "long":
                "The quick brown fox jumps over the lazy dog".map { Keystroke(keyCode: $0 == " " ? 49 : 0, modifiers: [], characters: String($0), keyCharacters: String($0)) }
            default:
                [Keystroke(keyCode: 21, modifiers: [.shift, .command], characters: "$", keyCharacters: "4")]
            }
            let display = KeystrokeDisplay(mode: .all)
            if let window = display.debugShowBehindWallpaper(keys, width: 900) {
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    await captureHiddenWindow(window, name: "keystroke-\(kind)")
                    display.hide()
                }
            }
        case "studio-demo":
            // A Studio recording of the demo window behind the desktop picture, nothing shown: seconds=, w=, h=
            // (points; 800x500 unless given), with a pause in the middle. Writes studio-demo.mp4 and
            // studio-demo.json (telemetry) to the snapshot folder.
            let seconds = Self.intParameter("seconds", in: url) ?? 4
            let size = CGSize(width: Self.intParameter("w", in: url) ?? 800, height: Self.intParameter("h", in: url) ?? 500)
            Task { await DebugRecordingDemo.runStudio(seconds: seconds, size: size) }
        case "studio-long-check":
            DebugRecordingDemo.startLongStudioCheck()
        case "studio-long-cancel":
            DebugRecordingDemo.cancelLongStudioCheck()
        case "studio-window":
            // The Studio window on a copy of studio-demo.mp4 with a made-up pointer, put in the history as
            // "Demo Studio Recording", behind the desktop picture, nothing shown. action=open (mode=dark,
            // at=<seconds> for the preview, select=0 to choose no zoom, cut=/choose=<from>-<to>, wait=<ms>
            // before the render, 1500 unless given, telemetry=real for studio-demo.json's) renders
            // studio-window[-dark].png; action=export keeps its movie in the history as Copy would, without
            // card, clipboard, or saved copy; action=reopen (mode=, at=) closes the window without exporting
            // and opens the demo again as Edit… would; action=play plays or pauses; action=export-edit
            // exports and changes the padding meanwhile; action=undo sends Undo down the responder chain;
            // action=export-cancel changes the padding and cancels an export 0.2 s in; action=render renders the
            // open window as it is (wait=<ms> first) to studio-window-now.png; action=state logs the
            // demo's record; open takes height=<points> for a taller window, camera=1 for a made-up camera
            // beside it (never a real one) from 0.3 s,
            // with fill=<from>-<to> when it filled the recording and corner=/shape=/size= for its bubble;
            // action=remove
            // deletes the demo and its project (always finish with it: the demo is a real history entry).
            let value = { (name: String) in Self.parameter(name, in: url) }
            let action = value("action") ?? "state"
            Task {
                switch action {
                case "open":
                    let dark = value("mode") == "dark"
                    let movie = Self.snapshotDirectory.appending(path: "studio-demo.mp4")
                    let asset = AVURLAsset(url: movie)
                    let duration = (try? await asset.load(.duration).seconds) ?? 4
                    let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 1600, height: 1000)
                    // telemetry=real takes what the demo wrote down (the user's pointer, wherever it was, and the
                    // demo's own clicks) instead of a made-up pointer.
                    let written = value("telemetry") == "real"
                        ? (try? Data(contentsOf: Self.snapshotDirectory.appending(path: "studio-demo.json"))).flatMap { try? JSONDecoder().decode(StudioTelemetry.self, from: $0) }
                        : nil
                    var telemetry = written ?? DebugRecordingDemo.syntheticTelemetry(size: CGSize(width: size.width / 2, height: size.height / 2), duration: duration)
                    // cut=<from>-<to> leaves a stretch out; choose=<from>-<to> chooses one on the clip.
                    let range = { (name: String) -> ClosedRange<Double>? in
                        let ends = (value(name) ?? "").split(separator: "-").compactMap { Double($0) }
                        return ends.count == 2 && ends[0] < ends[1] ? ends[0]...ends[1] : nil
                    }
                    var camera: URL?
                    // camerafailed=1: the bubble showed but no movie of it was kept.
                    if value("camerafailed") == "1" { telemetry.cameraFailed = true }
                    if value("camera") == "1" {
                        camera = await DebugRecordingDemo.syntheticCamera(seconds: duration)
                        var bubble = StudioProject.Camera()
                        if let corner = value("corner").flatMap(StudioProject.Camera.Corner.init(rawValue:)) { bubble.corner = corner }
                        if let shape = value("shape").flatMap(StudioProject.Camera.Shape.init(rawValue:)) { bubble.shape = shape }
                        if let side = value("size").flatMap(Double.init) { bubble.size = side }
                        telemetry.camera = StudioTelemetry.Camera(start: 0.3, fills: range("fill").map { [$0] } ?? [], bubble: bubble)
                    }
                    if let window = await recordings.debugOpenStudioDemo(movie: movie, telemetry: telemetry, dark: dark, camera: camera) {
                        let studio = recordings.debugStudioDemoWindow
                        if value("select") != "0" { studio?.debugSelectFirstZoom() }
                        if let cut = range("cut") { studio?.debugCut(cut) }
                        if let chosen = range("choose") { studio?.debugChoose(chosen) }
                        studio?.debugSeek(to: Double(value("at") ?? "1") ?? 1)
                        // Explicit dimensions exercise the editor's smallest window as well as tall inspectors.
                        if value("width") != nil || value("height") != nil {
                            window.setContentSize(CGSize(
                                width: value("width").flatMap(Double.init) ?? window.contentLayoutRect.width,
                                height: value("height").flatMap(Double.init) ?? window.contentLayoutRect.height
                            ))
                        }
                        try? await Task.sleep(for: .milliseconds(Int(value("wait") ?? "1500") ?? 1500))
                        await captureHiddenWindow(window, name: dark ? "studio-window-dark" : "studio-window")
                    }
                case "reopen":
                    let dark = value("mode") == "dark"
                    if let window = await recordings.debugReopenStudioDemo(dark: dark) {
                        recordings.debugStudioDemoWindow?.debugSeek(to: Double(value("at") ?? "1") ?? 1)
                        try? await Task.sleep(for: .milliseconds(1500))
                        await captureHiddenWindow(window, name: dark ? "studio-window-dark" : "studio-window")
                        Log.app.notice("debug.studio-window reopened, changes waiting to export \(recordings.debugStudioDemoWindow?.hasUnexportedChanges == true, privacy: .public)")
                    }
                case "play":
                    recordings.debugStudioDemoWindow?.debugTogglePlay()
                case "keyboard-check":
                    if let studio = recordings.debugStudioDemoWindow {
                        let checks = await studio.debugKeyboardChecks()
                        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: Self.snapshotDirectory.appending(path: "studio-keyboard-check.json"), options: .atomic)
                        }
                        Log.app.notice("debug.studio-window keyboard: \(checks.filter { !$0.value }.keys.sorted().joined(separator: ","), privacy: .public)")
                    }
                case "zoom-in", "zoom-out", "fit-selection", "fit":
                    let pressed = recordings.debugStudioDemoWindow?.debugTimelineControl(action) ?? false
                    Log.app.notice("debug.studio-window timeline \(action, privacy: .public): pressed \(pressed, privacy: .public)")
                    try? await Task.sleep(for: .milliseconds(1000))
                    if let window = recordings.debugStudioDemoWindow?.window {
                        await captureHiddenWindow(window, name: "studio-timeline-\(action)")
                    }
                case "render":
                    // The open demo's window as it is now (wait=<ms> first), to studio-window-now.png.
                    try? await Task.sleep(for: .milliseconds(Int(value("wait") ?? "0") ?? 0))
                    if let window = recordings.debugStudioDemoWindow?.window { await captureHiddenWindow(window, name: "studio-window-now") }
                case "undo":
                    // Undo as Edit › Undo sends it, down the window's responder chain.
                    guard let studio = recordings.debugStudioDemoWindow else { break }
                    let before = studio.studio.project.padding
                    let route = studio.debugUndo()
                    Log.app.notice("debug.studio-window undo: padding \(before, privacy: .public) → \(studio.studio.project.padding, privacy: .public); \(route, privacy: .public)")
                case "export-cancel":
                    // A change, then an export cancelled 0.2 s in: nothing kept, the change still waiting.
                    guard let studio = recordings.debugStudioDemoWindow else { break }
                    studio.debugSetPadding(0.2)
                    let left = await studio.debugExportAndCancel(after: .milliseconds(200))
                    Log.app.notice("debug.studio-window export-cancel: \(left, privacy: .public)")
                case "export-edit":
                    // Exports, and changes the padding while the movie is being made: the change must be
                    // exported after it.
                    guard let studio = recordings.debugStudioDemoWindow else { break }
                    let exporting = Task { await studio.debugExport() }
                    try? await Task.sleep(for: .milliseconds(300))
                    studio.debugSetPadding(0.15)
                    let url = await exporting.value
                    Log.app.notice("debug.studio-window exported \(url?.lastPathComponent ?? "nothing", privacy: .public) with a change made meanwhile; changes waiting \(studio.hasUnexportedChanges, privacy: .public)")
                case "export":
                    let url = await recordings.debugStudioDemoWindow?.debugExport()
                    Log.app.notice("debug.studio-window exported \(url?.lastPathComponent ?? "nothing", privacy: .public)")
                case "remove":
                    recordings.debugRemoveStudioDemo()
                default:
                    break
                }
                Log.app.notice("debug.studio-window \(action, privacy: .public): \(recordings.debugStudioDemoState, privacy: .public)")
            }
        case "replay":
            // The replay through the app's own coordinator, on the scrolling window behind the desktop picture
            // kept as if it were a display (nothing of the user's read): action=on (w=/h= points), save (writes
            // replay-saved.mp4 to the snapshot folder instead of the history; sound=all|system|microphone|none
            // sets the replay's sound first, a real setting: put it back), off, state.
            if #available(macOS 27, *) {
                let value = { (name: String) in Self.parameter(name, in: url) }
                let action = value("action") ?? "state"
                Task {
                    guard let replay = replay() as? ReplayCoordinator else { return }
                    switch action {
                    case "on":
                        let size = CGSize(width: Self.intParameter("w", in: url) ?? 800, height: Self.intParameter("h", in: url) ?? 500)
                        if let window = await DebugRecordingDemo.openReplayWindow(size: size) {
                            do {
                                try await replay.debugKeep(filter: window.filter, width: window.width, height: window.height, as: 0)
                            } catch {
                                Log.app.error("debug.replay couldn't start: \(String(describing: error), privacy: .public)")
                            }
                        }
                    case "save":
                        if let sound = value("sound").flatMap(ReplaySound.init(rawValue:)) { settings.replaySound = sound }
                        replay.debugSaveFolder = Self.snapshotDirectory
                        replay.save()
                    case "off":
                        await replay.debugStopAll()
                        replay.debugSaveFolder = nil
                        DebugRecordingDemo.closeReplayWindow()
                    default:
                        break
                    }
                    Log.app.notice("debug.replay \(action, privacy: .public): \(replay.debugState, privacy: .public)")
                }
            } else {
                Log.app.notice("debug.replay needs macOS 27")
            }
        case "replay-demo":
            // The replay spike (macOS 27): the last-15-seconds buffer on the scrolling window behind the
            // desktop picture, nothing shown: seconds= of buffering (20 unless given), w=/h= points, fps=, speed=,
            // clip= seconds to export (15), keep=1 keeps replay-demo.mov in the snapshot folder, frames=0 asks
            // the stream for no frames of its own (only the buffer).
            if #available(macOS 27, *) {
                let seconds = Self.intParameter("seconds", in: url) ?? 20
                let size = CGSize(width: Self.intParameter("w", in: url) ?? 800, height: Self.intParameter("h", in: url) ?? 500)
                let fps = Self.intParameter("fps", in: url) ?? 60
                let speed = Double(Self.intParameter("speed", in: url) ?? 240)
                let clip = Double(Self.intParameter("clip", in: url) ?? 15)
                let keeps = Self.intParameter("keep", in: url) == 1
                let takesFrames = Self.intParameter("frames", in: url) != 0
                let audio = Self.intParameter("audio", in: url) == 1
                let takesAudio = Self.intParameter("audiooutput", in: url) != 0
                // mic=1 buffers the user's microphone: only with their word; the clip is never kept then.
                let microphone = Self.intParameter("mic", in: url) == 1
                // silence=0: sound asked for, but none played.
                let playsSilence = Self.intParameter("silence", in: url) != 0
                Task {
                    await DebugRecordingDemo.runReplaySpike(
                        seconds: seconds, size: size, framesPerSecond: fps, speed: speed, clip: clip, keeps: keeps && !microphone,
                        takesFrames: takesFrames, audio: audio, takesAudio: takesAudio, microphone: microphone, playsSilence: playsSilence
                    )
                }
            } else {
                Log.app.notice("debug.replay-demo needs macOS 27")
            }
        case "studio-render":
            // Films studio-demo.mp4 as the Studio window would export it, from a made-up pointer, over the sky
            // gradient with automatic zooms: writes studio-render.mp4 and logs the time it took and the most
            // memory used. blur=0 films it without motion blur; camera=1 with a made-up camera beside it.
            let blur = Self.intParameter("blur", in: url) != 0
            let camera = Self.intParameter("camera", in: url) == 1
            Task { await DebugRecordingDemo.renderStudio(motionBlur: blur, camera: camera) }
        case "gif-demo":
            // Makes a GIF of record-demo.mov in the snapshot folder (record it first with record-demo?keep=1):
            // fps=, scale= (percent of the recording's pixels). Logs frames, size, time, and the most memory
            // the app used meanwhile; writes record-demo.gif.
            let fps = Self.intParameter("fps", in: url) ?? 15
            let scale = Double(Self.intParameter("scale", in: url) ?? 50) / 100
            Task { await DebugRecordingDemo.makeGIF(framesPerSecond: fps, scale: scale) }
        case "record-window-demo":
            // The recording window on a copy of record-demo.mp4 (make it with record-demo?keep=1) put in the
            // history as "Demo Recording", behind the desktop picture, nothing shown. action=open (mode=dark)
            // renders it to record-window[-dark].png; action=edit with trim=<start>-<end> (seconds),
            // mute=1, scale=<percent> edits it as the toolbar would and renders record-window-edited.png;
            // action=close keeps the edits; action=reopen opens it again (rendering
            // record-window-reopened.png); action=revert (window open) puts it back; action=state logs its
            // record; action=remove deletes the demo.
            let value = { (name: String) in Self.parameter(name, in: url) }
            let action = value("action") ?? "state"
            Task {
                switch action {
                case "open":
                    let dark = value("mode") == "dark"
                    if let window = await recordings.debugOpenDemo(movie: Self.snapshotDirectory.appending(path: "record-demo.mp4"), dark: dark) {
                        try? await Task.sleep(for: .milliseconds(600))
                        await captureHiddenWindow(window, name: dark ? "record-window-dark" : "record-window")
                    }
                case "edit":
                    let bounds = value("trim")?.split(separator: "-").compactMap { Double($0) } ?? []
                    let trim = bounds.count == 2
                        ? CMTimeRange(start: CMTime(seconds: bounds[0], preferredTimescale: 600), end: CMTime(seconds: bounds[1], preferredTimescale: 600))
                        : nil
                    recordings.debugDemoWindow?.debugEdit(trim: trim, keepsAudio: value("mute") != "1", scale: Double(value("scale") ?? "100").map { $0 / 100 } ?? 1)
                    if let window = recordings.debugDemoWindow?.window {
                        try? await Task.sleep(for: .milliseconds(400))
                        await captureHiddenWindow(window, name: "record-window-edited")
                    }
                case "reopen":
                    if let window = recordings.debugReopenDemo() {
                        try? await Task.sleep(for: .milliseconds(600))
                        await captureHiddenWindow(window, name: "record-window-reopened")
                    }
                case "close":
                    recordings.debugDemoWindow?.debugPerform("close")
                case "revert":
                    recordings.debugDemoWindow?.debugPerform("revert")
                case "remove":
                    recordings.debugRemoveDemo()
                default:
                    break
                }
                Log.app.notice("debug.record-window \(action, privacy: .public): \(recordings.debugDemoState, privacy: .public)")
            }
        case "record-bar-render":
            // The control bar alone behind the desktop picture, captured without showing anything:
            // elapsed= (seconds), paused=1, mode=light|dark, mic=<percent> for the microphone's meter, stalled=1
            // for the microphone that stopped sending sound, denied=1 for one left out without access, ask=1 for Delete
            // pressed once. Writes record-bar-<mode>[-paused][-stalled][-denied][-ask].png.
            let paused = Self.intParameter("paused", in: url) == 1
            let stalled = Self.intParameter("stalled", in: url) == 1
            let denied = Self.intParameter("denied", in: url) == 1
            let asks = Self.intParameter("ask", in: url) == 1
            let dark = Self.parameter("mode", in: url) == "dark"
            let level = Self.intParameter("mic", in: url).map { Double($0) / 100 }
            let window = RecordingControlBar.debugHiddenWindow(
                elapsed: .seconds(Self.intParameter("elapsed", in: url) ?? 42), paused: paused, dark: dark,
                microphone: denied ? .denied : level != nil || stalled ? .metered : .none, microphoneLevel: level, microphoneStalled: stalled,
                asksDelete: asks
            )
            Task {
                await captureHiddenWindow(window, name: "record-bar-\(dark ? "dark" : "light")\(paused ? "-paused" : "")\(stalled ? "-stalled" : "")\(denied ? "-denied" : "")\(asks ? "-ask" : "")")
                window.orderOut(nil)
            }
        default:
            return false
        }
        return true
    }

    /// The recording overlay over drawn screens with `rect` (display points from the top-left of the
    /// pointer's display) chosen: the recording bar shows; Record logs the outcome and records nothing.
    func runRecordingSetupDemo(_ rect: CGRect) async {
        guard let display = injectToolsDemoFrames() else { return }
        overlay.freezesScreen = false
        overlay.recordingChoices = RecordingChoices(systemAudio: true, microphone: false, showsClicks: true)
        overlay.begin(mode: .area, purpose: .record) { outcome in
            Log.app.notice("debug.record-setup outcome \(String(describing: outcome), privacy: .public)")
        }
        await waitForOverlayFrames()
        overlay.simulateSelection(CGRect(x: display.frame.minX + rect.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height))
        Log.app.notice("debug.record-setup \(overlay.debugRecordingSetup(nil) ?? "nothing framed", privacy: .public)")
    }
}
#endif
