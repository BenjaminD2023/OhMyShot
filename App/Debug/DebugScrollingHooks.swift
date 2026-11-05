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

/// Endpoints for scrolling capture.
extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleScrollingHook(_ hook: String, _ url: URL) -> Bool {
        switch hook {
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
            guard let display = displays.layout.primary else { return true }
            Task { await DebugScrollingDemo.runFlow(options, coordinator: scrolling, display: display, dark: dark, render: render) }
        case "scroll-panel-render":
            // The scrolling capture's panel on its own, behind the desktop picture, with a made-up picture and
            // progress, captured into scroll-panel.png (mode=dark, hint=back|full|auto|access|stopped|cancel, axis=horizontal;
            // cancel presses Cancel once, after the picture).
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
            if Self.parameter("hint", in: url) == "cancel" { panel.debugPressCancel() }
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
        case "scroll-setup-act":
            // action=start|auto|cancel drives the scrolling bar while an area is framed; none logs what is framed.
            let action = Self.parameter("action", in: url)
            Log.app.notice("debug.scroll-setup \(action ?? "state", privacy: .public): \(overlay.debugScrollingSetup(action) ?? "nothing framed", privacy: .public), capturing=\(scrolling.isCapturing, privacy: .public)")
        case "scroll-cancel":
            scrolling.cancel()
            Log.app.notice("debug.scroll-cancel capturing=\(scrolling.isCapturing, privacy: .public)")
        default:
            return false
        }
        return true
    }
}
#endif
