import AppKit
import Foundation
import OMSCapture
import OMSCore
import OSLog

/// Scrolling capture: choose the part of the screen that scrolls, then scroll it (or let the app scroll it)
/// while the stream stitches what comes into view; Done keeps the long picture as a screenshot is kept.
///
/// While it runs the area keeps its outline and a panel beside it shows the picture growing, with Done,
/// Auto-scroll, and Cancel. The app being scrolled keeps the keyboard, so the shortcut again, the panel, or
/// the menu bar ends it, never Escape.
final class ScrollingCaptureCoordinator {
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let overlay: OverlayController
    private let permissions: PermissionCenter
    private let captures: CaptureCoordinator
    private let outline = AreaOutline()
    /// Made for each capture, so it takes the accessibility display options as they are then.
    private var panel = ScrollingPanel()
    private var run: Run?
    /// The keys of the Scrolling Capture shortcut, which also ends a capture; set by the composition root.
    var doneKeys: (() -> String?)?

    /// One capture under way.
    private final class Run {
        let capture: ScrollingCapture
        let display: DisplayInfo
        let appName: String?
        let copiesToClipboard: Bool
        var axis: ScrollStitcher.Axis?
        /// The way the capture has been going, which Auto-scroll goes on.
        var direction: AutoScroller.Direction = .down
        var scroller: AutoScroller?
        var scrollSpeed = 1.0
        var hasFirstFrame = false
        var requestsAutoScroll = false
        /// Views that scrolled, and views that lined up with nothing, for the log.
        var scrolled = 0
        var lost = 0
        /// Views in a row that lined up with nothing since Auto-scroll last started.
        var lostInARow = 0
        /// Auto-scroll has run in this capture; when it last stopped; how far the content has moved against the
        /// way it goes since (by hand), which turns it once far enough.
        var hasAutoScrolled = false
        var autoScrollStopped: ContinuousClock.Instant?
        var against = 0
        /// How far the capture has got (the picture but what an overscroll pulled out), whether the content is
        /// pulled past its end or a blank stretch is going by, and the part of the view that last moved with it.
        var settled = 0
        var isPulled = false
        var isInBlank = false
        var moving: CGRect?
        /// Watches Auto-scroll's progress; and the places it was moved to, in fractions of the area.
        var watchdog: Task<Void, Never>?
        var moves: [CGPoint] = []
        /// A scroller inside the page that took Auto-scroll's gesture, left out of the picture; and whether it is
        /// taken in after all, nothing else in the area scrolling.
        var inner: CGRect?
        var takesInner = false

        init(capture: ScrollingCapture, display: DisplayInfo, appName: String?, copiesToClipboard: Bool) {
            self.capture = capture
            self.display = display
            self.appName = appName
            self.copiesToClipboard = copiesToClipboard
        }
    }

    init(displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController, permissions: PermissionCenter, captures: CaptureCoordinator) {
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        self.permissions = permissions
        self.captures = captures
    }

    var isCapturing: Bool { run != nil }

