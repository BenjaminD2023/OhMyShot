#if DEBUG
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

/// `ohmyshot-dev://debug/<hook>` endpoints for scripted checks. Compiled into debug builds only, and
/// reachable only through the debug build's own URL scheme.
struct DebugHooks {
    let displays: DisplayTopology
    let permissions: PermissionCenter
    let capturer: ScreenCapturer
    let overlay: OverlayController
    let captures: CaptureCoordinator
    let quickAccess: QuickAccessController
    let showSettings: (SettingsTab) -> Void
    let showOnboarding: () -> Void
    let showHistory: () -> Void
    let restoreLatestFromHistory: () -> Void
    let annotateLatestFromHistory: () -> Void
    let deleteLatestFromHistory: () -> Void
    let setRetention: (HistoryRetention) -> Void
    let historyWindow: () -> NSWindow?
    let historyCount: () -> Int
    /// The newest capture's file in the history.
    let latestCaptureFile: () -> URL?
    let previewRetentionChange: (HistoryRetention?) -> Void
    let textCapture: TextCaptureCoordinator
    let annotations: AnnotationCoordinator
    let pins: PinController
    let colorPicker: ColorPickerCoordinator
    let measurer: MeasureCoordinator
    let recordings: RecordingCoordinator
    let scrolling: ScrollingCaptureCoordinator
    let settings: SettingsStore
    /// The replay's coordinator on macOS 27, as any object.
    let replay: () -> AnyObject?

    /// Where `snapshot` writes window captures.
    static let snapshotDirectory = URL.cachesDirectory.appending(path: "\(Log.subsystem)/debug-snapshots", directoryHint: .isDirectory)
    /// The real reader of a capture's text, while redact-slow or textlines-slow stands in for it.
    private static var unslowedReadText: (@Sendable (CGImage) -> CaptureReading)?
    /// How many seconds longer the redaction suggestions and the highlighter's lines take to read.
    private static var readingDelays = (redactions: 0, textLines: 0)
    /// How many of the next readings of each fail, as a reading the capture could not be made for does.
    private static var readingFailures = (redactions: 0, textLines: 0)

