import AVFoundation
import CoreImage
import CoreText
import Foundation
import Testing
import VideoToolbox
@testable import OMSStudio

/// One at a time: with a third encoder session at once the same settings made movies two or three times as
/// large, which the tests that count bytes would measure (Docs/perf.md, "Studio movie quality").
@Suite(.serialized)
struct StudioExportTests {
    /// A movie of `seconds` at 30 fps, 320 × 200, its gray stepping up each second.
    private static func movie(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 200,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(60 + frame / 30 * 40), CVPixelBufferGetBytesPerRow(pixels) * 200)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private static func telemetry() -> StudioTelemetry {
        StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2,
            samples: stride(from: 0.0, through: 3, by: 1.0 / 60).map { .init(time: $0, x: 20 + 30 * $0, y: 50, cursor: 0) },
            clicks: [.init(time: 1, x: 50, y: 50, button: .primary)]
        )
    }

    @Test func aStudioMovieIsFramedAndCut() async throws {
        let source = try await Self.movie(seconds: 3)
        let output = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString).mp4")
        defer { [source, output].forEach { try? FileManager.default.removeItem(at: $0) } }

        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0.25, zooms: [
            .init(start: 0.5, end: 2, scale: 2, isAutomatic: true),
        ], cuts: [2...2.5])
        project.shadow = 0
        let renderer = StudioRenderer(telemetry: Self.telemetry(), project: project, duration: 3, recordingSize: CGSize(width: 320, height: 200), background: nil)
        // A quarter of the shorter side around it: 50 pixels each way.
        #expect(renderer.layout.canvas == CGSize(width: 420, height: 300))
        #expect(renderer.layout.frame == CGRect(x: 50, y: 50, width: 320, height: 200))

        let composition = try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: project.cuts)
        #expect(abs(composition.duration - 2.5) < 0.01)
        let movie = try await StudioExporter.export(composition, to: output)
        #expect((movie.pixelWidth, movie.pixelHeight) == (420, 300))
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 2.5) < 0.05)

        // The background is there around the frame; the recording's gray is inside it.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        #expect(image.width == 420 && image.height == 300)
        #expect(try Self.gray(of: image, x: 10, y: 10) > 240)
        let inside = try Self.gray(of: image, x: 300, y: 100)
        #expect(inside > 40 && inside < 90, "\(inside)")
    }

    /// A second of 320 × 200 at 30 fps in two flat colors, a gray on the left and an orange on the right,
    /// tagged Rec. 709 as ScreenCaptureKit's frames are.
    private static func twoColorMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 200,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            for y in 0..<200 {
                for x in 0..<320 {
                    // BGRA: a gray of 100 on the left, an orange (230, 120, 40) on the right.
                    let (red, green, blue): (UInt8, UInt8, UInt8) = x < 160 ? (100, 100, 100) : (230, 120, 40)
                    let pixel = base + y * row + x * 4
                    pixel[0] = blue
                    pixel[1] = green
                    pixel[2] = red
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func theRecordingsColorsComeThroughAsTheyWere() async throws {
        let source = try await Self.twoColorMovie()
        let output = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString).mp4")
        defer { [source, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
        project.shadow = 0
        project.cornerRadius = 0
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2)
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 1, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let composition = try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: [])
        _ = try await StudioExporter.export(composition, to: output)

        // Both read back as a player shows them, by their tags.
        func picture(_ url: URL) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        }
        let before = try await picture(source)
        let after = try await picture(output)
        for (x, y) in [(80, 100), (240, 100)] {
            let was = try Self.color(of: before, x: x, y: y), now = try Self.color(of: after, x: x, y: y)
            for channel in 0..<3 {
                #expect(abs(was[channel] - now[channel]) <= 4, "at \(x),\(y): \(was) became \(now)")
            }
        }
        // And the movie says how its colors are encoded, as the recording does.
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        #expect(extensions[kCVImageBufferYCbCrMatrixKey as String] as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        #expect(extensions[kCVImageBufferTransferFunctionKey as String] as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    }

    /// Four seconds of 640 × 400 at 30 fps: a page of text scrolling 16 pixels a frame, encoded as the recorder
    /// encodes (constant quality 0.6, real time, no B-frames, a key frame every two seconds), so it weighs what a
    /// recording of text does. Flat colors weigh the same at every quality.
    private static func scrollingText() async throws -> URL {
        let width = 640, height = 400, fps = 30
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.6, AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 2,
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

        // Three screens of lines of words, drawn once.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let pageContext = try #require(CGContext(
            data: nil, width: width, height: height * 3, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo
        ))
        pageContext.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1))
        pageContext.fill(CGRect(x: 0, y: 0, width: width, height: height * 3))
        let words = ["screen", "capture", "studio", "movie", "quality", "export", "pointer", "zoom", "frame", "cursor", "the", "of", "and", "a", "to", "in", "is", "that", "for", "with"]
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 22, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
        ]
        var seed: UInt64 = 12345
        var baseline = Double(height * 3) - 30
        while baseline > 20 {
            var line = ""
            while line.count < 64 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                line += words[Int(seed >> 33) % words.count] + " "
            }
            pageContext.textPosition = CGPoint(x: 24, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), pageContext)
            baseline -= 32
        }
        let page = try #require(pageContext.makeImage())

        for frame in 0..<(4 * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try #require(CGContext(
                data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: sRGB, bitmapInfo: bitmapInfo
            ))
            context.draw(page, in: CGRect(x: 0, y: -height * 2 + frame * 16 % (height * 2), width: width, height: height * 3))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// The scrolling text exported at each quality with `project`: the movie's bytes at each, and the bytes the
    /// estimate gives for each.
    private static func exportedAtEveryQuality(
        _ source: URL, project: StudioProject
    ) async throws -> [StudioProject.Quality: (made: Int, estimated: Int?)] {
        let size = CGSize(width: 640, height: 400)
        let sourceBytes = try #require(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        var results: [StudioProject.Quality: (made: Int, estimated: Int?)] = [:]
        for quality in StudioProject.Quality.allCases {
            var project = project
            project.quality = quality
            let output = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let telemetry = StudioTelemetry(width: 320, height: 200, pixelsPerPoint: 2)
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: size, background: nil)
            let composition = try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: project.cuts)
            let movie = try await StudioExporter.export(composition, to: output)
            let estimate = StudioExporter.estimatedByteCount(
                sourceByteCount: sourceBytes, sourceSize: size, sourceDuration: 4, canvas: renderer.layout.canvas, keptDuration: composition.duration,
                quality: quality
            )
            results[quality] = (movie.byteCount, estimate)
        }
        return results
    }

    @Test func aBetterQualityMakesALargerMovieOfTheSamePicture() async throws {
        let source = try await Self.scrollingText()
        defer { try? FileManager.default.removeItem(at: source) }
        let made = try await Self.exportedAtEveryQuality(source, project: StudioProject()).mapValues { $0.made }
        let smaller = try #require(made[.smaller]), standard = try #require(made[.standard]), best = try #require(made[.best])
        #expect(smaller < standard && standard < best, "\(smaller), \(standard), \(best) bytes")
    }

    @Test func theEstimateIsCloseToTheMovieMadeAtEveryQuality() async throws {
        let source = try await Self.scrollingText()
        defer { try? FileManager.default.removeItem(at: source) }
        // The default frame around it. Within half again either way: ten exports of this page at Standard came out
        // 0.72 to 1.30 of the estimate (Docs/perf.md), and another Mac's encoder may spread wider.
        for (quality, result) in try await Self.exportedAtEveryQuality(source, project: StudioProject()) {
            let estimate = try #require(result.estimated)
            #expect(Double(estimate) > Double(result.made) / 1.5 && Double(estimate) < Double(result.made) * 1.5, "\(quality): \(estimate) estimated, \(result.made) made")
        }
    }

    @Test func aClicksRingShowsOnAWhitePage() throws {
        // A white recording, a click in its middle at 1 s; the ring's line a tenth of a second later.
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
        project.shadow = 0
        project.cornerRadius = 0
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)],
            clicks: [.init(time: 1, x: 80, y: 50, button: .primary)]
        )
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let context = CIContext()
        let frame = try #require(context.createCGImage(renderer.image(source: white, at: 1.1), from: CGRect(x: 0, y: 0, width: 320, height: 200)))
        // 0.1 s in, eased: the ring is 54 × (1/3 + 2/3 × 0.4375) points across, its line 2 points inside
        // that; the darkest pixel across it is the line's.
        let eased = 1 - 0.75 * 0.75
        let radius = 54 * 2 * (1.0 / 3 + 2.0 / 3 * eased) / 2
        let across = try (Int(160 + radius * 0.8)...Int(160 + radius + 2)).map { try Self.color(of: frame, x: $0, y: 100) }
        let line = try #require(across.min { $0.min()! < $1.min()! })
        #expect(line.min()! < 200 && line[2] > 240, "\(line)")
        // Away from the ring, the page is still white.
        #expect(try Self.color(of: frame, x: 20, y: 20).min()! > 250)
    }

    /// A camera's movie of `seconds` at 30 fps, 160 × 120, a flat color each second: red, green, blue, white.
    private static func cameraMovie(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-camera-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 120,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let (red, green, blue) = colors[(frame / 30) % colors.count]
            for y in 0..<120 {
                for x in 0..<160 {
                    let pixel = base + y * row + x * 4
                    pixel[0] = blue
                    pixel[1] = green
                    pixel[2] = red
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func theCameraKeepsInStepAroundCuts() async throws {
        let source = try await Self.movie(seconds: 4)
        let camera = try await Self.cameraMovie(seconds: 4)
        let output = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString).mp4")
        defer { [source, camera, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0, cuts: [2...2.5])
        project.shadow = 0
        project.cornerRadius = 0
        project.camera = StudioProject.Camera(shape: .roundedSquare, size: 60, corner: .bottomLeft)
        // The camera's movie began a second after the recording's first frame.
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 150, y: 10, cursor: 0)],
            camera: .init(start: 1, bubble: project.camera)
        )
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), background: nil)
        // 60 points across, 20 in from the bottom-left corner (the recording is only 100 high): in pixels, y up.
        #expect(renderer.camera?.bubble == CGRect(x: 40, y: 40, width: 120, height: 120))
        let composition = try await StudioComposition.make(
            source: AVURLAsset(url: source), renderer: renderer, cuts: project.cuts, camera: .init(asset: AVURLAsset(url: camera), start: 1)
        )
        _ = try await StudioExporter.export(composition, to: output)
        func center(at time: Double) async throws -> [Double] {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            return try Self.color(of: image, x: 100, y: 100)
        }
        // Before the camera began, its first frame is held; then each second's color as the camera's movie
        // had it then, the cut left out of both: movie 2.2 s is the recording's 2.7 s, the camera's 1.7 s.
        let held = try await center(at: 0.5)
        #expect(held[0] > 200 && held[1] < 60 && held[2] < 60, "\(held)")
        let red = try await center(at: 1.5), green = try await center(at: 2.2), blue = try await center(at: 3)
        #expect(red[0] > 200 && red[1] < 60 && red[2] < 60, "\(red)")
        #expect(green[1] > 200 && green[0] < 60 && green[2] < 60, "\(green)")
        #expect(blue[2] > 200 && blue[0] < 60 && blue[1] < 60, "\(blue)")
    }

    @Test func aMovieWithTheCameraIsOneAPlayerCanDraw() async throws {
        // Times made from seconds round either way: a camera a 6000th of a second past the recording's end
        // made the composition one a player draws nothing of, though an export read it.
        let source = try await Self.movie(seconds: 4)
        let camera = try await Self.cameraMovie(seconds: 4)
        defer { [source, camera].forEach { try? FileManager.default.removeItem(at: $0) } }
        var project = StudioProject()
        project.camera = StudioProject.Camera(size: 60)
        for start in [0.3, 0.1, -0.2, 0.7] {
            for cuts in [[], [1.01...2.02], [3.98...4.0], [0.0...0.3]] as [[ClosedRange<Double>]] {
                let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, camera: .init(start: start, bubble: project.camera))
                let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), background: nil)
                let composition = try await StudioComposition.make(
                    source: AVURLAsset(url: source), renderer: renderer, cuts: cuts, camera: .init(asset: AVURLAsset(url: camera), start: start)
                )
                let valid = try await composition.videoComposition.isValid(
                    for: composition.asset, timeRange: CMTimeRange(start: .zero, duration: try await composition.asset.load(.duration)), validationDelegate: nil
                )
                #expect(valid, "camera from \(start) s, cuts \(cuts)")
                // The camera is there from the first frame to the last.
                let tracks = try await composition.asset.loadTracks(withMediaType: .video)
                #expect(tracks.count == 2 && tracks[1].segments.allSatisfy { !$0.isEmpty }, "camera from \(start) s, cuts \(cuts)")
            }
        }
    }

    @Test func theCameraFillsTheFrameWhenItDid() throws {
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
        project.shadow = 0
        project.cornerRadius = 0
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, camera: .init(start: 0, fills: [2...3], bubble: project.camera))
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let context = CIContext()
        func corner(at time: Double) throws -> [Double] {
            let frame = try #require(context.createCGImage(renderer.image(source: white, camera: red, at: time), from: CGRect(x: 0, y: 0, width: 320, height: 200)))
            // The top-right corner: never under the bubble, at the bottom-left.
            return try Self.color(of: frame, x: 300, y: 20)
        }
        #expect(try corner(at: 1.5).min()! > 250)
        let filled = try corner(at: 2.5)
        #expect(filled[0] > 250 && filled[1] < 5, "\(filled)")
        #expect(try corner(at: 3.5).min()! > 250)
        // Hidden, the camera shows nowhere.
        project.camera.isShown = false
        #expect(StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), background: nil).camera == nil)
    }

    @Test func theCameraIsNeverShownTwice() throws {
        // A white recording, a red camera that fills the frame from 2 s: the bubble (bottom-left) fades out over
        // the first half of the change, the frame fills over the second, and halfway there is neither.
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
        project.shadow = 0
        project.cornerRadius = 0
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, camera: .init(start: 0, fills: [2...3], bubble: project.camera))
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let bubble = try #require(renderer.camera?.bubble)
        let context = CIContext()
        func colors(at time: Double) throws -> (bubble: [Double], corner: [Double]) {
            let frame = try #require(context.createCGImage(renderer.image(source: white, camera: red, at: time), from: CGRect(x: 0, y: 0, width: 320, height: 200)))
            return (try Self.color(of: frame, x: Int(bubble.midX), y: 199 - Int(bubble.midY)), try Self.color(of: frame, x: 300, y: 20))
        }
        // A quarter of the way: the bubble half there, nothing filling.
        let quarter = try colors(at: 2 + StudioRenderer.cameraFade * 0.25)
        #expect(quarter.bubble[1] > 40 && quarter.bubble[1] < 230 && quarter.corner.min()! > 250, "\(quarter)")
        // Halfway: neither.
        let half = try colors(at: 2 + StudioRenderer.cameraFade * 0.5)
        #expect(half.bubble.min()! > 250 && half.corner.min()! > 250, "\(half)")
        // Three quarters: the frame half filled, the bubble gone (its spot only as red as the rest).
        let threeQuarters = try colors(at: 2 + StudioRenderer.cameraFade * 0.75)
        #expect(threeQuarters.corner[1] > 40 && threeQuarters.corner[1] < 230, "\(threeQuarters)")
        #expect(abs(threeQuarters.bubble[1] - threeQuarters.corner[1]) < 6, "\(threeQuarters)")
    }

    @Test func aFilledCameraLeavesNothingOfTheRecordingAtItsEdges() throws {
        // A green recording under a red camera filling the frame, its corners rounded, on a white background:
        // along the frame's soft edges only red over white, never green.
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0.1)
        project.shadow = 0
        project.cornerRadius = 20
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, camera: .init(start: 0, fills: [0...4], bubble: project.camera))
        // Filmed smaller than the recording, as the preview is, so the frame's edges fall between pixels.
        let renderer = StudioRenderer(
            telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), background: nil, largestSide: 301
        )
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let canvas = CGRect(origin: .zero, size: renderer.layout.canvas)
        let frame = try #require(CIContext().createCGImage(renderer.image(source: green, camera: red, at: 2), from: canvas))
        let box = renderer.layout.frame
        // Along each rounded corner's diagonal, from outside the frame inward: the soft edge's pixels are red
        // over white (green and blue alike), and some are there to be checked.
        var soft = 0
        for (cornerX, cornerY, stepX, stepY) in [
            (box.minX, box.minY, 1.0, 1.0), (box.maxX - 1, box.minY, -1.0, 1.0), (box.minX, box.maxY - 1, 1.0, -1.0), (box.maxX - 1, box.maxY - 1, -1.0, -1.0),
        ] {
            for step in 0..<24 {
                let x = Int(cornerX + stepX * Double(step)), y = Int(canvas.height - 1 - (cornerY + stepY * Double(step)))
                let pixel = try Self.color(of: frame, x: x, y: y)
                #expect(abs(pixel[1] - pixel[2]) < 6, "at \(x),\(y): \(pixel)")
                if pixel[0] > 200, pixel[2] > 10, pixel[2] < 245 { soft += 1 }
            }
        }
        #expect(soft >= 2, "\(soft) soft edge pixels")
        // And the straight edges' outermost pixels, where the camera scaled as it was blended with clear.
        for x in [Int(box.minX), Int(box.maxX) - 1] {
            let pixel = try Self.color(of: frame, x: x, y: Int(canvas.height - box.midY))
            #expect(abs(pixel[1] - pixel[2]) < 6, "at \(x): \(pixel)")
        }
    }

    @Test func cutsLeaveTheRestEndToEnd() {
        let segments = StudioComposition.keptSegments(duration: 10, cuts: [2...3, 7...12, 2.5...4])
        #expect(segments == [
            .init(movieStart: 0, sourceStart: 0, duration: 2),
            .init(movieStart: 2, sourceStart: 4, duration: 3),
        ])
    }

    /// The pixel's red, green, and blue in sRGB.
    private static func color(of image: CGImage, x: Int, y: Int) throws -> [Double] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Double(bytes[$0]) }
    }

    private static func gray(of image: CGImage, x: Int, y: Int) throws -> Double {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Double(try #require(context.data).assumingMemoryBound(to: UInt8.self)[1])
    }
}
