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
import OMSDesign
import OMSOCR
import OMSRecording
import OMSStudio
import OMSUI
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Endpoints for capturing over drawn screens, never the real one unless a hook says so: the overlay drawn and timed, areas,
/// windows, All-In-One, Self-Timer, freezing, in-place annotation, and what captures take in of the desktop.
extension DebugHooks {
    /// A picture's average color as hex, from a 1×1 drawing of it.
    private static func averageColor(of image: CGImage) -> String {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "?" }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X alpha %d", pixel[0], pixel[1], pixel[2], pixel[3])
    }

    /// Returns true when `hook` was one of these.
    func handleCaptureHook(_ hook: String, _ url: URL) -> Bool {
        switch hook {
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
            let windowMode = Self.parameter("mode", in: url) == "window"
            let purpose: OverlayController.Purpose = Self.parameter("purpose", in: url) == "text" ? .text : .screenshot
            let selects = Self.parameter("select", in: url) != "0"
            Task { await renderOverlayDemo(pointerFromTopLeft: pointer, mode: windowMode ? .window : .area, purpose: purpose, selects: selects) }
        case "capture-test":
            // A 400×300 point region at the center of the primary display, delivered like any capture.
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await captures.captureArea(rect, appName: "Test", copiesToClipboard: false) }
            }
        case "capture-window-test":
            // The frontmost window of the app named `owner` (default Finder), with and without shadow.
            let owner = Self.parameter("owner", in: url) ?? "Finder"
            Task { await testWindowCapture(owner: owner) }
        case "bench-overlay":
            // freeze=1 measures a frozen overlay, which appears once the pointer's display is captured.
            let count = Self.intParameter("n", in: url) ?? 10
            Task { await benchmarkOverlay(count: count, freezes: Self.intParameter("freeze", in: url) == 1) }
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
        case "window-wallpaper-demo":
            // The drawn page as a window centered on the pointer's display, put on the desktop picture around it as a
            // window screenshot would be; writes window-wallpaper.png to the snapshot folder (it holds a piece of the
            // wallpaper, nothing else of the screen) and keeps nothing in the history.
            Task {
                let layout = displays.layout
                guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary, let page = DebugPanelDemo.image() else { return }
                let size = DebugPanelDemo.size
                let frame = CGRect(x: display.frame.midX - size.width / 2, y: display.frame.midY - size.height / 2, width: size.width, height: size.height)
                guard let picture = await captures.debugWindowOnWallpaper(page, frame: frame, displayID: display.id) else {
                    return Log.app.notice("debug.window-wallpaper-demo: no picture")
                }
                let url = Self.snapshotDirectory.appending(path: "window-wallpaper.png")
                try? FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
                if let data = try? await ImageExporter.encode(picture, as: .png) { try? data.write(to: url) }
                Log.app.notice("debug.window-wallpaper-demo \(url.path(percentEncoded: false), privacy: .public) \(picture.width, privacy: .public)x\(picture.height, privacy: .public)")
            }
        case "allinone-render":
            // All-In-One behind the desktop picture, captured alone: part=setup (the framed area and its bar, default) or
            // part=modes (the bar before an area); mode=dark; upload=0 without the Upload chip. Writes allinone-<part>.png.
            let setup = Self.parameter("part", in: url) != "modes"
            let window = AllInOneRenders.hiddenWindow(
                setup: setup, dark: Self.parameter("mode", in: url) == "dark", offersUpload: Self.intParameter("upload", in: url) != 0,
                showsCopy: Self.intParameter("copy", in: url) != 0,
                marksText: Self.intParameter("text", in: url) == 1,
                actions: (Self.parameter("act", in: url) ?? "").split(separator: ",").map(String.init)
            )
            Task {
                await captureHiddenWindow(window, name: setup ? "allinone-setup" : "allinone-modes")
                window.close()
            }
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
            actInPlace { Self.parameter($0, in: url) }
        case "allinone-demo":
            // All-In-One on drawn screens (never the real one), the clipboard left alone: the area (x, y, w, h in the
            // display's points from its top-left corner) is framed, then `key` is pressed in the frame (return, cmd-c,
            // e, p, o, s, r, f, escape…; default return). A capture is compared with the frozen area and removed; text
            // and scrolling only log what would be read or scrolled; a recording logs its bar and is cancelled.
            // ahead=1 hands the area to All-In-One as the URL API does instead of dragging it; drag=0 neither hands nor
            // drags one, so the area remembered from the last run comes back; keep=1 leaves the area it took
            // remembered (else the one remembered before is put back).
            let rect = ["x", "y", "w", "h"].compactMap { Self.intParameter($0, in: url) }
            let key = Self.parameter("key", in: url) ?? "return"
            let ahead = Self.intParameter("ahead", in: url) == 1
            let drags = Self.intParameter("drag", in: url) != 0
            let keeps = Self.intParameter("keep", in: url) == 1
            // hold=1 presses nothing and leaves the frame up, for allinone-act and snapshots; escape ends it.
            let holds = Self.intParameter("hold", in: url) == 1
            Task {
                await runAllInOneDemo(
                    area: rect.count == 4 ? CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) : nil, key: key, ahead: ahead,
                    drags: drags, keepsArea: keeps, holds: holds
                )
            }
        case "allinone-act":
            // key=… presses a key in All-In-One's frame; none logs what is framed.
            let key = Self.parameter("key", in: url)
            Log.app.notice("debug.allinone-act \(key ?? "state", privacy: .public): \(overlay.debugAllInOneSetup(key) ?? "nothing framed", privacy: .public)")
        case "overlay-state":
            // Whether the overlay is up and has the keyboard, and who is in front: for runs started from Shortcuts.
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            Log.app.notice("debug.overlay-state active=\(overlay.isActive, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none", privacy: .public) front=\(front, privacy: .public) panels \(overlay.panelStates, privacy: .public)")
        case "overlay-select":
            // Chooses an area in the open overlay as a drag would: x, y, w, h in the pointer's display's points from its
            // top-left corner.
            let rect = ["x", "y", "w", "h"].compactMap { Self.intParameter($0, in: url) }
            if rect.count == 4, let display = displays.layout.display(at: NSEvent.mouseLocation) ?? displays.layout.primary {
                let area = CGRect(x: display.frame.minX + CGFloat(rect[0]), y: display.frame.maxY - CGFloat(rect[1] + rect[3]), width: CGFloat(rect[2]), height: CGFloat(rect[3]))
                overlay.simulateSelection(area)
                Log.app.notice("debug.overlay-select \(NSStringFromRect(area), privacy: .public) active=\(overlay.isActive, privacy: .public)")
            }
        case "copy-after-capture":
            // value=0|1 sets the Dev app's Copy after capture and after recording, so a scripted capture leaves the
            // clipboard alone; put it back afterwards.
            if let value = Self.intParameter("value", in: url) {
                settings.copyAfterCapture = value == 1
                settings.copyAfterRecording = value == 1
            }
            Log.app.notice("debug.copy-after-capture \(settings.copyAfterCapture, privacy: .public)")
        case "desktop-cover-check":
            // The covers' windows, then the display under the pointer captured as a screenshot is (covers in) and with
            // them left out: logs how much of the picture they change and where, the pixels themselves dropped.
            Log.app.notice("debug.desktop-cover \(desktopIcons.debugSummary, privacy: .public)")
            Task { await checkDesktopCoverInCaptures() }
        case "wallpaper-check":
            // Takes each display's wallpaper as Hide Desktop Icons does and logs its size, time, and average color;
            // nothing is kept or shown.
            Task {
                let start = ContinuousClock.now
                do {
                    let pictures = try await capturer.captureWallpapers(of: displays.layout.displays)
                    let elapsed = ContinuousClock.now - start
                    for display in displays.layout.displays {
                        let found = pictures[display.id].map { "\($0.width)x\($0.height), average \(Self.averageColor(of: $0))" } ?? "none"
                        Log.app.notice("debug.wallpaper-check display \(display.id, privacy: .public): \(found, privacy: .public) (all in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public))")
                    }
                } catch {
                    Log.app.notice("debug.wallpaper-check failed: \(String(describing: error), privacy: .public)")
                }
            }
        default:
            return false
        }
        return true
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

    func runAllInOneDemo(area: CGRect?, key: String, ahead: Bool, drags: Bool = true, keepsArea: Bool = false, holds: Bool = false) async {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]
        for each in layout.displays {
            if let image = DebugPanelDemo.screen(for: each, page: each.id == display.id) {
                frames[each.id] = CapturedFrame(image: image, hdrImage: nil, displayID: each.id, frame: each.frame)
            }
        }
        let chosen = area ?? DebugPanelDemo.pageRect(on: display)
        let rect = CGRect(x: display.frame.minX + chosen.minX, y: display.frame.maxY - chosen.maxY, width: chosen.width, height: chosen.height)
        guard let expected = frames[display.id]?.cropped(to: rect) else { return }
        // What a check must not change: the area kept for next time, what text and scrolling would do.
        let remembered = settings.allInOneArea
        let text = captures.allInOneText, scroll = captures.allInOneScroll
        var handed: String?
        captures.allInOneText = { area, frozen in handed = "text of \(NSStringFromRect(area)) from \(frozen.map { "the frozen \($0.image.width)x\($0.image.height)" } ?? "the live screen")" }
        captures.allInOneScroll = { area in handed = "scrolling capture of \(NSStringFromRect(area))" }
        defer {
            if !keepsArea { settings.allInOneArea = remembered }
            captures.allInOneText = text
            captures.allInOneScroll = scroll
        }
        let before = historyCount()
        overlay.injectedFrames = frames
        captures.allInOne(choosing: ahead ? rect : nil, copiesToClipboard: false, freezes: true)
        await waitForOverlayFrames()
        if !ahead, drags { overlay.simulateSelection(rect) }
        for _ in 0..<20 where overlay.debugAllInOneSetup(nil) == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let framed = overlay.debugAllInOneSetup(nil) ?? "nothing framed"
        Log.app.notice("debug.allinone-demo framed: \(framed, privacy: .public), key window \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none", privacy: .public), first responder \(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none", privacy: .public)")
        if holds { return }
        _ = overlay.debugAllInOneSetup(key)
        try? await Task.sleep(for: .milliseconds(150))
        if overlay.isActive {
            let recording = overlay.debugRecordingSetup(nil)
            let keyWindow = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"
            Log.app.notice("debug.allinone-demo still open after \(key, privacy: .public): recording bar \(recording ?? "none", privacy: .public), app active \(NSApp.isActive, privacy: .public), key window \(keyWindow, privacy: .public), first responder \(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none", privacy: .public); cancelled")
            overlay.cancel()
            return
        }
        if let handed {
            Log.app.notice("debug.allinone-demo \(key, privacy: .public) handed on \(handed, privacy: .public)")
            return
        }
        for _ in 0..<80 where historyCount() == before {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard historyCount() == before + 1 else {
            Log.app.notice("debug.allinone-demo \(key, privacy: .public) kept nothing")
            return
        }
        let kept = settings.allInOneArea.map { NSStringFromRect($0.area) } ?? "none"
        defer { deleteLatestFromHistory() }
        guard let file = latestCaptureFile(), let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let difference = Self.pixelDifference(image, expected.image)
        Log.app.notice("debug.allinone-demo \(key, privacy: .public) kept \(image.width, privacy: .public)x\(image.height, privacy: .public), area \(expected.image.width, privacy: .public)x\(expected.image.height, privacy: .public), largest channel difference \(difference.map(String.init) ?? "n/a (sizes differ)", privacy: .public), remembered \(kept, privacy: .public)")
    }

    /// The display under the pointer captured with the desktop covers (as every screenshot is) and without them: how
    /// many of its pixels the covers change, and the box around them. Nothing is kept.
    func checkDesktopCoverInCaptures() async {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        do {
            let covered = try await capturer.captureDisplay(display)
            let included = capturer.includedWindowIDs
            let covers = desktopIcons.windowIDs
            capturer.includedWindowIDs = { included?().subtracting(covers) ?? [] }
            defer { capturer.includedWindowIDs = included }
            let bare = try await capturer.captureDisplay(display)
            let (count, box) = Self.differingPixels(covered.image, bare.image)
            Log.app.notice("debug.desktop-cover capture of display \(display.id, privacy: .public) with covers \(covers.sorted().map(String.init).joined(separator: ","), privacy: .public): \(count, privacy: .public) of every 16 pixels differ from the capture without them, within \(box.map { NSStringFromRect($0) } ?? "nothing", privacy: .public) (pixels of the display, top left)")
            // The same way of letting the covers in (this app left out, its covers excepted), with every other app's
            // windows left out too, so the desktop shows even where windows hide it.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { return }
            let keeps: Set<String> = ["com.apple.finder", "com.apple.WindowManager", "com.apple.dock"]
            let others = content.applications.filter { !keeps.contains($0.bundleIdentifier) && !$0.bundleIdentifier.contains("Wallpaper") }
            let coverWindows = content.windows.filter { covers.contains($0.windowID) }
            func desktop(_ excepting: [SCWindow]) async throws -> CGImage? {
                let configuration = SCScreenshotConfiguration()
                configuration.showsCursor = false
                configuration.dynamicRange = .sdr
                configuration.width = Int(display.pixelSize.width)
                configuration.height = Int(display.pixelSize.height)
                let filter = SCContentFilter(display: scDisplay, excludingApplications: others, exceptingWindows: excepting)
                return try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration).sdrImage
            }
            guard let withCovers = try await desktop(coverWindows), let withoutCovers = try await desktop([]) else { return }
            let (shown, shownBox) = Self.differingPixels(withCovers, withoutCovers)
            let wallpaper = try await capturer.captureWallpapers(of: [display])[display.id]
            let (off, _) = wallpaper.map { Self.differingPixels(withCovers, $0) } ?? (-1, nil)
            Log.app.notice("debug.desktop-cover desktop alone (\(others.count, privacy: .public) apps left out, \(coverWindows.count, privacy: .public) cover window(s) found): \(shown, privacy: .public) of every 16 pixels differ with the covers excepted, within \(shownBox.map { NSStringFromRect($0) } ?? "nothing", privacy: .public); with them, \(off, privacy: .public) differ from the bare wallpaper")
        } catch {
            Log.app.error("debug.desktop-cover capture failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pixels (every fourth row and column) whose channels differ by more than 8, and the box around them in the
    /// pictures' pixels from the top left.
    private static func differingPixels(_ first: CGImage, _ second: CGImage) -> (count: Int, box: CGRect?) {
        guard first.width == second.width, first.height == second.height,
              let a = first.dataProvider?.data, let b = second.dataProvider?.data,
              first.bitsPerPixel == 32, second.bitsPerPixel == 32 else { return (-1, nil) }
        let pa = CFDataGetBytePtr(a)!, pb = CFDataGetBytePtr(b)!
        var count = 0
        var box = CGRect.null
        for y in stride(from: 0, to: first.height, by: 4) {
            for x in stride(from: 0, to: first.width, by: 4) {
                let i = y * first.bytesPerRow + x * 4, j = y * second.bytesPerRow + x * 4
                if (0..<3).contains(where: { abs(Int(pa[i + $0]) - Int(pb[j + $0])) > 8 }) {
                    count += 1
                    box = box.union(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        return (count, box.isNull ? nil : box)
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
            let tone = NSApp.effectiveAppearance.isDark ? "dark" : "light"
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