    func handle(_ url: URL) {
        let hook = url.pathComponents.dropFirst().first ?? ""
        switch hook {
        case "ping":
            Log.app.notice("debug.ping pong")
        case "displays":
            logDisplays()
        case "resources":
            logResources()
        case "permissions":
            permissions.refresh()
            for permission in Permission.allCases {
                Log.permissions.notice("debug.permission \(permission.rawValue, privacy: .public)=\(String(describing: permissions.status(of: permission)), privacy: .public)")
            }
        case "snapshot":
            Task { await snapshotWindows() }
        case "settings":
            let tab = url.pathComponents.dropFirst(2).first.flatMap(SettingsTab.init(rawValue:)) ?? .general
            showSettings(tab)
        case "onboarding":
            showOnboarding()
        case "history":
            showHistory()
        case "appearance":
            // mode=dark|light; anything else follows the system again.
            let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mode" }?.value
            NSApp.appearance = switch mode {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }
            Log.app.notice("debug.appearance \(mode ?? "system", privacy: .public)")
        case "qa-hover":
            quickAccess.previewHoverOnLatest()
        case "qa-copied":
            quickAccess.copyLatest()
        case "qa-dismiss-all":
            quickAccess.dismissAll()
        case "qa-restore":
            quickAccess.restoreRecentlyClosed()
        case "qa-dismiss-latest":
            quickAccess.dismissLatest()
        case "qa-render":
            // The Quick Access panel captured on its own (only this app's cards, nothing else of the screen)
            // into qa-cards.png. It holds every card showing: run it only when the cards are the checks' own.
            if let panel = quickAccess.debugPanel {
                Task { await captureHiddenWindow(panel, name: "qa-cards") }
            } else {
                Log.app.notice("debug.qa-render no cards")
            }
        case "history-key":
            // key=left|right|up|down|return|space|cmd-c|cmd-s|cmd-delete, sent through the window like a
            // real key press.
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value ?? ""
            sendKey(key, to: historyWindow())
        case "history-restore-latest":
            restoreLatestFromHistory()
        case "retention":
            // value=never|oneDay|threeDays|oneWeek|oneMonth
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "value" }?.value
            if let retention = value.flatMap(HistoryRetention.init(rawValue:)) {
                setRetention(retention)
                Log.app.notice("debug.retention \(retention.rawValue, privacy: .public)")
            }
        case "history-retention-preview":
            // value=never|oneDay|…; anything else dismisses the dialog. Never confirms anything.
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "value" }?.value
            previewRetentionChange(value.flatMap(HistoryRetention.init(rawValue:)))
            Log.app.notice("debug.history-retention-preview \(value ?? "dismiss", privacy: .public)")
        case "history-count":
            Log.app.notice("debug.history-count \(historyCount(), privacy: .public) in history, \(quickAccess.itemIDs.count, privacy: .public) card(s), can restore: \(quickAccess.canRestoreRecentlyClosed, privacy: .public)")
        case "capture-display":
            // save=1 also writes the last capture of each display: a picture of the real screen, so off
            // unless asked for.
            let count = Self.intParameter("n", in: url) ?? 10
            Task { await benchmarkDisplayCaptures(count: count, saves: Self.intParameter("save", in: url) == 1) }
        case "capture-timing":
            // Times captures of the pointer's display, each read and dropped (nothing is kept or looked
            // at), n= of them 400 ms apart; activity=1 holds a user-initiated activity meanwhile, which
            // keeps App Nap away.
            // display=<id> times that display instead of the pointer's.
            let count = Self.intParameter("n", in: url) ?? 8
            let displayID = Self.intParameter("display", in: url).map { CGDirectDisplayID($0) }
            Task { await timeCaptures(count: count, holdsActivity: Self.intParameter("activity", in: url) == 1, displayID: displayID) }
        case "overlay-demo":
            // Optional px/py: the pointer in display points from the top-left corner.
            let pointer = Self.intParameter("px", in: url).flatMap { x in Self.intParameter("py", in: url).map { CGPoint(x: x, y: $0) } }
            // mode=window, purpose=text, select=0 (no selection, as when the overlay first appears).
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let windowMode = items.contains { $0.name == "mode" && $0.value == "window" }
            let purpose: OverlayController.Purpose = items.contains { $0.name == "purpose" && $0.value == "text" } ? .text : .screenshot
            let selects = !items.contains { $0.name == "select" && $0.value == "0" }
            Task { await renderOverlayDemo(pointerFromTopLeft: pointer, mode: windowMode ? .window : .area, purpose: purpose, selects: selects) }
        case "capture-test":
            // A 400×300 point region at the center of the primary display, delivered like any capture.
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await captures.captureArea(rect, appName: "Test", copiesToClipboard: false) }
            }
        case "text-test":
            // Capture Text on the same centered region as capture-test, without touching the clipboard.
            let join = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "join" && $0.value == "1" } ?? false
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await textCapture.recognize(region: rect, joinLines: join, copiesToClipboard: false) }
            }
        case "text-card":
            // state=copied|empty|single: the optional result card with sample text, by a centered
            // selection; state=highlight: the selection highlight shown while text is read.
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? "copied"
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 210, y: display.frame.midY - 60, width: 420, height: 120)
                textCapture.previewCard(state, near: rect)
            }
        case "panel-demo":
            // The OCR panel on a drawn page (never the screen). via=file|pasteboard|finder opens it the
            // way a file, pasted image data, or a file copied in Finder would; state=loading|empty|failed|
            // unreadable|no-clipboard-image, or prose for a page without a table.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            Task { await openPanelDemo(via: value("via"), state: value("state")) }
        case "panel-state":
            // pane=text|table, join=0|1, select=<line>, hover=<line>, edited=1, translate=0|1,
            // target=auto|<language> (the setting itself: put it back to auto afterwards)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            textCapture.previewPanelState(
                pane: value("pane"), joinLines: value("join").map { $0 == "1" },
                selectLine: value("select").flatMap(Int.init), hoverLine: value("hover").flatMap(Int.init),
                edited: value("edited") == "1", translate: value("translate").map { $0 == "1" }, target: value("target")
            )
        case "translate-demo":
            // Translate Area on a drawn page (never the screen): its lens lies centered on the main
            // display. prose=0 for the page with the table; blank=1 for a page with nothing to
            // translate (it opens the panel); controls=1 shows its buttons.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let prose = items.first { $0.name == "prose" }?.value != "0"
            let blank = items.first { $0.name == "blank" }?.value == "1"
            let controls = items.first { $0.name == "controls" }?.value == "1"
            Task {
                await translateDemo(prose: prose, blank: blank)
                if controls { textCapture.revealLensControls() }
            }
        case "panel-test":
            // The centered region, as Option at the end of a Capture Text drag. Reads the screen: for
            // timing and logs only, never for snapshots.
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await textCapture.openPanel(region: rect) }
            }
        case "drop-check":
            // Whether AppKit finds drop targets by registered type rather than by the public hit test,
            // which the menu bar icon's drop target relies on.
            let selector = NSSelectorFromString("_hitTest:dragTypes:")
            Log.app.notice("debug.drop-check typed hit test available: \(NSView.instancesRespond(to: selector), privacy: .public)")
        case "capture-window-test":
            // The frontmost window of the app named `owner` (default Finder), with and without shadow.
            let owner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "owner" }?.value ?? "Finder"
            Task { await testWindowCapture(owner: owner) }
        case "bench-overlay":
            // freeze=1 measures a frozen overlay, which appears once the pointer's display is captured.
            let count = Self.intParameter("n", in: url) ?? 10
            Task { await benchmarkOverlay(count: count, freezes: Self.intParameter("freeze", in: url) == 1) }
        case "latency-selftest":
            Task {
                for milliseconds in [10, 20, 30, 40, 50] {
                    let probe = LatencyProbe("debug.selftest")
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    probe.end()
                }
            }
        case "relief":
            // Hands freed heap pages back now, to tell freed-but-kept memory from memory still in use.
            MemoryRelief.returnFreedPages()
            Log.app.notice("debug.relief done")
        case "relaunch":
            Relauncher.relaunch()
        case "editor-demo":
            // The annotation editor on the drawn page: marks=0 for none, spot=1 adds a spotlight,
            // tool=<tool>, select=<index>, edit=<index of a text mark>, zoom=actual; hidden=1 opens it
            // behind the wallpaper without making the app active, for editor-render; dark=1 turns the
            // page's shades over (white text on black).
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            DebugEditorDemo.open(
                marks: value("marks") != "0",
                spot: value("spot") == "1",
                tool: value("tool").flatMap(AnnotationTool.init(rawValue:)),
                select: value("select").flatMap(Int.init),
                editText: value("edit").flatMap(Int.init),
                actualSize: value("zoom") == "actual",
                hidden: value("hidden") == "1",
                dark: value("dark") == "1"
            )
        case "editor-render":
            // The demo editor's window alone, through ScreenCaptureKit, as <name>.png: works behind the
            // wallpaper (editor-demo?hidden=1), so nothing shows.
            if let window = DebugEditorDemo.window {
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? "editor-render"
                Task { await captureHiddenWindow(window, name: name) }
            } else {
                Log.app.error("debug.editor-render: no demo editor")
            }
        case "inplace-demo":
            // In-place annotation over a drawn screen, never the real one: x, y, w, h choose the area in
            // the display's points from its top-left corner (default: just around the drawn page).
            let rect = ["x", "y", "w", "h"].compactMap { Self.intParameter($0, in: url) }
            Task { await openInPlaceDemo(area: rect.count == 4 ? CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) : nil) }
        case "freeze-demo":
            // A frozen screenshot over drawn screens, never the real one, chosen without the mouse and kept
            // off the clipboard: logs whether what was kept is the frozen selection, then removes it. x, y,
            // w, h choose the area in the display's points from its top-left corner (default: the page);
            // span=1 takes an area across the edge two displays share, span=2 the same at the lower of
            // their bottom edges, reaching where no display is.
            let rect = ["x", "y", "w", "h"].compactMap { Self.intParameter($0, in: url) }
            let span = Self.intParameter("span", in: url) ?? 0
            Task { await runFreezeDemo(area: rect.count == 4 ? CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) : nil, span: span) }
        case "pin-demo":
            // Pins the drawn page, never anything from the screen or the clipboard: centered on the pointer's
            // display, or with x, y over that point in display points from its top-left corner, at 1:1.
            pinDemo(at: ["x", "y"].compactMap { Self.intParameter($0, in: url) })
        case "pin-text-demo":
            // Pins fixed demo text, never the clipboard's: code=1 for an indented snippet, long=1 for a
            // paragraph that wraps at the card's width.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let has = { (name: String) in items.contains { $0.name == name && $0.value == "1" } }
            let text = has("code")
                ? "func pinned() {\n    let shortcut = \"⌃⌥⌘7\"\n    print(\"Capture Area and Pin: \\(shortcut)\")\n}"
                : has("long")
                    ? "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。Quick Access keeps every capture one click away; the text in a capture can be copied, edited, and searched."
                    : "brew install --cask ohmyshot"
            pins.pin(text: text)
            Log.app.notice("debug.pin-text-demo \(self.pins.debugSummary, privacy: .public)")
        case "pin-color-demo":
            // Pins a fixed color, never the clipboard's: hex=RRGGBB[AA] (no #), default the accent-like blue.
            let hex = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hex" }?.value ?? "3366FF"
            if let color = PinColor.parse("#" + hex) {
                pins.pin(color: color)
            }
            Log.app.notice("debug.pin-color-demo \(self.pins.debugSummary, privacy: .public)")
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
        case "status-icon":
            // Whether the menu bar's mark loads from the app's asset catalog (not the fallback symbol), drawn
            // at 2× into status-icon.png in the snapshot folder: black for template ink.
            Task {
                let image = NSImage(named: "MenuBarIcon")
                Log.app.notice("debug.status-icon catalog image \(image != nil, privacy: .public), size \(String(describing: image?.size), privacy: .public), template \(image?.isTemplate ?? false, privacy: .public)")
                guard let image else { return }
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 72, height: 72).fill()
                image.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
                NSGraphicsContext.restoreGraphicsState()
                let file = Self.snapshotDirectory.appending(path: "status-icon.png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
                Log.app.notice("debug.status-icon \(file.path(percentEncoded: false), privacy: .public)")
            }
        case "own-window-check":
            // Whether captures take the app's own standard windows in: a titled window filled with magenta opens
            // at the center of the main display for about a second, the middle of it is captured as an area
            // would be, and the capture's average color is logged (magenta = in). Nothing is kept.
            Task { await checkOwnWindowInCapture() }
        case "app-icon":
            // The app's icon as the app itself sees it (`NSApp.applicationIconImage`), or with source=workspace as
            // Finder shows it, drawn at 128 pt into app-icon.png in the snapshot folder.
            let workspaceIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            let icon = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "source" && $0.value == "workspace" } == true
                ? workspaceIcon : NSApp.applicationIconImage
            Log.app.notice("debug.app-icon size \(String(describing: icon?.size), privacy: .public), \(icon?.representations.count ?? 0, privacy: .public) representations: \(icon?.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ", ") ?? "none", privacy: .public)")
            if let icon {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
                NSGraphicsContext.restoreGraphicsState()
                try? bitmap.representation(using: .png, properties: [:])?.write(to: Self.snapshotDirectory.appending(path: "app-icon.png"))
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
            let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
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
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let number = { (name: String, fallback: Int) in items.first { $0.name == name }?.value.flatMap(Int.init) ?? fallback }
            Task { await runRecordingSetupDemo(CGRect(x: number("x", 240), y: number("y", 200), width: number("w", 800), height: number("h", 500))) }
        case "record-setup-act":
            // action=record|cancel|video|gif|systemAudio|microphone|clicks, or none to log what is framed.
            let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
            Log.app.notice("debug.record-setup \(action ?? "state", privacy: .public): \(overlay.debugRecordingSetup(action) ?? "nothing framed", privacy: .public)")
        case "record-choices-render":
            // The recording bar (before recording) alone behind the desktop picture, captured without showing
            // anything: output=video|gif, audio=1, mic=1, clicks=1, mode=light|dark. Writes
            // record-choices-<mode>-<output>.png.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
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
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
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
            let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "keys" }?.value ?? "shortcut"
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
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
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
                        // height=<points> makes the window taller, to see all of the inspector.
                        if let height = value("height").flatMap(Double.init) {
                            window.setContentSize(CGSize(width: window.contentLayoutRect.width, height: height))
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
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value = { (name: String) in items.first { $0.name == name }?.value }
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
        case "scroll-input-check", "scroll-input-external":
            Task {
                let report = await AutoScrollDiagnostics.externalDelivery()
                Log.app.notice("debug.scroll-input-external \(report, privacy: .public)")
            }
        case "scroll-demo":
            // Scrolling capture on a window of made-up text the app draws behind the desktop picture, scrolled step
            // by step, nothing shown and nothing of the user's read: axis=horizontal, step= points, interval= ms,
            // header=/footer= points of the bars that stay put, w=/h= points, back=1 (back up some way at the end),
            // jump=1 (once too far, then back), scrollbars=1 (overlay scroll bars, which never fade back there),
            // sidebar=1 (a sidebar that never moves and a badge stuck over the page), forum=1 (a forum's topic: the
            // sidebar, a banner, posts whose avatars stick below the header and are pushed out, and a timeline right
            // of the page, timeline=<percent> of the view's height, its handle creeping).
            // Writes scroll-demo.png and scroll-demo-reference.png to the snapshot folder and logs how they compare
            // and how the stitching went.
            var options = DebugScrollingDemo.Options()
            options.horizontal = Self.parameter("axis", in: url) == "horizontal"
            if let step = Self.intParameter("step", in: url) { options.step = CGFloat(step) }
            if let interval = Self.intParameter("interval", in: url) { options.interval = interval }
            if let header = Self.intParameter("header", in: url) { options.header = CGFloat(header) }
            if let footer = Self.intParameter("footer", in: url) { options.footer = CGFloat(footer) }
            if let width = Self.intParameter("w", in: url) { options.size.width = CGFloat(width) }
            if let height = Self.intParameter("h", in: url) { options.size.height = CGFloat(height) }
            options.back = Self.intParameter("back", in: url) == 1
            options.jump = Self.intParameter("jump", in: url) == 1
            options.scrollBars = Self.intParameter("scrollbars", in: url) == 1
            options.sidebar = Self.intParameter("sidebar", in: url) == 1
            options.forum = Self.intParameter("forum", in: url) == 1
            if let timeline = Self.intParameter("timeline", in: url) { options.timeline = CGFloat(timeline) / 100 }
            Task { await DebugScrollingDemo.run(options) }
        case "scroll-x-check":
            Task { await DebugScrollingDemo.runXCheck() }
        case "scroll-e2e-flow":
            // The scrolling capture's own flow (coordinator, panel behind the desktop picture, Auto-scroll addressed to
            // the window) on a browser window a check opened itself, found by title= and pid=, the area below top=
            // points: left to stop by itself (seconds= at most), then Done. Writes scroll-flow.png and steps.txt (dumps=1:
            // every view as PNG too) to scroll-e2e-flow-<label>/ in the snapshot folder; nothing goes to the history or the
            // clipboard.
            let title = Self.parameter("title", in: url) ?? "OMS E2E"
            let layout = displays.layout
            Task {
                await DebugScrollingDemo.runFlowEndToEnd(
                    title: title, processID: Self.intParameter("pid", in: url).map { pid_t($0) }, label: Self.parameter("label", in: url) ?? "run",
                    seconds: Double(Self.parameter("seconds", in: url) ?? "") ?? 30, top: CGFloat(Self.intParameter("top", in: url) ?? 0),
                    dumps: Self.parameter("dumps", in: url) == "1", coordinator: scrolling, layout: layout
                )
            }
        case "scroll-e2e":
            // End to end on a browser window a check opened itself, found by title= and pid= (never the user's own windows):
            // the real stream over the window below top= points (window=1: the window alone), driven by driver=auto
            // (the real AutoScroller), debug (addressed to the window), or none (scrolled from outside), for seconds=
            // at speed=; stop=1 stops driving after two lost views as the coordinator does; dump=0 skips writing the
            // views. Writes every view the stitcher took (PNG), its steps, previews, and the picture to
            // scroll-e2e-<label>/ in the snapshot folder; nothing goes to the history or the clipboard.
            let title = Self.parameter("title", in: url) ?? "OMS E2E"
            let label = Self.parameter("label", in: url) ?? "run"
            let seconds = Double(Self.parameter("seconds", in: url) ?? "") ?? 8
            let speed = Double(Self.parameter("speed", in: url) ?? "") ?? 1
            let top = CGFloat(Self.intParameter("top", in: url) ?? 0)
            let driver = Self.parameter("driver", in: url) ?? "auto"
            let layout = displays.layout
            Task {
                await DebugScrollingDemo.runEndToEnd(
                    title: title, processID: Self.intParameter("pid", in: url).map { pid_t($0) }, label: label, seconds: seconds, speed: speed, window: Self.intParameter("window", in: url) == 1, top: top,
                    driver: driver, stopsWhenLost: Self.intParameter("stop", in: url) == 1, dumps: Self.intParameter("dump", in: url) != 0,
                    capturer: capturer, layout: layout
                )
            }
        case "scroll-long":
            // A long scrolling capture made up in memory, nothing shown or read: w×h pixel views (3346×2404) of a
            // page length= pixels long (50000) through the stitcher capped at mb= (256), then the picture, its PNG
            // and the card's thumbnail; logs the time and the app's highest footprint for each. Nothing is kept.
            let width = Self.intParameter("w", in: url) ?? 3346, height = Self.intParameter("h", in: url) ?? 2404
            let length = Self.intParameter("length", in: url) ?? 50_000, megabytes = Self.intParameter("mb", in: url) ?? 256
            Task { await DebugScrollingDemo.runLong(width: width, height: height, length: length, maxMB: megabytes) }
        case "scroll-flow":
            // The scrolling capture's own flow (coordinator, panel, stitching) on the same window, every part of it
            // behind the desktop picture: renders the panel midway as scroll-panel.png (mode=dark for dark) and
            // keeps the picture as scroll-flow.png in the snapshot folder instead of the history. axis=horizontal.
            var options = DebugScrollingDemo.Options()
            options.horizontal = Self.parameter("axis", in: url) == "horizontal"
            let dark = Self.parameter("mode", in: url) == "dark"
            let render: (NSWindow, String) async -> Void = { window, name in await self.captureHiddenWindow(window, name: name) }
            guard let display = displays.layout.primary else { return }
            Task { await DebugScrollingDemo.runFlow(options, coordinator: scrolling, display: display, dark: dark, render: render) }
        case "scroll-panel-render":
            // The scrolling capture's panel on its own, behind the desktop picture, with a made-up picture and
            // progress, captured into scroll-panel.png (mode=dark, hint=back|full|auto|access|stopped, axis=horizontal).
            let panel = ScrollingPanel()
            let horizontal = Self.parameter("axis", in: url) == "horizontal"
            panel.debugWindow.appearance = NSAppearance(named: Self.parameter("mode", in: url) == "dark" ? .darkAqua : .aqua)
            panel.show(beside: CGRect(x: 300, y: 200, width: horizontal ? 700 : 400, height: horizontal ? 260 : 500), displayFrame: displays.layout.primary?.frame ?? .zero, doneKeys: "⌃⌥⌘=")
            panel.debugHide()
            let across = 312, along = horizontal ? 900 : 700
            let context = CGContext(
                data: nil, width: horizontal ? along : across, height: horizontal ? across : along, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
            context?.setFillColor(CGColor(gray: 1, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: 2000, height: 2000))
            context?.setFillColor(CGColor(gray: 0.25, alpha: 1))
            for line in stride(from: 10, to: 1990, by: 24) { context?.fill(CGRect(x: 14, y: line, width: 200 + (line * 7) % 80, height: 10)) }
            let hint: ScrollingPanel.Hint? = switch Self.parameter("hint", in: url) {
            case "back": .scrollBack
            case "full": .full
            case "auto": .autoScrolling
            case "paused": .autoScrollPaused
            case "access": .needsAccessibility
            case "stopped": .autoScrollStopped(.click)
            default: nil
            }
            if hint == .autoScrolling || hint == .autoScrollPaused { panel.setAutoScrolling(true) }
            if hint == .autoScrollPaused { panel.setAutoScrolling(false) }
            if hint == .needsAccessibility { panel.showNeedsAccessibility() }
            if case .autoScrollStopped(let how) = hint { panel.showAutoScrollStopped(how) }
            panel.update(ScrollingCapture.Progress(
                step: .scrolled(offset: 40), axis: horizontal ? .horizontal : .vertical, pictureWidth: horizontal ? 9600 : 1280,
                pictureHeight: horizontal ? 960 : 8548, lostInARow: hint == .scrollBack ? 3 : 0, isFull: hint == .full, preview: context?.makeImage(), views: 40
            ))
            Task {
                await captureHiddenWindow(panel.debugWindow, name: "scroll-panel")
                panel.close()
            }
        case "scroll-test":
            // clipboard=0: scrolling captures the user makes go to the history and a card as usual but leave the
            // clipboard alone, for checks on the screen with the user's word; clipboard=1 puts it back.
            scrolling.debugLeavesClipboard = Self.parameter("clipboard", in: url) == "0"
            Log.app.notice("debug.scroll-test leaves the clipboard alone: \(scrolling.debugLeavesClipboard, privacy: .public)")
        case "scroll-bar-render":
            // The bar under an area chosen for a scrolling capture, behind the desktop picture, captured alone into
            // scroll-bar.png (mode=dark for dark).
            let window = ScrollingRenders.hiddenBarWindow(dark: Self.parameter("mode", in: url) == "dark")
            Task {
                await captureHiddenWindow(window, name: "scroll-bar")
                window.close()
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
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
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
            // elapsed= (seconds), paused=1, mode=light|dark, mic=<percent> for the microphone's meter. Writes
            // record-bar-<mode>[-paused].png.
            let paused = Self.intParameter("paused", in: url) == 1
            let dark = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mode" }?.value == "dark"
            let window = RecordingControlBar.debugHiddenWindow(
                elapsed: .seconds(Self.intParameter("elapsed", in: url) ?? 42), paused: paused, dark: dark,
                microphoneLevel: Self.intParameter("mic", in: url).map { Double($0) / 100 }
            )
            Task {
                await captureHiddenWindow(window, name: "record-bar-\(dark ? "dark" : "light")\(paused ? "-paused" : "")")
                window.orderOut(nil)
            }
        case "pin-render":
            // Draws a pin behind the desktop picture and captures its window alone, nothing shown:
            // kind=text|line|narrow|code|color|alpha|page (the drawn demo page as a picture),
            // zoom=<percent>, mode=light|dark, controls=1 for Close and More as on hover, select=all to
            // read a picture's text with Live Text and select all of it, select=part to select part of a
            // card's text. Writes pin-render-<kind>-<zoom>-<mode>[-controls][-select|-part].png to the
            // snapshot folder.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            let kind = value("kind") ?? "text"
            let zoom = value("zoom").flatMap(Double.init) ?? 100
            let mode = value("mode") ?? "light"
            let controls = value("controls") == "1"
            let select = value("select") == "all"
            let part = value("select") == "part"
            let content: PinController.Content? = switch kind {
            case "page": DebugPanelDemo.image().map { .image($0, scale: CGFloat($0.width) / DebugPanelDemo.size.width) }
            case "line": .text("npm run dev")
            case "narrow": .text("OK")
            case "code": .text("func pinned() {\n    let shortcut = \"⌃⌥⌘7\"\n    print(\"Capture Area and Pin: \\(shortcut)\")\n}")
            case "color": PinColor.parse("#3366FF").map { .color($0) }
            case "alpha": PinColor.parse("#3366FF80").map { .color($0) }
            default: .text("截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。Quick Access keeps every capture one click away; the text in a capture can be copied, edited, and searched.")
            }
            guard let content else { return }
            let name = "pin-render-\(kind)-\(Int(zoom))-\(mode)" + (controls ? "-controls" : "") + (select ? "-select" : part ? "-part" : "")
            Task { await renderPin(content, name: name, zoom: CGFloat(zoom) / 100, dark: mode == "dark", controls: controls, selectAll: select, selectPart: part) }
        case "measure-demo":
            // Measure over drawn screens (DebugToolsDemo), never the real one: the crosshair in the 120 × 36 pt
            // button, then a box drawn loosely around the 48 × 48 pt square; logs both readings. The overlay
            // stays for a snapshot; end it with close-windows. It covers a display: ask first.
            let drawsBox = Self.intParameter("box", in: url) != 0
            Task { await runMeasureDemo(drawsBox: drawsBox) }
        case "measure-copy":
            // ⌘C in a measure-demo session: the reading says "Copied"; the clipboard is left alone.
            overlay.debugCopyMeasurement()
        case "color-demo":
            // Pick Color over drawn screens: at=button|square puts the crosshair in the #007AFF button or the
            // Display P3 red square, and the overlay stays for a snapshot. It covers a display: ask first.
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "at" }?.value
            Task { await openColorDemo(at: target == "square" ? DebugToolsDemo.square : DebugToolsDemo.button) }
        case "color-pick":
            // Takes the color at the crosshair, as a click would (option=1: as an Option-click); the clipboard
            // is left alone whenever the session was opened by color-demo. The overlay logs what it took.
            let option = Self.intParameter("option", in: url) == 1
            if let point = overlay.debugPointer { overlay.simulatePick(at: point, modifiers: option ? .option : []) }
        case "color-card":
            // The color card behind the desktop picture, captured alone, nothing shown: hex=RRGGBB (default
            // 3366FF), against=RRGGBB for the contrast, mode=light|dark. Writes color-card-<mode>.png.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            let mode = value("mode") ?? "light"
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
            // p3=r,g,b (0...1) for a Display P3 color, which a hex cannot name.
            let p3 = value("p3")?.split(separator: ",").compactMap { Double($0) }
            let color = p3.flatMap { $0.count == 3 ? CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: $0.map { CGFloat($0) } + [1]) : nil }
                .flatMap(ScreenColor.init) ?? PinColor.parse("#" + (value("hex") ?? "3366FF")).flatMap { ScreenColor($0.original) }
            let other = value("against").flatMap { PinColor.parse("#" + $0) }.flatMap { ScreenColor($0.original) }
            guard let color, let window = colorPicker.debugHiddenCard(color, against: other) else { return }
            let name = value("name") ?? "color-card-\(mode)"
            Task {
                await captureHiddenWindow(window, name: name)
                colorPicker.debugDismissCard()
                NSApp.appearance = nil
            }
        case "pin-read":
            // Reads the drawn page's text with Live Text in a pin behind the desktop picture, nothing shown or
            // captured, and closes it; release=1 instead lets the text reader go and returns freed pages, as
            // closing the last pin does. For memory checks with footprint.
            if Self.intParameter("release", in: url) == 1 {
                pins.debugReleaseTextReader()
                MemoryRelief.returnFreedPages()
                Log.app.notice("debug.pin-read released")
            } else if let page = DebugPanelDemo.image() {
                Task {
                    let window = pins.debugHiddenPin(.image(page, scale: CGFloat(page.width) / DebugPanelDemo.size.width), zoom: 1, dark: false)
                    let characters = await pins.debugReadText(in: window, selectAll: false)
                    window.orderOut(nil)
                    Log.app.notice("debug.pin-read \(characters, privacy: .public) characters")
                }
            }
        case "pin-act":
            // Acts on the newest pin: zoom=<percent>, opacity=<percent>, lock=1|0, move=dx,dy (points),
            // hide=1|0, close=all. Logs every pin.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            let move = value("move")?.split(separator: ",").compactMap { Double($0) }
            pins.debugAct(
                zoom: value("zoom").flatMap(Double.init).map { CGFloat($0) / 100 },
                opacity: value("opacity").flatMap(Double.init).map { CGFloat($0) / 100 },
                locked: value("lock").map { $0 == "1" },
                move: move.flatMap { $0.count == 2 ? CGVector(dx: $0[0], dy: $0[1]) : nil }
            )
            if let hide = value("hide") { pins.setHidden(hide == "1") }
            if value("close") == "all" { pins.closeAll() }
            Log.app.notice("debug.pin-act pins=\(self.pins.count, privacy: .public) hidden=\(self.pins.areHidden, privacy: .public) locked=\(self.pins.hasLockedPins, privacy: .public) \(self.pins.debugSummary, privacy: .public)")
        case "pin-capture-check":
            // Whether a capture of the newest pin's area has the pin in it, as Settings says it should, or
            // with setting=0 that it does not. Reads that area of the screen to compare it with the drawn
            // page and drops it; nothing is kept or looked at.
            let setting = Self.intParameter("setting", in: url).map { $0 == 1 }
            Task { await checkPinInCapture(setting: setting) }
        case "selftimer-demo":
            // Self-Timer over a drawn screen, never the real one: the area chosen without the mouse on drawn
            // frames, the countdown shown over an app-drawn backdrop with a picture of the display taken
            // partway (selftimer-demo-<display>-<light|dark>.png), and at zero the drawn area delivered in place of a
            // capture, clipboard untouched, checked, and removed. seconds= sets the delay (default 3).
            Task { await runSelfTimerDemo(seconds: Self.intParameter("seconds", in: url) ?? 3) }
        case "inplace-act":
            // Acts on the in-place annotation: tool=<tool>, drag=x1,y1,x2,y2 (display points from the
            // top-left), shift=1, clicks=2, key=<characters>&code=<key code>[&cmd=1], type=<text>, redactall=1,
            // action=undo|redo|copy|save|cancel|openInEditor. Logs a summary.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            actInPlace { name in items.first { $0.name == name }?.value }
        case "editor-act":
            // Acts on the demo editor, or else on an editor opened from a card.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            DebugEditorDemo.act(on: annotations.openEditors.first) { name in items.first { $0.name == name }?.value }
        case "redact-slow":
            // Reads for redaction suggestions take seconds= longer (0 puts them back), so the capsule's
            // finding state can be captured.
            Self.readingDelays.redactions = Self.intParameter("seconds", in: url) ?? 3
            Self.wrapReadings()
            Log.app.notice("debug.redact-slow \(Self.readingDelays.redactions, privacy: .public) s")
        case "textlines-slow":
            // Reads for the highlighter's lines of text take seconds= longer (0 puts them back), so the
            // capsule's finding state can be captured.
            Self.readingDelays.textLines = Self.intParameter("seconds", in: url) ?? 3
            Self.wrapReadings()
            Log.app.notice("debug.textlines-slow \(Self.readingDelays.textLines, privacy: .public) s")
        case "reading-fail":
            // The next times= readings for redaction suggestions and for the highlighter's lines fail (0
            // puts them back), so the capsule's "Couldn't read text" and Try Again can be captured.
            let times = Self.intParameter("times", in: url) ?? 1
            Self.readingFailures = (times, times)
            Self.wrapReadings()
            Log.app.notice("debug.reading-fail \(times, privacy: .public)")
        case "redact-scan":
            // Reads the drawn demo page for redaction suggestions and logs them; nothing is shown.
            if let image = DebugPanelDemo.image(), let read = AnnotationSession.readText {
                Task {
                    let found = ((try? await read(image).redactionSuggestions()) ?? []).map { "\($0.label)@\(NSStringFromRect($0.rect))" }
                    Log.app.notice("debug.redact-scan \(found.joined(separator: "; "), privacy: .public)")
                }
            }
        case "textlines-scan":
            // Reads the drawn demo page for the lines the highlighter snaps to and logs where they lie (each
            // line's rect and word count); nothing is shown.
            if let image = DebugPanelDemo.image(), let read = AnnotationSession.readText {
                Task {
                    let found = ((try? await read(image).textLines()) ?? []).map { "\(NSStringFromRect($0.rect))/\($0.words.count)" }
                    Log.app.notice("debug.textlines-scan \(found.count, privacy: .public): \(found.joined(separator: "; "), privacy: .public)")
                }
            }
        case "reading-scan":
            // Reads the drawn demo page for both tools from one reading, as an editor does when both are
            // used: the redaction suggestions, then the lines, each with its latency probe. The lines come
            // from the Chinese reading the suggestions made, so theirs is the fitting alone. Logs counts.
            if let image = DebugPanelDemo.image(), let read = AnnotationSession.readText {
                Task {
                    let reading = read(image)
                    let suggestions = (try? await reading.redactionSuggestions())?.count ?? -1
                    let lines = (try? await reading.textLines())?.count ?? -1
                    Log.app.notice("debug.reading-scan suggestions=\(suggestions, privacy: .public) lines=\(lines, privacy: .public)")
                }
            }
        case "qa-demo":
            // The drawn page delivered as a capture: into the history and a card, never the clipboard.
            if let image = DebugPanelDemo.image(), let display = displays.layout.primary {
                Task { await captures.deliverDemo(image, displayID: display.id) }
            }
        case "qa-annotate":
            quickAccess.annotateLatest()
        case "history-annotate-latest":
            // The newest capture in the editor, as Capture History's Annotate opens it.
            annotateLatestFromHistory()
        case "history-delete-latest":
            // Deletes the newest capture outright (no Trash), its card too: cleanup after scripted checks.
            deleteLatestFromHistory()
        case "close-windows":
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                window.performClose(nil)
            }
            textCapture.closeLens()
            // A demo's overlay too (Measure, Pick Color), as Escape would.
            if overlay.isActive { overlay.cancel() }
        default:
            Log.app.error("debug.unknown \(hook, privacy: .public)")
        }
    }

    func translateDemo(prose: Bool, blank: Bool = false) async {
        guard let image = DebugPanelDemo.image(blank: blank, prose: prose), let display = displays.layout.primary else { return }
        let size = DebugPanelDemo.size
        let frame = CGRect(x: display.frame.midX - size.width / 2, y: display.frame.midY - size.height / 2, width: size.width, height: size.height)
        await textCapture.translate(image, scale: 2, over: frame.integral, source: "Demo", inPanel: false)
    }

    func openPanelDemo(via: String?, state: String?) async {
        guard let image = DebugPanelDemo.image(blank: state == "empty", prose: state == "prose") else { return }
        switch (via, state) {
        case (_, "loading"):
            textCapture.previewPanel(image: image, scale: 2, source: "Demo") { _ in
                try await Task.sleep(for: .seconds(600))
                throw CancellationError()
            }
        case (_, "failed"):
            textCapture.previewPanel(image: image, scale: 2, source: "Demo") { _ in throw OCRError.timedOut }
        case (_, "unreadable"):
            textCapture.previewPanelFailure(.unreadableFile)
        case (_, "no-clipboard-image"):
            textCapture.previewPanelFailure(.noImageOnClipboard)
        case ("file", _), ("finder", _), ("pasteboard", _):
            guard let png = DebugPanelDemo.png() else { return }
            let file = Self.snapshotDirectory.appending(path: "ocr-panel-demo.png")
            do {
                try FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
                try png.write(to: file)
            } catch {
                Log.app.error("debug.panel-demo could not write the demo: \(error.localizedDescription, privacy: .public)")
                return
            }
            if via == "file" {
                await textCapture.openPanel(forFileAt: file)
                return
            }
            // A private pasteboard, so the clipboard is never touched. "finder" adds an icon as TIFF
            // beside the file, as Finder does when a file is copied.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("\(Log.subsystem).debug"))
            pasteboard.clearContents()
            if via == "finder" {
                pasteboard.writeObjects([file as NSURL])
                pasteboard.addTypes([.tiff], owner: nil)
                pasteboard.setData(NSWorkspace.shared.icon(forFile: file.path(percentEncoded: false)).tiffRepresentation, forType: .tiff)
            } else {
                pasteboard.setData(png, forType: .png)
            }
            let opened = textCapture.openPanel(from: pasteboard, source: "Debug Pasteboard")
            Log.app.notice("debug.panel-demo via \(via ?? "", privacy: .public) opened: \(opened, privacy: .public)")
            pasteboard.releaseGlobally()
        default:
            textCapture.openPanel(image: image, scale: 2, source: "Demo")
        }
    }

    /// Captures each of this app's on-screen windows to a PNG, so UI can be reviewed from scripts
    /// without granting the terminal Screen Recording permission.
    private func sendKey(_ key: String, to window: NSWindow?) {
        guard let window else {
            Log.app.error("debug.history-key: no history window")
            return
        }
        let table: [String: (code: UInt16, characters: String, flags: NSEvent.ModifierFlags)] = [
            "left": (123, "\u{F702}", [.function, .numericPad]),
            "right": (124, "\u{F703}", [.function, .numericPad]),
            "down": (125, "\u{F701}", [.function, .numericPad]),
            "up": (126, "\u{F700}", [.function, .numericPad]),
            "return": (36, "\r", []),
            "space": (49, " ", []),
            "cmd-c": (8, "c", .command),
            "cmd-s": (1, "s", .command),
            "cmd-delete": (51, "\u{7F}", .command),
        ]
        guard let entry = table[key] else {
            Log.app.error("debug.history-key: unknown key \(key, privacy: .public)")
            return
        }
        if entry.flags.contains(.command) {
            // A ⌘ key is a menu key equivalent: find its item in the main menu, then send the item's
            // action to the key window's responder chain, as the menu does.
            let characters = key == "cmd-delete" ? "\u{8}" : entry.characters
            let item = NSApp.mainMenu.flatMap { Self.menuItem(withKeyEquivalent: characters, in: $0) }
            window.makeKeyAndOrderFront(nil)
            let handled = item?.action.map { NSApp.sendAction($0, to: nil, from: item) } ?? false
            Log.app.notice("debug.history-key \(key, privacy: .public) menu=\(item?.title ?? "none", privacy: .public) handled=\(handled, privacy: .public)")
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: entry.flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: entry.characters,
                charactersIgnoringModifiers: entry.characters,
                isARepeat: false,
                keyCode: entry.code
            ) else { continue }
            window.sendEvent(event)
        }
        Log.app.notice("debug.history-key \(key, privacy: .public) key=\(window.isKeyWindow, privacy: .public)")
    }

    private static func menuItem(withKeyEquivalent characters: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == characters, item.keyEquivalentModifierMask == .command { return item }
            if let submenu = item.submenu, let found = menuItem(withKeyEquivalent: characters, in: submenu) { return found }
        }
        return nil
    }

    func snapshotWindows() async {
        let directory = Self.snapshotDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            // Every on-screen window of ours, up to the overlay's level while an area is chosen (the screen
            // saver's) and the copied reading just above it. The overlay's own panels are off screen whenever
            // it is not in use.
            let ceiling = Int(NSWindow.Level.screenSaver.rawValue) + 1
            let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer <= ceiling }
            var used = Set<String>()
            for window in windows {
                var name = (window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "window-\(window.windowID)")
                    .replacingOccurrences(of: "/", with: "-")
                // Two windows with one title (a closing editor and its successor) keep both captures.
                if !used.insert(name).inserted { name += " \(window.windowID)" }
                let configuration = SCScreenshotConfiguration()
                configuration.dynamicRange = .sdr
                configuration.showsCursor = false
                // Written with ImageIO rather than SCScreenshotConfiguration.fileURL: on macOS 27.2 beta
                // ScreenCaptureKit treats that URL as a directory and fails to save.
                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: configuration
                )
                guard let image = output.sdrImage else { continue }
                let file = directory.appending(path: "\(name).png")
                guard
                    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { continue }
                Log.app.notice("debug.snapshot \(file.path(percentEncoded: false), privacy: .public) \(image.width, privacy: .public)x\(image.height, privacy: .public) window \(window.windowID, privacy: .public) at \(NSStringFromRect(window.frame), privacy: .public)")
            }
            if windows.isEmpty {
                Log.app.notice("debug.snapshot no windows on screen")
            }
        } catch {
            Log.app.error("debug.snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens a pin of `content` behind the desktop picture, captures its window alone as the window server
    /// draws it, and closes it.
    func renderPin(_ content: PinController.Content, name: String, zoom: CGFloat, dark: Bool, controls: Bool, selectAll: Bool, selectPart: Bool = false) async {
        let window = pins.debugHiddenPin(content, zoom: zoom, dark: dark, controls: controls)
        defer { window.orderOut(nil) }
        if selectPart { pins.debugSelectText(in: window, range: NSRange(location: 10, length: 24)) }
        if selectAll {
            let characters = await pins.debugReadText(in: window, selectAll: true)
            Log.app.notice("debug.pin-render Live Text found \(characters, privacy: .public) characters")
        }
        await captureHiddenWindow(window, name: name)
    }

    /// Captures one of the app's windows alone as the window server draws it, once it has had its first
    /// frame, into the snapshot folder as `name`.png: for windows kept behind the desktop picture.
    func captureHiddenWindow(_ window: NSWindow, name: String) async {
        // Long enough for the window server to have the window's first frame.
        try? await Task.sleep(for: .milliseconds(250))
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                Log.app.error("debug.hidden-window no window \(window.windowNumber, privacy: .public)")
                return
            }
            let configuration = SCScreenshotConfiguration()
            configuration.dynamicRange = .sdr
            configuration.showsCursor = false
            let output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: configuration
            )
            guard let image = output.sdrImage else {
                Log.app.error("debug.hidden-window no image")
                return
            }
            let file = Self.snapshotDirectory.appending(path: "\(name).png")
            try FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
            try await ImageExporter.write(image, to: file, format: .png)
            Log.app.notice("debug.hidden-window \(file.path(percentEncoded: false), privacy: .public) \(image.width, privacy: .public)x\(image.height, privacy: .public)")
        } catch {
            Log.app.error("debug.hidden-window failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens a magenta titled window, captures its middle as an area capture would, logs the average color.
    func checkOwnWindowInCapture() async {
        guard let screen = NSScreen.screens.first else { return }
        let window = NSWindow(
            contentRect: CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 150, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Own Window Check"
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(400))
        do {
            let area = window.frame.insetBy(dx: 60, dy: 60)
            let frame = try await capturer.captureArea(area, in: displays.layout)
            let color = frame.color(atPixel: frame.image.width / 2, frame.image.height / 2)
            Log.app.notice("debug.own-window-check captured \(frame.image.width, privacy: .public)x\(frame.image.height, privacy: .public), middle \(color?.hex ?? "none", privacy: .public) (magenta FF00FF means the window is in the capture)")
        } catch {
            Log.app.error("debug.own-window-check failed: \(error.localizedDescription, privacy: .public)")
        }
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

    /// Frames of the drawn tools screen for every display, injected so nothing real is read.
    private func injectToolsDemoFrames() -> DisplayInfo? {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return nil }
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]
        for each in layout.displays {
            if let image = DebugToolsDemo.screen(for: each) {
                frames[each.id] = CapturedFrame(image: image, hdrImage: nil, displayID: each.id, frame: each.frame)
            }
        }
        overlay.injectedFrames = frames
        return display
    }

    /// Measure over the drawn tools screen: a reading inside the button, then a box around the square.
    func runMeasureDemo(drawsBox: Bool = true) async {
        guard let display = injectToolsDemoFrames() else { return }
        measurer.measure(copiesToClipboard: false)
        await waitForOverlayFrames()
        let button = DebugToolsDemo.button
        overlay.simulatePointer(DebugToolsDemo.global(CGPoint(x: button.midX, y: button.midY), on: display))
        // The ruler copies the frame's pixels off the main thread first.
        for _ in 0..<40 where overlay.debugMeasurement == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let hover = overlay.debugMeasurement ?? "none"
        // box=0 leaves the lines for a snapshot.
        guard drawsBox else {
            Log.app.notice("debug.measure-demo in the button \(hover, privacy: .public) (120 × 36 pt drawn)")
            return
        }
        overlay.simulateMeasureBox(DebugToolsDemo.global(DebugToolsDemo.square.insetBy(dx: -20, dy: -16), on: display))
        Log.app.notice("debug.measure-demo display \(display.id, privacy: .public) at \(display.pixelsPerPoint, privacy: .public) px/pt: in the button \(hover, privacy: .public) (120 × 36 pt drawn); box around the square \(self.overlay.debugMeasurement ?? "none", privacy: .public) (48 × 48 pt drawn)")
    }

    /// Pick Color over the drawn tools screen, with the crosshair in `target`.
    func openColorDemo(at target: CGRect) async {
        guard let display = injectToolsDemoFrames() else { return }
        colorPicker.pickColor(copiesToClipboard: false)
        await waitForOverlayFrames()
        overlay.simulatePointer(DebugToolsDemo.global(CGPoint(x: target.midX, y: target.midY), on: display))
        Log.app.notice("debug.color-demo crosshair at \(NSStringFromRect(target), privacy: .public) on display \(display.id, privacy: .public)")
    }

    /// Captures every display `count` times and logs per-display timing and the output size; the
    /// last capture of each display is saved next to the window snapshots.
    func benchmarkDisplayCaptures(count: Int, saves: Bool) async {
        for display in displays.layout.displays {
            var durations: [Double] = []
            var last: CapturedFrame?
            for _ in 0..<max(count, 1) {
                let probe = LatencyProbe("capture.display")
                do {
                    last = try await capturer.captureDisplay(display)
                } catch {
                    Log.app.error("debug.capture display=\(display.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                durations.append(probe.end())
            }
            let sorted = durations.sorted()
            let first = durations.first ?? 0
            let p50 = sorted[(sorted.count - 1) / 2]
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            let size = last.map { "\($0.image.width)x\($0.image.height)" } ?? "?"
            Log.app.notice("debug.capture.summary display=\(display.id, privacy: .public) n=\(sorted.count, privacy: .public) first=\(first, format: .fixed(precision: 1), privacy: .public) p50=\(p50, format: .fixed(precision: 1), privacy: .public) p95=\(p95, format: .fixed(precision: 1), privacy: .public) max=\(sorted.last ?? 0, format: .fixed(precision: 1), privacy: .public) ms size=\(size, privacy: .public)")
            if saves, let image = last?.image {
                try? FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
                try? await ImageExporter.write(image, to: Self.snapshotDirectory.appending(path: "display-\(display.id).png"), format: .png)
            }
        }
    }

    /// How long captures of the pointer's display take with the app as it is between shortcuts (in the
    /// background, no window shown), or holding an activity that keeps App Nap away.
    func timeCaptures(count: Int, holdsActivity: Bool, displayID: CGDirectDisplayID?) async {
        let layout = displays.layout
        guard let display = displayID.flatMap(layout.display(id:)) ?? layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        let activity = holdsActivity
            ? ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Timing captures")
            : nil
        defer { activity.map(ProcessInfo.processInfo.endActivity) }
        var durations: [Double] = []
        for _ in 0..<max(count, 1) {
            let probe = LatencyProbe("debug.capture-timing")
            _ = try? await capturer.captureDisplay(display)
            durations.append(probe.end())
            try? await Task.sleep(for: .milliseconds(400))
        }
        let list = durations.map { String(format: "%.1f", $0) }.joined(separator: " ")
        Log.app.notice("debug.capture-timing activity=\(holdsActivity, privacy: .public) display=\(display.id, privacy: .public) active=\(NSApp.isActive, privacy: .public) ms: \(list, privacy: .public)")
    }

    /// Opens the overlay, draws a 600×360 selection centered on the pointer's display with the pointer
    /// at its lower-right corner, captures the display including the overlay, and closes it again.
    func renderOverlayDemo(
        pointerFromTopLeft: CGPoint? = nil,
        mode: OverlayController.Mode = .area,
        purpose: OverlayController.Purpose = .screenshot,
        selects: Bool = true
    ) async {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        overlay.freezesScreen = false
        overlay.begin(mode: mode, purpose: purpose) { _ in }
        await waitForOverlayFrames()
        let selection = CGRect(x: display.frame.midX - 300, y: display.frame.midY - 180, width: 600, height: 360)
        let pointer = pointerFromTopLeft.map { CGPoint(x: display.frame.minX + $0.x, y: display.frame.maxY - $0.y) }
            ?? CGPoint(x: selection.maxX, y: selection.minY)
        overlay.simulate(selection: selects ? selection : CGRect(origin: pointer, size: .zero), pointer: pointer)
        try? await Task.sleep(for: .milliseconds(60))
        Log.app.notice("debug.overlay-demo frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public) panels: \(overlay.panelStates, privacy: .public)")
        defer { overlay.cancel() }
        do {
            let frame = try await capturer.captureDisplay(display, includingOwnWindows: true)
            try FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
            let file = Self.snapshotDirectory.appending(path: "overlay-demo-\(display.id).png")
            try await ImageExporter.write(frame.image, to: file, format: .png)
            Log.app.notice("debug.overlay-demo \(file.path(percentEncoded: false), privacy: .public)")
        } catch {
            Log.app.error("debug.overlay-demo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens and closes the overlay `count` times; read the results with Scripts/latency.sh
    /// overlay.visible and overlay.frozen.
    func benchmarkOverlay(count: Int, freezes: Bool) async {
        overlay.freezesScreen = freezes
        for _ in 0..<max(count, 1) {
            overlay.begin { _ in }
            await waitForOverlayFrames()
            overlay.cancel()
            try? await Task.sleep(for: .milliseconds(150))
        }
        Log.app.notice("debug.bench-overlay done n=\(count, privacy: .public)")
    }

    func testWindowCapture(owner: String) async {
        let layout = displays.layout
        guard let target = WindowCatalog.snapshot(layout: layout).first(where: { $0.ownerName == owner }) else {
            let owners = Set(WindowCatalog.snapshot(layout: layout).map(\.ownerName)).sorted().joined(separator: ", ")
            Log.app.error("debug.window-test no window owned by \(owner, privacy: .public); on screen: \(owners, privacy: .public)")
            return
        }
        for shadow in [true, false] {
            do {
                let frame = try await capturer.captureWindow(target, shadow: shadow, layout: layout)
                let alpha = frame.image.alphaInfo
                let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
                let file = Self.snapshotDirectory.appending(path: "window-test-\(shadow ? "shadow" : "plain").png")
                try await ImageExporter.write(frame.image, to: file, format: .png)
                Log.app.notice("debug.window-test shadow=\(shadow, privacy: .public) frame=\(Int(target.frame.width), privacy: .public)x\(Int(target.frame.height), privacy: .public)pt image=\(frame.image.width, privacy: .public)x\(frame.image.height, privacy: .public) alpha=\(hasAlpha, privacy: .public)")
            } catch {
                Log.app.error("debug.window-test failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// In-place annotation on a drawn screen: every display shows a plain desktop, the pointer's the demo
    /// page too, so nothing on the real screen is recorded. Its copy never reaches the clipboard.
    func openInPlaceDemo(area: CGRect?) async {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]
        for each in layout.displays {
            if let image = DebugPanelDemo.screen(for: each, page: each.id == display.id) {
                frames[each.id] = CapturedFrame(image: image, hdrImage: nil, displayID: each.id, frame: each.frame)
            }
        }
        overlay.injectedFrames = frames
        captures.annotateArea(copiesToClipboard: false)
        await waitForOverlayFrames()
        let chosen = area ?? DebugPanelDemo.pageRect(on: display).insetBy(dx: -24, dy: -24)
        overlay.simulateAnnotation(selection: CGRect(
            x: display.frame.minX + chosen.minX, y: display.frame.maxY - chosen.maxY, width: chosen.width, height: chosen.height
        ))
        try? await Task.sleep(for: .milliseconds(100))
        if let view = captures.inPlaceView {
            Log.app.notice("debug.inplace-demo \(view.debugSummary, privacy: .public)")
        } else {
            Log.app.error("debug.inplace-demo did not start: annotating=\(self.overlay.isAnnotating, privacy: .public)")
        }
    }

    /// A frozen screenshot over drawn screens: the drawn page frozen behind the overlay, an area chosen
    /// without the mouse, and the capture delivered with the clipboard left alone. What is kept must be
    /// the area cut from the frozen frame, pixel for pixel; then the capture and its card are removed.
    func runFreezeDemo(area: CGRect?, span: Int) async {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]
        for each in layout.displays {
            if let image = DebugPanelDemo.screen(for: each, page: each.id == display.id) {
                frames[each.id] = CapturedFrame(image: image, hdrImage: nil, displayID: each.id, frame: each.frame)
            }
        }
        let rect: CGRect
        if span > 0 {
            guard let spanning = layout.displays.lazy.compactMap({ other in
                other.id == display.id ? nil : Self.areaAcross(display, other, atBottom: span == 2)
            }).first else {
                Log.app.error("debug.freeze-demo: no two displays share an edge")
                return
            }
            rect = spanning
        } else {
            let chosen = area ?? DebugPanelDemo.pageRect(on: display)
            rect = CGRect(x: display.frame.minX + chosen.minX, y: display.frame.maxY - chosen.maxY, width: chosen.width, height: chosen.height)
        }
        // What the frozen screens hold under the area: one display's crop, or each one's put together.
        let parts = layout.displays.compactMap { frames[$0.id]?.cropped(to: rect) }
        let scale = layout.displays.filter { !$0.frame.intersection(rect).isEmpty }.map(\.pixelsPerPoint).max() ?? 2
        guard let expected = parts.count == 1 ? parts.first : CapturedFrame.stitched(parts, covering: rect, pixelsPerPoint: scale) else { return }
        let before = historyCount()
        overlay.injectedFrames = frames
        captures.captureArea(copiesToClipboard: false, freezes: true)
        await waitForOverlayFrames()
        overlay.simulateSelection(rect)
        for _ in 0..<80 where historyCount() == before {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard historyCount() == before + 1 else {
            Log.app.error("debug.freeze-demo kept nothing: active=\(self.overlay.isActive, privacy: .public)")
            return
        }
        defer { deleteLatestFromHistory() }
        guard let file = latestCaptureFile(), let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let kept = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Log.app.error("debug.freeze-demo could not read the capture back")
            return
        }
        let difference = Self.pixelDifference(kept, expected.image)
        Log.app.notice("debug.freeze-demo kept \(kept.width, privacy: .public)x\(kept.height, privacy: .public) from \(parts.count, privacy: .public) display(s), frozen selection \(expected.image.width, privacy: .public)x\(expected.image.height, privacy: .public), largest channel difference \(difference.map(String.init) ?? "n/a (sizes differ)", privacy: .public)")
    }

    /// An area 600 × 400 points across the edge two displays share, in the middle of the stretch they
    /// share, or with `atBottom` from the lower of their bottom edges, so part of it lies where no
    /// display is. Nil when they share no edge.
    private static func areaAcross(_ first: DisplayInfo, _ second: DisplayInfo, atBottom: Bool) -> CGRect? {
        let a = first.frame, b = second.frame
        let sideBySide = abs(a.minX - b.maxX) < 1 || abs(b.minX - a.maxX) < 1
        let stacked = abs(a.minY - b.maxY) < 1 || abs(b.minY - a.maxY) < 1
        if sideBySide {
            let edge = abs(a.minX - b.maxX) < 1 ? a.minX : a.maxX
            let low = max(a.minY, b.minY), high = min(a.maxY, b.maxY)
            guard high - low >= 400 else { return nil }
            let y = atBottom ? min(a.minY, b.minY) : (low + high) / 2 - 200
            return CGRect(x: edge - 300, y: y, width: 600, height: 400)
        }
        if stacked {
            let edge = abs(a.minY - b.maxY) < 1 ? a.minY : a.maxY
            let low = max(a.minX, b.minX), high = min(a.maxX, b.maxX)
            guard high - low >= 600 else { return nil }
            let x = atBottom ? min(a.minX, b.minX) : (low + high) / 2 - 300
            return CGRect(x: x, y: edge - 200, width: 600, height: 400)
        }
        return nil
    }

    /// Pins the drawn page at 1:1: over a point when given (display points from the top-left corner of
    /// the pointer's display), else centered.
    func pinDemo(at point: [Int]) {
        guard let image = DebugPanelDemo.image() else { return }
        let layout = displays.layout
        let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary
        let scale = display?.pixelsPerPoint ?? 2
        var area: CGRect?
        if point.count == 2, let display {
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            area = CGRect(x: display.frame.minX + CGFloat(point[0]), y: display.frame.maxY - CGFloat(point[1]) - size.height, width: size.width, height: size.height)
        }
        pins.pin(image, scale: scale, origin: .clipboard, over: area)
        Log.app.notice("debug.pin-demo \(self.pins.debugSummary, privacy: .public)")
    }

    /// Captures the newest pin's area, compares its middle (clear of the rounded corners and the edge)
    /// with the drawn page, and logs whether the pin was in the capture.
    func checkPinInCapture(setting: Bool?) async {
        guard let frame = pins.newestFrame, let page = DebugPanelDemo.image() else {
            Log.app.error("debug.pin-capture-check: no pin")
            return
        }
        let saved = settings.pinsAppearInCaptures
        if let setting { settings.pinsAppearInCaptures = setting }
        defer { settings.pinsAppearInCaptures = saved }
        do {
            let inset = CGFloat(settings.pinCornerRadius) + 4
            let middle = frame.insetBy(dx: inset, dy: inset)
            let captured = try await capturer.captureArea(middle, in: displays.layout)
            // The same middle of the page, as the pin shows it at 1:1.
            let scale = CGFloat(page.width) / frame.width
            let crop = CGRect(x: (inset * scale).rounded(), y: (inset * scale).rounded(), width: CGFloat(captured.image.width), height: CGFloat(captured.image.height))
            guard let expected = page.cropping(to: crop) else { return }
            let difference = Self.pixelDifference(captured.image, expected)
            Log.app.notice("debug.pin-capture-check setting=\(self.settings.pinsAppearInCaptures, privacy: .public) largest channel difference \(difference.map(String.init) ?? "n/a (sizes differ)", privacy: .public)")
        } catch {
            Log.app.error("debug.pin-capture-check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Self-Timer on drawn screens. The backdrop under the countdown is the drawn page too, so neither the
    /// picture taken partway nor the countdown's glass holds anything of the real screen.
    func runSelfTimerDemo(seconds: Int) async {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]
        for each in layout.displays {
            if let image = DebugPanelDemo.screen(for: each, page: each.id == display.id) {
                frames[each.id] = CapturedFrame(image: image, hdrImage: nil, displayID: each.id, frame: each.frame)
            }
        }
        guard let drawn = frames[display.id] else { return }
        let backdrop = DemoBackdropPanel(frame: display.frame, image: drawn.image)
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }
        let before = historyCount()
        captures.selfTimerCapture = { rect in drawn.cropped(to: rect) }
        defer { captures.selfTimerCapture = nil }
        overlay.injectedFrames = frames
        captures.selfTimer(copiesToClipboard: false, freezes: true, delay: seconds)
        await waitForOverlayFrames()
        let page = DebugPanelDemo.pageRect(on: display)
        let rect = CGRect(x: display.frame.minX + page.minX, y: display.frame.maxY - page.maxY, width: page.width, height: page.height)
        overlay.simulateSelection(rect)
        try? await Task.sleep(for: .milliseconds(1200))
        Log.app.notice("debug.selftimer-demo counting=\(self.captures.isSelfTimerRunning, privacy: .public)")
        do {
            let picture = try await capturer.captureDisplay(display, includingOwnWindows: true)
            try FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
            let tone = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            let file = Self.snapshotDirectory.appending(path: "selftimer-demo-\(display.id)-\(tone).png")
            try await ImageExporter.write(picture.image, to: file, format: .png)
            Log.app.notice("debug.selftimer-demo \(file.path(percentEncoded: false), privacy: .public)")
        } catch {
            Log.app.error("debug.selftimer-demo picture failed: \(error.localizedDescription, privacy: .public)")
        }
        for _ in 0..<((seconds + 4) * 10) where historyCount() == before {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard historyCount() == before + 1 else {
            Log.app.error("debug.selftimer-demo kept nothing")
            return
        }
        defer { deleteLatestFromHistory() }
        guard let expected = drawn.cropped(to: rect)?.image, let file = latestCaptureFile(),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil), let kept = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Log.app.error("debug.selftimer-demo could not read the capture back")
            return
        }
        let difference = Self.pixelDifference(kept, expected)
        Log.app.notice("debug.selftimer-demo kept \(kept.width, privacy: .public)x\(kept.height, privacy: .public) at zero, largest channel difference \(difference.map(String.init) ?? "n/a (sizes differ)", privacy: .public)")
    }

    /// The largest difference of any channel between two pictures of one size, both drawn in sRGB; nil
    /// when their sizes differ.
    private static func pixelDifference(_ first: CGImage, _ second: CGImage) -> Int? {
        guard first.width == second.width, first.height == second.height else { return nil }
        func bytes(_ image: CGImage) -> [UInt8]? {
            guard let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * 4 * image.height))
        }
        guard let a = bytes(first), let b = bytes(second) else { return nil }
        return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    func actInPlace(_ value: (String) -> String?) {
        guard let view = captures.inPlaceView, view.window != nil else {
            Log.app.error("debug.inplace-act: no in-place annotation")
            return
        }
        if let tool = value("tool").flatMap(AnnotationTool.init(rawValue:)) { view.session.tool = tool }
        if value("redactall") == "1" { view.session.acceptAllRedactionSuggestions() }
        if let drag = value("drag")?.split(separator: ",").compactMap({ Double($0) }), drag.count == 4 {
            var modifiers: NSEvent.ModifierFlags = value("shift") == "1" ? .shift : []
            // With a drag and no key, cmd=1 holds ⌘ through the drag.
            if value("cmd") == "1", value("key") == nil { modifiers.insert(.command) }
            view.simulateDrag(
                from: CGPoint(x: drag[0], y: drag[1]), to: CGPoint(x: drag[2], y: drag[3]),
                modifiers: modifiers, clickCount: value("clicks").flatMap(Int.init) ?? 1
            )
        }
        if let key = value("key") {
            view.simulateKey(key, keyCode: value("code").flatMap(UInt16.init) ?? 0, modifiers: value("cmd") == "1" ? (value("shift") == "1" ? [.command, .shift] : .command) : [])
        }
        if let text = value("type") { view.simulateTyping(text) }
        let summary = view.debugSummary
        if let action = value("action") { view.simulateAction(action) }
        Log.app.notice("debug.inplace-act \(summary, privacy: .public) annotating=\(self.overlay.isAnnotating, privacy: .public)")
    }

    private func waitForOverlayFrames() async {
        for _ in 0..<40 where overlay.isActive && !overlay.hasFrames {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Makes the tools' readings take `readingDelays` longer and fail `readingFailures` times, the real
    /// reading still under them, or puts the real one back when they are neither slowed nor failing.
    private static func wrapReadings() {
        if unslowedReadText == nil { unslowedReadText = AnnotationSession.readText }
        let original = unslowedReadText
        let delays = readingDelays
        guard delays != (0, 0) || readingFailures != (0, 0) else {
            AnnotationSession.readText = original
            return
        }
        AnnotationSession.readText = { @Sendable image in
            let reading = original?(image) ?? CaptureReading()
            return CaptureReading(
                redactionSuggestions: {
                    try? await Task.sleep(for: .seconds(delays.redactions))
                    if await takeFailure(redactions: true) { throw CocoaError(.fileReadUnknown) }
                    return try await reading.redactionSuggestions()
                },
                textLines: {
                    try? await Task.sleep(for: .seconds(delays.textLines))
                    if await takeFailure(redactions: false) { throw CocoaError(.fileReadUnknown) }
                    return try await reading.textLines()
                }
            )
        }
    }

    /// Whether this reading is one of the failures asked for, counting it.
    private static func takeFailure(redactions: Bool) -> Bool {
        if redactions {
            guard readingFailures.redactions > 0 else { return false }
            readingFailures.redactions -= 1
        } else {
            guard readingFailures.textLines > 0 else { return false }
            readingFailures.textLines -= 1
        }
        return true
    }

    private static func intParameter(_ name: String, in url: URL) -> Int? {
        parameter(name, in: url).flatMap(Int.init)
    }

    private static func parameter(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func logDisplays() {
        for display in displays.layout.displays {
            Log.display.notice("""
                debug.display id=\(display.id, privacy: .public) name=\(display.name, privacy: .public) \
                frame=\(String(describing: display.frame), privacy: .public) \
                pixels=\(Int(display.pixelSize.width), privacy: .public)x\(Int(display.pixelSize.height), privacy: .public) \
                scale=\(display.backingScale, privacy: .public) edr=\(display.maximumPotentialEDR, privacy: .public)
                """)
        }
    }

    func logResources() {
        let snapshot = ActiveResources.shared.snapshot
        let summary = snapshot.isEmpty
            ? "idle"
            : snapshot.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
        Log.resources.notice("debug.resources \(summary, privacy: .public)")
    }
}
/// A drawn screen behind Self-Timer's countdown in scripted checks: one level under it, above
/// everything else, and letting clicks through.
private final class DemoBackdropPanel: NSPanel {
    init(frame: CGRect, image: CGImage) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        contentView = view
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
