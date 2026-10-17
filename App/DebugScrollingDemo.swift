#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import OMSCapture
import OMSCore
import OSLog
import ScreenCaptureKit

/// Scrolling capture on a window the app draws behind the desktop picture, nothing shown and nothing of the
/// user's read: a scroll view of made-up text between two bars that stay put, scrolled step by step while the
/// real stream and stitcher take it in. The picture is then compared with the window's own drawing of the
/// whole page between the bars.
@MainActor
enum DebugScrollingDemo {
    /// A bounded capture of the explicitly opened X test tab, using the production input and stitcher.
    /// Saves only in the debug snapshot folder, never to History or the clipboard.
    static func runXCheck() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = content.windows.first(where: {
                $0.owningApplication?.applicationName.contains("Chrome") == true && ($0.title?.contains("/ X") ?? false)
            }), let processID = target.owningApplication?.processID else {
                let windows = content.windows.filter { $0.owningApplication?.applicationName.contains("Chrome") == true }
                let candidates = windows.filter { $0.title?.contains("X") == true }.map { "\($0.windowID): \($0.title ?? "")" }
                Log.app.notice("debug.scroll-x-check unavailable: Chrome windows \(windows.count), untitled \(windows.filter { $0.title == nil }.count), X candidates \(candidates, privacy: .public)")
                return
            }
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            let frame = CGRect(x: target.frame.minX, y: primaryHeight - target.frame.maxY, width: target.frame.width, height: target.frame.height)
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let source = ScrollingCapture.Source(filter: filter, sourceRect: nil,
                pixelWidth: Int((filter.contentRect.width * scale).rounded()), pixelHeight: Int((filter.contentRect.height * scale).rounded()),
                pixelsPerPoint: scale, frame: frame, displayID: CGMainDisplayID())
            guard let scroller = AutoScroller.debugWindow(area: frame, processID: processID, windowID: target.windowID, windowFrame: target.frame) else { return }
            let capture = ScrollingCapture(source, preview: (240, 1200))
            var started = false
            var moved = 0
            var lost = 0
            capture.onProgress = { progress in
                if progress.step == .started { started = scroller.start() }
                if case .scrolled = progress.step { moved += 1 }
                if progress.step == .lost { lost += 1 }
                if progress.lostInARow >= 2 { scroller.stop() }
            }
            ScrollingCapture.debugDumpFolder = DebugHooks.snapshotDirectory
            defer { ScrollingCapture.debugDumpFolder = nil; scroller.stop() }
            try await capture.start()
            try? await Task.sleep(for: .seconds(4))
            scroller.stop()
            try? await Task.sleep(for: .milliseconds(200))
            let image = await capture.finish()
            let summary = await capture.summary()
            if let image {
                try await ImageExporter.write(image, to: DebugHooks.snapshotDirectory.appending(path: "scroll-x-check.png"), format: .png)
                Log.app.notice("debug.scroll-x-check \(image.width, privacy: .public)x\(image.height, privacy: .public), started \(started), moved \(moved), lost \(lost); \(summary, privacy: .public)")
            }
        } catch {
            Log.app.error("debug.scroll-x-check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// End to end on a browser window a check opened itself (a throwaway profile showing a test page), found by a
    /// title the page sets, never the user's own: the real stream over the window's area below `top` points (the
    /// production source, or the window alone with `window`), driven by the real AutoScroller (`auto`), the one
    /// addressed to the window (`debug`), or nothing (`none`, scrolled from outside). Every view the stitcher takes in
    /// is written as PNG with the step it made, the previews the panel would show every so often, and the picture, to
    /// a folder of the snapshot folder; nothing goes to the history or the clipboard.
    static func runEndToEnd(
        title: String, processID wanted: pid_t?, label: String, seconds: Double, speed: Double, window: Bool, top: CGFloat, driver: String, stopsWhenLost: Bool,
        dumps: Bool, capturer: ScreenCapturer, layout: DisplayLayout
    ) async {
        let folder = DebugHooks.snapshotDirectory.appending(path: "scroll-e2e-\(label)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = content.windows.first(where: {
                ($0.title ?? "").contains(title) && $0.owningApplication?.processID != getpid() && $0.windowLayer == 0
                    && (wanted == nil || $0.owningApplication?.processID == wanted)
            }), let processID = target.owningApplication?.processID else {
                Log.app.notice("debug.scroll-e2e unavailable: no window titled \(title, privacy: .public)")
                return
            }
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            // SCWindow frames are in Core Graphics' global space: points, y down from the primary display's top.
            let windowFrame = target.frame
            let areaCG = CGRect(x: windowFrame.minX, y: windowFrame.minY + top, width: windowFrame.width, height: windowFrame.height - top)
            let area = CGRect(x: areaCG.minX, y: primaryHeight - areaCG.maxY, width: areaCG.width, height: areaCG.height)
            guard let display = layout.displays.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }) else {
                Log.app.notice("debug.scroll-e2e unavailable: the window's middle is on no display")
                return
            }
            // The screen over the area, or the real Auto-scroll addressed to whatever is under the area's middle: only
            // with the check's own window in front there, never over or into a window of the user's.
            if !window || driver == "auto" {
                let front = WindowCatalog.target(at: CGPoint(x: area.midX, y: area.midY), in: WindowCatalog.snapshot(layout: layout, excludingPID: getpid()))
                guard front?.id == target.windowID else {
                    Log.app.notice("debug.scroll-e2e unavailable: the check's window is not in front at the area's middle (\(front?.ownerName ?? "nothing", privacy: .public) is)")
                    return
                }
            }
            var source: ScrollingCapture.Source
            if window {
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let scale = CGFloat(filter.pointPixelScale)
                let rect = CGRect(x: 0, y: top, width: windowFrame.width, height: windowFrame.height - top)
                source = ScrollingCapture.Source(
                    filter: filter, sourceRect: rect, pixelWidth: Int((rect.width * scale).rounded()), pixelHeight: Int((rect.height * scale).rounded()),
                    pixelsPerPoint: scale, frame: area, displayID: CGMainDisplayID()
                )
            } else {
                source = try await capturer.scrollingSource(for: area, on: display)
            }
            // As a window chosen with Space: its rounded corners the area shares, filled.
            source.corners = await capturer.windowCorners(for: source.frame, on: display, layout: layout, windowID: target.windowID)

            // Every view as PNG, written off the stream's queue, at most 8 at a time.
            let writing = DispatchQueue(label: "OhMyShot.scroll-e2e", qos: .utility, attributes: .concurrent)
            let group = DispatchGroup()
            let slots = DispatchSemaphore(value: 8)
            let space = ScrollingCapture.colorSpace
            let width = source.pixelWidth, height = source.pixelHeight
            /// Touched on the stream's queue only, and read once the capture has finished.
            nonisolated final class Record: @unchecked Sendable {
                var steps: [String] = []
                var skips: [String: Int] = [:]
            }
            let record = Record()
            ScrollingCapture.debugViewSink = { @Sendable base, bytesPerRow, step, why in
                let index = record.steps.count
                let name: String = switch step {
                case .started: "started"
                case .unchanged: "unchanged"
                case .scrolled(let offset): "scrolled \(offset)"
                case .lost: "LOST (\(why))"
                case .full: "full"
                }
                record.steps.append("\(index) \(name)")
                guard dumps else { return }
                nonisolated(unsafe) let buffer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
                for row in 0..<height { memcpy(buffer + row * width * 4, base + row * bytesPerRow, width * 4) }
                slots.wait()
                group.enter()
                writing.async {
                    defer { buffer.deallocate(); slots.signal(); group.leave() }
                    guard let context = CGContext(
                        data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    ), let image = context.makeImage(),
                    let destination = CGImageDestinationCreateWithURL(
                        folder.appending(path: String(format: "frame-%05d.png", index)) as CFURL, "public.png" as CFString, 1, nil
                    ) else { return }
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
            ScrollingCapture.debugSkipSink = { @Sendable reason in record.skips[reason, default: 0] += 1 }
            defer {
                ScrollingCapture.debugViewSink = nil
                ScrollingCapture.debugSkipSink = nil
            }

            let capture = ScrollingCapture(source, preview: (240, 1200))
            var scroller: AutoScroller?
            var started = false
            var tookOver: [String] = []
            var previews = 0
            var progressLine = ""
            capture.onProgress = { progress in
                if progress.step == .started, driver != "none" {
                    let made = driver == "debug"
                        ? AutoScroller.debugWindow(area: area, processID: processID, windowID: target.windowID, windowFrame: windowFrame)
                        : AutoScroller(area: area)
                    made?.speedMultiplier = speed
                    made?.onUserTookOver = { how in tookOver.append("\(how)") }
                    started = made?.start() ?? false
                    scroller = made
                }
                if stopsWhenLost, progress.lostInARow >= 2 || progress.isFull { scroller?.stop() }
                if let preview = progress.preview, previews < 400 {
                    previews += 1
                    let url = folder.appending(path: String(format: "preview-%04d.png", previews))
                    Task { try? await ImageExporter.write(preview, to: url, format: .png) }
                }
                progressLine = "views \(progress.views), picture \(progress.pictureWidth)x\(progress.pictureHeight)"
            }
            try await capture.start()
            try? await Task.sleep(for: .seconds(seconds))
            scroller?.stop()
            try? await Task.sleep(for: .milliseconds(300))
            let picture = await capture.finish()
            let summary = await capture.summary()
            await withCheckedContinuation { continuation in group.notify(queue: .main) { continuation.resume() } }
            if let picture { try await ImageExporter.write(picture, to: folder.appending(path: "picture.png"), format: .png) }
            let steps = record.steps
            // The corners filled come first, as a replay takes what the capture was told before the first view.
            let told = source.corners.map { ["- \($0.description)"] } ?? []
            try (told + steps).joined(separator: "\n").write(to: folder.appending(path: "steps.txt"), atomically: true, encoding: .utf8)
            let counts = Dictionary(grouping: steps.map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? "" }, by: { $0 }).mapValues(\.count)
            let lost = steps.filter { $0.contains("LOST") }.prefix(12).joined(separator: " | ")
            Log.app.notice("""
            debug.scroll-e2e \(label, privacy: .public): source \(width)x\(height) px over \(Int(area.width))x\(Int(area.height)) pt (\(window ? "window" : "area", privacy: .public)), \
            driver \(driver, privacy: .public) started \(started), took over \(tookOver.joined(separator: ","), privacy: .public); picture \(picture?.width ?? 0)x\(picture?.height ?? 0); \
            steps \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public); \
            skipped \(record.skips.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public); last progress \(progressLine, privacy: .public); \(summary, privacy: .public); lost: \(lost, privacy: .public); folder \(folder.path, privacy: .public)
            """)
        } catch {
            Log.app.error("debug.scroll-e2e failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The whole scrolling capture flow on a browser window a check opened itself, as `runEndToEnd` finds it: the real
    /// coordinator with Auto-scroll on (addressed to that window), left to stop by itself, then Done a moment later,
    /// or after `seconds` at the most. The picture is written as scroll-flow.png to scroll-e2e-flow-<label>/ in the
    /// snapshot folder, with each view's step and, between them, what the capture was told (`- driven …`, `- trim …`),
    /// and with `dumps` every view as PNG, for replaying the run offline; the panel and outline stay behind the
    /// desktop picture.
    static func runFlowEndToEnd(
        title: String, processID wanted: pid_t?, label: String, seconds: Double, top: CGFloat, dumps: Bool,
        coordinator: ScrollingCaptureCoordinator, layout: DisplayLayout
    ) async {
        let folder = DebugHooks.snapshotDirectory.appending(path: "scroll-e2e-flow-\(label)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = content.windows.first(where: {
                ($0.title ?? "").contains(title) && $0.owningApplication?.processID != getpid() && $0.windowLayer == 0
                    && (wanted == nil || $0.owningApplication?.processID == wanted)
            }), let processID = target.owningApplication?.processID else {
                Log.app.notice("debug.scroll-e2e-flow unavailable: no window titled \(title, privacy: .public)")
                return
            }
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            let windowFrame = target.frame
            let area = CGRect(x: windowFrame.minX, y: primaryHeight - windowFrame.maxY, width: windowFrame.width, height: windowFrame.height - top)
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let rect = CGRect(x: 0, y: top, width: windowFrame.width, height: windowFrame.height - top)
            let source = ScrollingCapture.Source(
                filter: filter, sourceRect: rect, pixelWidth: Int((rect.width * scale).rounded()), pixelHeight: Int((rect.height * scale).rounded()),
                pixelsPerPoint: scale, frame: area, displayID: CGMainDisplayID()
            )
            guard let display = layout.displays.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }) ?? layout.primary else { return }
            /// Touched on the stream's queue only, and read once the capture has finished.
            nonisolated final class Record: @unchecked Sendable {
                var steps: [String] = []
                var views = 0
            }
            let record = Record()
            let writing = DispatchQueue(label: "OhMyShot.scroll-e2e-flow", qos: .utility, attributes: .concurrent)
            let group = DispatchGroup()
            let slots = DispatchSemaphore(value: 8)
            let space = ScrollingCapture.colorSpace
            let width = source.pixelWidth, height = source.pixelHeight
            // When each view was taken in, and how long writing the views held the capture up, to tell a page standing
            // still from the check itself.
            let began = ContinuousClock.now
            ScrollingCapture.debugViewSink = { @Sendable base, bytesPerRow, step, why in
                let index = record.views
                record.views += 1
                let name: String = switch step {
                case .started: "started"
                case .unchanged: "unchanged"
                case .scrolled(let offset): "scrolled \(offset)"
                case .lost: "LOST (\(why))"
                case .full: "full"
                }
                record.steps.append("\(index) \(name) t=\(Int((ContinuousClock.now - began) / .milliseconds(1)))")
                guard dumps else { return }
                nonisolated(unsafe) let buffer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
                for row in 0..<height { memcpy(buffer + row * width * 4, base + row * bytesPerRow, width * 4) }
                let waiting = ContinuousClock.now
                slots.wait()
                let waited = ContinuousClock.now - waiting
                if waited > .milliseconds(20) { record.steps.append("# view \(index) waited \(Int(waited / .milliseconds(1))) ms to be written") }
                group.enter()
                writing.async {
                    defer { buffer.deallocate(); slots.signal(); group.leave() }
                    guard let context = CGContext(
                        data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    ), let image = context.makeImage(),
                    let destination = CGImageDestinationCreateWithURL(
                        folder.appending(path: String(format: "frame-%05d.png", index)) as CFURL, "public.png" as CFString, 1, nil
                    ) else { return }
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
            ScrollingCapture.debugEventSink = { @Sendable event in record.steps.append("- \(event)") }
            defer {
                ScrollingCapture.debugViewSink = nil
                ScrollingCapture.debugEventSink = nil
            }
            coordinator.debugAutoScrollTarget = (processID, target.windowID, windowFrame)
            defer { coordinator.debugAutoScrollTarget = nil }
            let started = ContinuousClock.now
            await coordinator.debugStart(source, on: display, savingTo: folder, autoScrolls: true, cornersOf: target.windowID)
            var ranAt: ContinuousClock.Instant?
            var stoppedAt: ContinuousClock.Instant?
            while ContinuousClock.now - started < .seconds(seconds) {
                try? await Task.sleep(for: .milliseconds(250))
                if coordinator.debugAutoScrolling { ranAt = ranAt ?? .now } else if ranAt != nil, stoppedAt == nil { stoppedAt = .now }
                // Stopped by itself: Done a moment later, once the content has settled.
                if let stoppedAt, ContinuousClock.now - stoppedAt > .milliseconds(1500) { break }
            }
            let ran = ranAt.map { (stoppedAt ?? .now) - $0 } ?? .zero
            coordinator.finish()
            try? await Task.sleep(for: .milliseconds(1500))
            await withCheckedContinuation { continuation in group.notify(queue: .main) { continuation.resume() } }
            let steps = record.steps
            try steps.joined(separator: "\n").write(to: folder.appending(path: "steps.txt"), atomically: true, encoding: .utf8)
            let counts = Dictionary(grouping: steps.filter { !$0.hasPrefix("- ") && !$0.hasPrefix("# ") }.map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? "" }, by: { $0 })
                .mapValues(\.count)
            Log.app.notice("""
            debug.scroll-e2e-flow \(label, privacy: .public): Auto-scroll ran \(ran.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))), privacy: .public), \
            \(stoppedAt == nil ? "never stopped by itself" : "stopped by itself", privacy: .public); steps \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public); folder \(folder.path, privacy: .public)
            """)
        } catch {
            Log.app.error("debug.scroll-e2e-flow failed: \(String(describing: error), privacy: .public)")
        }
    }

    struct Options {
        var horizontal = false
        /// Points per step, and the pause between steps.
        var step: CGFloat = 37
        var interval: Int = 40
        /// The bars' size along the scroll, in points.
        var header: CGFloat = 44
        var footer: CGFloat = 30
        var size = CGSize(width: 640, height: 480)
        /// Scroll to the end and some way back.
        var back = false
        /// Jump once, midway, too far to line up, then come back.
        var jump = false
        /// Show scroll bars. Behind the desktop picture the window never takes the pointer and its overlay
        /// scroll bar never fades, so its track and knob are in every view: the comparison leaves them out.
        var scrollBars = false
        /// A forum's layout: a sidebar that never moves left of the page (a list of the same item over and
        /// over), and a badge stuck over the page's top-left corner, as a post's avatar sticks.
        var sidebar = false
        /// A forum's topic as a forum lays it out: the sidebar; a banner atop the page; posts whose avatars move
        /// with their post, stick below the header while it scrolls on, and are pushed out by its end; and right of
        /// the page a timeline that never moves, `timeline` of the view's height, its handle creeping as the page
        /// scrolls. Steps vary as a trackpad's do. No footer.
        var forum = false
        var timeline: CGFloat = 0.3
    }

    static func run(_ options: Options) async {
        ScrollingCapture.debugDumpFolder = DebugHooks.snapshotDirectory
        defer { ScrollingCapture.debugDumpFolder = nil }
        let window = DemoWindow(options)
        window.orderFront(nil)
        defer { window.letGo() }
        // Long enough for the window server to have the window's first frame.
        try? await Task.sleep(for: .milliseconds(300))
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                Log.app.error("debug.scroll-demo no window \(window.windowNumber, privacy: .public)")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let source = ScrollingCapture.Source(
                filter: filter, sourceRect: nil, pixelWidth: Int((filter.contentRect.width * scale).rounded()),
                pixelHeight: Int((filter.contentRect.height * scale).rounded()), pixelsPerPoint: scale, frame: window.frame,
                displayID: CGMainDisplayID()
            )
            let capture = ScrollingCapture(source, preview: (240, 1200))
            var lost = 0
            var previews = 0
            capture.onProgress = { progress in
                if progress.step == .lost { lost += 1 }
                if progress.preview != nil { previews += 1 }
            }
            try await capture.start()
            try? await Task.sleep(for: .milliseconds(200))
            let started = ContinuousClock.now
            let before = CPUTimes.now()
            await window.scrollThrough(options)
            let used = CPUTimes.now() - before
            let busy = (ContinuousClock.now - started) / .seconds(1)
            // Long enough for the overlay scroll bar to fade, as it does once the scrolling stops.
            try? await Task.sleep(for: .milliseconds(1500))
            let scrolled = ContinuousClock.now - started
            let finishing = ContinuousClock.now
            let picture = await capture.finish()
            let finished = ContinuousClock.now - finishing
            let summary = await capture.summary()
            guard let picture else {
                Log.app.error("debug.scroll-demo no picture: \(summary, privacy: .public)")
                return
            }
            let reference = window.reference()
            let skipped = options.scrollBars ? Int((18 * scale).rounded()) : 0
            var comparison = reference.map { compare(picture, $0, skippingEnd: skipped, horizontal: options.horizontal) } ?? "no reference"
            if options.forum, let reference {
                // The timeline's column apart: whether it was taken for a column that stays put decides it.
                let timeline = window.timelineColumns(scale: scale)
                comparison = "page and sidebar: " + compare(picture, reference, skippingEnd: 0, horizontal: false, columns: 0 ..< timeline.lowerBound)
                    + "; timeline column: " + compare(picture, reference, skippingEnd: 0, horizontal: false, columns: timeline)
            }
            try FileManager.default.createDirectory(at: DebugHooks.snapshotDirectory, withIntermediateDirectories: true)
            try await ImageExporter.write(picture, to: DebugHooks.snapshotDirectory.appending(path: "scroll-demo.png"), format: .png)
            if let reference {
                try await ImageExporter.write(reference, to: DebugHooks.snapshotDirectory.appending(path: "scroll-demo-reference.png"), format: .png)
            }
            Log.app.notice("debug.scroll-demo \(picture.width, privacy: .public)x\(picture.height, privacy: .public) (reference \(reference?.width ?? 0, privacy: .public)x\(reference?.height ?? 0, privacy: .public)): \(comparison, privacy: .public); \(summary, privacy: .public); lost reports \(lost, privacy: .public), previews \(previews, privacy: .public); scrolled for \(String(describing: scrolled), privacy: .public), finished in \(String(describing: finished), privacy: .public); CPU while scrolling: app \(used.app / busy * 100, format: .fixed(precision: 1), privacy: .public)%, replayd \(used.replayd.map { String(format: "%.1f%%", $0 / busy * 100) } ?? "n/a", privacy: .public)")
        } catch {
            Log.app.error("debug.scroll-demo failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The scrolling capture's own flow on the demo window, all of it behind the desktop picture: the
    /// coordinator, its panel (rendered midway), and Done, which writes the picture to the snapshot folder.
    static func runFlow(
        _ options: Options, coordinator: ScrollingCaptureCoordinator, display: DisplayInfo, dark: Bool, render: @escaping (NSWindow, String) async -> Void
    ) async {
        let window = DemoWindow(options)
        window.orderFront(nil)
        defer { window.letGo() }
        try? await Task.sleep(for: .milliseconds(300))
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let source = ScrollingCapture.Source(
                filter: filter, sourceRect: nil, pixelWidth: Int((filter.contentRect.width * scale).rounded()),
                pixelHeight: Int((filter.contentRect.height * scale).rounded()), pixelsPerPoint: scale, frame: window.frame, displayID: display.id
            )
            await coordinator.debugStart(source, on: display, savingTo: DebugHooks.snapshotDirectory, appearance: NSAppearance(named: dark ? .darkAqua : .aqua))
            try? await Task.sleep(for: .milliseconds(300))
            await window.scrollThrough(options) {
                await render(coordinator.debugPanelWindow, "scroll-panel")
            }
            try? await Task.sleep(for: .milliseconds(500))
            coordinator.finish()
            try? await Task.sleep(for: .milliseconds(1500))
        } catch {
            Log.app.error("debug.scroll-flow failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A long scrolling capture made up in memory, nothing shown and nothing read: views `width` × `height` pixels
    /// of a page `length` pixels long beside a sidebar that never moves, scrolled 96 to 128 pixels a view, through
    /// the stitcher capped at `maxMB`, then the picture, its PNG, and the card's thumbnail, as a capture's
    /// delivery makes them. Logs how long each took and the app's footprint at each; nothing is kept.
    static func runLong(width: Int, height: Int, length: Int, maxMB: Int) async {
        let before = Memory.footprint()
        // The footprint at its highest while each part runs.
        let peak = PeakWatch()
        let line = await Task.detached(priority: .userInitiated) { () -> String in
            let lineBytes = width * 4
            // A page of text-like rows, 4096 of them repeated down the page, each row told apart by its number
            // written in black and white beside the sidebar.
            let tileRows = 4096
            // Its own buffers mapped and unmapped, so the allocator keeps none of them after.
            guard let tileBuffer = PageBuffer(byteCount: width * tileRows * 4), let sidebarBuffer = PageBuffer(byteCount: 640 * height * 4),
                  let viewBuffer = PageBuffer(byteCount: lineBytes * height) else { return "no memory" }
            let tile = UnsafeMutableBufferPointer(start: tileBuffer.bound(to: UInt32.self, count: width * tileRows), count: width * tileRows)
            tile.update(repeating: 0xFFFF_FFFF)
            var seed: UInt64 = 17
            func random(_ range: ClosedRange<Int>) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
            }
            var top = 8
            while top + 30 < tileRows {
                var x = 760 + random(0...40)
                while x < width - 160 {
                    let word = min(random(24...140), width - 160 - x)
                    let ink = UInt32(random(0x18...0x60)) * 0x010101 | 0xFF00_0000
                    for y in top + random(0...3) ..< top + 26 - random(0...3) {
                        (tile.baseAddress! + y * width + x).update(repeating: ink &+ UInt32(y % 5), count: word)
                    }
                    x += word + random(12...28)
                }
                top += random(36...48)
            }
            // The sidebar: an item every 72 rows, the same on every view.
            let sidebar = UnsafeMutableBufferPointer(start: sidebarBuffer.bound(to: UInt32.self, count: 640 * height), count: 640 * height)
            sidebar.update(repeating: 0xFFF5_F5F7)
            for y in 0..<height where y % 72 >= 20 && y % 72 < 48 {
                (sidebar.baseAddress! + y * 640 + 40).update(repeating: 0xFF59_5966, count: 28)
                (sidebar.baseAddress! + y * 640 + 100).update(repeating: 0xFF40_4040 &+ UInt32(y % 3), count: 180 + y / 72 % 4 * 40)
            }
            let view = viewBuffer.baseAddress
            func fill(at offset: Int) {
                for row in 0..<height {
                    let y = offset + row
                    let target = (view + row * lineBytes).assumingMemoryBound(to: UInt32.self)
                    memcpy(target, tile.baseAddress! + (y % tileRows) * width, lineBytes)
                    memcpy(target, sidebar.baseAddress! + row * 640, 640 * 4)
                    for bit in 0..<24 { (target + 700 + bit * 2).update(repeating: y >> bit & 1 == 1 ? 0xFF00_0000 : 0xFFFF_FFFF, count: 2) }
                }
            }
            let space = CGColorSpace(name: CGColorSpace.displayP3)!
            var stitcher: ScrollStitcher? = ScrollStitcher(
                width: width, height: height, pixelsPerPoint: 2, colorSpace: space, maxBytes: maxMB << 20
            )
            var offset = 0, views = 0, lost = 0, full = false
            var step = 96
            let started = ContinuousClock.now
            fill(at: 0)
            _ = stitcher?.add(view, bytesPerRow: lineBytes)
            while offset + step + height <= length, !full {
                offset += step
                step = 96 + (step * 7 + 13) % 33
                fill(at: offset)
                switch stitcher?.add(view, bytesPerRow: lineBytes) {
                case .lost: lost += 1
                case .full: full = true
                default: break
                }
                views += 1
            }
            let stitched = ContinuousClock.now - started
            let stitchingPeak = peak.take()
            let picturing = ContinuousClock.now
            var picture = stitcher?.takePicture()
            let made = ContinuousClock.now - picturing
            let summary = stitcher?.summary ?? ""
            stitcher = nil
            let picturePeak = peak.take()
            let afterStitcher = Memory.footprint()
            guard let image = picture else { return "no picture: \(summary)" }
            let encoding = ContinuousClock.now
            var png: Data? = try? await ImageExporter.encode(image, as: .png)
            let encoded = ContinuousClock.now - encoding
            let encodingPeak = peak.take()
            let thumbnailing = ContinuousClock.now
            var thumbnail: CGImage?
            if png != nil { thumbnail = await HistoryStore.cardThumbnail(of: image, maxPixels: 560) }
            let thumbnailed = ContinuousClock.now - thumbnailing
            let thumbnailPeak = peak.take()
            let size = "\(image.width)x\(image.height)", bytes = png?.count ?? 0
            picture = nil
            png = nil
            let mb = { (value: UInt64) in value / 1_048_576 }
            return "\(size) from \(views) views (\(lost) lost\(full ? ", full" : "")), \(summary); stitched in \(stitched) (\(stitched / max(views, 1)) a view), footprint at most \(mb(stitchingPeak)) MB; picture in \(made), at most \(mb(picturePeak)) MB, \(mb(afterStitcher)) MB once the stitcher went; PNG \(bytes / 1_048_576) MB in \(encoded), at most \(mb(encodingPeak)) MB; thumbnail \(thumbnail?.width ?? 0)x\(thumbnail?.height ?? 0) in \(thumbnailed), at most \(mb(thumbnailPeak)) MB"
        }.value
        try? await Task.sleep(for: .milliseconds(500))
        peak.stop()
        Log.app.notice("debug.scroll-long \(line, privacy: .public); footprint \(before / 1_048_576, privacy: .public) MB before, \(Memory.footprint() / 1_048_576, privacy: .public) MB after")
    }

    /// Watches the app's footprint every 20 ms for its highest since last asked.
    nonisolated private final class PeakWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var highest: UInt64 = 0
        private var timer: DispatchSourceTimer?

        init() {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Memory.footprint()
                lock.lock()
                highest = max(highest, now)
                lock.unlock()
            }
            timer.resume()
            self.timer = timer
        }

        /// The highest footprint since the last time, and starting anew from now.
        func take() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let value = max(highest, Memory.footprint())
            highest = 0
            return value
        }

        func stop() {
            timer?.cancel()
            timer = nil
        }
    }

    /// How two pictures of the same page differ: lines (rows, or columns sideways) past a small tolerance, and
    /// the largest difference, leaving out `skippingEnd` pixels where a scroll bar shows at the end of each line;
    /// only `columns` of each row, when given.
    private static func compare(_ picture: CGImage, _ reference: CGImage, skippingEnd: Int, horizontal: Bool, columns: Range<Int>? = nil) -> String {
        guard picture.width == reference.width, picture.height == reference.height else { return "sizes differ" }
        let width = picture.width, height = picture.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        let a = pixels(picture), b = pixels(reference)
        let lines = horizontal ? width : height
        var differing = 0
        var largest = 0
        var first: Int?
        var last = 0
        for line in 0..<lines {
            var worst = 0
            let across = horizontal ? height - skippingEnd : width - skippingEnd
            for position in columns ?? 0..<max(across, 0) {
                let (x, y) = horizontal ? (line, position) : (position, line)
                let index = (y * width + x) * 4
                for channel in 0..<3 { worst = max(worst, abs(Int(a[index + channel]) - Int(b[index + channel]))) }
            }
            largest = max(largest, worst)
            if worst > 24 {
                differing += 1
                if first == nil { first = line }
                last = line
            }
        }
        return "\(differing) of \(lines) lines differ past 24\(first.map { " (\($0)…\(last))" } ?? ""), largest difference \(largest)"
    }
}

