import AppKit
import AVFoundation
import CoreText
import CryptoKit
import Darwin
import Foundation
import OMSCore
import Testing
import VideoToolbox
@testable import OMSStudio

/// Opt in with OMS_STUDIO_BENCHMARK=1, in Debug and in Release (`-c release -Xswiftc -enable-testing`). Fixed
/// inputs, three runs, median reported; timings are observations, not pass/fail thresholds that depend on the
/// machine running the suite. OMS_STUDIO_BENCHMARK_FRAMES=<path> also writes each composed frame's digest
/// there, one line a frame, to find the first frame two builds draw differently.
///
/// The recording is made as ScreenRecorder makes one: a frame only when the screen changed, so where nothing
/// moves one frame is held for seconds, and where the page scrolls there are 30 a second. The pointer rests
/// where the page does; it moves, clicks, and is zoomed on where it scrolls, and once over the still page.
@Suite(.serialized)
struct StudioExportBenchmarks {
    static let pixels = (width: 1920, height: 1200)
    static let duration = 30.0
    /// Where the page scrolls, 400 pixels a second, with the pointer moving.
    static let scrolling: [ClosedRange<Double>] = [5...8, 13...16]
    /// Where only the pointer moves, over the still page.
    static let pointing: [ClosedRange<Double>] = [21...24]
    /// Where the pointer rests, in points, from each still stretch to the next.
    static let rests: [(x: Double, y: Double)] = [(300, 200), (600, 350), (450, 420), (700, 250)]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_STUDIO_BENCHMARK"] == "1"))
    func exportOfStillAndMovingStretches() async throws {
        let source = try await Self.recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let renderer = StudioRenderer(
            telemetry: Self.telemetry(), project: Self.project(), duration: Self.duration,
            recordingSize: CGSize(width: Self.pixels.width, height: Self.pixels.height), background: nil
        )
        let composition = try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: [])
        let frames = Int((composition.duration * 60).rounded())

