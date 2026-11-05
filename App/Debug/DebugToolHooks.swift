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

/// Endpoints for pins, Measure, and Pick Color.
extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleToolHook(_ hook: String, _ url: URL) -> Bool {
        switch hook {
        case "pin-demo":
            // Pins the drawn page, never anything from the screen or the clipboard: centered on the pointer's
            // display, or with x, y over that point in display points from its top-left corner, at 1:1.
            pinDemo(at: ["x", "y"].compactMap { Self.intParameter($0, in: url) })
        case "pin-text-demo":
            // Pins fixed demo text, never the clipboard's: code=1 for an indented snippet, long=1 for a
            // paragraph that wraps at the card's width.
            let has = { (name: String) in Self.parameter(name, in: url) == "1" }
            let text = has("code")
                ? "func pinned() {\n    let shortcut = \"⌃⌥⌘7\"\n    print(\"Capture Area and Pin: \\(shortcut)\")\n}"
                : has("long")
                    ? "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。Quick Access keeps every capture one click away; the text in a capture can be copied, edited, and searched."
                    : "brew install --cask ohmyshot"
            pins.pin(text: text)
            Log.app.notice("debug.pin-text-demo \(self.pins.debugSummary, privacy: .public)")
        case "pin-color-demo":
            // Pins a fixed color, never the clipboard's: hex=RRGGBB[AA] (no #), default the accent-like blue.
            let hex = Self.parameter("hex", in: url) ?? "3366FF"
            if let color = PinColor.parse("#" + hex) {
                pins.pin(color: color)
            }
            Log.app.notice("debug.pin-color-demo \(self.pins.debugSummary, privacy: .public)")
        case "pin-render":
            // Draws a pin behind the desktop picture and captures its window alone, nothing shown:
            // kind=text|line|narrow|code|color|alpha|page (the drawn demo page as a picture),
            // zoom=<percent>, mode=light|dark, controls=1 for Close and More as on hover, select=all to
            // read a picture's text with Live Text and select all of it, select=part to select part of a
            // card's text. Writes pin-render-<kind>-<zoom>-<mode>[-controls][-select|-part].png to the
            // snapshot folder.
            let value = { (name: String) in Self.parameter(name, in: url) }
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
            guard let content else { return true }
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
            let target = Self.parameter("at", in: url)
            Task { await openColorDemo(at: target == "square" ? DebugToolsDemo.square : DebugToolsDemo.button) }
        case "color-pick":
            // Takes the color at the crosshair, as a click would (option=1: as an Option-click); the clipboard
            // is left alone whenever the session was opened by color-demo. The overlay logs what it took.
            let option = Self.intParameter("option", in: url) == 1
            if let point = overlay.debugPointer { overlay.simulatePick(at: point, modifiers: option ? .option : []) }
        case "color-card":
            // The color card behind the desktop picture, captured alone, nothing shown: hex=RRGGBB (default
            // 3366FF), against=RRGGBB for the contrast, mode=light|dark. Writes color-card-<mode>.png.
            let value = { (name: String) in Self.parameter(name, in: url) }
            let mode = value("mode") ?? "light"
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
            // p3=r,g,b (0...1) for a Display P3 color, which a hex cannot name.
            let p3 = value("p3")?.split(separator: ",").compactMap { Double($0) }
            let color = p3.flatMap { $0.count == 3 ? CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: $0.map { CGFloat($0) } + [1]) : nil }
                .flatMap(ScreenColor.init) ?? PinColor.parse("#" + (value("hex") ?? "3366FF")).flatMap { ScreenColor($0.original) }
            let other = value("against").flatMap { PinColor.parse("#" + $0) }.flatMap { ScreenColor($0.original) }
            guard let color, let window = colorPicker.debugHiddenCard(color, against: other) else { return true }
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
            let value = { (name: String) in Self.parameter(name, in: url) }
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
        default:
            return false
        }
        return true
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
}
#endif
