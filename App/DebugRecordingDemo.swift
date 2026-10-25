#if DEBUG
import AppKit
import AVFoundation
import OMSAnnotate
import CoreMedia
import CoreText
import Darwin
import Foundation
import Metal
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

    private static var longStudioCheck: Task<Void, Never>?

    /// End-to-end diagnostic over a generated movie, never a user's recording. The fixture is prepared
    /// independently as studio-long-source.mp4; the report describes its actual duration and frame rate.
    static func startLongStudioCheck() {
        guard longStudioCheck == nil else { return }
        longStudioCheck = Task {
            await checkLongStudio()
            longStudioCheck = nil
        }
    }

    static func cancelLongStudioCheck() { longStudioCheck?.cancel() }

    private static func checkLongStudio() async {
        let source = directory.appending(path: "studio-long-source.mp4")
        let output = directory.appending(path: "studio-long-output.mp4")
        let projectFolder = directory.appending(path: "studio-long-project")
        let reportURL = directory.appending(path: "studio-long-report.json")
        let device = MTLCreateSystemDefaultDevice()
        var report: [String: Any] = ["fixture": "generated", "started": Date().description]
        var peakFootprint = Memory.footprint()
        var peakMetalBytes = device?.currentAllocatedSize ?? 0
        var memorySamples = 0
        let sampler = Task {
            while !Task.isCancelled {
                peakFootprint = max(peakFootprint, Memory.footprint())
                peakMetalBytes = max(peakMetalBytes, device?.currentAllocatedSize ?? 0)
                memorySamples += 1
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        defer {
            sampler.cancel()
            report["peak_process_footprint_bytes"] = peakFootprint
            report["peak_metal_allocated_bytes"] = peakMetalBytes
            report["memory_samples"] = memorySamples
            report["finished"] = Date().description
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: projectFolder)
            MemoryRelief.returnFreedPages()
        }
        do {
            let asset = AVURLAsset(url: source)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.noVideo }
            let duration = try await asset.load(.duration).seconds
            let size = try await video.load(.naturalSize)
            report["source_seconds"] = duration
            report["source_fps"] = try await video.load(.nominalFrameRate)
            report["source_size"] = [size.width, size.height]
            guard duration >= 30, duration <= 3_601 else { throw StudioError.noVideo }
            let telemetry = syntheticTelemetry(size: CGSize(width: size.width / 2, height: size.height / 2), duration: duration)
            var project = StudioProject()
            project.zooms = stride(from: 1.0, to: duration - 3, by: 6).map {
                .init(start: $0, end: $0 + 2.4, scale: 1.8, isAutomatic: true)
            }
            project.cuts = [duration / 3 ... duration / 3 + 2]
            let document = StudioDocument(
                source: source, telemetry: telemetry, project: project, duration: duration,
                recordingSize: size, folder: projectFolder, hasBeenExported: false,
                background: { name, size in BackdropGradient(rawValue: name)?.image(width: Int(size.width), height: Int(size.height)) }
            )
            defer { document.releaseDiagnosticPreview() }
            document.setPreviewSize(CGSize(width: 1280, height: 720))
            try await document.flushSave()
            let previewStart = ContinuousClock.now
            await document.makeComposition()
            guard let preview = document.composition, !document.compositionFailed else { throw StudioError.renderFailed }
            report["preview_prepare_seconds"] = (ContinuousClock.now - previewStart) / .seconds(1)
            let images = AVAssetImageGenerator(asset: preview.asset)
            images.videoComposition = preview.videoComposition
            images.requestedTimeToleranceBefore = .zero
            images.requestedTimeToleranceAfter = .zero
            var seeks: [Double] = []
            for time in [preview.duration - 1, 0, preview.duration / 2, 1] {
                try Task.checkCancellation()
                let began = ContinuousClock.now
                _ = try await images.image(at: CMTime(seconds: time, preferredTimescale: 600))
                seeks.append((ContinuousClock.now - began) / .seconds(1))
            }
            report["random_preview_seek_seconds"] = seeks
            let beforeCPU = CPUTimes.now()
            let began = ContinuousClock.now
            let composition = try await document.makeExportComposition()
            let movie = try await StudioExporter.export(composition, to: output)
            let wall = (ContinuousClock.now - began) / .seconds(1)
            let cpu = CPUTimes.now() - beforeCPU
            let exportedDuration = try await AVURLAsset(url: movie.url).load(.duration).seconds
            guard abs(exportedDuration - (duration - 2)) < 0.05 else { throw StudioError.renderFailed }
            report["export_seconds"] = wall
            report["output_seconds"] = exportedDuration
            report["output_bytes"] = movie.byteCount
            report["output_size"] = [movie.pixelWidth, movie.pixelHeight]
            report["app_cpu_percent_during_export"] = cpu.app / wall * 100
            report["encoder_cpu_percent_during_export"] = cpu.encoder / wall * 100
            report["status"] = "passed"
            Log.app.notice("debug.studio-long-check passed: \(exportedDuration, privacy: .public)s in \(wall, privacy: .public)s, peak footprint \(peakFootprint, privacy: .public), Metal \(peakMetalBytes, privacy: .public)")
        } catch {
            report["status"] = error is CancellationError ? "cancelled" : "failed"
            report["error"] = String(describing: error)
            Log.app.error("debug.studio-long-check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Records `seconds` of the scrolling page in a window of `size` points, then finishes it as the app
    /// would. `speed` is points per second; 0 keeps the page still.
    static func run(seconds: Int, size: CGSize, framesPerSecond: Int, speed: Double, prefersHEVC: Bool, keeps: Bool, systemAudio: Bool = false) async {
        let window = DemoScrollWindow(size: size, speed: speed)
        window.orderFront(nil)
        defer { window.close() }
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
        defer { window.close() }
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
    static func renderStudio(motionBlur: Bool = true, camera: Bool = false) async {
        let source = directory.appending(path: "studio-demo.mp4")
        let output = directory.appending(path: "studio-render.mp4")
        let asset = AVURLAsset(url: source)
        do {
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await track.load(.naturalSize)
            var telemetry = syntheticTelemetry(size: CGSize(width: size.width / 2, height: size.height / 2), duration: duration)
            var project = StudioProject()
            project.zooms = AutoZoom.zooms(for: telemetry, duration: duration)
            project.motionBlur = motionBlur
            // camera=1: a made-up camera beside it, never a real one.
            let cameraMovie = camera ? await syntheticCamera(seconds: duration) : nil
            defer { if let cameraMovie { try? FileManager.default.removeItem(at: cameraMovie) } }
            if cameraMovie != nil { telemetry.camera = StudioTelemetry.Camera(start: 0, bubble: project.camera) }
            let layout = StudioRenderer.layout(recordingSize: size, project: project, hasCamera: telemetry.camera != nil)
            let background = BackdropGradient.sky.image(width: Int(layout.canvas.width), height: Int(layout.canvas.height))
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: duration, recordingSize: size, background: background)
            let started = ContinuousClock.now
            let composition = try await StudioComposition.make(
                source: asset, renderer: renderer, cuts: [], camera: cameraMovie.map { .init(asset: AVURLAsset(url: $0), start: 0) }
            )
            let sampler = Task {
                var peak = Memory.footprint()
                while !Task.isCancelled {
                    peak = max(peak, Memory.footprint())
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return peak
            }
            let movie = try await StudioExporter.export(composition, to: output)
            let wall = (ContinuousClock.now - started) / .seconds(1)
            sampler.cancel()
            let peak = await sampler.value
            Log.app.notice("debug.studio-render \(movie.pixelWidth, privacy: .public)x\(movie.pixelHeight, privacy: .public), \(movie.duration, format: .fixed(precision: 2), privacy: .public) s in \(wall, format: .fixed(precision: 2), privacy: .public) s (\(movie.duration / wall, format: .fixed(precision: 1), privacy: .public)x real time), \(movie.byteCount, privacy: .public) bytes, peak \(peak / 1_048_576, privacy: .public) MB, motion blur \(motionBlur, privacy: .public), camera \(camera, privacy: .public); zooms \(project.zooms.map { String(format: "%.2f-%.2f@%.1f", $0.start, $0.end, $0.scale) }.joined(separator: ", "), privacy: .public)")
        } catch {
            Log.app.error("debug.studio-render failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A made-up camera for Studio's checks, never a real one: `seconds` of 640 × 480 at 30 fps, a person's
    /// outline on a soft backdrop, swaying a little, with the second in the corner. Written to a new file in
    /// the temporary folder.
    static func syntheticCamera(seconds: Double) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "studio-camera-\(UUID().uuidString).mov")
        let width = 640, height = 480
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<Int(seconds * 30) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                guard let pool = adaptor.pixelBufferPool else { return nil }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let pixels = buffer else { return nil }
                CVPixelBufferLockBaseAddress(pixels, [])
                if let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) {
                    let time = Double(frame) / 30
                    let colors = [CGColor(srgbRed: 0.80, green: 0.86, blue: 0.93, alpha: 1), CGColor(srgbRed: 0.93, green: 0.88, blue: 0.82, alpha: 1)]
                    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
                        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
                    }
                    let sway = 14 * sin(time * 1.6)
                    context.setFillColor(CGColor(srgbRed: 0.35, green: 0.42, blue: 0.55, alpha: 1))
                    context.fillEllipse(in: CGRect(x: 170 + sway, y: -120, width: 300, height: 300))
                    context.setFillColor(CGColor(srgbRed: 0.88, green: 0.72, blue: 0.62, alpha: 1))
                    context.fillEllipse(in: CGRect(x: 250 + sway * 1.2, y: 170, width: 140, height: 170))
                    let label = CTLineCreateWithAttributedString(NSAttributedString(string: String(format: "%.0f s", time.rounded(.down)), attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .semibold), .foregroundColor: CGColor(gray: 0.2, alpha: 0.8),
                    ]))
                    context.textPosition = CGPoint(x: 24, y: 24)
                    CTLineDraw(label, context)
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
            input.markAsFinished()
            await writer.finishWriting()
            return writer.status == .completed ? url : nil
        } catch {
            Log.app.error("debug: the made-up camera couldn't be written: \(String(describing: error), privacy: .public)")
            return nil
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
        defer { window.close() }
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
nonisolated enum Memory {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

extension DebugRecordingDemo {
    /// The replay spike: ScreenCaptureKit's rolling buffer of the last 15 seconds (macOS 27) on the scrolling
    /// window behind the desktop picture, nothing of the user's read. Buffers for `seconds` with `size`
    /// points at `framesPerSecond`, logs what it cost meanwhile (CPU of the app, the encoder's service,
    /// replayd; the app's footprint), then exports the last `clip` seconds to replay-demo.mov and logs how
    /// long that took and what came out. Nothing is kept unless `keeps`.
    @available(macOS 27, *)
    static func runReplaySpike(
        seconds: Int, size: CGSize, framesPerSecond: Int, speed: Double, clip: Double, keeps: Bool, takesFrames: Bool = true, audio: Bool = false,
        takesAudio: Bool = true, microphone: Bool = false, playsSilence: Bool = true
    ) async {
        let window = DemoScrollWindow(size: size, speed: speed)
        window.orderFront(nil)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(300))
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                Log.app.error("debug.replay-demo no window \(window.windowNumber, privacy: .public)")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((filter.contentRect.width * scale).rounded()) & ~1
            configuration.height = Int((filter.contentRect.height * scale).rounded()) & ~1
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.showsCursor = false
            configuration.queueDepth = 5
            // audio: this app's own sound (silence it plays meanwhile), the only sound a window's stream takes.
            var silence: AVAudioEngine?
            if audio, !playsSilence {
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = false
            } else if audio {
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = false
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                engine.attach(player)
                let format = engine.mainMixerNode.outputFormat(forBus: 0)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                    buffer.frameLength = buffer.frameCapacity
                    player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                }
                try engine.start()
                player.play()
                silence = engine
            }
            defer { silence?.stop() }
            // microphone: the default microphone too (the user's; only with their word, and the clip is deleted).
            if microphone { configuration.captureMicrophone = true }
            let observer = ReplayObserver()
            let stream = SCStream(filter: filter, configuration: configuration, delegate: observer)
            let queue = DispatchSerialQueue(label: "OhMyShot.replay-demo")
            // takesFrames: false asks for no frames at all, only the buffer.
            if takesFrames { try stream.addStreamOutput(observer, type: .screen, sampleHandlerQueue: queue) }
            // takesAudio: false buffers sound with no audio output of the app's own.
            if audio, takesAudio { try stream.addStreamOutput(observer, type: .audio, sampleHandlerQueue: queue) }
            try await stream.startCapture()
            let buffering = SCClipBufferingOutput(delegate: observer)
            try stream.addClipBufferingOutput(buffering)
            let before = CPUTimes.now()
            let started = ContinuousClock.now
            let footprintBefore = Memory.footprint()
            var peak = footprintBefore
            for _ in 0..<(seconds * 4) {
                try await Task.sleep(for: .milliseconds(250))
                peak = max(peak, Memory.footprint())
            }
            let wall = (ContinuousClock.now - started) / .seconds(1)
            let used = CPUTimes.now() - before
            Log.app.notice("""
                debug.replay-demo buffering \(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) \(framesPerSecond, privacy: .public) fps, \
                \(speed, privacy: .public) pt/s, \(observer.frames, privacy: .public) frames came; CPU over \(wall, format: .fixed(precision: 1), privacy: .public) s: \
                app \(used.app / wall * 100, format: .fixed(precision: 1), privacy: .public)%, encoder service \(used.encoder / wall * 100, format: .fixed(precision: 1), privacy: .public)%, \
                replayd \(used.replayd.map { String(format: "%.1f%%", $0 / wall * 100) } ?? "n/a", privacy: .public), \
                WindowServer \(used.windowServer.map { String(format: "%.1f%%", $0 / wall * 100) } ?? "n/a", privacy: .public)
                """)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let movie = directory.appending(path: "replay-demo.mov")
            // The export refuses a file that is there already (AVFoundation's -11823), whatever its header says.
            try? FileManager.default.removeItem(at: movie)
            let exporting = ContinuousClock.now
            try await buffering.exportClip(to: movie, duration: clip)
            let exportTime = (ContinuousClock.now - exporting) / .seconds(1)
            try stream.removeClipBufferingOutput(buffering)
            try await stream.stopCapture()
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let natural = try await videoTracks.first?.load(.naturalSize) ?? .zero
            let codec = try await videoTracks.first?.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
            let bytes = (try? movie.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let format = try await track.load(.formatDescriptions).first
                let basic = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let range = try await track.load(.timeRange)
                // How loud the track is (its level only, nothing of what it holds), to tell sound from silence.
                var sum = 0.0, count = 0
                if let reader = try? AVAssetReader(asset: asset) {
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                    ])
                    reader.add(output)
                    reader.startReading()
                    while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
                        let length = CMBlockBufferGetDataLength(block)
                        var floats = [Float](repeating: 0, count: length / 4)
                        _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                        for value in floats { sum += Double(value * value) }
                        count += floats.count
                    }
                }
                let rms = count > 0 ? (sum / Double(count)).squareRoot() : 0
                let level = rms > 0 ? 20 * log10(rms) : -.infinity
                Log.app.notice("debug.replay-demo audio track \(track.trackID, privacy: .public): \(basic.map { "\($0.mSampleRate) Hz, \($0.mChannelsPerFrame) ch, format \($0.mFormatID)" } ?? "?", privacy: .public), \(range.start.seconds, format: .fixed(precision: 2), privacy: .public)+\(range.duration.seconds, format: .fixed(precision: 2), privacy: .public) s, level \(level, format: .fixed(precision: 1), privacy: .public) dBFS")
            }
            Log.app.notice("""
                debug.replay-demo \(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) \(framesPerSecond, privacy: .public) fps, \
                \(speed, privacy: .public) pt/s: buffering started \(observer.started, privacy: .public), \(observer.frames, privacy: .public) frames came; \
                CPU over \(wall, format: .fixed(precision: 1), privacy: .public) s: app \(used.app / wall * 100, format: .fixed(precision: 1), privacy: .public)%, \
                encoder service \(used.encoder / wall * 100, format: .fixed(precision: 1), privacy: .public)%, \
                replayd \(used.replayd.map { String(format: "%.1f%%", $0 / wall * 100) } ?? "n/a", privacy: .public); \
                footprint \(footprintBefore / 1_048_576, privacy: .public) → at most \(peak / 1_048_576, privacy: .public) MB; \
                clip of \(clip, format: .fixed(precision: 1), privacy: .public) s exported in \(exportTime, format: .fixed(precision: 2), privacy: .public) s: \
                \(duration, format: .fixed(precision: 2), privacy: .public) s, \(Int(natural.width), privacy: .public)x\(Int(natural.height), privacy: .public) \(fourCC, privacy: .public), \
                \(bytes, privacy: .public) bytes, \(Double(bytes) * 8 / max(duration, 0.001) / 1e6, format: .fixed(precision: 1), privacy: .public) Mb/s\(observer.failure.map { ", failed: \($0)" } ?? "", privacy: .public)
                """)
            if !keeps { try? FileManager.default.removeItem(at: movie) }
        } catch {
            Log.app.error("debug.replay-demo failed: \(String(describing: error), privacy: .public)")
        }
        MemoryRelief.returnFreedPages()
    }
}