        var exports: [Double] = []
        var cpu: [Double] = []
        for _ in 0..<3 {
            let output = FileManager.default.temporaryDirectory.appending(path: "OMSStudioBench-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let processBefore = Self.processSeconds()
            let start = Date.timeIntervalSinceReferenceDate
            let movie = try await StudioExporter.export(composition, to: output)
            let wall = Date.timeIntervalSinceReferenceDate - start
            exports.append(wall)
            cpu.append((Self.processSeconds() - processBefore) / wall * 100)
            #expect(movie.byteCount > 0)
        }
        #if DEBUG
        let countsBefore = StudioComposition.debugCompositorCounts
        #endif
        let framesBefore = composition.frameCounts
        var composes: [Double] = []
        for _ in 0..<3 {
            let start = Date.timeIntervalSinceReferenceDate
            let read = try await Self.compose(composition, digesting: false)
            composes.append(Date.timeIntervalSinceReferenceDate - start)
            #expect(read.frames == frames)
        }
        let framesAfter = composition.frameCounts
        #if DEBUG
        let countsAfter = StudioComposition.debugCompositorCounts
        var counts = " asked_per_compose=\((countsAfter.asked - countsBefore.asked) / 3) finished_per_compose=\((countsAfter.drawn - countsBefore.drawn) / 3)"
        #else
        var counts = ""
        #endif
        counts += " drawn_per_compose=\((framesAfter.drawn - framesBefore.drawn) / 3) reused_per_compose=\((framesAfter.reused - framesBefore.reused) / 3) most_in_flight=\(framesAfter.mostInFlight)"
        var encodes: [Double] = []
        for _ in 0..<3 {
            encodes.append(try await Self.encode(composition, frames: frames))
        }
        let digested = try await Self.compose(composition, digesting: true)
        if let path = ProcessInfo.processInfo.environment["OMS_STUDIO_BENCHMARK_FRAMES"] {
            try digested.lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let export = exports.sorted()[1], compose = composes.sorted()[1], encode = encodes.sorted()[1]
        let canvas = renderer.layout.canvas
        func fixed(_ value: Double) -> String { String(format: "%.3f", value) }
        print("""
            STUDIO_EXPORT_BENCH config=\(configuration) canvas=\(Int(canvas.width))x\(Int(canvas.height)) frames=\(frames) \
            export_median_s=\(fixed(export)) export_fps=\(fixed(Double(frames) / export)) export_runs_s=\(exports.map(fixed)) \
            app_cpu_pct=\(fixed(cpu.sorted()[1])) compose_median_s=\(fixed(compose)) compose_fps=\(fixed(Double(frames) / compose)) \
            compose_runs_s=\(composes.map(fixed))\(counts) encode_only_fps=\(fixed(Double(frames) / encode)) \
            encode_only_runs_s=\(encodes.map(fixed)) digest=\(digested.digest)
            """)
    }

    /// The app's debug/studio-long-check, as far as this package can make it: a generated 30-minute
    /// recording, 1280 × 720 at a frame a second, the pointer always moving, a zoom every six seconds and two
    /// seconds cut, through the real exporter, once. OMS_STUDIO_BENCHMARK_LONG=1; minutes in Debug. The
    /// app's own check differs in its background (a gradient drawn by the editor's code, here one of two
    /// colors) and in building the composition through StudioDocument.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_STUDIO_BENCHMARK_LONG"] == "1"))
    func exportOfALongRecording() async throws {
        let duration = 1800.0
        let source = try await Self.longRecording(seconds: Int(duration))
        defer { try? FileManager.default.removeItem(at: source) }
        let points = CGSize(width: 640, height: 360)
        let samples = stride(from: 0.0, through: duration, by: 1.0 / 60).map { time in
            StudioTelemetry.Sample(
                time: time, x: points.width * (0.25 + 0.5 * time / duration) + 60 * sin(time * 2.2),
                y: points.height * 0.55 + 40 * cos(time * 1.7), cursor: 0
            )
        }
        var telemetry = Self.telemetry()
        telemetry.width = points.width
        telemetry.height = points.height
        telemetry.samples = samples
        telemetry.clicks = [0.8, 1.4, duration - 1.2].map { time in
            let sample = samples[Int((time * 60).rounded())]
            return .init(time: time, x: sample.x, y: sample.y, button: .primary)
        }
        telemetry.keys = [("H", 4), ("e", 14), ("l", 37), ("l", 37), ("o", 31)].enumerated().map { index, key in
            .init(time: duration - 1.6 + Double(index) * 0.12, keyCode: UInt16(key.1), modifiers: 0, characters: key.0, keyCharacters: key.0.lowercased(), isRepeat: false)
        }
        var project = StudioProject()
        project.zooms = stride(from: 1.0, to: duration - 3, by: 6).map { .init(start: $0, end: $0 + 2.4, scale: 1.8, isAutomatic: true) }
        project.cuts = [duration / 3 ... duration / 3 + 2]
        let size = CGSize(width: 1280, height: 720)
        let canvas = StudioRenderer.layout(recordingSize: size, project: project, hasCamera: false).canvas
        let renderer = StudioRenderer(
            telemetry: telemetry, project: project, duration: duration, recordingSize: size, background: try Self.gradient(size: canvas)
        )
        let composition = try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: project.cuts)
        let output = FileManager.default.temporaryDirectory.appending(path: "OMSStudioBench-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let processBefore = Self.processSeconds()
        let start = Date.timeIntervalSinceReferenceDate
        let movie = try await StudioExporter.export(composition, to: output)
        let wall = Date.timeIntervalSinceReferenceDate - start
        let cpu = (Self.processSeconds() - processBefore) / wall * 100
        let frames = Int((composition.duration * 60).rounded())
        let counts = composition.frameCounts
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        print("""
            STUDIO_EXPORT_BENCH_LONG config=\(configuration) canvas=\(movie.pixelWidth)x\(movie.pixelHeight) frames=\(frames) \
            export_s=\(String(format: "%.3f", wall)) export_fps=\(String(format: "%.1f", Double(frames) / wall)) \
            app_cpu_pct=\(String(format: "%.1f", cpu)) drawn=\(counts.drawn) reused=\(counts.reused) most_in_flight=\(counts.mostInFlight) \
            peak_footprint_mb=\(Self.peakFootprint() / 1_000_000) bytes=\(movie.byteCount)
            """)
        #expect(abs(movie.duration - (duration - 2)) < 0.05)
    }

    /// A generated recording of `seconds`, 1280 × 720 at a frame a second: bands of gray shifting each frame.
    static func longRecording(seconds: Int) async throws -> URL {
        let width = 1280, height = 720
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioBench-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let base = try #require(CVPixelBufferGetBaseAddress(pixels))
            for y in 0..<height { memset(base + y * row, Int32(40 + ((y / 24 + frame) % 9) * 22), row) }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 1))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.writingFailed(String(describing: writer.error)) }
        return url
    }

    /// A background of `size`, a light blue at the top to a paler one at the foot.
    static func gradient(size: CGSize) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let colors = [CGColor(srgbRed: 0.55, green: 0.75, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.85, green: 0.92, blue: 0.98, alpha: 1)]
        let gradient = try #require(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        return try #require(context.makeImage())
    }

    /// The most memory this process has had, in bytes, as Activity Monitor counts it.
    static func peakFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : 0
    }

    // MARK: Inputs

    static func project() -> StudioProject {
        // The default look (gradient's place taken by its plain fallback, shadow, rounded corners, motion blur),
        // zoomed once over a still stretch and once over a scrolling one.
        StudioProject(zooms: [
            .init(start: 9, end: 12.5, scale: 2, isAutomatic: false),
            .init(start: 13.5, end: 15.5, scale: 1.6, isAutomatic: false),
        ])
    }

    /// Where the pointer is at `time`, in points: at a rest, or on its way from one to the next, wavering.
    static func pointer(at time: Double) -> (x: Double, y: Double) {
        let moving = (scrolling + pointing).sorted { $0.lowerBound < $1.lowerBound }
        for (index, stretch) in moving.enumerated() {
            if time < stretch.lowerBound { return rests[index] }
            if time <= stretch.upperBound {
                let u = (time - stretch.lowerBound) / (stretch.upperBound - stretch.lowerBound)
                let from = rests[index], to = rests[index + 1]
                return (from.x + (to.x - from.x) * u + 80 * sin(3 * .pi * u), from.y + (to.y - from.y) * u + 40 * sin(2 * .pi * u))
            }
        }
        return rests[moving.count]
    }

    static func telemetry() -> StudioTelemetry {
        let samples = stride(from: 0.0, through: duration, by: 1.0 / 60).map { time in
            let place = pointer(at: time)
            return StudioTelemetry.Sample(time: time, x: place.x, y: place.y, cursor: 0)
        }
        let arrow = NSCursor.arrow
        let clicks = [6.0, 7.2, 14.5, 22.0].map { time in
            let place = pointer(at: time)
            return StudioTelemetry.Click(time: time, x: place.x, y: place.y, button: .primary)
        }
        let keys = [(15.0, "a", UInt16(0)), (15.15, "b", UInt16(11)), (15.3, "c", UInt16(8))].map { time, character, code in
            StudioTelemetry.Key(time: time, keyCode: code, modifiers: 0, characters: character, keyCharacters: character, isRepeat: false)
        }
        return StudioTelemetry(
            width: Double(pixels.width) / 2, height: Double(pixels.height) / 2, pixelsPerPoint: 2, samples: samples,
            cursors: [.init(
                png: TelemetryRecorder.png(of: arrow.image, scale: 4) ?? Data(), scale: 4, width: arrow.image.size.width,
                height: arrow.image.size.height, hotSpotX: arrow.hotSpot.x, hotSpotY: arrow.hotSpot.y
            )],
            clicks: clicks, keys: keys, keystrokeMode: .all
        )
    }

    /// How far the page has scrolled at `time`, in pixels.
    static func scrolled(at time: Double) -> Int {
        Int(scrolling.reduce(0.0) { sum, stretch in sum + max(0, min(time, stretch.upperBound) - stretch.lowerBound) } * 400)
    }

    /// The recording: a page of text, its first frame at 0 and 30 frames a second where it scrolls, encoded as
    /// the recorder encodes (constant quality 0.6, real time, no B-frames, a key frame every two seconds).
    static func recording() async throws -> URL {
        let (width, height) = pixels
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioBench-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.6, AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false, kVTCompressionPropertyKey_RealTime as String: true,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Lines of words, drawn once, as tall as the screen and all it scrolls.
        let pageHeight = height + scrolled(at: duration)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let pageContext = try #require(CGContext(
            data: nil, width: width, height: pageHeight, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo
        ))
        pageContext.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1))
        pageContext.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))
        let words = ["screen", "capture", "studio", "movie", "quality", "export", "pointer", "zoom", "frame", "cursor", "the", "of", "and", "a", "to", "in", "is", "that", "for", "with"]
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 26, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
        ]
        var seed: UInt64 = 12345
        var baseline = Double(pageHeight) - 40
        while baseline > 20 {
            var line = ""
            while line.count < 110 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                line += words[Int(seed >> 33) % words.count] + " "
            }
            pageContext.textPosition = CGPoint(x: 40, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), pageContext)
            baseline -= 38
        }
        let page = try #require(pageContext.makeImage())

        let times = [0.0] + scrolling.flatMap { stretch in
            stride(from: stretch.lowerBound + 1.0 / 30, to: stretch.upperBound, by: 1.0 / 30).map { $0 }
        }
        for time in times {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try #require(CGContext(
                data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: sRGB, bitmapInfo: bitmapInfo
            ))
            // The page's top at the screen's top, moved up as it scrolls.
            context.draw(page, in: CGRect(x: 0, y: height - pageHeight + scrolled(at: time), width: width, height: pageHeight))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue((time * 600).rounded()), timescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(duration * 600), timescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.writingFailed(String(describing: writer.error)) }
        return url
    }

    // MARK: Measuring

    /// The composition's frames as its compositor draws them, read without encoding: how many, and when
    /// `digesting`, each one's digest (both planes, without the rows' padding) and one over them all.
    static func compose(_ composition: StudioComposition, digesting: Bool) async throws -> (frames: Int, digest: String, lines: [String]) {
        let reader = try AVAssetReader(asset: composition.asset)
        let tracks = try await composition.asset.loadTracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.videoComposition = composition.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw StudioError.readingFailed(String(describing: reader.error)) }
        var frames = 0
        var all = SHA256()
        var lines: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames += 1
            guard digesting else { continue }
            let digest = Self.digest(of: buffer)
            all.update(data: Data(digest.utf8))
            lines.append("\(String(format: "%.4f", sample.presentationTimeStamp.seconds)) \(digest)")
        }
        guard reader.status == .completed else { throw StudioError.readingFailed(String(describing: reader.error)) }
        return (frames, digesting ? all.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description : "-", lines)
    }

    /// The encoder alone at the export's settings, for how fast an export could go at all: `count` frames
    /// cycled from a second of the composed scrolling page, appended as fast as it takes them. Seconds.
    static func encode(_ composition: StudioComposition, frames count: Int) async throws -> Double {
        let reader = try AVAssetReader(asset: composition.asset)
        reader.timeRange = CMTimeRange(start: CMTime(value: 5, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await composition.asset.loadTracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.videoComposition = composition.videoComposition
        reader.add(output)
        guard reader.startReading() else { throw StudioError.readingFailed(String(describing: reader.error)) }
        var buffers: [CVPixelBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { buffers.append(buffer) }
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioBench-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: StudioExporter.videoSettings(
            canvas: composition.renderer.layout.canvas, quality: composition.renderer.project.quality, colors: composition.colors
        ))
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        let start = Date.timeIntervalSinceReferenceDate
        guard writer.startWriting() else { throw StudioError.writingFailed(String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)
        let feed = EncodeFeed(buffers: buffers, count: count, input: input, adaptor: adaptor)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            feed.run { continuation.resume() }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.writingFailed(String(describing: writer.error)) }
        return Date.timeIntervalSinceReferenceDate - start
    }

    /// A 4:2:0 frame's digest: each plane's rows, without their padding.
    static func digest(of buffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var hash = SHA256()
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            // Two bytes a pixel in the chroma plane, one in the luma.
            let used = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * row, count: used))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// This process's CPU time so far, user and system, in seconds.
    static func processSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

/// The frames the encoder-only run appends, one after another, as fast as the encoder takes them; touched
/// only on its queue.
nonisolated private final class EncodeFeed: @unchecked Sendable {
    private let buffers: [CVPixelBuffer]
    private let count: Int
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var index = 0
    private var finished = false

    init(buffers: [CVPixelBuffer], count: Int, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        self.buffers = buffers
        self.count = count
        self.input = input
        self.adaptor = adaptor
    }

    /// Appends all `count` frames, then marks the input finished and calls `done`, once.
    func run(_ done: @escaping @Sendable () -> Void) {
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "OhMyShot.bench.encode")) { [self] in
            while input.isReadyForMoreMediaData, index < count, !buffers.isEmpty {
                adaptor.append(buffers[index % buffers.count], withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 60))
                index += 1
            }
            guard index >= count || buffers.isEmpty, !finished else { return }
            finished = true
            input.markAsFinished()
            done()
        }
    }
}
