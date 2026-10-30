import AppKit
import AVFoundation
import CoreImage
import Foundation
import OMSCore
import QuartzCore
import Testing
@testable import OMSStudio

extension StudioExportTests {
    /// The compositor draws a few frames at once and hands back the last one where nothing changed: neither may
    /// change a pixel of what it draws. Nested in the export tests to run one at a time with them: encoder sessions
    /// at once change what each makes, and those tests count the bytes made.
    @Suite
    struct StudioCompositorTests {
        /// Six seconds of 320 × 200 made as ScreenRecorder makes them, a frame only when the picture changed:
        /// one frame held for the first two seconds, a bar moving across the next 0.6 s at 30 fps, then held again.
        private static func movie() async throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioCompositor-\(UUID().uuidString).mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0],
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 200,
            ])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            let frames = [0] + Array(60..<78)
            for frame in frames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
                let pixels = try #require(buffer)
                CVPixelBufferLockBaseAddress(pixels, [])
                let row = CVPixelBufferGetBytesPerRow(pixels)
                let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
                // A gray page, a light bar 20 pixels wide where it has moved to.
                let bar = 20 + max(0, frame - 60) * 14
                for y in 0..<200 {
                    memset(base + y * row, 90, row)
                    if y >= 60, y < 140 { memset(base + y * row + bar * 4, 230, 80) }
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: 6, timescale: 1))
            await writer.finishWriting()
            return url
        }

        /// The pointer rests, moves while the bar does, clicking on the way, and rests again; two keys are typed
        /// over the still page, so their caption stands at full opacity while nothing else changes.
        private static func telemetry() -> StudioTelemetry {
            func pointer(at time: Double) -> (x: Double, y: Double) {
                let u = min(max((time - 2) / 0.6, 0), 1)
                return (40 + 80 * u, 50 - 10 * u)
            }
            let arrow = NSCursor.arrow
            return StudioTelemetry(
                width: 160, height: 100, pixelsPerPoint: 2,
                samples: stride(from: 0.0, through: 6, by: 1.0 / 60).map { time in
                    let place = pointer(at: time)
                    return .init(time: time, x: place.x, y: place.y, cursor: 0)
                },
                cursors: [.init(
                    png: TelemetryRecorder.png(of: arrow.image, scale: 4) ?? Data(), scale: 4, width: arrow.image.size.width,
                    height: arrow.image.size.height, hotSpotX: arrow.hotSpot.x, hotSpotY: arrow.hotSpot.y
                )],
                clicks: [.init(time: 2.3, x: pointer(at: 2.3).x, y: pointer(at: 2.3).y, button: .primary)],
                keys: [
                    .init(time: 4.6, keyCode: 0, modifiers: 0, characters: "a", keyCharacters: "a", isRepeat: false),
                    .init(time: 4.7, keyCode: 11, modifiers: 0, characters: "b", keyCharacters: "b", isRepeat: false),
                ],
                keystrokeMode: .all
            )
        }

        /// The default look, zoomed in and out over the first still stretch.
        private static func project() -> StudioProject {
            StudioProject(zooms: [.init(start: 0.2, end: 1.8, scale: 2, isAutomatic: false)])
        }

        private static func composition(of source: URL, reusesFrames: Bool) async throws -> StudioComposition {
            let renderer = StudioRenderer(
                telemetry: telemetry(), project: project(), duration: 6, recordingSize: CGSize(width: 320, height: 200), background: nil
            )
            return try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: [], reusesFrames: reusesFrames)
        }

        /// Each frame the composition's compositor makes, read without encoding: its time and both planes' rows,
        /// without their padding.
        private static func composedFrames(_ composition: StudioComposition) async throws -> [(time: CMTime, bytes: Data)] {
            let reader = try AVAssetReader(asset: composition.asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await composition.asset.loadTracks(withMediaType: .video), videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            output.videoComposition = composition.videoComposition
            reader.add(output)
            #expect(reader.startReading())
            var frames: [(time: CMTime, bytes: Data)] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                frames.append((sample.presentationTimeStamp, bytes(of: buffer)))
            }
            #expect(reader.status == .completed, "\(String(describing: reader.error))")
            return frames
        }

        /// A frame's planes, row by row, without their padding.
        private static func bytes(of buffer: CVPixelBuffer) -> Data {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            var data = Data()
            let planes = CVPixelBufferGetPlaneCount(buffer)
            for plane in 0..<max(planes, 1) {
                guard let base = planes > 0 ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer) else { continue }
                let row = planes > 0 ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
                let height = planes > 0 ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
                let used = planes > 0 ? CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2) : CVPixelBufferGetWidth(buffer) * 4
                for y in 0..<height { data.append((base + y * row).assumingMemoryBound(to: UInt8.self), count: used) }
            }
            return data
        }

        @Test func framesHandedBackAreTheOnesThatWouldBeDrawn() async throws {
            let source = try await Self.movie()
            defer { try? FileManager.default.removeItem(at: source) }
            let reusing = try await Self.composition(of: source, reusesFrames: true)
            let drawing = try await Self.composition(of: source, reusesFrames: false)
            let handedBack = try await Self.composedFrames(reusing)
            let drawn = try await Self.composedFrames(drawing)

            #expect(handedBack.count == 360 && drawn.count == 360, "\(handedBack.count), \(drawn.count) frames")
            let different = zip(handedBack, drawn).enumerated().filter { $0.element.0.time != $0.element.1.time || $0.element.0.bytes != $0.element.1.bytes }
            #expect(different.isEmpty, "frames \(different.map(\.offset)) differ")
            // Frames were handed back (before the zoom, in its hold, the still page under the caption once the cursor
            // has settled: 70 of them when this was written), and none where reuse is off.
            let counts = reusing.frameCounts
            #expect(counts.reused >= 30 && counts.drawn + counts.reused == 360, "\(counts)")
            #expect(drawing.frameCounts.reused == 0 && drawing.frameCounts.drawn == 360, "\(drawing.frameCounts)")
            print("StudioCompositorTests: \(counts.reused) of 360 frames handed back, \(counts.mostInFlight) at once at most")
        }

        @Test func aMovieExportedWithFramesHandedBackShowsWhatOneWithEveryFrameShows() async throws {
            let source = try await Self.movie()
            let outputs = (0..<2).map { _ in FileManager.default.temporaryDirectory.appending(path: "OMSStudioCompositor-\(UUID().uuidString).mp4") }
            defer { ([source] + outputs).forEach { try? FileManager.default.removeItem(at: $0) } }
            let reusing = try await Self.composition(of: source, reusesFrames: true)
            let drawing = try await Self.composition(of: source, reusesFrames: false)
            _ = try await StudioExporter.export(reusing, to: outputs[0])
            _ = try await StudioExporter.export(drawing, to: outputs[1])
            let reused = reusing.frameCounts.reused
            #expect(reused > 0)

            /// Every frame of the movie, decoded as a player decodes it, in RGB.
            func decoded(_ url: URL) async throws -> [(time: CMTime, bytes: Data)] {
                let asset = AVURLAsset(url: url)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: try #require(try await asset.loadTracks(withMediaType: .video).first), outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ])
                reader.add(output)
                #expect(reader.startReading())
                var frames: [(time: CMTime, bytes: Data)] = []
                while let sample = output.copyNextSampleBuffer() {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    frames.append((sample.presentationTimeStamp, Self.bytes(of: buffer)))
                }
                return frames
            }
            let held = try await decoded(outputs[0])
            let every = try await decoded(outputs[1])
            // Each frame handed back was left out, but the last: it is written again, so the video reaches the end.
            #expect(every.count == 360 && held.count < 360 && held.count >= 360 - reused, "\(held.count) and \(every.count) frames, \(reused) handed back")
            #expect(held.first?.time == every.first?.time && held.last?.time == every.last?.time, "\(String(describing: held.last?.time.seconds))")
            for url in outputs {
                let asset = AVURLAsset(url: url)
                let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
                let length = try await asset.load(.duration).seconds, videoEnd = try await track.load(.timeRange).end.seconds
                #expect(abs(length - 6) < 0.02 && abs(videoEnd - 6) < 0.02, "\(url.lastPathComponent): \(length) s, video to \(videoEnd) s")
            }

            // At every time, the frame showing then (the last one at or before it) is the same picture. The encoder
            // may encode the same pixels a little differently when other encoder sessions run (Docs/perf.md, "Studio
            // movie quality"), so to within a trace of compression.
            var shown = 0, same = 0
            var worst = 0.0
            for (index, frame) in every.enumerated() {
                while shown + 1 < held.count, held[shown + 1].time <= frame.time { shown += 1 }
                let showing = held[shown]
                if showing.bytes == frame.bytes {
                    same += 1
                    continue
                }
                let difference = zip(showing.bytes, frame.bytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                let mean = Double(difference) / Double(frame.bytes.count)
                worst = max(worst, mean)
                #expect(showing.bytes.count == frame.bytes.count && mean < 1.5, "at \(frame.time.seconds) s (frame \(index)): mean difference \(mean)")
            }

            // Seeking into a held frame finds it: in the zoom's hold, and in the still end.
            func picture(_ url: URL, at seconds: Double) async throws -> CGImage {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            }
            for seconds in [1.0, 1.95, 5.5, 5.99] {
                let a = try Self.rgba(try await picture(outputs[0], at: seconds)), b = try Self.rgba(try await picture(outputs[1], at: seconds))
                let mean = Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(max(a.count, 1))
                #expect(a.count == b.count && mean < 1.5, "at \(seconds) s: mean difference \(mean)")
            }
            print("StudioCompositorTests: \(held.count) of \(every.count) frames encoded, \(same) shown exactly the same, worst mean difference \(worst)")
        }

        /// A picture's pixels, as sRGB bytes.
        private static func rgba(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }

        @Test func drawingWithoutWaitingDrawsWhatRenderingDrew() throws {
            // Frames with all there is on them: the zoom moving (several exposures) and holding, the cursor and the
            // click's effect, the caption.
            let renderer = StudioRenderer(
                telemetry: Self.telemetry(), project: Self.project(), duration: 6, recordingSize: CGSize(width: 320, height: 200), background: nil
            )
            let source = CIImage(color: CIColor(red: 0.35, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
            let canvas = renderer.layout.canvas
            func buffer() throws -> CVPixelBuffer {
                var made: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(canvas.width), Int(canvas.height), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [
                    kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                ] as CFDictionary, &made)
                let buffer = try #require(made)
                // Tagged as the composition tags the movie's frames.
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                return buffer
            }
            for time in [0.1, 0.35, 1.0, 2.35, 4.8] {
                let image = renderer.image(source: source, at: time)
                let rendered = try buffer(), drawn = try buffer()
                let space = try #require(CVBufferCopyAttachments(rendered, .shouldPropagate).flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() })
                StudioCompositor.context.render(image, to: rendered, bounds: CGRect(origin: .zero, size: canvas), colorSpace: space)
                _ = try StudioCompositor.startDrawing(image, into: drawn, canvas: canvas, colorSpace: space).waitUntilCompleted()
                #expect(Self.bytes(of: rendered) == Self.bytes(of: drawn), "at \(time) s")
            }
        }

        @Test func cancellingFinishesEveryFrameAskedFor() async throws {
            let source = try await Self.movie()
            defer { try? FileManager.default.removeItem(at: source) }
            let composition = try await Self.composition(of: source, reusesFrames: true)
            let reader = try AVAssetReader(asset: composition.asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await composition.asset.loadTracks(withMediaType: .video), videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            output.videoComposition = composition.videoComposition
            reader.add(output)
            #expect(reader.startReading())
            for _ in 0..<20 { _ = output.copyNextSampleBuffer() }
            let compositor = try #require(output.customVideoCompositor as? StudioCompositor)
            // Cancelling while frames are on their way finishes each, and returns. (AVFoundation cancels too, from
            // its own threads: when reading starts and stops, and when a player seeks.)
            let cancelledBefore = compositor.cancelCount
            let returned = await Self.within(seconds: 10) { () -> Bool in
                compositor.cancelAllPendingVideoCompositionRequests()
                return true
            }
            #expect(returned == true && compositor.cancelCount > cancelledBefore)
            reader.cancelReading()
            let drained = await Self.within(seconds: 10) { () -> Bool in
                while compositor.pendingCount > 0 { usleep(1_000) }
                return true
            }
            #expect(drained == true && compositor.pendingCount == 0)

            // An export cancelled partway stops, leaves no file, and the same composition exports after.
            let destination = FileManager.default.temporaryDirectory.appending(path: "OMSStudioCompositor-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: destination) }
            let cancellation = PartwayCancellation()
            let export = Task {
                try await StudioExporter.export(composition, to: destination, progress: { fraction in
                    if fraction > 0.4 { cancellation.cancel() }
                })
            }
            cancellation.set(export)
            let stopped = await Self.within(seconds: 30) { () -> String in
                do {
                    _ = try await export.value
                    return "finished"
                } catch {
                    return error is CancellationError ? "cancelled" : String(describing: error)
                }
            }
            #expect(stopped == "cancelled" && !FileManager.default.fileExists(atPath: destination.path), "\(String(describing: stopped))")
            let movie = try await StudioExporter.export(composition, to: destination)
            #expect(movie.byteCount > 0)
        }

        @Test func aPlayerDrawsTheMovieAndGoesOnAfterASeek() async throws {
            let source = try await Self.movie()
            defer { try? FileManager.default.removeItem(at: source) }
            let composition = try await Self.composition(of: source, reusesFrames: true)
            let item = AVPlayerItem(asset: composition.asset)
            item.videoComposition = composition.videoComposition
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            defer { player.pause() }
            /// How many new frames the player shows over `seconds`.
            func framesShown(over seconds: Double) async throws -> Int {
                var shown = 0
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { shown += 1 }
                    try await Task.sleep(for: .milliseconds(5))
                }
                return shown
            }
            player.play()
            let first = try await framesShown(over: 1)
            #expect(first > 10, "\(first) frames shown")
            let compositor = try #require(item.customVideoCompositor as? StudioCompositor)
            let cancelledBefore = compositor.cancelCount
            // Seeking cancels the frames on their way; drawing goes on from the new place.
            await player.seek(to: CMTime(value: 2, timescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
            await player.seek(to: CMTime(value: 1, timescale: 2), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            let after = try await framesShown(over: 1)
            #expect(after > 10, "\(after) frames shown after seeking")
            #expect(compositor.cancelCount > cancelledBefore && compositor.pendingCount <= StudioCompositor.framesInFlight)
            #expect(item.status == .readyToPlay && item.error == nil, "\(String(describing: item.error))")
        }

        /// What `work` returns, run off the main actor, or nil if it took longer than `seconds`: a frame never
        /// finished fails the test rather than hanging it.
        private static func within<Value: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> Value) async -> Value? {
            let race = Race()
            return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                Task.detached {
                    let value = await work()
                    if race.win() { continuation.resume(returning: value) }
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(seconds))
                    if race.win() { continuation.resume(returning: nil) }
                }
            }
        }
    }
}

/// Whichever of two finishes first.
nonisolated private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func win() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// Cancels an export once it is partway, from its progress handler, whichever thread that runs on.
nonisolated private final class PartwayCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<StudioExporter.Movie, Error>?
    private var cancelled = false

    func set(_ task: Task<StudioExporter.Movie, Error>) {
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }
}
