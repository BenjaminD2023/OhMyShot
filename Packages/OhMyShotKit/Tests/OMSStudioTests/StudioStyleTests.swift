import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMSStudio

/// The cursor's styles, the clicks' effects and colors, and how projects saved before them open.
struct StudioStyleTests {
    // MARK: Projects

    @Test func aProjectSavedBeforeStylesOpensWithTheOldLook() throws {
        // As the first version saved it: a cursor without style or effect, a camera without a layout.
        let old = #"{"background":{"gradient":{"_0":"sky"}},"padding":0.1,"cornerRadius":12,"shadow":0.6,"aspect":"auto","cursor":{"size":2,"smoothing":0.5,"hidesWhenIdle":true,"showsClicks":false},"zooms":[],"cuts":[],"showsKeys":true,"camera":{"isShown":true,"shape":"roundedSquare","size":260,"corner":"topRight","mirrored":false}}"#
        let project = try JSONDecoder().decode(StudioProject.self, from: Data(old.utf8))
        #expect(project.cursor.style == .recorded)
        #expect(project.cursor.clickEffect == .ring && project.cursor.clickColor == .accent)
        // Clicks that were off stay off.
        #expect(!project.cursor.showsClicks && project.cursor.size == 2)
        #expect(project.camera.layout == .pictureInPicture && project.camera.isShown)
        #expect(project.camera.side == .right)
        #expect(project.camera.shape == .roundedSquare && project.camera.size == 260 && project.camera.corner == .topRight && !project.camera.mirrored)
    }

    @Test func aHiddenCameraStaysHiddenAsScreenOnly() throws {
        let hidden = #"{"isShown":false,"shape":"circle","size":120,"corner":"bottomRight","mirrored":true}"#
        let camera = try JSONDecoder().decode(StudioProject.Camera.self, from: Data(hidden.utf8))
        #expect(camera.layout == .screenOnly && !camera.isShown)
        // Saved again, a version that knows no layouts still finds the camera hidden.
        let saved = try JSONEncoder().encode(camera)
        let keys = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(keys["isShown"] as? Bool == false && keys["layout"] as? String == "screenOnly")
    }

    @Test func showingTheCameraAgainBringsBackTheBubble() {
        var camera = StudioProject.Camera(layout: .sideBySide)
        camera.isShown = false
        #expect(camera.layout == .screenOnly)
        camera.isShown = true
        #expect(camera.layout == .pictureInPicture)
        // Showing what is shown changes nothing.
        camera.layout = .cameraOnly
        camera.isShown = true
        #expect(camera.layout == .cameraOnly)
        #expect(StudioProject.Camera(isShown: false).layout == .screenOnly)
    }

    @Test func everyNewSettingIsKept() throws {
        var project = StudioProject()
        project.cursor.style = .highlight
        project.cursor.clickEffect = .ripple
        project.cursor.clickColor = .purple
        project.cursor.showsClicks = false
        project.camera.layout = .sideBySide
        project.camera.side = .left
        let data = try JSONEncoder().encode(project)
        let again = try JSONDecoder().decode(StudioProject.self, from: data)
        #expect(again == project)
        #expect(again.cursor.style == .highlight && again.cursor.clickEffect == .ripple && again.cursor.clickColor == .purple)
        #expect(!again.cursor.showsClicks && again.camera.layout == .sideBySide && again.camera.side == .left)
        // And a different value of each, so a field missing from what is saved can't pass by being the default.
        var other = project
        other.cursor.style = .arrow
        other.cursor.clickEffect = .ring
        other.cursor.clickColor = .white
        other.camera.layout = .cameraOnly
        other.camera.side = .right
        #expect(try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(other)) == other)
    }

    @Test func aNameFromANewerVersionTakesTheDefaultInsteadOfLosingTheProject() throws {
        let newer = #"{"padding":0.2,"cursor":{"style":"neon","clickEffect":"burst","clickColor":"teal","size":2.5},"camera":{"layout":"splitScreen","isShown":true,"side":"top"}}"#
        let project = try JSONDecoder().decode(StudioProject.self, from: Data(newer.utf8))
        #expect(project.padding == 0.2 && project.cursor.size == 2.5)
        #expect(project.cursor.style == .recorded && project.cursor.clickEffect == .ring && project.cursor.clickColor == .accent)
        #expect(project.camera.layout == .pictureInPicture && project.camera.side == .right)
    }