    /// The shortcut, the menu, or the URL: chooses the area on the live screen, or finishes the capture
    /// under way. `autoScrolls` starts the app scrolling as soon as the capture starts.
    func begin(autoScrolls: Bool = false) {
        if run != nil { return finish() }
        guard !overlay.isActive else { return }
        captures.cancelSelfTimer()
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.localizedName }
        overlay.freezesScreen = false
        #if DEBUG
        let copies = !debugLeavesClipboard
        #else
        let copies = true
        #endif
        overlay.begin(mode: .area, purpose: .scroll) { [weak self] outcome in
            guard let self, case .scroll(let area, let display, let auto) = outcome else { return }
            if auto || autoScrolls, !AutoScroller.isAllowed {
                // Asked now, before anything is captured: macOS's question would be in the picture.
                askForAccessibility()
                return
            }
            Task { await self.start(area, on: display, autoScrolls: auto || autoScrolls, appName: app, copiesToClipboard: copies) }
        }
    }

    /// The menu's title for the capture's entry, as it stands.
    var menuTitle: String {
        isCapturing ? String(localized: "Finish Scrolling Capture") : String(localized: "Scrolling Capture")
    }

    private func start(_ area: CGRect, on display: DisplayInfo, autoScrolls: Bool, appName: String?, copiesToClipboard: Bool = true) async {
        do {
            let source = try await capturer.scrollingSource(for: area, on: display)
            // The app whose window is scrolled, which need not be the one in front when the shortcut was pressed.
            let owner = Self.appName(at: CGPoint(x: area.midX, y: area.midY)) ?? appName
            await start(source, on: display, autoScrolls: autoScrolls, appName: owner, copiesToClipboard: copiesToClipboard)
        } catch {
            failed(error)
        }
    }

    private func start(_ source: ScrollingCapture.Source, on display: DisplayInfo, autoScrolls: Bool, appName: String?, copiesToClipboard: Bool) async {
        guard run == nil else { return }
        let capture = ScrollingCapture(source, preview: ScrollingPanel.previewPixels(on: display))
        capture.onProgress = { [weak self] progress in self?.progressed(progress) }
        capture.onStopped = { [weak self] _ in self?.streamEnded() }
        let run = Run(capture: capture, display: display, appName: appName, copiesToClipboard: copiesToClipboard)
        self.run = run
        panel = makePanel()
        do {
            try await capture.start()
        } catch {
            if self.run === run { self.run = nil }
            failed(error)
            return
        }
        // Done or Cancel while the stream started: it was ended already, and the stream goes with it.
        guard self.run === run else {
            await capture.cancel()
            return
        }
        // Only what the stream sees counts: the outline and the panel are this app's, left out of it.
        let keys = doneKeys?()
        #if DEBUG
        if debugHidden {
            panel.debugWindow.appearance = debugAppearance
            panel.show(beside: source.frame, displayFrame: display.frame, doneKeys: keys)
            panel.debugHide()
        } else {
            outline.show(source.frame, layout: displays.layout)
            panel.show(beside: source.frame, displayFrame: display.frame, doneKeys: keys)
        }
        #else
        outline.show(source.frame, layout: displays.layout)
        panel.show(beside: source.frame, displayFrame: display.frame, doneKeys: keys)
        #endif
        Log.capture.notice("Scrolling capture started on \(Int(source.frame.width), privacy: .public)x\(Int(source.frame.height), privacy: .public) pt")
        if autoScrolls { setAutoScroll(true) }
    }

    private func progressed(_ progress: ScrollingCapture.Progress) {
        guard let run else { return }
        panel.update(progress)
        if progress.axis != nil { run.axis = progress.axis }
        run.settled = progress.settledLength
        run.isPulled = progress.isPulled
        run.isInBlank = progress.isInBlank
        if let moving = progress.moving { run.moving = moving }
        if let inner = progress.inner {
            run.inner = inner
            run.moving = inner
            moveOffInnerScroller(run, from: inner)
        }
        switch progress.step {
        case .started:
            run.hasFirstFrame = true
            if run.requestsAutoScroll { setAutoScroll(true) }
        case .scrolled(let offset):
            run.scrolled += 1
            run.lostInARow = 0
            // Moved off the scroller inside the page, the page itself scrolls: that is what is captured.
            if !run.moves.isEmpty, !run.takesInner { run.inner = nil }
            followManualScroll(offset, in: run)
        case .lost:
            run.lost += 1
            run.lostInARow += 1
        case .unchanged:
            run.lostInARow = 0
        default:
            break
        }
        // Stop driving before the capture loses its overlap. A failed match or a length limit must never
        // silently deliver a partial image; the user keeps the preview and decides when it is done. Views lost
        // before the content could have moved (a video playing in the first view) are no reason yet.
        if let scroller = run.scroller, progress.isFull || (run.lostInARow >= 2 && scroller.posted * 8 >= extent(of: run)) {
            setAutoScroll(false)
        }
    }

    /// The name of the app whose window is frontmost at `point` (global points), this app's own windows aside.
    private static func appName(at point: CGPoint) -> String? {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let location = CGPoint(x: point.x, y: primaryHeight - point.y)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(location) else { continue }
            return NSRunningApplication(processIdentifier: pid)?.localizedName ?? window[kCGWindowOwnerName as String] as? String
        }
        return nil
    }

    /// The area's length along the axis, in points.
    private func extent(of run: Run) -> Double {
        let frame = run.capture.source.frame
        return Double(run.axis == .horizontal || !run.direction.isVertical ? frame.width : frame.height)
    }

    /// Auto-scroll goes on the way the user scrolled by hand: before it first ran, after a quarter of the area;
    /// after, only on a deliberate turn of a whole area, never on scrolling back a little to find the place again,
    /// and never on the content springing back (or snapping back) as Auto-scroll stops.
    private func followManualScroll(_ offset: Int, in run: Run) {
        guard offset != 0, run.scroller == nil else { return }
        if let stopped = run.autoScrollStopped, ContinuousClock.now - stopped < .seconds(1) { return }
        let direction = AutoScroller.Direction(axis: run.axis, offset: offset)
        guard direction != run.direction else {
            run.against = 0
            return
        }
        run.against += abs(offset)
        let pixels = extent(of: run) * Double(run.capture.source.pixelsPerPoint)
        guard Double(run.against) >= (run.hasAutoScrolled ? pixels : pixels / 4) else { return }
        run.direction = direction
        run.against = 0
        panel.setAutoScrollDirection(direction)
    }

    /// While Auto-scroll runs, a scroller inside the page that took its gesture (a code block, a chat pane, a map)
    /// scrolls alone around the place the gesture lands, and is left out of the picture: the gesture moves off it, to
    /// the larger part of the area beside it, so the page itself scrolls.
    private func moveOffInnerScroller(_ run: Run, from inner: CGRect) {
        guard let scroller = run.scroller, run.moves.count < 2, !run.takesInner else { return }
        let vertical = run.axis.map { $0 == .vertical } ?? run.direction.isVertical
        guard inner.contains(run.moves.last ?? CGPoint(x: 0.5, y: 0.5)) else { return }
        let before = vertical ? inner.minY : inner.minX
        let after = 1 - (vertical ? inner.maxY : inner.maxX)
        guard max(before, after) >= 0.1 else { return }
        let middle = before >= after ? before / 2 : 1 - after / 2
        moveAutoScroll(to: vertical ? CGPoint(x: 0.5, y: middle) : CGPoint(x: middle, y: 0.5), in: run, scroller: scroller)
    }

    /// Moves Auto-scroll's gesture to `point`, in fractions of the area from its top left.
    private func moveAutoScroll(to point: CGPoint, in run: Run, scroller: AutoScroller) {
        let frame = run.capture.source.frame
        run.moves.append(point)
        run.capture.setDriven(true, at: run.takesInner ? nil : point)
        scroller.retarget(to: CGPoint(x: frame.minX + point.x * frame.width, y: frame.maxY - point.y * frame.height))
    }

    /// Every quarter second while Auto-scroll runs: once the capture gets little of what it pushes (`AutoScrollWatch`),
    /// the content stopped. Pulled past its end, or in a blank stretch pushed through for a long while, it came to its
    /// end; otherwise what took the gesture stopped, and it is moved once or twice to where the page might scroll.
    private func watch(_ run: Run) {
        run.watchdog?.cancel()
        run.watchdog = Task { [weak self, weak run] in
            var watch = AutoScrollWatch(extent: 0)
            let began = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let run, self.run === run, let scroller = run.scroller else { return }
                let now = ContinuousClock.now
                let scale = Double(run.capture.source.pixelsPerPoint)
                watch.extent = extent(of: run) * scale
                let load = run.capture.load
                let verdict = watch.look(AutoScrollWatch.Sample(
                    time: now - began, pushed: scroller.posted * scale, settled: run.settled, views: load.views, busy: load.busy,
                    taking: load.takingSince.map { now - $0 } ?? .zero, isInBlank: run.isInBlank, isPulled: run.isPulled
                ))
                guard case .stopped(let pushed, let got) = verdict else {
                    if verdict == .behind { Log.capture.notice("Auto-scroll watch: the capture is behind, \(load.views, privacy: .public) views") }
                    continue
                }
                // Through a blank stretch the page itself was scrolling: the gesture is where it should be.
                if !run.isPulled, !run.isInBlank, run.moves.count < 2 {
                    let places = [CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)]
                    if let place = places.first(where: { place in !run.moves.contains(place) && !(run.moving?.contains(place) ?? false) }) {
                        moveAutoScroll(to: place, in: run, scroller: scroller)
                        watch.restart()
                        continue
                    }
                }
                // Nothing beside the scroller inside the page scrolls: it is what there is to capture.
                if !run.isPulled, !run.isInBlank, let inner = run.inner, !run.takesInner {
                    run.takesInner = true
                    moveAutoScroll(to: CGPoint(x: inner.midX, y: inner.midY), in: run, scroller: scroller)
                    watch.restart()
                    continue
                }
                Log.capture.notice("Auto-scroll stopped: \(pushed, privacy: .public) px pushed, \(got, privacy: .public) px got, pulled \(run.isPulled, privacy: .public), blank \(run.isInBlank, privacy: .public)")
                run.capture.trimOverscroll()
                setAutoScroll(false)
                panel.showAutoScrollStopped(.reachedEnd)
                return
            }
        }
    }

    /// Done: the stream stops and the picture is kept.
    func finish() {
        guard let run else { return }
        // Done while Auto-scroll pushed past the end: what the pull showed past it is no part of the picture.
        if run.scroller != nil { run.capture.trimOverscroll() }
        end(run)
        Task {
            let picture = await run.capture.finish()
            let summary = await run.capture.summary()
            guard let picture else {
                Log.capture.error("Scrolling capture kept nothing: \(summary, privacy: .public)")
                NSSound.beep()
                return
            }
            Log.capture.notice("Scrolling capture: \(picture.width, privacy: .public)x\(picture.height, privacy: .public), \(run.scrolled, privacy: .public) scrolls and \(run.lost, privacy: .public) lost; \(summary, privacy: .public)")
            #if DEBUG
            if let folder = debugSaveFolder {
                debugSaveFolder = nil
                try? await ImageExporter.write(picture, to: folder.appending(path: "scroll-flow.png"), format: .png)
                Log.app.notice("debug.scroll-flow kept \(picture.width, privacy: .public)x\(picture.height, privacy: .public) as scroll-flow.png")
                return
            }
            #endif
            await captures.deliverScrollingCapture(
                picture, area: run.capture.source.frame, pixelsPerPoint: run.capture.source.pixelsPerPoint, displayID: run.display.id,
                appName: run.appName, copiesToClipboard: run.copiesToClipboard
            )
        }
    }

    func cancel() {
        guard let run else { return }
        end(run)
        Task { await run.capture.cancel() }
    }

    private func end(_ run: Run) {
        self.run = nil
        run.watchdog?.cancel()
        run.scroller?.stop()
        outline.hide()
        panel.close()
        #if DEBUG
        debugHidden = false
        #endif
    }

    /// The stream ended on its own: the display went away, or Screen Recording was turned off. What was
    /// stitched so far is kept.
    private func streamEnded() {
        guard run != nil else { return }
        Log.capture.notice("Scrolling capture: the stream ended on its own, keeping what was stitched")
        NSSound.beep()
        finish()
    }

    private func failed(_ error: any Error) {
        Log.capture.error("Scrolling capture couldn't start: \(String(describing: error), privacy: .public)")
        NSSound.beep()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: String(localized: "The scrolling capture couldn’t start."), .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func makePanel() -> ScrollingPanel {
        let panel = ScrollingPanel()
        panel.onDone = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onAutoScroll = { [weak self] on in self?.setAutoScroll(on) }
        panel.onSpeedChanged = { [weak self] speed in
            guard let run = self?.run else { return }
            run.scrollSpeed = speed
            run.scroller?.speedMultiplier = speed
        }
        return panel
    }

    // MARK: Auto-scroll

    /// Asks for Accessibility, which Auto-scroll needs: macOS asks once; after that, System Settings. Nothing is
    /// captured meanwhile, so the question is never in a picture.
    private func askForAccessibility() {
        if permissions.hasAsked(.accessibility) {
            permissions.openSystemSettings(for: .accessibility)
        } else {
            Task { await permissions.request(.accessibility) }
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: String(localized: "Auto-scroll needs Accessibility. Turn it on in System Settings › Privacy & Security, then start the scrolling capture again."),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func setAutoScroll(_ on: Bool) {
        guard let run else { return }
        run.requestsAutoScroll = on
        guard on else {
            if let scroller = run.scroller {
                scroller.stop()
                run.autoScrollStopped = .now
            }
            run.scroller = nil
            run.watchdog?.cancel()
            run.capture.prefer(nil)
            run.capture.setDriven(false)
            panel.setAutoScrolling(false)
            return
        }
        guard run.scroller == nil else { return }
        guard AutoScroller.isAllowed else {
            // Mid-capture only the hint: a question or System Settings would come up over the area.
            panel.showNeedsAccessibility()
            run.requestsAutoScroll = false
            return
        }
        guard run.hasFirstFrame else {
            panel.setAutoScrolling(true)
            return
        }
        #if DEBUG
        let made = debugAutoScrollTarget.flatMap {
            AutoScroller.debugWindow(area: run.capture.source.frame, processID: $0.processID, windowID: $0.windowID, windowFrame: $0.frame, direction: run.direction)
        } ?? AutoScroller(area: run.capture.source.frame, direction: run.direction)
        let scroller = made
        #else
        let scroller = AutoScroller(area: run.capture.source.frame, direction: run.direction)
        #endif
        scroller.speedMultiplier = run.scrollSpeed
        scroller.onUserTookOver = { [weak self, weak run] how in
            guard let self, let run, self.run === run else { return }
            run.requestsAutoScroll = false
            run.scroller = nil
            run.autoScrollStopped = .now
            run.watchdog?.cancel()
            run.capture.prefer(nil)
            run.capture.setDriven(false)
            panel.setAutoScrolling(false)
            panel.showAutoScrollStopped(how)
        }
        run.scroller = scroller
        guard scroller.start() else {
            run.requestsAutoScroll = false
            run.scroller = nil
            panel.setAutoScrolling(false)
            panel.showNoScrollTarget()
            return
        }
        run.hasAutoScrolled = true
        run.lostInARow = 0
        run.against = 0
        run.moves = []
        run.inner = nil
        run.takesInner = false
        // Until the first scroll says which way the content goes, only the way the app is made to scroll counts: a
        // carousel's slide must not turn the capture on its side.
        if run.axis == nil { run.capture.prefer(run.direction.isVertical ? .vertical : .horizontal) }
        // The gesture lands in the area's middle.
        run.capture.setDriven(true, at: CGPoint(x: 0.5, y: 0.5))
        panel.setAutoScrolling(true)
        watch(run)
        // A quiet frame can mean loading or a blank margin, never implicit Done: Auto-scroll only stops.
    }

    #if DEBUG
    /// Scrolling captures the user makes leave the clipboard alone, as Settings may not, for checks made on
    /// the screen with the user's word.
    var debugLeavesClipboard = false

    /// The panel and the outline go behind the desktop picture, for scripted checks that show nothing.
    private var debugHidden = false
    /// Where Done writes the picture instead of keeping it, for scripted checks.
    private var debugSaveFolder: URL?

    /// The panel's look in scripted checks: Light or Dark.
    private var debugAppearance: NSAppearance?

    /// Runs a scrolling capture of `source` without choosing an area, everything of it behind the desktop
    /// picture, the picture written to `folder` instead of kept: for scripted checks on the app's own windows.
    func debugStart(
        _ source: ScrollingCapture.Source, on display: DisplayInfo, savingTo folder: URL, appearance: NSAppearance? = nil, autoScrolls: Bool = false
    ) async {
        debugHidden = true
        debugSaveFolder = folder
        debugAppearance = appearance
        await start(source, on: display, autoScrolls: autoScrolls, appName: "Demo", copiesToClipboard: false)
    }

    /// The window Auto-scroll is addressed to in scripted checks, whatever is over it on screen.
    var debugAutoScrollTarget: (processID: pid_t, windowID: CGWindowID, frame: CGRect)?

    /// Whether Auto-scroll is running, and the hint the panel shows, for scripted checks.
    var debugAutoScrolling: Bool { run?.scroller != nil }

    /// The panel's window, for scripted renders.
    var debugPanelWindow: NSWindow { panel.debugWindow }
    #endif
}
