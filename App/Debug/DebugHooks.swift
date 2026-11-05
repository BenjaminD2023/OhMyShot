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
    /// Types into the open Settings window's search field.
    let searchSettings: (String) -> Void
    let showOnboarding: (OnboardingWindowController.Step, (hotKeys: () -> [String: Any]?, bindings: @MainActor () -> [SystemScreenshotKeys.Binding])?) -> Void
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
    let historySearch: HistorySearchHooks
    let textCapture: TextCaptureCoordinator
    let annotations: AnnotationCoordinator
    let pins: PinController
    let colorPicker: ColorPickerCoordinator
    let measurer: MeasureCoordinator
    let recordings: RecordingCoordinator
    let scrolling: ScrollingCaptureCoordinator
    let settings: SettingsStore
    let uploads: UploadCoordinator
    let desktopIcons: DesktopCover
    /// Deletes the captures the scripted checks made in the last few hours (the apps "Demo" and "Test"),
    /// and says how many.
    let removeCheckCaptures: () -> Int
    /// Runs a URL API command as if it had come in through the URL scheme, past its approval prompt.
    let perform: (AutomationCommand) -> Void
    /// What the URL API's `action=upload` does with a capture just kept.
    let uploadAfterCapture: (HistoryItem) -> Void
    /// Runs what a global shortcut does, as if its keys were pressed.
    let pressShortcut: (CaptureShortcut) -> Void
    /// The newest capture's id in the history.
    let latestCaptureID: () -> UUID?
    /// The replay's coordinator on macOS 27, as any object.
    let replay: () -> AnyObject?
    /// What the Shortcuts action Recognize Formula in Image answers for a picture's data.
    let shortcutFormula: (Data) async throws -> String?
    /// What the Shortcuts action Recognize Text in Image answers for a picture's data, its line breaks kept.
    let shortcutText: (Data) async throws -> String?
    /// Puts scripted checks' cloud models in place of the person's, or the person's back with nil.
    let setCloudDemo: (CloudModelStore?) -> Void
    /// Adds a model to the scripted checks' cloud models, with its key, agreed.
    let addCloudDemoModel: (CloudModel, String?) -> Void

    /// Capture History's search, for scripted checks on the hook's own test pictures.
    struct HistorySearchHooks {
        /// Adds a picture file to the history as a screenshot taken in "OhMyShot Test", read as a capture is.
        let add: (URL) -> Void
        /// Removes every picture `add` added.
        let removeTests: () -> Void
        /// How a search of the whole history comes out, as a log line.
        let search: (String) -> String
        let read: () -> Void
        /// Captures being read now.
        let reading: () -> Int
        /// Types into the History window's search field.
        let setQuery: (String) -> Void
        /// Chooses the History window's Show filter by name.
        let setFilter: (String) -> Void
    }

    /// Where `snapshot` writes window captures.
    static let snapshotDirectory = AppFolders.caches.appending(path: "debug-snapshots", directoryHint: .isDirectory)

    /// Runs the hook `url` names, in the file of the feature it belongs to.
    func handle(_ url: URL) {
        let hook = url.pathComponents.dropFirst().first ?? ""
        let handled = handleAppHook(hook, url) || handleHistoryHook(hook, url) || handleCaptureHook(hook, url) || handleTextHook(hook, url)
            || handleEditorHook(hook, url) || handleToolHook(hook, url) || handleRecordingHook(hook, url) || handleScrollingHook(hook, url)
            || handleUploadHook(hook, url) || handleCloudHook(hook, url) || handleAppTextHook(hook, url) || handleAccessibilityHook(hook, url)
        if !handled { Log.app.error("debug.unknown \(hook, privacy: .public)") }
    }

    /// The app itself: its displays, permissions, windows, menus, icons, and memory. Returns true when `hook` was one of these.
    private func handleAppHook(_ hook: String, _ url: URL) -> Bool {
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
        case "draw-windows":
            drawWindows()
        case "settings":
            let tab = url.pathComponents.dropFirst(2).first.flatMap(SettingsTab.init(rawValue:)) ?? .general
            showSettings(tab)
        case "settings-search":
            searchSettings(Self.parameter("q", in: url) ?? "")
        case "onboarding":
            // step=shortcuts opens on macOS's screenshot keys. keys=on (as on a Mac where they were never changed), off
            // (all five turned off), or mixed (only ⇧⌘3's turned off) shows made-up hot keys against the release build's default shortcuts, in place of
            // the Mac's hot keys (never written) and this build's ⌃⌥⌘ keys, which never clash.
            // act=escape sends the open onboarding window what Escape sends when no button answers it.
            if Self.parameter("act", in: url) == "escape" {
                let window = NSApp.windows.first { $0.isVisible && $0.windowController is OnboardingWindowController }
                let handled = window.map { ($0.firstResponder ?? $0).tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) } ?? false
                Log.app.notice("debug.onboarding escape handled=\(handled, privacy: .public) open=\(NSApp.windows.contains { $0.isVisible && $0.windowController is OnboardingWindowController }, privacy: .public)")
                return true
            }
            let step: OnboardingWindowController.Step = Self.parameter("step", in: url) == "shortcuts" ? .shortcuts : .permission
            let off = Dictionary(uniqueKeysWithValues: ["28", "29", "30", "31", "184"].map { ($0, ["enabled": false] as [String: Any]) })
            let release: @MainActor () -> [SystemScreenshotKeys.Binding] = { SystemScreenshotKeys.defaultBindings(for: .release) }
            switch Self.parameter("keys", in: url) {
            case "on": showOnboarding(step, ({ nil }, release))
            case "off": showOnboarding(step, ({ off }, release))
            case "mixed": showOnboarding(step, ({ ["28": ["enabled": false]] }, release))
            default: showOnboarding(step, nil)
            }
        case "appearance":
            // mode=dark|light; anything else follows the system again.
            let mode = Self.parameter("mode", in: url)
            NSApp.appearance = switch mode {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }
            Log.app.notice("debug.appearance \(mode ?? "system", privacy: .public)")
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
        case "end-event-wait":
            // An event of the app's own, as the user's next click would bring: what waited on the run loop's
            // autorelease pool and current event goes. Scripted runs never bring one (the app is never active).
            MemoryRelief.endEventWait()
            Log.app.notice("debug.end-event-wait posted")
        case "relaunch":
            Relauncher.relaunch()
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
            let icon = Self.parameter("source", in: url) == "workspace"
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
        case "menu-act":
            // title= a main-menu item's title as shown ("…" included), window= part of the title of the window it goes
            // to (else the key window), sent as the menu would: for commands with no key or button of their own here.
            let title = Self.parameter("title", in: url) ?? ""
            let window = Self.parameter("window", in: url)
                .flatMap { part in NSApp.windows.first { $0.isVisible && $0.title.contains(part) } } ?? NSApp.keyWindow
            let item = NSApp.mainMenu.flatMap { Self.menuItem(titled: title, in: $0) }
            // activate=1 brings the app forward first, so the window is key and the command goes as the menu sends it.
            if Self.hasParameter("activate", in: url) { NSApp.activate() }
            window?.makeKeyAndOrderFront(nil)
            let handled = item?.action.map { action in
                window?.isKeyWindow == true
                    ? NSApp.sendAction(action, to: item?.target, from: item)
                    : window?.firstResponder?.tryToPerform(action, with: item) ?? false
            } ?? false
            Log.app.notice("debug.menu-act \(title, privacy: .public) window=\(window?.title ?? "none", privacy: .public) found=\(item != nil, privacy: .public) handled=\(handled, privacy: .public)")
        case "end-sheets":
            // Cancel on every sheet open on our windows (a print panel, Image Size), pressed as a person would.
            for window in NSApp.windows {
                guard let sheet = window.attachedSheet else { continue }
                let cancel = Self.button(in: sheet.contentView) { $0.keyEquivalent == "\u{1b}" || $0.title == "Cancel" }
                if let cancel { cancel.performClick(nil) } else { window.endSheet(sheet, returnCode: .cancel) }
                Log.app.notice("debug.end-sheets \(window.title, privacy: .public) pressed=\(cancel != nil, privacy: .public)")
            }
        case "close-windows":
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                window.performClose(nil)
            }
            textCapture.closeLens()
            // A demo's overlay too (Measure, Pick Color), as Escape would.
            if overlay.isActive { overlay.cancel() }
        default:
            return false
        }
        return true
    }

    private static func menuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = menuItem(titled: title, in: submenu) { return found }
        }
        return nil
    }

    private static func button(in view: NSView?, where matches: (NSButton) -> Bool) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, matches(button) { return button }
        for subview in view.subviews {
            if let found = button(in: subview, where: matches) { return found }
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

    /// Every visible window of ours, drawn by the app itself, title bar and toolbar included, as `<title>-drawn.png` in
    /// the snapshot folder: works without Screen Recording, though materials the window server blends are left plain.
    func drawWindows() {
        let directory = Self.snapshotDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible {
            guard let frame = window.contentView?.superview, let layer = frame.layer else { continue }
            let scale = window.backingScaleFactor
            let size = frame.bounds.size
            guard let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.setFillColor(window.backgroundColor.cgColor)
            context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            // Glass (a sidebar's, say) is drawn by the window server, and the layers above it with it: draw what is on it.
            func drawGlass(in view: NSView) {
                for subview in view.subviews {
                    if subview is NSGlassEffectView, let content = (subview as! NSGlassEffectView).contentView, let glassLayer = content.layer {
                        let origin = content.convert(CGPoint.zero, to: frame)
                        context.saveGState()
                        context.translateBy(x: origin.x, y: frame.isFlipped ? size.height - origin.y - content.bounds.height : origin.y)
                        glassLayer.render(in: context)
                        context.restoreGState()
                    }
                    drawGlass(in: subview)
                }
            }
            drawGlass(in: frame)
            // Lists draw their rows in layers of their own: each list as it draws itself, beside the window's picture.
            func drawLists(in view: NSView) {
                for subview in view.subviews {
                    if let table = subview as? NSTableView, let rep = table.bitmapImageRepForCachingDisplay(in: table.bounds) {
                        table.cacheDisplay(in: table.bounds, to: rep)
                        let name = (window.title.isEmpty ? "window-\(window.windowNumber)" : window.title).replacingOccurrences(of: "/", with: "-")
                        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name)-list.png"))
                    }
                    drawLists(in: subview)
                }
            }
            drawLists(in: frame)
            let name = (window.title.isEmpty ? "window-\(window.windowNumber)" : window.title).replacingOccurrences(of: "/", with: "-")
            let file = directory.appending(path: "\(name)-drawn.png")
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            Log.app.notice("debug.draw-windows \(file.path(percentEncoded: false), privacy: .public)")
            var lines: [String] = []
            func walk(_ view: NSView, _ depth: Int) {
                guard depth < 40 else { return }
                lines.append(String(repeating: " ", count: depth) + "\(type(of: view)) \(NSStringFromRect(view.frame))\(view.isHidden ? " hidden" : "")")
                view.subviews.forEach { walk($0, depth + 1) }
            }
            walk(frame, 0)
            try? lines.joined(separator: "\n").write(to: directory.appending(path: "\(name)-tree.txt"), atomically: true, encoding: .utf8)
        }
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

    /// Frames of the drawn tools screen for every display, injected so nothing real is read.
    func injectToolsDemoFrames() -> DisplayInfo? {
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

    /// The largest difference of any channel between two pictures of one size, both drawn in sRGB; nil
    /// when their sizes differ.
    static func pixelDifference(_ first: CGImage, _ second: CGImage) -> Int? {
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

    func waitForOverlayFrames() async {
        for _ in 0..<40 where overlay.isActive && !overlay.hasFrames {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    static func intParameter(_ name: String, in url: URL) -> Int? {
        parameter(name, in: url).flatMap(Int.init)
    }

    static func parameter(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// Whether the hook's URL names `name` at all, with a value or without.
    static func hasParameter(_ name: String, in url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == name } ?? false
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
