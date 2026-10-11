import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import OMSStudio

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
