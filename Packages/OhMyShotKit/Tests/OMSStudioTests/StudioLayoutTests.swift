import CoreImage
import Foundation
import OMSCore
import Testing
@testable import OMSStudio

/// How the camera and the recording share the movie: the geometry of each layout, and what is drawn where.
struct StudioLayoutTests {
    private static func project(_ layout: StudioProject.Camera.Layout, side: StudioProject.Camera.Side = .right) -> StudioProject {
        var project = StudioProject(background: .color(red: 0, green: 0, blue: 1), padding: 0)
        project.shadow = 0
        project.cornerRadius = 0
        project.camera.layout = layout
        project.camera.side = side
        return project
    }

    // MARK: Geometry

    @Test func theRecordingKeepsItsPixelsBesideTheCamera() throws {
        let size = CGSize(width: 320, height: 200)
        let layout = StudioRenderer.layout(recordingSize: size, project: Self.project(.sideBySide), hasCamera: true)
        let camera = try #require(layout.camera)
        // The movie is wider by the gap (2.5% of the height) and the camera's picture (3:4 at the same height),
        // rounded up to an even width.
        #expect(layout.canvas == CGSize(width: 476, height: 200))
        #expect(layout.frame.size == size && layout.scale == 1)
        #expect(camera.height == layout.frame.height && abs(camera.width / camera.height - 0.75) < 0.01)
        // Side by side, not over one another, and both inside the movie.
        #expect(layout.frame.maxX < camera.minX && camera.minX - layout.frame.maxX == 5)
        let movie = CGRect(origin: .zero, size: layout.canvas)
        #expect(movie.contains(layout.frame) && movie.contains(camera))
        #expect(layout.canvas.width.truncatingRemainder(dividingBy: 2) == 0 && layout.canvas.height.truncatingRemainder(dividingBy: 2) == 0)
    }

    @Test func theCameraCanStandOnEitherSide() throws {
        let size = CGSize(width: 320, height: 200)
        let right = StudioRenderer.layout(recordingSize: size, project: Self.project(.sideBySide, side: .right), hasCamera: true)
        let left = StudioRenderer.layout(recordingSize: size, project: Self.project(.sideBySide, side: .left), hasCamera: true)
        #expect(try #require(right.camera).minX > right.frame.maxX - 1)
        #expect(try #require(left.camera).maxX < left.frame.minX + 1)
        // The same room either way.
        #expect(right.canvas == left.canvas)
        #expect(left.frame.minX > right.frame.minX)
    }

    @Test func theOtherLayoutsLeaveTheMovieAsItWas() {
        let size = CGSize(width: 320, height: 200)
        let reference = StudioRenderer.layout(recordingSize: size, project: Self.project(.screenOnly), hasCamera: true)
        for layout in [StudioProject.Camera.Layout.pictureInPicture, .cameraOnly, .screenOnly] {
            let made = StudioRenderer.layout(recordingSize: size, project: Self.project(layout), hasCamera: true)
            #expect(made == reference && made.camera == nil, "\(layout)")
        }
        // And side by side without a camera recorded has nothing to make room for.
        #expect(StudioRenderer.layout(recordingSize: size, project: Self.project(.sideBySide), hasCamera: false) == reference)
        #expect(reference.canvas == CGSize(width: 320, height: 200) && reference.frame == CGRect(x: 0, y: 0, width: 320, height: 200))
    }

    @Test func aMovieOfAFixedShapeCentersBothPictures() throws {
        var project = Self.project(.sideBySide)
        project.aspect = .widescreen
        project.padding = 0.1
        let layout = StudioRenderer.layout(recordingSize: CGSize(width: 1600, height: 1000), project: project, hasCamera: true)
        let camera = try #require(layout.camera)
        // 16:9, to within a pixel of rounding.
        #expect(abs(layout.canvas.width / layout.canvas.height - 16.0 / 9) < 0.01)
        // The pair is centered: as much room left of the pair as right of it, above as below.
        let pair = layout.frame.union(camera)
        #expect(abs(pair.minX - (layout.canvas.width - pair.maxX)) <= 2)
        #expect(abs(pair.minY - (layout.canvas.height - pair.maxY)) <= 2)
        #expect(layout.frame.size == CGSize(width: 1600, height: 1000) || layout.scale < 1)
    }