extension DebugRecordingDemo {
    /// The scrolling window behind the desktop picture for the replay's checks, while one is open.
    private static var replayWindow: NSWindow?

    /// Opens the scrolling window behind the desktop picture and returns a filter of it and its size in
    /// pixels, for keeping it in the replay as if it were a display.
    static func openReplayWindow(size: CGSize) async -> (filter: SCContentFilter, width: Int, height: Int)? {
        closeReplayWindow()
        let window = DemoScrollWindow(size: size, speed: 240)
        window.orderFront(nil)
        replayWindow = window
        try? await Task.sleep(for: .milliseconds(300))
        guard
            let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
            let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = CGFloat(filter.pointPixelScale)
        return (filter, Int((filter.contentRect.width * scale).rounded()), Int((filter.contentRect.height * scale).rounded()))
    }

    static func closeReplayWindow() {
        replayWindow?.close()
        replayWindow = nil
    }
}

/// Hears the replay spike's stream and buffer: counts frames, notes when buffering starts or fails.
@available(macOS 27, *)
nonisolated private final class ReplayObserver: NSObject, SCStreamOutput, SCStreamDelegate, SCClipBufferingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var counted = 0
    private var didStart = false
    private var failed: String?

    var frames: Int { lock.withLock { counted } }
    var started: Bool { lock.withLock { didStart } }
    var failure: String? { lock.withLock { failed } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.withLock { counted += 1 }
    }

    func clipBufferingOutputDidStartBuffering(_ clipBufferingOutput: SCClipBufferingOutput) {
        lock.withLock { didStart = true }
    }

    func clipBufferingOutput(_ clipBufferingOutput: SCClipBufferingOutput, didFailWithError error: any Error) {
        lock.withLock { failed = String(describing: error) }
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
