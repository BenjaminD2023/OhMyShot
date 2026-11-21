import CoreImage
import CoreVideo
import Foundation
import OMSCore
import Testing
@testable import OMSStudio

/// What the camera shows behind the person: the room as it was, blurred, or cut away, in every layout, and the
/// matte made once for each of the camera's frames.
struct StudioCameraBackgroundTests {
    /// Blends in sRGB as the movie's compositor does.
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private static let size = CGSize(width: 320, height: 200)

    private static func project(_ layout: StudioProject.Camera.Layout, background: StudioProject.Camera.Background) -> StudioProject {
        var project = StudioProject(background: .color(red: 0, green: 0, blue: 1), padding: 0.1)
        project.shadow = 0.5
        project.cornerRadius = 0
        project.camera.layout = layout
        project.camera.mirrored = false
        project.camera.background = background
        return project
    }

    /// A matte with the person on the left half of the frame.
    nonisolated private static func leftHalf() -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 12))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12)))
    }

    /// The same as Vision hands it back: one byte a pixel, which Core Image reads into red alone.
    nonisolated private static func visionLeftHalf() -> CIImage? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 12, kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<12 { for x in 0..<16 { base[y * row + x] = x < 8 ? 255 : 0 } }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// A green recording and a red camera, the person found by `segmenter` instead of Vision.
    private static func frame(
        of project: StudioProject, segmenter: (@Sendable (CIImage, Bool) -> CIImage?)? = { _, _ in leftHalf() }
    ) throws -> (image: CGImage, renderer: StudioRenderer) {
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)],
            camera: .init(start: 0, bubble: project.camera)
        )
        let renderer = StudioRenderer(
            telemetry: telemetry, project: project, duration: 4, recordingSize: size, background: nil,
            layout: StudioRenderer.layout(recordingSize: size, project: project, hasCamera: true), ringColor: .systemBlue, preparedTrack: nil,
            cameraMatte: StudioCameraMatte(quality: .preview, segmenter: segmenter)
        )
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let canvas = CGRect(origin: .zero, size: renderer.layout.canvas)
        let image = try #require(Self.context.createCGImage(renderer.image(source: green, camera: red, at: 1), from: canvas))
        return (image, renderer)
    }

    /// The color at `x`, `y` (y up, as the layout has it), red, green, blue, and alpha from 0 to 255.
    private static func color(of image: CGImage, x: Double, y: Double) throws -> [Double] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -Int(x), y: -Int(y), width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Double(bytes[$0]) }
    }

    private static func isRed(_ color: [Double]) -> Bool { color[0] > 245 && color[1] < 10 && color[2] < 10 }
    private static func isGreen(_ color: [Double]) -> Bool { color[1] > 245 && color[0] < 10 && color[2] < 10 }
    private static func isBlue(_ color: [Double]) -> Bool { color[2] > 245 && color[0] < 10 && color[1] < 10 }

    // MARK: Keeping

    @Test func aCameraSavedBeforeBackgroundsShowsTheRoomAsItWas() throws {
        let old = try JSONDecoder().decode(StudioProject.Camera.self, from: Data(#"{"isShown":true,"shape":"circle"}"#.utf8))
        #expect(old.background == .original)
        // One from a newer version, unknown here, shows the room as it was rather than losing the camera.
        let newer = try JSONDecoder().decode(StudioProject.Camera.self, from: Data(#"{"layout":"sideBySide","background":"studio"}"#.utf8))
        #expect(newer.background == .original && newer.layout == .sideBySide)
        let camera = StudioProject.Camera(background: .cutout)
        #expect(try JSONDecoder().decode(StudioProject.Camera.self, from: JSONEncoder().encode(camera)) == camera)
    }

    // MARK: Drawing

    @Test func blurAndCutoutChangeOnlyWhatIsAroundThePerson() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)
        let checks = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 0, blue: 0), "inputColor1": CIColor(red: 0, green: 0, blue: 1), "inputWidth": 2,
        ])
        let frame = try #require(checks?.outputImage).cropped(to: extent)
        let matte = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 48))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let original = try #require(Self.context.createCGImage(frame, from: extent))
        let cut = try #require(Self.context.createCGImage(StudioRenderer.treated(frame, background: .cutout, matte: matte), from: extent))
        let blurred = try #require(Self.context.createCGImage(StudioRenderer.treated(frame, background: .blur, matte: matte), from: extent))
        for x in [5.0, 10, 21] {
            let person = try Self.color(of: original, x: x, y: 24)
            #expect(try Self.color(of: cut, x: x, y: 24) == person)
            #expect(try Self.color(of: blurred, x: x, y: 24) == person)
        }
        // Around the person: nothing, cut out; blurred, the red and the blue run together.
        let room = try Self.color(of: cut, x: 50, y: 24)
        #expect(room[3] == 0, "cut out: \(room)")
        let soft = try Self.color(of: blurred, x: 50, y: 24)
        #expect(soft[0] > 60 && soft[2] > 60 && soft[3] > 250, "blurred: \(soft)")
        // As it was without a matte, or with the Original background.
        #expect(StudioRenderer.treated(frame, background: .cutout, matte: nil) === frame)
        #expect(StudioRenderer.treated(frame, background: .original, matte: matte) === frame)
    }

    @Test func aCutOutPersonSitsOnTheRecordingWithNoBubble() throws {
        let (cut, renderer) = try Self.frame(of: Self.project(.pictureInPicture, background: .cutout))
        let bubble = try #require(renderer.camera?.bubble)
        // The person on the bubble's left, the recording right through the rest of it, and no ring or shadow.
        #expect(Self.isRed(try Self.color(of: cut, x: bubble.minX + bubble.width * 0.25, y: bubble.midY)))
        #expect(Self.isGreen(try Self.color(of: cut, x: bubble.minX + bubble.width * 0.75, y: bubble.midY)))
        // On the ring, inside the circle's edge on the bubble's right.
        let ring = (x: bubble.midX + bubble.width * 0.25, y: bubble.midY + sqrt(pow(bubble.width * 0.475, 2) - pow(bubble.width * 0.25, 2)))
        let shadow = (x: bubble.midX, y: bubble.minY - 6)
        #expect(Self.isGreen(try Self.color(of: cut, x: ring.x, y: ring.y)))
        #expect(Self.isGreen(try Self.color(of: cut, x: shadow.x, y: shadow.y)))
        // The room as it was, or blurred, keeps the bubble's ring and shadow.
        for background in [StudioProject.Camera.Background.original, .blur] {
            let (image, _) = try Self.frame(of: Self.project(.pictureInPicture, background: background))
            let edge = try Self.color(of: image, x: ring.x, y: ring.y)
            #expect(edge[0] > 200 && edge[1] > 200 && edge[2] > 200, "\(background) ring: \(edge)")
            #expect(Self.isRed(try Self.color(of: image, x: bubble.minX + bubble.width * 0.75, y: bubble.midY)), "\(background)")
        }
        // Where the person can't be found, the camera shows as it was, in its bubble.
        let (lost, _) = try Self.frame(of: Self.project(.pictureInPicture, background: .cutout), segmenter: { _, _ in nil })
        let edge = try Self.color(of: lost, x: ring.x, y: ring.y)
        #expect(edge[0] > 200 && edge[1] > 200 && edge[2] > 200, "ring: \(edge)")
        #expect(Self.isRed(try Self.color(of: lost, x: bubble.minX + bubble.width * 0.75, y: bubble.midY)))
    }

    @Test func aCutOutPersonFillingTheMovieStandsOnItsBackground() throws {
        let (cut, renderer) = try Self.frame(of: Self.project(.cameraOnly, background: .cutout))
        let frame = renderer.layout.frame
        #expect(Self.isRed(try Self.color(of: cut, x: frame.minX + frame.width * 0.25, y: frame.midY)))
        #expect(Self.isBlue(try Self.color(of: cut, x: frame.minX + frame.width * 0.75, y: frame.midY)))
        // No frame to cast a shadow under it.
        let under = (x: frame.minX + frame.width * 0.75, y: frame.minY - 4)
        #expect(Self.isBlue(try Self.color(of: cut, x: under.x, y: under.y)))
        let (original, _) = try Self.frame(of: Self.project(.cameraOnly, background: .original))
        #expect(Self.isRed(try Self.color(of: original, x: frame.minX + frame.width * 0.75, y: frame.midY)))
        #expect(try Self.color(of: original, x: under.x, y: under.y)[2] < 245)
    }

    @Test func aCutOutPersonBesideTheRecordingStandsOnTheBackground() throws {
        let (cut, renderer) = try Self.frame(of: Self.project(.sideBySide, background: .cutout))
        let pane = try #require(renderer.layout.camera)
        #expect(Self.isRed(try Self.color(of: cut, x: pane.minX + pane.width * 0.2, y: pane.midY)))
        #expect(Self.isBlue(try Self.color(of: cut, x: pane.minX + pane.width * 0.8, y: pane.midY)))
        #expect(Self.isGreen(try Self.color(of: cut, x: renderer.layout.frame.midX, y: renderer.layout.frame.midY)))
        // No picture's edge to cast a shadow under it.
        let under = (x: pane.minX + pane.width * 0.8, y: pane.minY - 4)
        #expect(Self.isBlue(try Self.color(of: cut, x: under.x, y: under.y)))
        let (original, _) = try Self.frame(of: Self.project(.sideBySide, background: .original))
        #expect(Self.isRed(try Self.color(of: original, x: pane.minX + pane.width * 0.8, y: pane.midY)))
        #expect(try Self.color(of: original, x: under.x, y: under.y)[2] < 245)
    }

    @Test func visionsOneChannelMatteKeepsThePerson() throws {
        let (cut, renderer) = try Self.frame(of: Self.project(.sideBySide, background: .cutout), segmenter: { _, _ in Self.visionLeftHalf() })
        let pane = try #require(renderer.layout.camera)
        #expect(Self.isRed(try Self.color(of: cut, x: pane.minX + pane.width * 0.2, y: pane.midY)))
        #expect(Self.isBlue(try Self.color(of: cut, x: pane.minX + pane.width * 0.8, y: pane.midY)))
        // Blurred around them, in a frame with edges to blur: the person stays sharp, the room runs together.
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)
        let checks = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 0, blue: 0), "inputColor1": CIColor(red: 0, green: 0, blue: 1), "inputWidth": 2,
        ])
        let frame = try #require(checks?.outputImage).cropped(to: extent)
        let matte = try #require(StudioCameraMatte(quality: .preview) { _, _ in Self.visionLeftHalf() }.matte(for: frame, at: 0))
        let original = try #require(Self.context.createCGImage(frame, from: extent))
        let blurred = try #require(Self.context.createCGImage(StudioRenderer.treated(frame, background: .blur, matte: matte), from: extent))
        for x in [5.0, 10, 21] {
            #expect(try Self.color(of: blurred, x: x, y: 24) == Self.color(of: original, x: x, y: 24))
        }
        let soft = try Self.color(of: blurred, x: 50, y: 24)
        #expect(soft[0] > 60 && soft[2] > 60 && soft[3] > 250, "blurred: \(soft)")
    }

    // MARK: Matte

    @Test func eachCameraFrameIsLookedAtOnceAndAJumpStartsAfresh() throws {
        nonisolated final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Bool] = []
            var fresh: [Bool] { lock.withLock { values } }
            func append(_ value: Bool) { lock.withLock { values.append(value) } }
        }
        let calls = Calls()
        let matte = StudioCameraMatte(quality: .preview) { _, fresh in
            calls.append(fresh)
            return Self.leftHalf()
        }
        func cameraFrame() throws -> CIImage {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            return CIImage(cvPixelBuffer: try #require(buffer))
        }
        let first = try cameraFrame(), second = try cameraFrame(), later = try cameraFrame(), earlier = try cameraFrame()
        let made = try #require(matte.matte(for: first, at: 0))
        #expect(made.extent == first.extent)
        // The movie's next frame shows the same camera frame: Vision isn't asked again.
        _ = matte.matte(for: first, at: 1.0 / 60)
        _ = matte.matte(for: second, at: 2.0 / 60)
        #expect(calls.fresh == [true, false])
        // Further on, or back, a sequence of its own.
        _ = matte.matte(for: later, at: 2)
        _ = matte.matte(for: earlier, at: 1.9)
        #expect(calls.fresh == [true, false, true, true])
        // A picture with no decoder's frame behind it is looked at each time.
        let drawn = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        _ = matte.matte(for: drawn, at: 1.9 + 1.0 / 30)
        _ = matte.matte(for: drawn, at: 1.9 + 1.0 / 30)
        #expect(calls.fresh.count == 6)
    }

    @Test func visionLooksAtACameraFrameWithNoOneInIt() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = CIImage(cvPixelBuffer: try #require(buffer))
        // Whatever this Mac's Vision can do, the matte, when there is one, covers the frame.
        if let matte = StudioCameraMatte(quality: .preview).matte(for: frame, at: 0) {
            #expect(matte.extent == frame.extent)
        }
    }
}
