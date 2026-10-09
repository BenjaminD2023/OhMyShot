#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
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
    let settings: SettingsStore

    /// Where `snapshot` writes window captures.
    static let snapshotDirectory = URL.cachesDirectory.appending(path: "\(Log.subsystem)/debug-snapshots", directoryHint: .isDirectory)
    /// The real reader for redaction suggestions, while redact-slow stands in for it.
    private static var unslowedFindRedactions: (@Sendable (CGImage) async -> [RedactionSuggestion])?

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
        case "pin-render":
            // Draws a pin behind the desktop picture and captures its window alone, nothing shown:
            // kind=text|line|narrow|code|color|alpha|page (the drawn demo page as a picture),
            // zoom=<percent>, mode=light|dark, controls=1 for Close and More as on hover, select=all to
            // read a picture's text with Live Text and select all of it. Writes
            // pin-render-<kind>-<zoom>-<mode>[-controls][-select].png to the snapshot folder.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            let kind = value("kind") ?? "text"
            let zoom = value("zoom").flatMap(Double.init) ?? 100
            let mode = value("mode") ?? "light"
            let controls = value("controls") == "1"
            let select = value("select") == "all"
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
            let name = "pin-render-\(kind)-\(Int(zoom))-\(mode)" + (controls ? "-controls" : "") + (select ? "-select" : "")
            Task { await renderPin(content, name: name, zoom: CGFloat(zoom) / 100, dark: mode == "dark", controls: controls, selectAll: select) }
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
            if Self.unslowedFindRedactions == nil { Self.unslowedFindRedactions = AnnotationSession.findRedactions }
            let seconds = Self.intParameter("seconds", in: url) ?? 3
            let original = Self.unslowedFindRedactions
            if seconds == 0 {
                AnnotationSession.findRedactions = original
            } else {
                AnnotationSession.findRedactions = { @Sendable image in
                    try? await Task.sleep(for: .seconds(seconds))
                    return await original?(image) ?? []
                }
            }
            Log.app.notice("debug.redact-slow \(seconds, privacy: .public) s")
        case "redact-scan":
            // Reads the drawn demo page for redaction suggestions and logs them; nothing is shown.
            if let image = DebugPanelDemo.image(), let find = AnnotationSession.findRedactions {
                Task {
                    let found = await find(image).map { "\($0.label)@\(NSStringFromRect($0.rect))" }
                    Log.app.notice("debug.redact-scan \(found.joined(separator: "; "), privacy: .public)")
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
    func renderPin(_ content: PinController.Content, name: String, zoom: CGFloat, dark: Bool, controls: Bool, selectAll: Bool) async {
        let window = pins.debugHiddenPin(content, zoom: zoom, dark: dark, controls: controls)
        defer { window.orderOut(nil) }
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
            view.simulateDrag(
                from: CGPoint(x: drag[0], y: drag[1]), to: CGPoint(x: drag[2], y: drag[3]),
                modifiers: value("shift") == "1" ? .shift : [], clickCount: value("clicks").flatMap(Int.init) ?? 1
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

    private static func intParameter(_ name: String, in url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value.flatMap(Int.init)
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