/// A borderless window behind the desktop picture: a bar, a scroll view of made-up text, a bar; or a forum.
@MainActor
private final class DemoWindow: NSWindow {
    private let options: DebugScrollingDemo.Options
    private let scrollView = NSScrollView()
    private let page: PageView
    private let header = BarView(color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1), title: "Sticky Header")
    private let footer = BarView(color: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1), title: "Footer that stays")
    private let sidebar = SidebarView()
    private let badge = BadgeView()
    /// The forum's posts, their avatars over the page, and the timeline right of it.
    private let posts: [ForumPost]
    private let avatarLayer = FlippedView()
    private var avatars: [AvatarView] = []
    private let timeline = TimelineView()
    private var firstTimeline: CGImage?
    private static let sidebarWidth: CGFloat = 160
    private static let timelineWidth: CGFloat = 120

    init(_ options: DebugScrollingDemo.Options) {
        self.options = options
        let size = options.size
        let forum = options.forum && !options.horizontal
        let side = (options.sidebar || forum) && !options.horizontal ? Self.sidebarWidth : 0
        let right = forum ? Self.timelineWidth : 0
        posts = forum ? ForumPost.layout(height: 3200) : []
        page = PageView(frame: options.horizontal
            ? CGRect(x: 0, y: 0, width: 4200, height: size.height)
            : CGRect(x: 0, y: 0, width: size.width - side - right, height: 3200), posts: posts)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        isReleasedWhenClosed = false
        hasShadow = false
        animationBehavior = .none
        if let screen = NSScreen.screens.first {
            setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        }
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        scrollView.documentView = page
        scrollView.hasVerticalScroller = options.scrollBars && !options.horizontal
        scrollView.hasHorizontalScroller = options.scrollBars && options.horizontal
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        if options.horizontal {
            header.frame = CGRect(x: 0, y: 0, width: options.header, height: size.height)
            scrollView.frame = CGRect(x: options.header, y: 0, width: size.width - options.header - options.footer, height: size.height)
            footer.frame = CGRect(x: size.width - options.footer, y: 0, width: options.footer, height: size.height)
        } else {
            // y up: the header at the top.
            let bottom = forum ? 0 : options.footer
            header.frame = CGRect(x: 0, y: size.height - options.header, width: size.width, height: options.header)
            scrollView.frame = CGRect(x: side, y: bottom, width: size.width - side - right, height: size.height - options.header - bottom)
            footer.frame = CGRect(x: 0, y: 0, width: size.width, height: bottom)
            sidebar.frame = CGRect(x: 0, y: bottom, width: side, height: size.height - options.header - bottom)
            badge.frame = CGRect(x: side + 10, y: size.height - options.header - 6 - 36, width: 36, height: 36)
        }
        for view in [header, scrollView, footer] { content.addSubview(view) }
        if side > 0 {
            content.addSubview(sidebar)
            if !forum { content.addSubview(badge) }
        }
        if forum {
            // The avatars over the page, kept to it; the timeline right of it.
            avatarLayer.frame = scrollView.frame
            avatarLayer.wantsLayer = true
            avatarLayer.layer?.masksToBounds = true
            for (index, post) in posts.enumerated() {
                let avatar = AvatarView(index: index, letter: post.letter, scale: NSScreen.screens.first?.backingScaleFactor ?? 2)
                avatarLayer.addSubview(avatar)
                avatars.append(avatar)
            }
            content.addSubview(avatarLayer)
            timeline.frame = CGRect(x: size.width - right, y: 0, width: right, height: size.height - options.header)
            timeline.widgetHeight = (size.height - options.header) * options.timeline
            content.addSubview(timeline)
            arrange(offset: 0)
            firstTimeline = timeline.picture(scale: NSScreen.screens.first?.backingScaleFactor ?? 2)
        }
        contentView = content
    }

    /// The timeline's columns in the picture, in pixels.
    func timelineColumns(scale: CGFloat) -> Range<Int> {
        Int(((options.size.width - Self.timelineWidth) * scale).rounded()) ..< Int((options.size.width * scale).rounded())
    }

    /// Puts the forum's avatars and the timeline's handle where they are with the page scrolled to `offset`: an
    /// avatar where its post begins, stuck 6 points below the header while its post goes on under it, pushed out
    /// by its post's end.
    private func arrange(offset: CGFloat) {
        guard options.forum, !options.horizontal else { return }
        for (avatar, post) in zip(avatars, posts) {
            let top = min(max(post.top + 8 - offset, 6), post.top + post.height - offset - AvatarView.size)
            avatar.frame = CGRect(x: 10, y: top, width: AvatarView.size, height: AvatarView.size)
        }
        let end = page.frame.height - scrollView.contentView.bounds.height
        timeline.progress = end > 0 ? min(max(offset / end, 0), 1) : 0
    }

    /// Closes the window and lets its page go, which AppKit may hold on to a while with the window.
    func letGo() {
        close()
        page.letGo()
        contentView = nil
    }

    /// Scrolls to the end in steps, as a trackpad would (and back, or with a jump, as asked); `halfway` runs
    /// once, half the steps in.
    func scrollThrough(_ options: DebugScrollingDemo.Options, halfway: (() async -> Void)? = nil) async {
        let clip = scrollView.contentView
        let end = options.horizontal ? page.frame.width - clip.bounds.width : page.frame.height - clip.bounds.height
        var offset: CGFloat = 0
        var positions: [CGFloat] = []
        // A forum is scrolled in steps that vary, as a trackpad's do.
        var seed: UInt64 = 5
        while offset < end {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let step = options.forum ? (options.step * (0.4 + Double((seed >> 33) % 120) / 100)).rounded() : options.step
            offset = min(offset + step, end)
            positions.append(offset)
        }
        if options.jump, positions.count > 8 {
            // Far past the view and back to where it was.
            let middle = positions.count / 2
            positions.insert(contentsOf: [min(positions[middle] + 3 * clip.bounds.height, end), positions[middle]], at: middle + 1)
        }
        if options.back {
            var back = end
            while back > end * 0.6 {
                back -= options.step
                positions.append(back)
            }
        }
        for (index, position) in positions.enumerated() {
            if index == positions.count / 2 { await halfway?() }
            let point = options.horizontal ? NSPoint(x: position, y: 0) : NSPoint(x: 0, y: position)
            clip.scroll(to: point)
            scrollView.reflectScrolledClipView(clip)
            arrange(offset: position)
            displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(options.interval))
        }
    }

    /// The window's own drawing of what the picture should be: the bars around the whole page; with the
    /// sidebar, the sidebar and the badge once, as the first view showed them, and the sidebar's ground below.
    func reference() -> CGImage? {
        if options.forum, !options.horizontal {
            return forumReference()
        }
        guard let header = image(of: header), let page = page.picture, let footer = image(of: footer) else { return nil }
        if options.sidebar, !options.horizontal, let side = image(of: sidebar), let badge = image(of: badge) {
            let scale = backingScaleFactor
            let width = side.width + page.width
            let height = header.height + page.height + footer.height
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            // y up: the footer at the bottom, the page over the rest, the sidebar beside its top.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let top = CGFloat(footer.height + page.height)
            context.draw(footer, in: CGRect(x: 0, y: 0, width: footer.width, height: footer.height))
            context.draw(page, in: CGRect(x: side.width, y: footer.height, width: page.width, height: page.height))
            context.draw(side, in: CGRect(x: 0, y: top - CGFloat(side.height), width: CGFloat(side.width), height: CGFloat(side.height)))
            context.draw(badge, in: CGRect(x: CGFloat(side.width) + 10 * scale, y: top - (6 + 36) * scale, width: CGFloat(badge.width), height: CGFloat(badge.height)))
            context.draw(header, in: CGRect(x: 0, y: top, width: CGFloat(header.width), height: CGFloat(header.height)))
            return context.makeImage()
        }
        let horizontal = options.horizontal
        let width = horizontal ? header.width + page.width + footer.width : page.width
        let height = horizontal ? page.height : header.height + page.height + footer.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        if horizontal {
            context.draw(header, in: CGRect(x: 0, y: 0, width: header.width, height: header.height))
            context.draw(page, in: CGRect(x: header.width, y: 0, width: page.width, height: page.height))
            context.draw(footer, in: CGRect(x: header.width + page.width, y: 0, width: footer.width, height: footer.height))
        } else {
            // y up: the header at the top.
            context.draw(footer, in: CGRect(x: 0, y: 0, width: footer.width, height: footer.height))
            context.draw(page, in: CGRect(x: 0, y: footer.height, width: page.width, height: page.height))
            context.draw(header, in: CGRect(x: 0, y: footer.height + page.height, width: header.width, height: header.height))
        }
        return context.makeImage()
    }

    /// The forum as the picture should be: the header, the page with each avatar where its post begins, and
    /// beside its top the sidebar and the timeline as the first view showed them, their ground below.
    private func forumReference() -> CGImage? {
        guard let header = image(of: header), let page = page.picture, let side = image(of: sidebar), let timeline = firstTimeline else { return nil }
        let scale = backingScaleFactor
        let width = side.width + page.width + timeline.width
        let height = header.height + page.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // y up: the page under the header, the sidebar and the timeline beside its top.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let top = CGFloat(page.height)
        context.draw(page, in: CGRect(x: side.width, y: 0, width: page.width, height: page.height))
        for (avatar, post) in zip(avatars, posts) {
            guard let picture = avatar.picture else { continue }
            let size = AvatarView.size * scale
            context.draw(picture, in: CGRect(x: CGFloat(side.width) + 10 * scale, y: top - (post.top + 8) * scale - size, width: size, height: size))
        }
        context.draw(side, in: CGRect(x: 0, y: top - CGFloat(side.height), width: CGFloat(side.width), height: CGFloat(side.height)))
        context.draw(timeline, in: CGRect(x: CGFloat(side.width + page.width), y: top - CGFloat(timeline.height), width: CGFloat(timeline.width), height: CGFloat(timeline.height)))
        context.draw(header, in: CGRect(x: 0, y: top, width: CGFloat(header.width), height: CGFloat(header.height)))
        return context.makeImage()
    }

    private func image(of view: NSView) -> CGImage? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }
}

