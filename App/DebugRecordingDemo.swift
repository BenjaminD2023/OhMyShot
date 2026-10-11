#if DEBUG
import AppKit
import AVFoundation
import OMSAnnotate
import CoreMedia
import CoreText
import Darwin
import Foundation
import OMSCapture
import OMSCore
import OMSRecording
import OMSStudio
import OSLog
import QuartzCore
import ScreenCaptureKit

/// The recording spike inside the app: records a window the app draws itself, kept behind the desktop
/// picture so nothing shows on screen and nothing of the user's is read, through the real recorder, and
/// logs what it cost.
///
/// The window shows a page of text (prose and highlighted code) scrolling at a steady speed, animated by
/// Core Animation in the window server as another app's content would be.
@MainActor
enum DebugRecordingDemo {
    /// Where the demo's movies go: the snapshot folder.
    static var directory: URL { DebugHooks.snapshotDirectory }

    /// Records `seconds` of the scrolling page in a window of `size` points, then finishes it as the app
    /// would. `speed` is points per second; 0 keeps the page still.
    static func run(seconds: Int, size: CGSize, framesPerSecond: Int, speed: Double, prefersHEVC: Bool, keeps: Bool, systemAudio: Bool = false) async {
        let window = DemoScrollWindow(size: size, speed: speed)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        // Long enough for the window server to have the window's first frame.
        try? await Task.sleep(for: .milliseconds(300))
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                Log.app.error("debug.record-demo no window \(window.windowNumber, privacy: .public)")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let format = RecordingFormat.choose(
                width: Int((filter.contentRect.width * scale).rounded()), height: Int((filter.contentRect.height * scale).rounded()),
                framesPerSecond: framesPerSecond, prefersHEVC: prefersHEVC
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let movie = directory.appending(path: "record-demo.mov")
            let recorder = try ScreenRecorder(ScreenRecorder.Request(
                filter: filter, sourceRect: nil, format: format, audio: RecordingAudio(system: systemAudio, microphone: nil),
                showsCursor: false, showsClicks: false, movieURL: movie
            ))
            let before = CPUTimes.now()
            let started = ContinuousClock.now
            try await recorder.start()
            try await Task.sleep(for: .seconds(seconds))
            let counts = recorder.frameCounts
            let statistics = try await recorder.stop()
            let wall = (ContinuousClock.now - started) / .seconds(1)
            let used = CPUTimes.now() - before
            let bytes = (try? movie.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            Log.app.notice("""
                debug.record-demo \(format.width, privacy: .public)x\(format.height, privacy: .public) \(format.codec.rawValue, privacy: .public) \
                \(framesPerSecond, privacy: .public) fps, \(speed, privacy: .public) pt/s: \(counts.complete, privacy: .public) frames came \
                (\(counts.idle, privacy: .public) idle), \(statistics.framesWritten, privacy: .public) written, \(statistics.framesDropped, privacy: .public) dropped, \
                \(statistics.duration.seconds, format: .fixed(precision: 2), privacy: .public) s, \(Double(bytes) * 8 / max(statistics.duration.seconds, 0.001) / 1e6, format: .fixed(precision: 1), privacy: .public) Mb/s, \
                \(statistics.audioBuffersWritten, privacy: .public) audio buffers (\(statistics.audioBuffersDropped, privacy: .public) left out); \
                CPU over \(wall, format: .fixed(precision: 1), privacy: .public) s: app \(used.app / wall * 100, format: .fixed(precision: 1), privacy: .public)%, \
                encoder service \(used.encoder / wall * 100, format: .fixed(precision: 1), privacy: .public)%, \
                replayd \(used.replayd.map { String(format: "%.1f%%", $0 / wall * 100) } ?? "n/a", privacy: .public), \
                WindowServer \(used.windowServer.map { String(format: "%.1f%%", $0 / wall * 100) } ?? "n/a", privacy: .public)
                """)
            let finishing = LatencyProbe("recording.finish")
            let finished = try await RecordingFinisher.finish(movie, to: directory.appending(path: "record-demo.mp4"))
            finishing.end()
            Log.app.notice("debug.record-demo finished \(finished.url.path(percentEncoded: false), privacy: .public): \(finished.pixelWidth, privacy: .public)x\(finished.pixelHeight, privacy: .public), \(finished.duration, format: .fixed(precision: 2), privacy: .public) s, \(finished.byteCount, privacy: .public) bytes, audio \(finished.hasAudio, privacy: .public)")
            if !keeps {
                try? FileManager.default.removeItem(at: movie)
                try? FileManager.default.removeItem(at: finished.url)
            }
        } catch {
            Log.app.error("debug.record-demo failed: \(String(describing: error), privacy: .public)")
        }
        MemoryRelief.returnFreedPages()
    }
}

extension DebugRecordingDemo {
    /// A Studio recording of the scrolling window behind the desktop picture, nothing shown: the stream without
    /// the cursor, the pointer written down meanwhile and moved onto the movie's timeline. Writes
    /// studio-demo.mp4 and studio-demo.json (the telemetry) to the snapshot folder and logs counts only: the
    /// pointer is the user's, so its places are never logged.
    static func runStudio(seconds: Int, size: CGSize) async {
        let window = DemoScrollWindow(size: size, speed: 240)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(300))
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let format = RecordingFormat.choose(
                width: Int((filter.contentRect.width * scale).rounded()), height: Int((filter.contentRect.height * scale).rounded()),
                framesPerSecond: 60
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let movie = directory.appending(path: "studio-demo.mov")
            let recorder = try ScreenRecorder(ScreenRecorder.Request(
                filter: filter, sourceRect: nil, format: format, audio: .none, showsCursor: false, showsClicks: false, movieURL: movie
            ))
            let telemetry = TelemetryRecorder()
            telemetry.start(area: window.frame, pixelsPerPoint: Double(scale), keys: nil)
            try await recorder.start()
            try await Task.sleep(for: .seconds(Double(seconds) / 2))
            // A pause in the middle, cut out of the movie and of the telemetry alike.
            recorder.pause()
            telemetry.debugClick(at: CGPoint(x: window.frame.midX, y: window.frame.midY))
            try await Task.sleep(for: .milliseconds(700))
            recorder.resume()
            telemetry.debugClick(at: CGPoint(x: window.frame.midX + 40, y: window.frame.midY - 20))
            try await Task.sleep(for: .seconds(Double(seconds) / 2))
            let raw = telemetry.stop()
            let statistics = try await recorder.stop()
            let moved = raw.retimed(start: statistics.start?.seconds ?? 0, pauses: statistics.pauses.map { $0.start.seconds...$0.end.seconds })
            let finished = try await RecordingFinisher.finish(movie, to: directory.appending(path: "studio-demo.mp4"))
            try? FileManager.default.removeItem(at: movie)
            try JSONEncoder().encode(moved).write(to: directory.appending(path: "studio-demo.json"))
            let times = moved.samples.map(\.time)
            Log.app.notice("debug.studio-demo \(finished.pixelWidth, privacy: .public)x\(finished.pixelHeight, privacy: .public), \(finished.duration, format: .fixed(precision: 2), privacy: .public) s, \(statistics.pauses.count, privacy: .public) pause(s); telemetry \(raw.samples.count, privacy: .public) reading(s) taken, \(moved.samples.count, privacy: .public) kept from \(times.first ?? -1, format: .fixed(precision: 2), privacy: .public) to \(times.last ?? -1, format: .fixed(precision: 2), privacy: .public) s, \(moved.cursors.count, privacy: .public) cursor(s), clicks at \(moved.clicks.map { String(format: "%.2f", $0.time) }.joined(separator: ", "), privacy: .public) s (one fell in the pause)")
        } catch {
            Log.app.error("debug.studio-demo failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Films studio-demo.mp4 (made by runStudio) as the Studio window would export it, over the sky gradient,
    /// with automatic zooms, from a made-up pointer that wanders and clicks (the demo's own telemetry holds
    /// the user's pointer, which barely moves): writes studio-render.mp4 and logs how fast it went.
    static func renderStudio() async {
        let source = directory.appending(path: "studio-demo.mp4")
        let output = directory.appending(path: "studio-render.mp4")
        let asset = AVURLAsset(url: source)
        do {
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await track.load(.naturalSize)
            let telemetry = syntheticTelemetry(size: CGSize(width: size.width / 2, height: size.height / 2), duration: duration)
            var project = StudioProject()
            project.zooms = AutoZoom.zooms(for: telemetry, duration: duration)
            let layout = StudioRenderer.layout(recordingSize: size, project: project)
            let background = BackdropGradient.sky.image(width: Int(layout.canvas.width), height: Int(layout.canvas.height))
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: duration, recordingSize: size, background: background)
            let started = ContinuousClock.now
            let composition = try await StudioComposition.make(source: asset, renderer: renderer, cuts: [])
            let movie = try await StudioExporter.export(composition, to: output)
            let wall = (ContinuousClock.now - started) / .seconds(1)
            Log.app.notice("debug.studio-render \(movie.pixelWidth, privacy: .public)x\(movie.pixelHeight, privacy: .public), \(movie.duration, format: .fixed(precision: 2), privacy: .public) s in \(wall, format: .fixed(precision: 2), privacy: .public) s (\(movie.duration / wall, format: .fixed(precision: 1), privacy: .public)x real time), \(movie.byteCount, privacy: .public) bytes; zooms \(project.zooms.map { String(format: "%.2f-%.2f@%.1f", $0.start, $0.end, $0.scale) }.joined(separator: ", "), privacy: .public)")
        } catch {
            Log.app.error("debug.studio-render failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A made-up pointer over a recording `size` points large: drifting across in loops, clicking twice close
    /// together, then once more later, with the arrow cursor; "Hello" typed and ⌘S pressed near the end.
    static func syntheticTelemetry(size points: CGSize, duration: Double) -> StudioTelemetry {
        let samples = stride(from: 0.0, through: duration, by: 1.0 / 60).map { time in
            StudioTelemetry.Sample(
                time: time, x: points.width * (0.25 + 0.5 * time / max(duration, 1)) + 60 * sin(time * 2.2),
                y: points.height * 0.55 + 40 * cos(time * 1.7), cursor: 0
            )
        }
        let arrow = NSCursor.arrow
        var telemetry = StudioTelemetry(
            width: points.width, height: points.height, pixelsPerPoint: 2, samples: samples,
            cursors: [.init(
                png: TelemetryRecorder.png(of: arrow.image, scale: 4) ?? Data(), scale: 4, width: arrow.image.size.width,
                height: arrow.image.size.height, hotSpotX: arrow.hotSpot.x, hotSpotY: arrow.hotSpot.y
            )]
        )
        for time in [0.8, 1.4, max(duration - 1.2, 2.5)] where time < duration {
            let place = AutoZoom.pointer(at: time, in: samples)
            telemetry.clicks.append(.init(time: time, x: place.x, y: place.y, button: .primary))
        }
        let typing: [(String, UInt16)] = [("H", 4), ("e", 14), ("l", 37), ("l", 37), ("o", 31)]
        let typed = max(duration - 1.6, 0.5)
        for (index, (character, code)) in typing.enumerated() where typed + Double(index) * 0.12 < duration {
            telemetry.keys.append(.init(
                time: typed + Double(index) * 0.12, keyCode: code, modifiers: character == "H" ? NSEvent.ModifierFlags.shift.rawValue : 0,
                characters: character, keyCharacters: character.lowercased(), isRepeat: false
            ))
        }
        if typed + 0.9 < duration {
            telemetry.keys.append(.init(
                time: typed + 0.9, keyCode: 1, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "s", keyCharacters: "s", isRepeat: false
            ))
        }
        telemetry.keystrokeMode = .all
        return telemetry
    }

    /// The whole recording flow on the scrolling window behind the desktop picture: the countdown (as
    /// Settings has it), recording with the control bar and the menu bar's time, Stop after `seconds`, and
    /// the recording kept in the history with a card. The countdown and the bar show on screen.
    static func runFlow(
        recordings: RecordingCoordinator, displays: DisplayTopology, seconds: Int, countdown: Int, size: CGSize, output: RecordingOutput = .video
    ) async {
        let window = DemoScrollWindow(size: size, speed: 240)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(300))
        guard let display = displays.layout.primary else { return }
        let target = WindowTarget(id: CGWindowID(window.windowNumber), frame: window.frame, ownerName: "Demo", title: nil)
        recordings.debugLeavesClipboard = true
        recordings.record(.window(target), on: display, choices: RecordingChoices(output: output), appName: "Demo")
        // The countdown, the stream's start, then the recording itself.
        try? await Task.sleep(for: .seconds(countdown) + .milliseconds(600) + .seconds(seconds))
        guard recordings.isRecording else {
            recordings.debugLeavesClipboard = false
            Log.app.error("debug.record-flow the recording did not start")
            return
        }
        recordings.stop()
        // Finishing and keeping take a moment (a GIF longer); the window stays until then, and the clipboard
        // is left alone until the recording is kept, however long that takes.
        let started = ContinuousClock.now
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
        } while recordings.debugIsKeeping && ContinuousClock.now - started < .seconds(120)
        // Recordings the user makes afterwards go to the clipboard again.
        recordings.debugLeavesClipboard = false
        Log.app.notice("debug.record-flow stopped after \(seconds, privacy: .public) s")
    }

    /// Makes a GIF of the demo movie record-demo.mov, as a GIF recording would be made, and logs what it
    /// cost: frames, size, time, and the most memory the app used meanwhile.
    static func makeGIF(framesPerSecond: Int, scale: Double) async {
        let movie = directory.appending(path: "record-demo.mov")
        let destination = directory.appending(path: "record-demo.gif")
        let before = Memory.footprint()
        let sampler = Task {
            var peak = before
            while !Task.isCancelled {
                peak = max(peak, Memory.footprint())
                try? await Task.sleep(for: .milliseconds(50))
            }
            return peak
        }
        let started = ContinuousClock.now
        do {
            let gif = try await GIFMaker.make(from: movie, to: destination, options: .init(framesPerSecond: framesPerSecond, scale: scale))
            let wall = (ContinuousClock.now - started) / .seconds(1)
            sampler.cancel()
            let peak = await sampler.value
            Log.app.notice("debug.gif-demo \(gif.pixelWidth, privacy: .public)x\(gif.pixelHeight, privacy: .public) \(framesPerSecond, privacy: .public) fps: \(gif.frameCount, privacy: .public) frames, \(gif.duration, format: .fixed(precision: 2), privacy: .public) s, \(gif.byteCount, privacy: .public) bytes in \(wall, format: .fixed(precision: 2), privacy: .public) s; footprint \(before / 1_048_576, privacy: .public) MB before, at most \(peak / 1_048_576, privacy: .public) MB while making")
        } catch {
            sampler.cancel()
            Log.app.error("debug.gif-demo failed: \(String(describing: error), privacy: .public)")
        }
        MemoryRelief.returnFreedPages()
    }
}

/// The app's memory as Activity Monitor counts it.
private enum Memory {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// CPU seconds used so far by this app, the video encoder's service, ScreenCaptureKit's daemon, and the
/// window server (the last two only where the system lets them be read).
struct CPUTimes {
    var app: Double
    var encoder: Double
    var replayd: Double?
    var windowServer: Double?

    static func now() -> CPUTimes {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let app = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        return CPUTimes(
            app: app, encoder: cpu(ofProcessesNamed: "VTEncoderXPCService") ?? 0,
            replayd: cpu(ofProcessesNamed: "/replayd"), windowServer: cpu(ofProcessesNamed: "/WindowServer")
        )
    }

    static func - (lhs: CPUTimes, rhs: CPUTimes) -> CPUTimes {
        CPUTimes(
            app: lhs.app - rhs.app, encoder: lhs.encoder - rhs.encoder,
            replayd: lhs.replayd.flatMap { l in rhs.replayd.map { l - $0 } },
            windowServer: lhs.windowServer.flatMap { l in rhs.windowServer.map { l - $0 } }
        )
    }

    /// The CPU seconds of every process whose path contains `name`; nil when none could be read.
    private static func cpu(ofProcessesNamed name: String) -> Double? {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var total: Double?
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).contains(name) else { continue }
            var info = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard read == 0 else { continue }
            total = (total ?? 0) + Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        return total
    }
}

/// A window behind the desktop picture showing a page of text that scrolls without end.
private final class DemoScrollWindow: NSWindow {
    init(size: CGSize, speed: Double) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        isReleasedWhenClosed = false
        animationBehavior = .none
        if let screen = NSScreen.screens.first {
            setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        }
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(gray: 1, alpha: 1)
        view.layer?.masksToBounds = true
        // Two pages one above the other, so the scroll can wrap around without a jump.
        let page = Self.page(size: size, scale: scale)
        let strip = CALayer()
        strip.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height * 4)
        for index in 0..<2 {
            let layer = CALayer()
            layer.contents = page
            layer.contentsScale = scale
            layer.frame = CGRect(x: 0, y: CGFloat(index) * size.height * 2, width: size.width, height: size.height * 2)
            strip.addSublayer(layer)
        }
        view.layer?.addSublayer(strip)
        contentView = view
        if speed > 0 {
            let travel = size.height * 2
            let animation = CABasicAnimation(keyPath: "position.y")
            animation.fromValue = strip.position.y
            animation.toValue = strip.position.y - travel
            animation.duration = travel / speed
            animation.repeatCount = .infinity
            strip.add(animation, forKey: "scroll")
        }
    }

