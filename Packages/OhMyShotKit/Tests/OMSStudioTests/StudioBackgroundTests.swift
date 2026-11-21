import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMSStudio

/// A picture or the recording blurred behind a Studio movie: the picture kept in the project's folder, read no
/// larger than it shows, drawn covering the movie in the preview and the export alike; the recording blurred
/// behind itself as it plays.
@MainActor
struct StudioBackgroundTests {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A PNG of `width` × `height`, red on its left half and blue on its right, written somewhere of its own.
    private static func picture(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let url = try folder().appending(path: "chosen.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func pixelSize(of url: URL) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(width: try #require(properties[kCGImagePropertyPixelWidth] as? Int), height: try #require(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    private static func color(of image: CGImage, x: Int, y: Int) throws -> [Double] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Double(bytes[$0]) }
    }

    // MARK: Keeping

    @Test func aPictureIsKeptInTheProjectsFolderOnce() throws {
        let chosen = try Self.picture(width: 64, height: 40)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent()) }
        let name = try StudioBackgroundPicture.keep(chosen, in: folder)
        #expect(name.hasPrefix(StudioBackgroundPicture.prefix) && name.hasSuffix(".png"))
        #expect(try Data(contentsOf: folder.appending(path: name)) == Data(contentsOf: chosen))
        // Chosen again, it is the same picture under the same name.
        #expect(try StudioBackgroundPicture.keep(chosen, in: folder) == name)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == [name])
        // A name never reaches outside the folder.
        #expect(StudioBackgroundPicture.url(named: "../../\(name)", in: folder) == folder.appending(path: name))
    }

    @Test func aLargePictureIsKeptNoLargerThanABackgroundNeeds() throws {
        let chosen = try Self.picture(width: 5000, height: 120)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent()) }
        let name = try StudioBackgroundPicture.keep(chosen, in: folder)
        let kept = try Self.pixelSize(of: folder.appending(path: name))
        #expect(kept.width == CGFloat(StudioBackgroundPicture.largestSide))
        #expect(abs(kept.height - 120 * kept.width / 5000) <= 1)
        // Opaque, it is kept as a JPEG.
        #expect(name.hasSuffix(".jpg"))
    }

    @Test func aFileThatIsNotAPictureIsRefused() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appending(path: "notes.png")
        try Data("not a picture".utf8).write(to: text)
        let into = folder.appending(path: "project", directoryHint: .isDirectory)
        #expect(throws: (any Error).self) { try StudioBackgroundPicture.keep(text, in: into) }
        #expect(!FileManager.default.fileExists(atPath: into.path(percentEncoded: false)))
    }

    @Test func aPictureIsReadNoLargerThanTheMovieShowsIt() throws {
        let chosen = try Self.picture(width: 2000, height: 1000)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent()) }
        let name = try StudioBackgroundPicture.keep(chosen, in: folder)
        // Covering 640 × 360 takes it at 0.36 of its size: 720 × 360.
        let small = try #require(StudioBackgroundPicture.image(named: name, in: folder, covering: CGSize(width: 640, height: 360)))
        #expect(small.width == 720 && small.height == 360)
        // Never larger than it is.
        let whole = try #require(StudioBackgroundPicture.image(named: name, in: folder, covering: CGSize(width: 3840, height: 2160)))
        #expect(whole.width == 2000 && whole.height == 1000)
        #expect(StudioBackgroundPicture.image(named: "background-gone.png", in: folder, covering: CGSize(width: 640, height: 360)) == nil)
    }

    @Test func picturesPutAsideGoWhenTheProjectIsOpenedAgain() throws {
        let first = try Self.picture(width: 64, height: 40)
        let second = try Self.picture(width: 40, height: 64)
        let folder = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let used = try StudioBackgroundPicture.keep(first, in: folder)
        let aside = try StudioBackgroundPicture.keep(second, in: folder)
        try Data("{}".utf8).write(to: folder.appending(path: StudioFiles.telemetry))
        try JSONEncoder().encode(StudioProject(background: .picture(used))).write(to: folder.appending(path: StudioFiles.project))
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2),
            project: StudioProject(background: .picture(used)), duration: 4, recordingSize: CGSize(width: 320, height: 200), folder: folder,
            hasBeenExported: false, background: { _, _ in nil }
        )
        #expect(document.lastPicture == used)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: used).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: aside).path(percentEncoded: false)))
        // The project's other files stay.
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: StudioFiles.telemetry).path(percentEncoded: false)))
        // Its tile is read once, no larger than the tile: this one is smaller than that already.
        #expect(document.pictureThumbnail(used)?.width == 64)
    }

    @Test func picturesStayWhileTheProjectCantBeRead() throws {
        let first = try Self.picture(width: 64, height: 40)
        let second = try Self.picture(width: 40, height: 64)
        let folder = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let named = try StudioBackgroundPicture.keep(first, in: folder)
        let aside = try StudioBackgroundPicture.keep(second, in: folder)
        func open() {
            _ = StudioDocument(
                source: folder.appending(path: "none.mp4"), telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2),
                project: StudioProject(), duration: 4, recordingSize: CGSize(width: 320, height: 200), folder: folder,
                hasBeenExported: true, background: { _, _ in nil }
            )
        }
        func kept(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) }
        // Opened on defaults with no project to read, every picture stays.
        open()
        #expect(kept(named) && kept(aside))
        // A project from a newer version, naming its picture in a form this one can't read, keeps that picture.
        try Data(#"{"background":{"video":"\#(named)"}}"#.utf8).write(to: folder.appending(path: StudioFiles.project))
        open()
        #expect(kept(named) && !kept(aside))
    }

    @Test func aPictureGoneFromTheFolderGivesWayToTheDefaultInTheProject() async throws {
        let chosen = try Self.picture(width: 64, height: 40)
        let folder = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent())
        }
        let name = try StudioBackgroundPicture.keep(chosen, in: folder)
        try FileManager.default.removeItem(at: folder.appending(path: name))
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2),
            project: StudioProject(background: .picture(name)), duration: 4, recordingSize: CGSize(width: 320, height: 200), folder: folder,
            hasBeenExported: true, background: { _, _ in nil }
        )
        // The movie in the history was made with the picture: it is made again.
        #expect(document.project.background == .gradient(StudioDocument.missingPictureGradient))
        #expect(document.hasUnexportedChanges && document.lastPicture == nil)
        // Choosing the same picture again is a change of its own.
        document.markExported()
        try await document.choosePicture(at: chosen)
        #expect(document.project.background == .picture(name) && document.hasUnexportedChanges)
    }

    @Test func theNewBackgroundsAreKeptWithTheProject() throws {
        for background in [StudioProject.Background.picture("background-0123456789abcdef.png"), .blur] {
            let project = StudioProject(background: background)
            #expect(try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project)) == project)
        }
        // A background this version doesn't know takes the default, and the rest of the project is kept.
        let json = #"{"background":{"video":{"_0":"x"}},"padding":0.2}"#
        let project = try JSONDecoder().decode(StudioProject.self, from: Data(json.utf8))
        #expect(project.background == StudioProject().background && project.padding == 0.2)
    }

    // MARK: Drawing

    /// The movie at `time` from a recording that is `recording`, 320 × 200, drawn by `project` with `background`.
    private static func frame(_ project: StudioProject, background: CGImage?, recording: CIImage) throws -> (image: CGImage, layout: StudioRenderer.Layout) {
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)])
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 320, height: 200), background: background)
        let canvas = CGRect(origin: .zero, size: renderer.layout.canvas)
        return (try #require(context.createCGImage(renderer.image(source: recording, at: 1), from: canvas)), renderer.layout)
    }

    private static let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 200))

    @Test func aPictureCoversTheMovieAroundTheRecording() throws {
        let chosen = try Self.picture(width: 400, height: 400)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent()) }
        let name = try StudioBackgroundPicture.keep(chosen, in: folder)
        var project = StudioProject(background: .picture(name), padding: 0.2, aspect: .widescreen)
        project.shadow = 0
        let layout = StudioRenderer.layout(recordingSize: CGSize(width: 320, height: 200), project: project, hasCamera: false)
        let picture = try #require(StudioBackgroundPicture.image(named: name, in: folder, covering: layout.canvas))
        let (image, made) = try Self.frame(project, background: picture, recording: Self.green)
        // The square picture covers the wide movie: its red half on the left, its blue half on the right, cut at the
        // top and bottom rather than stretched.
        #expect(try Self.color(of: image, x: 2, y: 2) == [255, 0, 0])
        #expect(try Self.color(of: image, x: Int(made.canvas.width) - 3, y: Int(made.canvas.height) - 3) == [0, 0, 255])
        // The recording sits on it as it does on a gradient.
        #expect(try Self.color(of: image, x: Int(made.frame.midX), y: Int(made.canvas.height - made.frame.midY)) == [0, 255, 0])
    }

    @Test func theBlurredRecordingIsTheRecordingBehindItself() throws {
        // Red on the left, blue on the right.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 200))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 160, y: 0, width: 160, height: 200))
        var project = StudioProject(background: .blur, padding: 0.25)
        project.shadow = 0
        let (image, layout) = try Self.frame(project, background: nil, recording: blue.composited(over: red))
        let left = try Self.color(of: image, x: 2, y: Int(layout.canvas.height) / 2)
        let right = try Self.color(of: image, x: Int(layout.canvas.width) - 3, y: Int(layout.canvas.height) / 2)
        #expect(left[0] > 200 && left[2] < 60, "\(left)")
        #expect(right[2] > 200 && right[0] < 60, "\(right)")
        // Blurred: between them, the colors run together.
        let middle = try Self.color(of: image, x: Int(layout.canvas.width) / 2, y: 2)
        #expect(middle[0] > 40 && middle[2] > 40, "\(middle)")
        // And it follows the recording as it plays.
        let (green, _) = try Self.frame(project, background: nil, recording: Self.green)
        let corner = try Self.color(of: green, x: 2, y: 2)
        #expect(corner[1] > 240 && corner[0] < 15 && corner[2] < 15, "\(corner)")
    }

    // MARK: The movie made

    /// A one-second movie, 320 × 200, a flat gray.
    private static func movie() async throws -> URL {
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
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetBytesPerRow(pixels) * 200)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func theMovieTakesItsPictureFromTheProjectAndTheDefaultWhenItHasGone() async throws {
        let chosen = try Self.picture(width: 400, height: 400)
        let folder = try Self.folder()
        let source = try await Self.movie()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: source)
        }
        // The default gradient, painted as a flat magenta for this test.
        let magenta = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ).map { context -> CGImage? in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            return context.makeImage()
        } ?? nil)
        let document = StudioDocument(
            source: source, telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)]),
            project: StudioProject(padding: 0.2), duration: 1, recordingSize: CGSize(width: 320, height: 200), folder: folder,
            hasBeenExported: false, background: { name, _ in name == StudioDocument.missingPictureGradient ? magenta : nil }
        )
        try await document.choosePicture(at: chosen)
        let name = try #require(document.lastPicture)
        #expect(document.project.background == .picture(name))
        func corner() async throws -> [Double] {
            let renderer = try await document.makeExportComposition().renderer
            let canvas = CGRect(origin: .zero, size: renderer.layout.canvas)
            let image = try #require(Self.context.createCGImage(renderer.image(source: Self.green, at: 0.5), from: canvas))
            return try Self.color(of: image, x: 1, y: 1)
        }
        #expect(try await corner() == [255, 0, 0])
        try FileManager.default.removeItem(at: folder.appending(path: name))
        #expect(try await corner() == [255, 0, 255])
    }
}