/// A view whose subviews stand from the top down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A forum post: where it begins on the page, how tall it is, and whether its author's avatar is a letter on a
/// plain disc rather than a picture.
private struct ForumPost {
    var top: CGFloat
    var height: CGFloat
    var letter: Bool

    /// Posts down a page `height` points tall, under a banner: long and short ones, every other avatar a letter.
    static func layout(height: CGFloat) -> [ForumPost] {
        var posts: [ForumPost] = []
        var top: CGFloat = 76
        for (index, length) in [1060, 300, 820, 420, 640, 360].enumerated() {
            let length = min(CGFloat(length), height - top)
            guard length > 120 else { break }
            posts.append(ForumPost(top: top, height: length, letter: !index.isMultiple(of: 2)))
            top += length + 12
        }
        return posts
    }
}

/// A post's avatar, 40 points: a picture, or a letter on a plain disc. Drawn once, as its layer's picture.
private final class AvatarView: NSView {
    static let size: CGFloat = 40
    private(set) var picture: CGImage?

    init(index: Int, letter: Bool, scale: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        let pixels = Int(Self.size * scale)
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        if let context {
            let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.addEllipse(in: bounds)
            context.clip()
            if letter {
                context.setFillColor(CGColor(srgbRed: 0.23, green: 0.48, blue: 0.84, alpha: 1))
                context.fill(bounds)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let mark = NSAttributedString(string: ["A", "M", "K"][index % 3], attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 22 * scale), .foregroundColor: NSColor.white,
                ])
                let size = mark.size()
                mark.draw(at: CGPoint(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2))
                NSGraphicsContext.restoreGraphicsState()
            } else {
                // A picture: a sky going from violet to orange, a sun, a hill.
                let colors = [CGColor(srgbRed: 0.33, green: 0.2, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.98, green: 0.6, blue: 0.35, alpha: 1)] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(pixels)), end: .zero, options: [])
                }
                context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1))
                context.fillEllipse(in: CGRect(x: CGFloat(pixels) * 0.55, y: CGFloat(pixels) * 0.45, width: CGFloat(pixels) * 0.25, height: CGFloat(pixels) * 0.25))
                context.setFillColor(CGColor(srgbRed: 0.18, green: 0.15 + 0.05 * CGFloat(index % 3), blue: 0.3, alpha: 1))
                context.fillEllipse(in: CGRect(x: -CGFloat(pixels) * 0.3, y: -CGFloat(pixels) * 0.6, width: CGFloat(pixels) * 1.6, height: CGFloat(pixels) * 0.95))
            }
        }
        picture = context?.makeImage()
        wantsLayer = true
        layer?.contents = picture
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A forum's timeline that never moves, right of the page: a track `widgetHeight` tall with the topic's first
/// and last dates, and a handle that creeps down it as the page scrolls.
private final class TimelineView: NSView {
    var widgetHeight: CGFloat = 200 {
        didSet { needsDisplay = true; placeHandle() }
    }
    /// How far down the page the view is, 0 to 1.
    var progress: CGFloat = 0 {
        didSet { placeHandle() }
    }
    private let handle = NSView()
    private var handlePicture: CGImage?
    private static let handleSize = CGSize(width: 90, height: 36)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let size = CGSize(width: Self.handleSize.width * scale, height: Self.handleSize.height * scale)
        if let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4 * scale, height: size.height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "12 / 80", attributes: [.font: NSFont.boldSystemFont(ofSize: 12 * scale), .foregroundColor: NSColor.darkGray])
                .draw(at: CGPoint(x: 12 * scale, y: 10 * scale))
            NSGraphicsContext.restoreGraphicsState()
            handlePicture = context.makeImage()
        }
        handle.wantsLayer = true
        handle.layer?.contents = handlePicture
        handle.layer?.contentsGravity = .resize
        addSubview(handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var track: CGRect { CGRect(x: 20, y: 30, width: 2, height: max(widgetHeight - 60, 10)) }

    private func placeHandle() {
        let track = self.track
        handle.frame = CGRect(x: track.minX, y: track.minY + (track.height - Self.handleSize.height) * progress, width: Self.handleSize.width, height: Self.handleSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        track.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.gray]
        ("Oct 2" as NSString).draw(at: CGPoint(x: 16, y: 10), withAttributes: attributes)
        ("2h ago" as NSString).draw(at: CGPoint(x: 16, y: track.maxY + 6), withAttributes: attributes)
    }

    /// The timeline as it shows now, handle and all, at `scale` pixels a point.
    func picture(scale: CGFloat) -> CGImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        guard let still = bitmap.cgImage, let handlePicture, let context = CGContext(
            data: nil, width: still.width, height: still.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(still, in: CGRect(x: 0, y: 0, width: still.width, height: still.height))
        // y up in the context: the handle's frame counts from the top.
        let frame = handle.frame
        context.draw(handlePicture, in: CGRect(x: frame.minX * scale, y: CGFloat(still.height) - frame.maxY * scale, width: frame.width * scale, height: frame.height * scale))
        return context.makeImage()
    }
}