    /// A page twice the window's height: lines of prose and of highlighted code.
    private static func page(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(size.width * scale)
        let height = Int(size.height * 2 * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let prose = CTFontCreateUIFontForLanguage(.system, 13 * scale, nil)!
        let code = CTFontCreateWithName("Menlo" as CFString, 12 * scale, nil)
        let words = "the screen recorder writes each frame to a movie while the encoder keeps up with the stream and nothing is dropped when the page scrolls through long paragraphs of text".split(separator: " ")
        let tokens = ["let", "frame", "=", "try", "await", "stream.next()", "guard", "writer.isReady", "else", "{", "return", "}", "// keep the last frame"]
        let inks = [CGColor(gray: 0.1, alpha: 1), CGColor(red: 0.67, green: 0.05, blue: 0.57, alpha: 1), CGColor(red: 0.11, green: 0.27, blue: 0.82, alpha: 1), CGColor(red: 0.2, green: 0.5, blue: 0.2, alpha: 1)]
        var seed: UInt64 = 11
        func random(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
        }
        var y = CGFloat(height) - 24 * scale
        var line = 0
        while y > 8 * scale {
            let isCode = (line / 6) % 2 == 1
            let text = NSMutableAttributedString()
            let x = 24 * scale + (isCode ? CGFloat(random(0...3)) * 28 * scale : 0)
            let target = (CGFloat(width) - x - 24 * scale) * CGFloat(random(55...95)) / 100
            while CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil) < target {
                let word = isCode ? tokens[random(0...tokens.count - 1)] : String(words[random(0...words.count - 1)])
                text.append(NSAttributedString(string: word + " ", attributes: [
                    .init(kCTFontAttributeName as String): isCode ? code : prose,
                    .init(kCTForegroundColorAttributeName as String): isCode ? inks[random(0...inks.count - 1)] : inks[0],
                ]))
            }
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            y -= (isCode ? 17 : 19) * scale
            line += 1
        }
        return context.makeImage()
    }
}
#endif