    @Test func aLargeRecordingIsFilmedSmallerToFitWithTheCamera() throws {
        let layout = StudioRenderer.layout(recordingSize: CGSize(width: 3456, height: 2234), project: Self.project(.sideBySide), hasCamera: true)
        let camera = try #require(layout.camera)
        #expect(max(layout.canvas.width, layout.canvas.height) <= StudioRenderer.largestSide)
        #expect(layout.scale < 1)
        let movie = CGRect(origin: .zero, size: layout.canvas)
        #expect(movie.insetBy(dx: -1, dy: -1).contains(layout.frame) && movie.insetBy(dx: -1, dy: -1).contains(camera))
        #expect(abs(camera.height - layout.frame.height) < 1e-9)
    }

    // MARK: Drawing

    /// Blends in sRGB as the movie's compositor does.
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private static let size = CGSize(width: 320, height: 200)

    /// A recording that is green, a camera that is red.
    private static func frame(of project: StudioProject, camera: Bool = true, at time: Double = 1) throws -> (image: CGImage, layout: StudioRenderer.Layout) {
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)],
            camera: camera ? .init(start: 0, bubble: project.camera) : nil
        )
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: size, background: nil)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
        let canvas = CGRect(origin: .zero, size: renderer.layout.canvas)
        let image = try #require(Self.context.createCGImage(renderer.image(source: green, camera: camera ? red : nil, at: time), from: canvas))
        return (image, renderer.layout)
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

    /// The color at the middle of `rect` (y up, as the layout has it) in `image`.
    private static func color(at rect: CGRect, in image: CGImage) throws -> [Double] {
        try color(of: image, x: Int(rect.midX), y: image.height - 1 - Int(rect.midY))
    }

    @Test func sideBySideShowsTheRecordingAndTheCameraEachInItsPlace() throws {
        let (image, layout) = try Self.frame(of: Self.project(.sideBySide))
        let camera = try #require(layout.camera)
        let screen = try Self.color(at: layout.frame, in: image)
        let person = try Self.color(at: camera, in: image)
        #expect(screen[1] > 250 && screen[0] < 5, "recording: \(screen)")
        #expect(person[0] > 250 && person[1] < 5, "camera: \(person)")
        // The gap between them is the background, here blue.
        let gap = CGRect(x: layout.frame.maxX, y: layout.frame.midY, width: camera.minX - layout.frame.maxX, height: 1)
        let between = try Self.color(at: gap, in: image)
        #expect(between[2] > 250 && between[0] < 5 && between[1] < 5, "gap: \(between)")
        // No bubble over the recording's corner: it is the recording all the way down.
        let corner = try Self.color(of: image, x: Int(layout.frame.minX) + 20, y: image.height - 1 - (Int(layout.frame.minY) + 20))
        #expect(corner[1] > 250 && corner[0] < 5, "corner: \(corner)")
    }

    @Test func theCameraPictureIsCutToTheRecordingsCornersAndThrowsItsShadow() throws {
        var project = Self.project(.sideBySide)
        project.cornerRadius = 30
        project.shadow = 1
        project.padding = 0.1
        let (image, layout) = try Self.frame(of: project)
        let camera = try #require(layout.camera)
        // The camera's top-left corner pixel is rounded away: it shows the background (and shadow), not red.
        let corner = try Self.color(of: image, x: Int(camera.minX) + 1, y: image.height - 1 - Int(camera.maxY) + 1)
        #expect(corner[0] < 200, "corner: \(corner)")
        // Its middle is red; and under it the shadow darkens the blue background.
        #expect(try Self.color(at: camera, in: image)[0] > 250)
        let under = try Self.color(of: image, x: Int(camera.midX), y: image.height - 1 - Int(camera.minY) + 6)
        #expect(under[2] < 250, "under: \(under)")
    }

    @Test func cameraOnlyFillsTheRecordingFromTheFirstFrameToTheLast() throws {
        for time in [0.0, 1.5, 3.9] {
            let (image, layout) = try Self.frame(of: Self.project(.cameraOnly), at: time)
            for (x, y) in [(0.25, 0.25), (0.5, 0.5), (0.9, 0.9), (0.1, 0.9)] {
                let spot = CGRect(x: layout.frame.minX + layout.frame.width * x, y: layout.frame.minY + layout.frame.height * y, width: 1, height: 1)
                let picture = try Self.color(at: spot, in: image)
                #expect(picture[0] > 250 && picture[1] < 5, "at \(time) s, \(x),\(y): \(picture)")
            }
        }
    }

    @Test func pictureInPictureStillHasItsBubble() throws {
        let (image, layout) = try Self.frame(of: Self.project(.pictureInPicture))
        // The bottom-left bubble over the green recording; the top-right corner is the recording.
        let bubble = CGRect(x: layout.frame.minX + 80, y: layout.frame.minY + 80, width: 1, height: 1)
        #expect(try Self.color(at: bubble, in: image)[0] > 250)
        let top = CGRect(x: layout.frame.maxX - 20, y: layout.frame.maxY - 20, width: 1, height: 1)
        #expect(try Self.color(at: top, in: image)[1] > 250)
    }

    @Test func screenOnlyShowsNoCamera() throws {
        let (image, layout) = try Self.frame(of: Self.project(.screenOnly))
        for spot in [CGRect(x: layout.frame.minX + 80, y: layout.frame.minY + 80, width: 1, height: 1), CGRect(x: layout.frame.midX, y: layout.frame.midY, width: 1, height: 1)] {
            let picture = try Self.color(at: spot, in: image)
            #expect(picture[1] > 250 && picture[0] < 5, "\(picture)")
        }
        // No camera in the recording at all: whatever the layout says, the recording alone.
        var project = Self.project(.sideBySide)
        project.padding = 0
        let (alone, aloneLayout) = try Self.frame(of: project, camera: false)
        #expect(aloneLayout.camera == nil)
        #expect(try Self.color(at: aloneLayout.frame, in: alone)[1] > 250)
    }

    @Test func theKeysSitAboveTheRecordingNotTheMiddleOfTheMovie() throws {
        // A caption centers on the recording's picture; beside the camera that is not the movie's middle.
        var project = Self.project(.sideBySide, side: .right)
        project.padding = 0
        project.showsKeys = true
        let keys = [StudioTelemetry.Key(time: 0.5, keyCode: 1, modifiers: 1 << 20, characters: "s", keyCharacters: "s", isRepeat: false)]
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)], keys: keys, keystrokeMode: .all,
            camera: .init(start: 0, bubble: project.camera)
        )
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: Self.size, background: nil)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(origin: .zero, size: Self.size))
        let canvas = CGRect(origin: .zero, size: renderer.layout.canvas)
        let image = try #require(Self.context.createCGImage(renderer.image(source: green, at: 1), from: canvas))
        // The caption is light: find the columns of the lowest rows of the recording that are not green.
        var lit: [Int] = []
        let y = image.height - 1 - Int(renderer.layout.frame.minY + 28 * 2 + 26)
        for x in 0..<image.width where try Self.color(of: image, x: x, y: y)[0] > 100 { lit.append(x) }
        let middle = try #require(lit.isEmpty ? nil : Double(lit.min()! + lit.max()!) / 2)
        #expect(abs(middle - renderer.layout.frame.midX) < 6, "caption at \(middle), recording's middle \(renderer.layout.frame.midX)")
    }
}