/// A sidebar that never moves: the same item over and over, as a forum's list of topics, on white.
private final class SidebarView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray]
        var y: CGFloat = 10
        var index = 0
        while y < bounds.height - 20 {
            NSColor(srgbRed: 0.35, green: 0.35, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 14, y: y + 3, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
            // Most items are alike; every fifth says something else.
            let title: NSString = index % 5 == 4 ? "Messages \(index)" as NSString : "Topics"
            title.draw(at: CGPoint(x: 34, y: y), withAttributes: attributes)
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: CGRect(x: 120, y: y + 7, width: 5, height: 5)).fill()
            y += 36
            index += 1
        }
    }
}

/// A badge stuck over the page, as a post's avatar sticks while the post scrolls.
private final class BadgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.18, green: 0.55, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        ("A" as NSString).draw(at: CGPoint(x: 11, y: 8), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
    }
}

/// A bar that stays put: a color and a title.
private final class BarView: NSView {
    private let color: NSColor
    private let title: String

    init(color: NSColor, title: String) {
        self.color = color
        self.title = title
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        (title as NSString).draw(at: CGPoint(x: 12, y: (bounds.height - 16) / 2), withAttributes: attributes)
    }
}

/// A page of made-up text in a grid of cells: words and numbers of varying lengths, some in code colors. It is
/// drawn once, whole, as its layer's picture: a window behind the desktop picture never draws what scrolls
/// into view on demand, so a page drawn as it scrolls showed blank parts in the stream.
private final class PageView: NSView {
    private(set) var picture: CGImage?

