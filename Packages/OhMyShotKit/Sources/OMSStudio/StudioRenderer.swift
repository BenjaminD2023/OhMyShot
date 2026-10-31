import AppKit
import CoreImage
import CoreText
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OMSCore
import SwiftUI

/// Films one frame of a Studio recording: the background, the recording framed on it with its shadow and
/// rounded corners, zoomed where the camera looks, the cursor drawn again over it (as recorded, as an arrow,
/// or with a circle of light), an effect at each click, the camera in a bubble in a corner (never zoomed),
/// in a picture beside the recording, or filling the frame, and the keys pressed at the foot. Core Image, so
/// frames are drawn on the GPU; what does not change from frame to frame (the background, the shadows, the
/// cursors, the click effects, the bubble's ring, each caption) is made once.
///
/// Sizes: the recording is framed at its own pixels where it can be, the background around it, so its text
/// stays as sharp as it was; a movie that would be larger than `largestSide` is filmed smaller to fit.
nonisolated public final class StudioRenderer: @unchecked Sendable {
    public struct Layout: Equatable, Sendable {
        /// The movie's size in pixels, both sides even.
        public let canvas: CGSize
        /// Where the recording sits, in the movie's pixels (y up, as Core Image draws).
        public let frame: CGRect
        /// Where the camera's own picture sits beside the recording in the side-by-side layout, as tall as the
        /// recording; nil in the other layouts.
        public let camera: CGRect?
        /// The movie's pixels per recording pixel.
        public let scale: Double
    }

    public let layout: Layout
    public let track: StudioTrack
    public let project: StudioProject
    /// The recording's size in pixels, and its pixels per point.
    let recordingSize: CGSize
    let pixelsPerPoint: Double

    private let background: CIImage
    private let shadow: CIImage?
    private let mask: CIImage
    private let cursors: [CursorLook?]
    /// The arrow drawn for the Arrow style, and the circle of light under the cursor for Highlight.
    private let arrow: CursorLook?
    private let halo: CIImage
    private let clicks: [StudioTelemetry.Click]
    let captions: [Caption]
    private let captionRuns: [(start: Double, end: Double)]
    /// The click effect's picture for the main button's clicks, and the dimmer one for the others'.
    private let clickPictures: (primary: CIImage, secondary: CIImage)
    /// The camera's bubble, picture, or fill of the movie; nil without a camera, or with it hidden.
    let camera: CameraLook?
    private let lock = NSLock()
    /// A bounded working set of caption pictures; evicted text is drawn again if the user seeks back.
    private var captionImages: [String: CIImage] = [:]
    private var captionImageOrder: [String] = []
    static let captionCacheLimit = 64

    var cachedCaptionCount: Int { lock.withLock { captionImages.count } }

    /// The longest side a movie is filmed at: 4K's.
    public static let largestSide = 3840.0
    /// Room around a caption's capsule for its shadow, in points.
    static let captionRoom = 12.0

    /// How long the camera takes to fill the recording, or to go back to its bubble, or any change of layout.
    static let cameraFade = StudioCameraPlan.fade

    /// The camera's own picture in the side-by-side layout is this wide for each unit of its height (3:4), and
    /// stands this far from the recording, as a fraction of the recording's height.
    static let cameraPaneAspect = 3.0 / 4
    static let cameraPaneGap = 0.025

    /// The circle of light under the cursor in the Highlight style: its diameter in points at the cursor's
    /// own size, and the color it is made of (a warm yellow at 0.40, holding to 60% of the radius and
    /// feathering to clear at the edge).
    static let haloDiameter = 44.0
    static let haloColor = (red: 1.0, green: 0.85, blue: 0.2)
    static let haloAlpha = 0.40

    /// The camera, made once: for the bubble, where it sits (in the movie's pixels, y up), its shape, the shadow
    /// under it, and the white ring over it, as the bubble on screen draws them; for the side-by-side layout,
    /// where its own picture sits, cut to the recording's corners with the recording's shadow.
    struct CameraLook {
        let bubble: CGRect
        let mask: CIImage
        let shadow: CIImage
        let ring: CIImage
        let mirrored: Bool
        /// When it is in its bubble, when it fills the recording, and when it is neither.
        let plan: StudioCameraPlan
        /// Beside the recording, instead of in a bubble or filling it.
        let pane: Pane?

        struct Pane {
            let rect: CGRect
            let mask: CIImage
            let shadow: CIImage?
        }
    }

    /// A cursor's picture and where its hot spot is: from a recording's, or the arrow drawn for the Arrow style.
    struct CursorLook {
        let image: CIImage
        /// Its size, and the hot spot, in points from its top-left corner.
        let width: Double
        let height: Double
        let hotSpotX: Double
        let hotSpotY: Double
    }

    /// A caption of keys and when it shows.
    struct Caption: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    /// - Parameters:
    ///   - background: the background at the movie's size, for gradients (painted by the editor's code); nil
    ///     draws the project's plain color, or white.
    ///   - largestSide: the longest side the movie may have; the preview films it smaller than the export.
    ///   - ringColor: the clicks' rings, in sRGB: the user's accent, as the rings shown while recording.
    ///   - preparedTrack: a track already built for these motion settings; shared by preview and export.
    public init(
        telemetry: StudioTelemetry, project: StudioProject, duration: Double, recordingSize: CGSize, background: CGImage?,
        largestSide: Double = StudioRenderer.largestSide, ringColor: RingColor = .systemBlue, preparedTrack: StudioTrack? = nil
    ) {
        self.project = project
        self.recordingSize = recordingSize
        pixelsPerPoint = telemetry.width > 0 ? Double(recordingSize.width) / telemetry.width : telemetry.pixelsPerPoint
        track = preparedTrack ?? StudioTrack(telemetry: telemetry, project: project, duration: duration)
        let layout = Self.layout(recordingSize: recordingSize, project: project, hasCamera: telemetry.camera != nil, largestSide: largestSide)
        self.layout = layout
        let canvas = CGRect(origin: .zero, size: layout.canvas)

        if let background {
            let image = CIImage(cgImage: background)
            self.background = image.transformed(by: CGAffineTransform(
                scaleX: layout.canvas.width / image.extent.width, y: layout.canvas.height / image.extent.height
            ))
        } else if case .color(let red, let green, let blue) = project.background {
            self.background = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: canvas)
        } else {
            self.background = CIImage(color: .white).cropped(to: canvas)
        }

        let radius = project.cornerRadius * pixelsPerPoint * layout.scale
        mask = Self.roundedMask(layout.frame, radius: radius)

        shadow = Self.shadowImage(frame: layout.frame, radius: radius, strength: project.shadow, unit: pixelsPerPoint * layout.scale, canvas: canvas)
        cursors = telemetry.cursors.map { cursor in
            guard let source = CGImageSourceCreateWithData(cursor.png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return CursorLook(
                image: CIImage(cgImage: image), width: cursor.width, height: cursor.height, hotSpotX: cursor.hotSpotX, hotSpotY: cursor.hotSpotY
            )
        }
        arrow = project.cursor.style == .arrow ? Self.arrowLook() : nil
        halo = Self.haloImage()
        clicks = telemetry.clicks.sorted { $0.time < $1.time }
        captions = project.showsKeys ? Self.captions(for: telemetry.keys, mode: project.keystrokeMode) : []
        captionRuns = Self.captionRuns(for: captions)
        let effectColor = project.cursor.clickColor.rgb.map { RingColor(red: $0.red, green: $0.green, blue: $0.blue) } ?? ringColor
        clickPictures = (
            Self.clickPicture(project.cursor.clickEffect, color: effectColor, strokeAlpha: 0.9),
            Self.clickPicture(project.cursor.clickEffect, color: effectColor, strokeAlpha: 0.55)
        )
        let unit = pixelsPerPoint * layout.scale
        let recording = CGSize(width: telemetry.width, height: telemetry.height)
        let plan = StudioCameraPlan(camera: project.camera, segments: project.cameraSegments, recordedFills: telemetry.camera?.fills ?? [])
        camera = plan.usesCamera ? telemetry.camera.map { take in
            Self.cameraLook(
                take: take, settings: project.camera, plan: plan, layout: layout, recording: recording, unit: unit, radius: radius,
                shadowStrength: project.shadow, canvas: canvas
            )
        } : nil
    }

    /// Where everything goes for a recording `recordingSize` pixels with `project`'s padding and shape. With
    /// the camera beside the recording (`hasCamera`, which is whether there is a camera's movie to show, and the
    /// side-by-side layout), the movie is wider by the camera's picture and the gap before it, so the recording
    /// keeps its own pixels.
    public static func layout(recordingSize: CGSize, project: StudioProject, hasCamera: Bool, largestSide: Double = largestSide) -> Layout {
        let width = Double(recordingSize.width), height = Double(recordingSize.height)
        let padding = max(0, project.padding) * min(width, height)
        let beside = hasCamera && project.camera.layout == .sideBySide
        let gap = beside ? (height * cameraPaneGap).rounded() : 0
        let cameraWidth = beside ? (height * cameraPaneAspect).rounded() : 0
        let content = width + gap + cameraWidth
        var canvas = CGSize(width: content + padding * 2, height: height + padding * 2)
        if let ratio = project.aspect.ratio {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        let scale = min(1, largestSide / max(canvas.width, canvas.height))
        // Even, rounded up with the camera beside the recording: its picture is cut to the width of the room.
        let wide = Int((canvas.width * scale).rounded()) + (beside ? 1 : 0)
        let evenWidth = max(2, wide) & ~1
        let evenHeight = max(2, Int((canvas.height * scale).rounded())) & ~1
        let size = CGSize(width: evenWidth, height: evenHeight)
        // The recording alone, or with the camera's picture, is centered as one piece.
        let left = ((size.width - content * scale) / 2).rounded()
        let top = ((size.height - height * scale) / 2).rounded()
        let cameraFirst = beside && project.camera.side == .left
        let frame = CGRect(
            x: left + (cameraFirst ? (cameraWidth + gap) * scale : 0).rounded(), y: top, width: width * scale, height: height * scale
        )
        let cameraRect: CGRect? = beside ? CGRect(
            x: cameraFirst ? left : left + ((width + gap) * scale).rounded(), y: top, width: cameraWidth * scale, height: height * scale
        ) : nil
        return Layout(canvas: size, frame: frame, camera: cameraRect, scale: scale)
    }

    /// The movie's frame at `time` (the recording's seconds) from the recording's frame `source` and, when
    /// there is one, the camera's frame then. Whatever it takes from `time` has to be in `isStill` too, or the
    /// compositor hands back a frame that should have changed.
    public func image(source: CIImage, camera cameraFrame: CIImage? = nil, at time: Double) -> CIImage {
        let state = track.frame(at: time)
        let height = Double(recordingSize.height)
        let frame = layout.frame
        // What the camera shows, in the recording's pixels, y up as the source image is.
        let shown = view(state)
        let k = shown.scale
        /// A point in the recording's points (y down) on the movie.
        func onMovie(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: frame.minX + (x * pixelsPerPoint - shown.x) * k, y: frame.minY + (height - y * pixelsPerPoint - shown.y) * k)
        }

        // The camera, in its bubble, filling the frame, or neither, as the plan has it. From one to the other,
        // what belongs to the first fades out over the first half of the change and what belongs to the second
        // fades in over the second, as the bubble on screen fades out and in: the person is never shown twice.
        let picture = camera.flatMap { look in cameraFrame.map { Self.oriented($0, mirrored: look.mirrored) } }
        let levels = camera?.plan.levels(at: time) ?? StudioCameraPlan.Levels(bubble: 0, fill: 0)
        // Beside the recording, the camera has a picture of its own: no bubble, and it never fills the frame.
        let beside = camera?.pane != nil
        let bubbleOpacity = picture == nil || beside ? 0 : levels.bubble
        let fillOpacity = picture == nil || beside ? 0 : levels.fill

        var scene: CIImage
        if let picture, fillOpacity > 0.999 {
            // Covered by the camera: nothing under it is drawn.
            scene = Self.filling(picture, into: frame)
        } else {
            // The recording as the camera shows it, exposed over the shutter while the camera moves.
            let views = project.motionBlur ? exposures(at: time) : [shown]
            let exposed = views.count > 1 ? blurred(source, over: views, around: shown) : screen(source, shown)
            scene = exposed.cropped(to: frame)
            // The click effects, at each click still showing.
            if project.cursor.showsClicks {
                let effect = project.cursor.clickEffect
                for click in activeClicks(at: time) {
                    let picture = click.button == .primary ? clickPictures.primary : clickPictures.secondary
                    let point = onMovie(click.x, click.y)
                    for piece in effect.pieces(age: time - click.time) {
                        let diameter = effect.diameter * pixelsPerPoint * k * piece.size
                        let scaled = picture.transformed(by: CGAffineTransform(scaleX: diameter / picture.extent.width, y: diameter / picture.extent.height))
                        let placed = scaled.transformed(by: CGAffineTransform(translationX: point.x - diameter / 2, y: point.y - diameter / 2))
                        scene = Self.faded(placed, opacity: piece.opacity).composited(over: scene)
                    }
                }
            }
            // The cursor, its hot spot on the pointer's place, with the circle of light under it in the Highlight style.
            if state.cursorOpacity > 0.01 {
                let point = onMovie(state.cursorX, state.cursorY)
                if project.cursor.style == .highlight {
                    let diameter = Self.haloDiameter * project.cursor.size * pixelsPerPoint * k
                    let scaled = halo.transformed(by: CGAffineTransform(scaleX: diameter / halo.extent.width, y: diameter / halo.extent.height))
                    let placed = scaled.transformed(by: CGAffineTransform(translationX: point.x - diameter / 2, y: point.y - diameter / 2))
                    scene = Self.faded(placed, opacity: state.cursorOpacity).composited(over: scene)
                }
                let look = project.cursor.style == .arrow ? arrow : (state.cursor < cursors.count ? cursors[state.cursor] : nil)
                if let look {
                    let imageScale = look.image.extent.width / look.width
                    let size = project.cursor.size * pixelsPerPoint * k / imageScale
                    let hotSpot = CGPoint(x: look.hotSpotX * imageScale * size, y: (look.height - look.hotSpotY) * imageScale * size)
                    let placed = look.image
                        .transformed(by: CGAffineTransform(scaleX: size, y: size))
                        .transformed(by: CGAffineTransform(translationX: point.x - hotSpot.x, y: point.y - hotSpot.y))
                    scene = Self.faded(placed, opacity: state.cursorOpacity).composited(over: scene)
                }
            }
            // The camera filling the frame goes over everything in it before the frame's shape is cut: cut apart,
            // the recording showed through along the soft edges.
            if let picture, fillOpacity > 0.001 {
                scene = Self.faded(Self.filling(picture, into: frame), opacity: fillOpacity).composited(over: scene)
            }
        }
        scene = scene
            .cropped(to: frame)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputMaskImageKey: mask, kCIInputBackgroundImageKey: CIImage.empty()])

        var movie = background
        if let shadow { movie = shadow.composited(over: movie) }
        if let pane = camera?.pane, let paneShadow = pane.shadow { movie = paneShadow.composited(over: movie) }
        movie = scene.composited(over: movie)
        if let pane = camera?.pane, let picture {
            let inPane = Self.filling(picture, into: pane.rect)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputMaskImageKey: pane.mask, kCIInputBackgroundImageKey: CIImage.empty()])
            movie = inPane.composited(over: movie)
        }
        if let look = camera, let picture, bubbleOpacity > 0.001 { movie = bubble(look, picture: picture, opacity: bubbleOpacity, over: movie) }
        if let caption = caption(at: time) { movie = caption.composited(over: movie) }
        return movie.cropped(to: CGRect(origin: .zero, size: layout.canvas))
    }

    /// Whether the frames at `a` and `b` (the recording's seconds) come out alike from the same recording's
    /// frame, with no camera's: everything `image` takes from the time is the same at both. The camera holds
    /// the same view, the cursor stands as it stood, and each is drawn once, with no blur; no click's effect
    /// shows; the caption is the same, at full opacity or none at both; the camera's bubble and fill are
    /// at the same levels. False where any of that may differ, so a frame is drawn again rather than kept
    /// wrongly.
    func isStill(from a: Double, to b: Double) -> Bool {
        guard track.frame(at: a) == track.frame(at: b) else { return false }
        if project.motionBlur, exposures(at: a).count != 1 || exposures(at: b).count != 1 { return false }
        if project.cursor.showsClicks, !activeClicks(at: a).isEmpty || !activeClicks(at: b).isEmpty { return false }
        switch (captionIndex(at: a), captionIndex(at: b)) {
        case (nil, nil):
            break
        case (let first?, let second?):
            // A caption at 0.999 or more is drawn as it is, unfaded.
            let opacities = (captionOpacity(at: a, index: first), captionOpacity(at: b, index: second))
            guard captions[first].text == captions[second].text,
                  opacities.0 >= 0.999 && opacities.1 >= 0.999 || opacities.0 == 0 && opacities.1 == 0 else { return false }
        default:
            return false
        }
        return camera?.plan.levels(at: a) == camera?.plan.levels(at: b)
    }

    // MARK: Motion

    /// What the camera shows at `state`: the corner of what it shows, in the recording's pixels (y up), and
    /// how much larger it draws them.
    struct View: Equatable {
        let x: Double
        let y: Double
        let scale: Double
    }

    /// How long each frame is exposed while the camera moves: half a frame of the movie's 60, as a film
    /// camera's half-open shutter.
    static let shutter = 0.5 / 60
    /// The longest blur, as a fraction of the movie's longer side; and the farthest one exposure lies from
    /// the next at the frame's edges, in the movie's pixels, so the copies read as one smear.
    static let longestBlur = 0.01
    static let exposureSpacing = 1.5
    static let mostExposures = 32

    func view(_ state: StudioTrack.Frame) -> View {
        let width = Double(recordingSize.width), height = Double(recordingSize.height)
        let visibleWidth = width / state.zoom, visibleHeight = height / state.zoom
        return View(
            x: state.centerX * pixelsPerPoint - visibleWidth / 2, y: height - state.centerY * pixelsPerPoint - visibleHeight / 2,
            scale: layout.frame.width / visibleWidth
        )
    }

    /// The recording drawn as the camera shows it in `view`, cut to `rect` (the frame unless given), its edge
    /// pixels reaching past it so the frame's edge stays solid.
    private func screen(_ source: CIImage, _ view: View, cutTo rect: CGRect? = nil) -> CIImage {
        source
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -view.x, y: -view.y))
            .transformed(by: CGAffineTransform(scaleX: view.scale, y: view.scale))
            .transformed(by: CGAffineTransform(translationX: layout.frame.minX, y: layout.frame.minY))
            .cropped(to: rect ?? layout.frame)
    }

    /// The recording as `views` show it, averaged: drawn once as `center` shows it, with room around the
    /// frame for what the others reach, and each exposure moved from there. Drawing every exposure from the
    /// recording turned its 4:2:0 frame into color at full size each time, and a 4K export peaked at 3 GB.
    private func blurred(_ source: CIImage, over views: [View], around center: View) -> CIImage {
        let frame = layout.frame
        // Where each exposure's view of the frame lies in the center's drawing.
        func moving(to view: View) -> CGAffineTransform {
            // A point m of the center's drawing is drawn at fmin + (m − fmin)·(view/center) + (center − view)·view.
            let scale = view.scale / center.scale
            return CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: frame.minX + (center.x - view.x) * view.scale, y: frame.minY + (center.y - view.y) * view.scale))
        }
        let reach = views.reduce(frame) { union, view in union.union(frame.applying(moving(to: view).inverted())) }
        let drawn = screen(source, center, cutTo: reach.integral).insertingIntermediate(cache: false)
        let weight = 1 / Double(views.count)
        // Each weighted as a fade weighs it: CIColorMatrix works on colors unpremultiplied, so weighting the
        // alpha alone weighs the premultiplied color with it (weighting both too squared the weight, and the
        // average came out black).
        return views.map { Self.faded(drawn.transformed(by: moving(to: $0)).cropped(to: frame), opacity: weight) }
            .reduce(CIImage.empty()) { sum, part in part.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum]) }
    }

    /// The views the frame at `time` is exposed over: the one at `time` while the camera holds still (or
    /// moves less than a pixel and a half at the frame's edges over the shutter), so text stays sharp;
    /// while it moves, enough across the shutter that each lies within `exposureSpacing` of the next, the
    /// shutter shortened so no blur is longer than `longestBlur`.
    func exposures(at time: Double) -> [View] {
        let center = view(track.frame(at: time))
        let travel = Self.travel(from: view(track.frame(at: time - Self.shutter / 2)), to: view(track.frame(at: time + Self.shutter / 2)), across: layout.frame.size)
        guard travel > Self.exposureSpacing else { return [center] }
        let longest = Self.longestBlur * max(layout.canvas.width, layout.canvas.height)
        let shutter = Self.shutter * min(1, longest / travel)
        let count = min(Self.mostExposures, Int((min(travel, longest) / Self.exposureSpacing).rounded(.up)) + 1)
        return (0..<count).map { index in
            view(track.frame(at: time + shutter * (Double(index) / Double(count - 1) - 0.5)))
        }
    }

    /// How far the picture moves on the movie from `a` to `b`, at the frame's corners, where a zoom moves it
    /// most: a point drawn at offset m from the frame's corner in `a` is drawn at m·(b/a) + (a − b)·b's scale
    /// in `b`.
    static func travel(from a: View, to b: View, across frame: CGSize) -> Double {
        let ratio = b.scale / a.scale - 1
        let shiftX = (a.x - b.x) * b.scale, shiftY = (a.y - b.y) * b.scale
        return [(0.0, 0.0), (Double(frame.width), 0.0), (0.0, Double(frame.height)), (Double(frame.width), Double(frame.height))].map { corner in
            hypot(corner.0 * ratio + shiftX, corner.1 * ratio + shiftY)
        }.max() ?? 0
    }

    // MARK: Pieces

    /// The camera's frame as it is shown: mirrored when the project says so.
    static func oriented(_ frame: CIImage, mirrored: Bool) -> CIImage {
        guard mirrored else { return frame }
        return frame
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: frame.extent.minX + frame.extent.maxX, y: 0))
    }

    /// The camera in its bubble over `movie`, at `opacity`: its shadow, the picture cut to its shape, its ring.
    private func bubble(_ look: CameraLook, picture: CIImage, opacity: Double, over movie: CIImage) -> CIImage {
        let inBubble = Self.filling(picture, into: look.bubble)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputMaskImageKey: look.mask, kCIInputBackgroundImageKey: CIImage.empty()])
        var movie = Self.faded(look.shadow, opacity: opacity).composited(over: movie)
        movie = Self.faded(inBubble, opacity: opacity).composited(over: movie)
        return Self.faded(look.ring, opacity: opacity).composited(over: movie)
    }

    /// `image` scaled to cover `rect`, centered, and cut to it. Its edge pixels reach past it first: scaled
    /// as it is, its outermost pixels blend with the clear beyond them, and what is under them shows through.
    static func filling(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return CIImage.empty() }
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        return image
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.midX - extent.width * scale / 2, y: rect.midY - extent.height * scale / 2))
            .cropped(to: rect)
    }

    /// The bubble's outline in `rect`: a circle, or a square whose continuous corners take a fifth of its
    /// side, as the bubble on screen clips its picture.
    static func bubblePath(_ rect: CGRect, shape: StudioProject.Camera.Shape) -> CGPath {
        switch shape {
        case .circle: CGPath(ellipseIn: rect, transform: nil)
        case .roundedSquare: RoundedRectangle(cornerRadius: rect.width * 0.2, style: .continuous).path(in: rect).cgPath
        }
    }

    /// The camera's bubble for `settings`: its side in the recording's points as on screen (never more than
    /// half the recording's shorter side), 24 points in from the chosen corner of the recording's frame;
    /// circular or a rounded square (continuous corners, a fifth of its side); a white ring 3 points wide just
    /// inside its edge and a soft shadow (black 0.28, 12 points, 4 down), as the bubble on screen has.
    ///
    /// The `plan` says when it is in its bubble and when it fills the recording's frame; side by side draws the
    /// camera's picture in its own place instead, cut to the recording's corners (`radius`, in the movie's
    /// pixels) with the recording's shadow.
    static func cameraLook(
        take: StudioTelemetry.Camera, settings: StudioProject.Camera, plan: StudioCameraPlan, layout: Layout, recording: CGSize, unit: Double,
        radius: Double = 0, shadowStrength: Double = 0, canvas: CGRect = .zero
    ) -> CameraLook {
        let shorter = Double(min(recording.width, recording.height))
        let sidePoints = min(settings.size, max(shorter / 2, 60))
        let insetPoints = min(24, max(shorter - sidePoints, 0) / 2)
        let side = max(2, (sidePoints * unit).rounded())
        let inset = (insetPoints * unit).rounded()
        let frame = layout.frame
        let left = settings.corner == .bottomLeft || settings.corner == .topLeft
        let bottom = settings.corner == .bottomLeft || settings.corner == .bottomRight
        let bubble = CGRect(
            x: (left ? frame.minX + inset : frame.maxX - inset - side).rounded(),
            y: (bottom ? frame.minY + inset : frame.maxY - inset - side).rounded(),
            width: side, height: side
        )
        // The mask, the shadow, and the ring, drawn once around the bubble with room for the shadow.
        let room = (28 * unit).rounded(.up)
        let width = Int(side + room * 2)
        let outline = CGRect(x: room, y: room, width: side, height: side)
        func drawn(_ draw: (CGContext) -> Void) -> CIImage {
            guard let context = CGContext(
                data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return CIImage.empty() }
            draw(context)
            return context.makeImage().map {
                CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: bubble.minX - room, y: bubble.minY - room))
            } ?? CIImage.empty()
        }
        let mask = drawn { context in
            context.addPath(bubblePath(outline, shape: settings.shape))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
        }.cropped(to: bubble)
        let shadow = drawn { context in
            context.setShadow(offset: CGSize(width: 0, height: -4 * unit), blur: 12 * unit, color: CGColor(gray: 0, alpha: 0.28))
            context.addPath(bubblePath(outline, shape: settings.shape))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            // Only what falls outside the bubble: the camera covers the rest.
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setBlendMode(.clear)
            context.addPath(bubblePath(outline, shape: settings.shape))
            context.fillPath()
        }
        let ring = drawn { context in
            let line = 3 * unit
            context.addPath(bubblePath(outline.insetBy(dx: line / 2, dy: line / 2), shape: settings.shape))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(line)
            context.strokePath()
        }
        let pane = settings.layout == .sideBySide ? layout.camera.map { rect in
            CameraLook.Pane(
                rect: rect, mask: roundedMask(rect, radius: radius),
                shadow: shadowImage(frame: rect, radius: radius, strength: shadowStrength, unit: unit, canvas: canvas)
            )
        } : nil
        return CameraLook(bubble: bubble, mask: mask, shadow: shadow, ring: ring, mirrored: settings.mirrored, plan: plan, pane: pane)
    }

    /// A white rounded rectangle over `frame`, to cut a picture to its corners.
    private static func roundedMask(_ frame: CGRect, radius: Double) -> CIImage {
        let rounded = CIFilter.roundedRectangleGenerator()
        rounded.extent = frame
        rounded.radius = Float(radius)
        rounded.color = .white
        return rounded.outputImage?.cropped(to: frame) ?? CIImage(color: .white).cropped(to: frame)
    }

    /// The keys pressed as captions: each press shows the caption as it stands then, until the next press, or
    /// for a while after the last one.
    static func captions(for keys: [StudioTelemetry.Key], mode: KeystrokeMode, lingering: Double = 1.4) -> [Caption] {
        var caption = KeystrokeCaption(mode: mode)
        var captions: [Caption] = []
        for key in keys.sorted(by: { $0.time < $1.time }) {
            if let last = captions.last, key.time - last.start > lingering, last.end <= key.time { caption.clear() }
            let stroke = Keystroke(
                keyCode: key.keyCode, modifiers: NSEvent.ModifierFlags(rawValue: key.modifiers), characters: key.characters,
                keyCharacters: key.keyCharacters, isRepeat: key.isRepeat
            )
            guard caption.add(stroke) else { continue }
            if let last = captions.last, last.end > key.time {
                captions[captions.count - 1] = Caption(start: last.start, end: key.time, text: last.text)
            }
            captions.append(Caption(start: key.time, end: key.time + lingering, text: caption.text))
        }
        return captions
    }

    /// The caption showing at `time`, as a reading capsule centered near the foot of the movie, fading in and
    /// out over 0.12 s.
    private func caption(at time: Double) -> CIImage? {
        guard let index = captionIndex(at: time) else { return nil }
        let caption = captions[index]
        let image: CIImage
        lock.lock()
        if let cached = captionImages[caption.text] {
            image = cached
            lock.unlock()
        } else {
            lock.unlock()
            let made = captionImage(caption.text)
            lock.lock()
            if captionImages[caption.text] == nil {
                if captionImageOrder.count == Self.captionCacheLimit {
                    captionImages.removeValue(forKey: captionImageOrder.removeFirst())
                }
                captionImageOrder.append(caption.text)
                captionImages[caption.text] = made
            }
            image = captionImages[caption.text] ?? made
            lock.unlock()
        }
        let opacity = captionOpacity(at: time, index: index)
        // The capsule's foot 28 points above the recording's, centered on it; the picture has room around it.
        let x = layout.frame.midX - image.extent.width / 2
        let y = layout.frame.minY + (28 - Self.captionRoom) * pixelsPerPoint * layout.scale
        return Self.faded(image.transformed(by: CGAffineTransform(translationX: x, y: y)), opacity: opacity)
    }

    /// Independent binary searches keep scrubbing backwards and concurrent compositor requests deterministic.
    func activeClicks(at time: Double) -> ArraySlice<StudioTelemetry.Click> {
        // Compare ages in the same direction as the effect itself. Subtracting lifetime from time first
        // changes floating-point rounding at the exact expiration boundary.
        let lifetime = project.cursor.clickEffect.lifetime
        var start = 0, high = clicks.count
        while start < high {
            let middle = (start + high) / 2
            if time - clicks[middle].time >= lifetime { start = middle + 1 } else { high = middle }
        }
        let end = Self.upperBound(clicks, at: time, by: { $0.time })
        return clicks[start..<end]
    }

    func captionIndex(at time: Double) -> Int? {
        let index = Self.upperBound(captions, at: time, by: { $0.start }) - 1
        return index >= 0 && time < captions[index].end ? index : nil
    }

    /// Text changes within a typing run replace one another at full opacity. Only the whole run fades.
    func captionOpacity(at time: Double, index: Int) -> Double {
        let run = captionRuns[index]
        return max(0, min(1, (time - run.start) / 0.12, (run.end - time) / 0.12))
    }

    private static func captionRuns(for captions: [Caption]) -> [(start: Double, end: Double)] {
        var result = Array(repeating: (start: 0.0, end: 0.0), count: captions.count)
        var first = 0
        while first < captions.count {
            var last = first
            while last + 1 < captions.count, captions[last].end == captions[last + 1].start { last += 1 }
            let run = (start: captions[first].start, end: captions[last].end)
            for index in first...last { result[index] = run }
            first = last + 1
        }
        return result
    }

    private static func upperBound<T>(_ values: [T], at time: Double, by timestamp: (T) -> Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if timestamp(values[middle]) <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// A caption's capsule as the keystroke display draws it: the reading capsule's light surface (white
    /// 0.96), its 0.5 pt hairline, and the floating reading shadow, the keys in its rounded face at 26 pt
    /// semibold; drawn once per text with `captionRoom` points around it for the shadow.
    private func captionImage(_ text: String) -> CIImage {
        let unit = pixelsPerPoint * layout.scale
        let base = NSFont.systemFont(ofSize: 26 * unit, weight: .semibold)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 26 * unit) ?? base
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CGColor(gray: 0, alpha: 0.85),
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let height = 52 * unit
        let width = max(textWidth + 44 * unit, height)
        let room = Self.captionRoom * unit
        guard let context = CGContext(
            data: nil, width: Int((width + room * 2).rounded(.up)), height: Int((height + room * 2).rounded(.up)), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        let capsule = CGRect(x: room, y: room, width: width, height: height)
        let path = CGPath(roundedRect: capsule, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2 * unit), blur: 8 * unit, color: CGColor(gray: 0, alpha: 0.18))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 0.96))
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
        context.setLineWidth(0.5 * unit)
        context.strokePath()
        context.textPosition = CGPoint(x: capsule.midX - textWidth / 2, y: capsule.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }

    /// The soft shadow under the framed recording, made once: the annotation editor's background card
    /// shadow, so a screenshot and a Studio movie on the same background look alike. A short drop and a wide
    /// blur deepening together with `strength` (from 0 to 1): `unit` is the movie's pixels per point.
    private static func shadowImage(frame: CGRect, radius: Double, strength: Double, unit: Double, canvas: CGRect) -> CIImage? {
        guard strength > 0 else { return nil }
        let strength = min(strength, 1)
        // The editor's three box passes as wide as the blur spread like a Gaussian of half its width.
        let blur = (8 + 32 * strength) * unit
        let drop = (2 + 10 * strength) * unit
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = frame.offsetBy(dx: 0, dy: -drop)
        shape.radius = Float(radius)
        shape.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.14 + 0.30 * strength)
        guard let blurred = shape.outputImage?.applyingGaussianBlur(sigma: blur / 2).cropped(to: canvas) else { return nil }
        // Drawn once into memory, so frames don't blur it again.
        guard let image = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: canvas) else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
    }

    /// A click effect's picture at its full spread, drawn once at 256 pixels. The ring is the one shown while
    /// recording: a 3-point line of the color (at `strokeAlpha`) over a wash of it at 0.18, which holds on
    /// white pages as on dark ones. The ripple is a bare line of 2 points.
    private static func clickPicture(_ effect: StudioProject.ClickEffect, color: RingColor, strokeAlpha: Double) -> CIImage {
        let side = 256
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        let unit = Double(side) / effect.diameter
        let line = (effect == .ring ? 3 : 2) * unit
        let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 2 * unit, dy: 2 * unit)
        if effect == .ring {
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 0.18))
            context.fillEllipse(in: rect)
        }
        context.setStrokeColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: strokeAlpha))
        context.setLineWidth(line)
        context.strokeEllipse(in: rect)
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }

    /// The arrow drawn for the Arrow style, once, at four pixels a point like the cursors written down: the
    /// classic pointer, 12 points wide and 19 tall, black with a white edge 1.2 points wide outside it, its tip
    /// the hot spot. It is drawn here, not taken from the system, so it is sharp at any size.
    static func arrowLook() -> CursorLook? {
        let scale = 4.0, margin = 3.0, boxWidth = 12.0, boxHeight = 19.0
        let width = boxWidth + margin * 2, height = boxHeight + margin * 2
        guard let context = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Points from the top-left corner, y down.
        context.translateBy(x: 0, y: height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: margin, y: margin)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        for point in [(0, 16.2), (3.7, 12.7), (6.4, 18.8), (9.0, 17.6), (6.3, 11.8), (11.4, 11.8)] {
            path.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        path.closeSubpath()
        context.setLineJoin(.round)
        context.setLineWidth(2.4)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path)
        context.strokePath()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(path)
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return CursorLook(image: CIImage(cgImage: image), width: width, height: height, hotSpotX: margin, hotSpotY: margin)
    }

    /// The circle of light under the cursor in the Highlight style, drawn once at 256 pixels: the halo's color
    /// at `haloAlpha`, holding to 60% of the radius and feathering to clear at the edge.
    private static func haloImage() -> CIImage {
        let side = 256
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        let color = haloColor
        let colors = [
            CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: haloAlpha),
            CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: haloAlpha),
            CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 0),
        ]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.6, 1]) else {
            return CIImage.empty()
        }
        let middle = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        context.drawRadialGradient(gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: Double(side) / 2, options: [])
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }

    /// A color for the clicks' effects, in sRGB.
    public struct RingColor: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// The default accent's blue.
        public static let systemBlue = RingColor(red: 0, green: 0.478, blue: 1)
    }

    private static func faded(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
    }
}