    @Test func theAccentIsTheUsersAndTheOthersAreFixed() {
        #expect(StudioProject.ClickColor.accent.rgb == nil)
        for color in StudioProject.ClickColor.allCases where color != .accent {
            let rgb = color.rgb
            #expect(rgb != nil && (0...1).contains(rgb!.red) && (0...1).contains(rgb!.green) && (0...1).contains(rgb!.blue), "\(color)")
        }
    }

    // MARK: Click effects

    @Test func theRingIsTheOneShownWhileRecording() throws {
        let effect = StudioProject.ClickEffect.ring
        #expect(effect.diameter == 54 && effect.lifetime == 0.4)
        // 0.1 s in, easing out: 1/3 widening toward 1, fading by the same ease.
        let eased = 1 - 0.75 * 0.75
        let piece = try #require(effect.pieces(age: 0.1).first)
        #expect(effect.pieces(age: 0.1).count == 1)
        #expect(abs(piece.size - (1.0 / 3 + 2.0 / 3 * eased)) < 1e-9 && abs(piece.opacity - (1 - eased)) < 1e-9)
        // At the click it is a third of its size and fully there; it is gone at 0.4 s.
        let first = try #require(effect.pieces(age: 0).first)
        #expect(abs(first.size - 1.0 / 3) < 1e-9 && first.opacity == 1)
        #expect(effect.pieces(age: 0.4).isEmpty && effect.pieces(age: -0.1).isEmpty)
    }

    @Test func aRippleIsTwoWavesTheSecondBehindTheFirst() throws {
        let effect = StudioProject.ClickEffect.ripple
        #expect(effect.diameter == 72)
        #expect(abs(effect.lifetime - 0.69) < 1e-9)
        // Only the first wave before the second begins at 0.14 s.
        #expect(effect.pieces(age: 0.1).count == 1)
        let both = effect.pieces(age: 0.3)
        #expect(both.count == 2)
        // The first is further out and fainter than the second.
        #expect(both[0].size > both[1].size && both[0].opacity < both[1].opacity)
        // Each widens from a fifth of its size to all of it, fading as it goes.
        let start = try #require(effect.pieces(age: 0).first)
        #expect(abs(start.size - 0.2) < 1e-9 && start.opacity == 1)
        let late = try #require(effect.pieces(age: 0.6).first)
        #expect(late.size > 0.9 && late.opacity < 0.1)
        // The first wave is over at 0.55 s, the second at 0.69 s.
        #expect(effect.pieces(age: 0.6).count == 1)
        #expect(effect.pieces(age: 0.7).isEmpty)
    }

    // MARK: Drawing

    /// Blends in sRGB as the movie's compositor does.
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private static let canvas = CGRect(x: 0, y: 0, width: 320, height: 200)

    private static func plain() -> StudioProject {
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
        project.shadow = 0
        project.cornerRadius = 0
        return project
    }

    private static func frame(_ renderer: StudioRenderer, source: CIImage, at time: Double) throws -> CGImage {
        try #require(Self.context.createCGImage(renderer.image(source: source, at: time), from: canvas))
    }

    private static var white: CIImage { CIImage(color: .white).cropped(to: canvas) }

