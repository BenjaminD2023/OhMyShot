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

/// Endpoints for reading text: Capture Text and Capture Formula over drawn screens or files, what the Shortcuts actions
/// read, the Recognized Text window, and Translate Area.
extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleTextHook(_ hook: String, _ url: URL) -> Bool {
        switch hook {
        case "text-test":
            // Capture Text on the same centered region as capture-test, without touching the clipboard; path=<a picture>
            // reads that file instead. The log says how many characters were read, and the formulas put in.
            let join = Self.parameter("join", in: url) == "1"
            if Self.parameter("demo", in: url) == "1", let display = displays.layout.primary,
               let image = DebugPanelDemo.image(blank: Self.parameter("blank", in: url) == "1") {
                // demo=1: the drawn demo page, as a drag over the middle of the main display reads it; cloud=1 lets the
                // cloud model read it as a person's drag would (with cloud-demo's model and capture=1).
                let rect = CGRect(x: display.frame.midX - 380, y: display.frame.midY - 280, width: 760, height: 560)
                Task {
                    await textCapture.previewRecognition(of: image, near: rect, joinLines: join, allowsCloud: Self.parameter("cloud", in: url) == "1") { text in
                        Log.app.notice("debug.text-test read \(text.map { "\($0.count) characters" } ?? "nothing", privacy: .public)")
                    }
                }
            } else if let window = Self.parameter("window", in: url).flatMap({ CGWindowID($0) }),
                      let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]])?.first,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] {
                // window=<id>: Capture Text over that window alone, as when it is picked, without touching the clipboard;
                // apptext=1 turns Text from apps on for the run. The log has the text only when only=<app name> owns the
                // window: a check must never write down the person's own windows.
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                let target = WindowTarget(id: window, frame: displays.layout.flipped(frame), ownerName: owner, title: nil)
                let shows = Self.parameter("only", in: url) == owner
                let before = settings.readsAppText
                if Self.parameter("apptext", in: url) == "1" { settings.readsAppText = true }
                if Self.parameter("panel", in: url) == "1" {
                    // panel=1: read as the Recognized Text window reads it, without opening the window.
                    let analyze = textCapture.analyzer(for: textCapture.place(ofWindow: target))
                    settings.readsAppText = before
                    Task { [capturer, displays] in
                        guard let frame = try? await capturer.captureWindow(target, shadow: false, layout: displays.layout),
                              let analysis = try? await analyze(frame.image) else { return }
                        let text = analysis.result.text
                        Log.app.notice("debug.text-test read in the window's way \(shows ? "“\(text)”" : "\(text.count) characters", privacy: .public)")
                    }
                    return true
                }
                Task {
                    await textCapture.previewRecognition(ofWindow: target, joinLines: join) { [settings] text in
                        settings.readsAppText = before
                        let said = shows ? text.map { "“\($0)”" } : text.map { "\($0.count) characters" }
                        Log.app.notice("debug.text-test read \(said ?? "nothing", privacy: .public)")
                    }
                }
            } else if let path = Self.parameter("path", in: url) {
                Task {
                    await textCapture.recognize(fileAt: URL(filePath: path), joinLines: join, copiesToClipboard: false) { text in
                        Log.app.notice("debug.text-test read \(text.map { "“\($0)”" } ?? "nothing", privacy: .public)")
                    }
                }
            } else if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await textCapture.recognize(region: rect, joinLines: join, copiesToClipboard: false) }
            }
        case "formula-test":
            // Capture Formula without touching the clipboard: path=<a picture> reads that file; without it, the same
            // centered region as capture-test. Needs the formula pack; the log says what was read, and how fast.
            let path = Self.parameter("path", in: url)
            if let path {
                Task { await textCapture.readFormula(fileAt: URL(filePath: path), copiesToClipboard: false) }
            } else if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await textCapture.readFormula(region: rect, copiesToClipboard: false) }
            }
        case "shortcut-formula":
            // path=<a picture>: what the Shortcuts action Recognize Formula in Image hands on for it, in the log.
            if let path = Self.parameter("path", in: url) {
                let shortcutFormula = shortcutFormula
                Task {
                    do {
                        let data = try Data(contentsOf: URL(filePath: path))
                        let latex = try await shortcutFormula(data)
                        Log.app.notice("debug.shortcut-formula answered \(latex.map { "“\($0)”" } ?? "nothing", privacy: .public)")
                    } catch {
                        Log.app.notice("debug.shortcut-formula failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        case "shortcut-text":
            // path=<a picture>: what the Shortcuts action Recognize Text in Image hands on for it, in the log.
            if let path = Self.parameter("path", in: url) {
                let shortcutText = shortcutText
                Task {
                    do {
                        let started = ContinuousClock.now
                        let text = try await shortcutText(Data(contentsOf: URL(filePath: path)))
                        Log.app.notice("debug.shortcut-text answered in \(String(describing: ContinuousClock.now - started), privacy: .public): \(text.map { "“\($0)”" } ?? "nothing", privacy: .public)")
                    } catch {
                        Log.app.notice("debug.shortcut-text failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        case "formula-flow":
            // Capture Formula over drawn screens, never the real one: path=<a picture> drawn at its pixels in the middle
            // of the pointer's display (on white; dark=1 on #1f1f1f), chosen without the mouse, kept off the clipboard,
            // times=N in a row. Logs each reading's LaTeX and its time from the selection's end.
            if let path = Self.parameter("path", in: url) {
                let dark = Self.parameter("dark", in: url) == "1"
                Task {
                    await runFormulaFlow(path: path, dark: dark, times: Self.intParameter("times", in: url) ?? 1)
                    // The drawn screens are gone now: their pages go back, as the overlay's own do when it closes.
                    MemoryRelief.returnFreedPages()
                }
            }
        case "text-card":
            // state=copied|empty|single|formula|no-formula: the optional result card with sample text, by a
            // centered selection; state=highlight: the selection highlight shown while text is read.
            let state = Self.parameter("state", in: url) ?? "copied"
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 210, y: display.frame.midY - 60, width: 420, height: 120)
                textCapture.previewCard(state, near: rect)
            }
        case "panel-demo":
            // The OCR panel on a drawn page (never the screen). via=file|pasteboard|finder opens it the
            // way a file, pasted image data, or a file copied in Finder would; state=loading|empty|failed|
            // unreadable|no-clipboard-image, or prose for a page without a table.
            let value = { (name: String) in Self.parameter(name, in: url) }
            Task { await openPanelDemo(via: value("via"), state: value("state")) }
        case "panel-state":
            // pane=text|table, join=0|1, select=<line>, hover=<line>, edited=1, translate=0|1,
            // target=auto|<language> (the setting itself: put it back to auto afterwards),
            // cloud=read|read2|cancel|accept|device|cloud (with the cloud-demo models)
            let value = { (name: String) in Self.parameter(name, in: url) }
            textCapture.previewPanelState(
                pane: value("pane"), joinLines: value("join").map { $0 == "1" },
                selectLine: value("select").flatMap(Int.init), hoverLine: value("hover").flatMap(Int.init),
                edited: value("edited") == "1", translate: value("translate").map { $0 == "1" }, target: value("target"),
                cloud: value("cloud")
            )
        case "translate-demo":
            // Translate Area on a drawn page (never the screen): its lens lies centered on the main
            // display. prose=0 for the page with the table; blank=1 for a page with nothing to
            // translate (it opens the panel); controls=1 shows its buttons.
            let prose = Self.parameter("prose", in: url) != "0"
            let blank = Self.parameter("blank", in: url) == "1"
            let controls = Self.parameter("controls", in: url) == "1"
            Task {
                await translateDemo(prose: prose, blank: blank)
                if controls { textCapture.revealLensControls() }
            }
        case "memory-pressure":
            // level=normal|warning|critical: what the text reader takes the system's memory pressure to be when it reads
            // tables and charts (warning or critical leaves them to Vision); off: the system's own again.
            let level = Self.parameter("level", in: url).flatMap(MemoryPressure.init(name:))
            UserDefaults.standard.set(level?.name, forKey: "debugMemoryPressure")
            Log.app.notice("debug.memory-pressure \(level?.name ?? "system's", privacy: .public) (system: \(MemoryPressure.current().name, privacy: .public))")
        case "panel-file":
            // path=: the OCR panel on that picture, as Recognize Text in Image… opens it (the window shows on screen).
            if let path = Self.parameter("path", in: url) {
                Task { await textCapture.openPanel(forFileAt: URL(filePath: path)) }
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
        case "shortcut-recognize":
            // Runs the Shortcuts action Recognize Text in Image on the drawn demo page through ShortcutsBridge, as
            // Shortcuts would; logs how much text came back (never the text). Nothing is shown or copied.
            if let png = DebugPanelDemo.png() {
                Task {
                    let breaks = Self.parameter("breaks", in: url) != "0"
                    let intent = RecognizeTextIntent()
                    intent.image = IntentFile(data: png, filename: "Demo.png", type: .png)
                    intent.keepsLineBreaks = breaks
                    do {
                        let result = try await intent.perform()
                        let text = result.value ?? nil
                        Log.app.notice("debug.shortcut-recognize \(text?.count ?? -1, privacy: .public) characters, \(text.map { $0.split(separator: "\n").count } ?? 0, privacy: .public) lines")
                    } catch {
                        Log.app.notice("debug.shortcut-recognize failed \(String(describing: error), privacy: .public)")
                    }
                }
            }
        default:
            return false
        }
        return true
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
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("\(AppIdentity.bundleIdentifier).debug"))
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

    /// A frozen screenshot over drawn screens: the drawn page frozen behind the overlay, an area chosen
    /// without the mouse, and the capture delivered with the clipboard left alone. What is kept must be
    /// the area cut from the frozen frame, pixel for pixel; then the capture and its card are removed.
    /// `formula-flow`: the picture at `path` on drawn screens, its area chosen with a 12-point margin, read by Capture
    /// Formula `times` times, each timed from the selection's end (the mouse-up) to the LaTeX.
    func runFormulaFlow(path: String, dark: Bool, times: Int) async {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary,
              let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Log.app.error("debug.formula-flow could not read \(path, privacy: .public)")
            return
        }
        let scale = display.pixelsPerPoint
        let size = CGSize(width: CGFloat(picture.width) / scale, height: CGFloat(picture.height) / scale)
        // The picture's top-left corner in the display's points from its top-left corner.
        let origin = CGPoint(x: ((display.frame.width - size.width) / 2).rounded(), y: ((display.frame.height - size.height) / 2).rounded())
        var frames: [CGDirectDisplayID: CapturedFrame] = [:]
        for each in layout.displays {
            let width = Int(each.pixelSize.width), height = Int(each.pixelSize.height)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setFillColor(dark ? CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if each.id == display.id {
                // Core Graphics is y up.
                context.draw(picture, in: CGRect(x: origin.x * scale, y: (display.frame.height - origin.y - size.height) * scale, width: CGFloat(picture.width), height: CGFloat(picture.height)))
            }
            guard let image = context.makeImage() else { return }
            frames[each.id] = CapturedFrame(image: image, hdrImage: nil, displayID: each.id, frame: each.frame)
        }
        let local = CGRect(origin: origin, size: size).insetBy(dx: -12, dy: -12)
        let rect = CGRect(x: display.frame.minX + local.minX, y: display.frame.maxY - local.maxY, width: local.width, height: local.height)
        for run in 1...max(times, 1) {
            overlay.injectedFrames = frames
            let (answers, answer) = AsyncStream.makeStream(of: String?.self)
            textCapture.captureFormula(copiesToClipboard: false, freezes: true) { latex in
                answer.yield(latex)
                answer.finish()
            }
            await waitForOverlayFrames()
            let started = ContinuousClock.now
            overlay.simulateSelection(rect)
            var latex: String?
            for await value in answers {
                latex = value
                break
            }
            let elapsed = ContinuousClock.now - started
            Log.app.notice("debug.formula-flow run \(run, privacy: .public) of \(times, privacy: .public): \(String(describing: elapsed), privacy: .public) from the selection's end to \(latex.map { "\($0.count) characters: \($0)" } ?? "no formula", privacy: .public)")
            // The highlight fades before the next selection begins.
            try? await Task.sleep(for: .milliseconds(600))
        }
    }
}
#endif