    /// With `posts`, a forum's page: a banner, then the posts, their text right of the avatars' margin.
    init(frame: CGRect, posts: [ForumPost] = []) {
        super.init(frame: frame)
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        picture = posts.isEmpty ? Self.draw(size: frame.size, scale: scale) : Self.drawForum(size: frame.size, scale: scale, posts: posts)
        wantsLayer = true
        layer?.contents = picture
        layer?.contentsScale = scale
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = picture
    }

    /// Drops the page's picture, which would otherwise stay as long as AppKit keeps the closed window.
    func letGo() {
        picture = nil
        layer?.contents = nil
    }

    private static func drawForum(size: CGSize, scale: CGFloat, posts: [ForumPost]) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // The banner atop the page: a pale blue band, a line of text in it.
        NSColor(srgbRed: 0.85, green: 0.93, blue: 0.99, alpha: 1).setFill()
        CGRect(x: 12, y: 12, width: size.width - 24, height: 44).fill()
        NSAttributedString(string: "Be kind, be helpful, be clear. Read the community guidelines.", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ]).draw(at: CGPoint(x: 30, y: 24))
        let words = "the forum keeps scrolling while every post is read once and the picture grows at its end 2026 42 3.14 reply quote".split(separator: " ")
        var seed: UInt64 = 33
        func random(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
        }
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.1, alpha: 1)]
        for (index, post) in posts.enumerated() {
            NSAttributedString(string: "member\(index * 7 + 3)", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
                .draw(at: CGPoint(x: 70, y: post.top + 10))
            var y = post.top + 36
            while y < post.top + post.height - 36 {
                switch random(0...11) {
                case 0 where y + 150 < post.top + post.height - 30:
                    // A picture: an evening sky in a box.
                    let box = CGRect(x: 70, y: y, width: min(320, size.width - 100), height: 140)
                    NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.22, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.97, green: 0.62, blue: 0.38, alpha: 1)])?
                        .draw(in: box, angle: -90)
                    NSColor(srgbRed: 0.2, green: 0.16, blue: 0.3, alpha: 1).setFill()
                    CGRect(x: box.minX, y: box.maxY - 30, width: box.width, height: 30).fill()
                    y += 152
                case 1 where y + 80 < post.top + post.height - 30:
                    // A quote: a gray box with a bar down its left, alike from top to bottom.
                    let box = CGRect(x: 70, y: y, width: size.width - 100, height: 64)
                    NSColor(white: 0.95, alpha: 1).setFill()
                    box.fill()
                    NSColor(white: 0.75, alpha: 1).setFill()
                    CGRect(x: box.minX, y: box.minY, width: 4, height: box.height).fill()
                    (String(words[random(0...words.count - 1)]) + " " + String(words[random(0...words.count - 1)]) as NSString)
                        .draw(at: CGPoint(x: 84, y: y + 22), withAttributes: text)
                    y += 76
                default:
                    var x: CGFloat = 70
                    while x < size.width - 90 {
                        let attributed = NSAttributedString(string: String(words[random(0...words.count - 1)]), attributes: text)
                        attributed.draw(at: CGPoint(x: x, y: y))
                        x += attributed.size().width + 5
                    }
                    y += 22
                }
            }
            // The post's end: a hairline across.
            NSColor(white: 0.88, alpha: 1).setFill()
            CGRect(x: 10, y: post.top + post.height + 5, width: size.width - 20, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func draw(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Drawn in points from the top left, as a flipped view would.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let words = "the screen keeps scrolling while every line is taken in once and the picture grows at its end with headers kept on top 2026 42 3.14 OhMyShot".split(separator: " ")
        let inks: [NSColor] = [.black, NSColor(srgbRed: 0.67, green: 0.05, blue: 0.57, alpha: 1), NSColor(srgbRed: 0.11, green: 0.27, blue: 0.82, alpha: 1), NSColor(srgbRed: 0.2, green: 0.5, blue: 0.2, alpha: 1)]
        var seed: UInt64 = 21
        func random(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
        }
        var y: CGFloat = 12
        var row = 0
        while y < size.height - 24 {
            var x: CGFloat = 14 + CGFloat(random(0...20))
            while x < size.width - 80 {
                let count = random(1...4)
                let text = (0..<count).map { _ in String(words[random(0...words.count - 1)]) }.joined(separator: " ") + " \(row)"
                let attributed = NSAttributedString(string: text, attributes: [
                    .font: random(0...5) == 0 ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13),
                    .foregroundColor: inks[random(0...3) == 0 ? random(1...3) : 0],
                ])
                attributed.draw(at: CGPoint(x: x, y: y))
                x += attributed.size().width + CGFloat(random(18...60))
            }
            y += CGFloat(random(20...28))
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
#endif