    /// The pixel's red, green, and blue in sRGB, counted from the top-left.
    private static func color(of image: CGImage, x: Int, y: Int) throws -> [Double] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Double(bytes[$0]) }
    }

    /// The line of a ring 0.03 s after a click on a white page, the pixel across it with the least of `channel`:
    /// the ring is then 54 × 0.43 points across and 86% there.
    private static func ringLine(_ project: StudioProject, accent: StudioRenderer.RingColor = .systemBlue, least channel: Int) throws -> [Double] {
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)],
            clicks: [.init(time: 1, x: 80, y: 50, button: .primary)]
        )
        let renderer = StudioRenderer(
            telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil, ringColor: accent
        )
        let frame = try Self.frame(renderer, source: Self.white, at: 1.03)
        let piece = try #require(StudioProject.ClickEffect.ring.pieces(age: 0.03).first)
        let radius = 54 * 2 * piece.size / 2
        let across = try (Int(160 + radius * 0.8)...Int(160 + radius + 2)).map { try Self.color(of: frame, x: $0, y: 100) }
        return try #require(across.min { $0[channel] < $1[channel] })
    }

    @Test func aClickShowsInTheColorChosen() throws {
        var project = Self.plain()
        project.cursor.clickColor = .red
        // Red over white: the red stays full, green and blue fall.
        let line = try Self.ringLine(project, least: 1)
        #expect(line[0] > 240 && line[1] < 140 && line[2] < 140, "\(line)")
    }

    @Test func theAccentIsTheOneTheUserHas() throws {
        // The accent is what the renderer is given; a color chosen is its own, whatever the accent.
        var project = Self.plain()
        let green = StudioRenderer.RingColor(red: 0, green: 1, blue: 0)
        // Green accent: the line has no red.
        let accent = try Self.ringLine(project, accent: green, least: 0)
        #expect(accent[0] < 100 && accent[1] > 240 && accent[2] < 100, "\(accent)")
        // Chosen blue, the same accent: the blue is full and the red falls; the green falls less.
        project.cursor.clickColor = .blue
        let blue = try Self.ringLine(project, accent: green, least: 0)
        #expect(blue[0] < 100 && blue[2] > 240 && blue[1] > 100 && blue[1] < 200, "\(blue)")
    }

    @Test func aRippleIsABareLine() throws {
        var project = Self.plain()
        project.cursor.clickEffect = .ripple
        project.cursor.clickColor = .red
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)],
            clicks: [.init(time: 1, x: 80, y: 50, button: .primary)]
        )
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
        // 0.2 s in: the first wave out at 72 × (0.2 + 0.8 × 0.595) points across, the second behind it.
        let frame = try Self.frame(renderer, source: Self.white, at: 1.2)
        let pieces = StudioProject.ClickEffect.ripple.pieces(age: 0.2)
        #expect(pieces.count == 2)
        func darkest(near radius: Double) throws -> [Double] {
            let row = try (Int(160 + radius - 4)...Int(160 + radius + 4)).map { try Self.color(of: frame, x: $0, y: 100) }
            return try #require(row.min { $0[1] < $1[1] })
        }
        // Radii in pixels: half the diameter in points, times two pixels a point.
        let outer = 72 * pieces[0].size, inner = 72 * pieces[1].size
        let first = try darkest(near: outer)
        let second = try darkest(near: inner)
        #expect(first[0] > 240 && first[1] < 230, "\(first)")
        #expect(second[0] > 240 && second[1] < 230, "\(second)")
        // Between the two waves and in the middle, the page is as white as it was: no wash.
        #expect(try Self.color(of: frame, x: 160 + Int((outer + inner) / 2), y: 100).min()! > 250)
        #expect(try Self.color(of: frame, x: 160, y: 100).min()! > 250)
    }

    @Test func noEffectLeavesThePage() throws {
        var project = Self.plain()
        project.cursor.showsClicks = false
        let telemetry = StudioTelemetry(
            width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)],
            clicks: [.init(time: 1, x: 80, y: 50, button: .primary)]
        )
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
        let frame = try Self.frame(renderer, source: Self.white, at: 1.1)
        for x in stride(from: 100, to: 260, by: 4) {
            #expect(try Self.color(of: frame, x: x, y: 100).min()! > 250)
        }
    }

    // MARK: Cursor styles

    /// A black square `side` points wide as a cursor's picture at four pixels a point, its hot spot at its
    /// top-left corner.
    private static func squareCursor(side: Double = 8) throws -> StudioTelemetry.Cursor {
        let pixels = Int(side * 4)
        let context = try #require(CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return StudioTelemetry.Cursor(png: data as Data, scale: 4, width: side, height: side, hotSpotX: 0, hotSpotY: 0)
    }

    private static func pointer(_ cursors: [StudioTelemetry.Cursor]) -> StudioTelemetry {
        StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)], cursors: cursors)
    }

    @Test func theHighlightIsALightUnderTheCursor() throws {
        var project = Self.plain()
        project.cursor.size = 1
        project.cursor.showsClicks = false
        let telemetry = Self.pointer([try Self.squareCursor()])
        func frame(_ style: StudioProject.Cursor.Style) throws -> CGImage {
            project.cursor.style = style
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
            return try Self.frame(renderer, source: Self.white, at: 0.5)
        }
        // The pointer is at 160, 100 on the movie. Up and to the left of it, outside the square: the light.
        let lit = try Self.color(of: try frame(.highlight), x: 160 - 16, y: 100 - 16)
        // 8 points from the hot spot, well inside the halo's solid 60%: white under a warm yellow at 0.40.
        #expect(lit[0] > 250 && lit[1] > 225 && lit[1] < 245 && lit[2] > 150 && lit[2] < 200, "\(lit)")
        // As recorded, the same place is the page.
        #expect(try Self.color(of: try frame(.recorded), x: 160 - 16, y: 100 - 16).min()! > 250)
        // Far outside the halo (42 points out), the page; and the cursor itself is still drawn.
        let highlighted = try frame(.highlight)
        #expect(try Self.color(of: highlighted, x: 160 - 60, y: 100 - 60).min()! > 250)
        #expect(try Self.color(of: highlighted, x: 160 + 8, y: 100 + 8).max()! < 20)
    }

    @Test func theHighlightGrowsWithTheCursor() throws {
        var project = Self.plain()
        project.cursor.style = .highlight
        project.cursor.showsClicks = false
        let telemetry = Self.pointer([try Self.squareCursor()])
        func lit(size: Double) throws -> Bool {
            project.cursor.size = size
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
            let frame = try Self.frame(renderer, source: Self.white, at: 0.5)
            // 36 pixels up and to the left of the pointer is 25 points away: beyond the halo's radius of 22
            // points at 1×, and inside the solid 60% of its 44 points' radius at 2×.
            return try Self.color(of: frame, x: 160 - 36, y: 100 - 36)[2] < 245
        }
        #expect(try !lit(size: 1))
        #expect(try lit(size: 2))
    }

    @Test func theArrowIsDrawnWhateverWasRecorded() throws {
        var project = Self.plain()
        project.cursor.size = 1
        project.cursor.showsClicks = false
        // Nothing recorded as a cursor: as recorded, nothing shows; as the arrow, the arrow does.
        let telemetry = Self.pointer([])
        func frame(_ style: StudioProject.Cursor.Style) throws -> CGImage {
            project.cursor.style = style
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
            return try Self.frame(renderer, source: Self.white, at: 0.5)
        }
        // The tip is the hot spot; 1.5 points right and 5 down is inside the arrow's body, black.
        let arrow = try frame(.arrow)
        #expect(try Self.color(of: arrow, x: 160 + 3, y: 100 + 10).max()! < 30)
        #expect(try Self.color(of: try frame(.recorded), x: 160 + 3, y: 100 + 10).min()! > 250)
        // Left of the tip and above it, the page; its white edge is no darker than the page.
        #expect(try Self.color(of: arrow, x: 160 - 12, y: 100 - 12).min()! > 250)
        // Beyond the arrow's width (11 points) on the row of its tip, the page.
        #expect(try Self.color(of: arrow, x: 160 + 40, y: 100 + 2).min()! > 250)
    }

    @Test func theArrowGrowsWithTheSize() throws {
        var project = Self.plain()
        project.cursor.style = .arrow
        project.cursor.showsClicks = false
        let telemetry = Self.pointer([])
        func black(size: Double) throws -> Bool {
            project.cursor.size = size
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 2, recordingSize: CGSize(width: 320, height: 200), background: nil)
            let frame = try Self.frame(renderer, source: Self.white, at: 0.5)
            // Down the arrow's left edge, 36 pixels below its tip: black if the arrow reaches that far.
            return try Self.color(of: frame, x: 160 + 3, y: 100 + 36).max()! < 60
        }
        // At 1× the arrow's left edge is 16.2 points long, and 36 pixels is 18 points: past it. At 2× it is 32.4.
        #expect(try !black(size: 1))
        #expect(try black(size: 2))
    }
}
