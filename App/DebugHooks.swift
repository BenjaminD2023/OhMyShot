#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import ImageIO
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
    let setRetention: (HistoryRetention) -> Void
    let historyWindow: () -> NSWindow?
    let historyCount: () -> Int
    let previewRetentionChange: (HistoryRetention?) -> Void
    let textCapture: TextCaptureCoordinator

    /// Where `snapshot` writes window captures.
    static let snapshotDirectory = URL.cachesDirectory.appending(path: "\(Log.subsystem)/debug-snapshots", directoryHint: .isDirectory)

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
            let count = Self.intParameter("n", in: url) ?? 10
            Task { await benchmarkDisplayCaptures(count: count) }
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
                Task { await captures.captureRegion(rect, on: display, appName: "Test", copiesToClipboard: false) }
            }
        case "text-test":
            // Capture Text on the same centered region as capture-test, without touching the clipboard.
            let join = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "join" && $0.value == "1" } ?? false
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await textCapture.recognize(region: rect, on: display, joinLines: join, copiesToClipboard: false) }
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
                Task { await textCapture.openPanel(region: rect, on: display) }
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
            let count = Self.intParameter("n", in: url) ?? 10
            Task { await benchmarkOverlay(count: count) }
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
        case "close-windows":
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                window.performClose(nil)
            }
            textCapture.closeLens()
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
            // Every on-screen window of ours, up to the overlay's level (the text selection highlight
            // shares it). The overlay's own panels are off screen whenever it is not in use.
            let ceiling = Int(NSWindow.Level.popUpMenu.rawValue) + 1
            let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer <= ceiling }
            for window in windows {
                let name = (window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "window-\(window.windowID)")
                    .replacingOccurrences(of: "/", with: "-")
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
                Log.app.notice("debug.snapshot \(file.path(percentEncoded: false), privacy: .public) \(image.width, privacy: .public)x\(image.height, privacy: .public)")
            }
            if windows.isEmpty {
                Log.app.notice("debug.snapshot no windows on screen")
            }
        } catch {
            Log.app.error("debug.snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Captures every display `count` times and logs per-display timing and the output size; the
    /// last capture of each display is saved next to the window snapshots.
    func benchmarkDisplayCaptures(count: Int) async {
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
            if let image = last?.image {
                try? FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
                try? await ImageExporter.write(image, to: Self.snapshotDirectory.appending(path: "display-\(display.id).png"), format: .png)
            }
        }
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
    func benchmarkOverlay(count: Int) async {
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
#endif
