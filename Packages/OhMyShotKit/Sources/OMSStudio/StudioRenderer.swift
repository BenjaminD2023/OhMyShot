import AppKit
import CoreImage
import CoreText
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OMSCore
import SwiftUI

/// Films one frame of a Studio recording: the background, the recording framed on it with its shadow and
/// rounded corners, zoomed where the camera looks, the cursor drawn again over it, a ring at each click, the
/// camera's bubble in a corner (never zoomed), and the keys pressed at the foot. Core Image, so frames are
/// drawn on the GPU; what does not change from frame to frame (the background, the shadows, the cursors, the
/// bubble's ring, each caption) is made once.
///
/// Sizes: the recording is framed at its own pixels where it can be, the background around it, so its text
/// stays as sharp as it was; a movie that would be larger than `largestSide` is filmed smaller to fit.
nonisolated public final class StudioRenderer: @unchecked Sendable {
    public struct Layout: Equatable, Sendable {
        /// The movie's size in pixels, both sides even.
        public let canvas: CGSize
        /// Where the recording sits, in the movie's pixels (y up, as Core Image draws).
        public let frame: CGRect
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
    private let cursors: [(image: CIImage, telemetry: StudioTelemetry.Cursor)?]
    private let clicks: [StudioTelemetry.Click]
    private let captions: [Caption]
    /// The ring for the main button's clicks, and the dimmer one for the others'.
    private let rings: (primary: CIImage, secondary: CIImage)
    /// The camera's bubble; nil without a camera, or with it hidden.
    let camera: CameraLook?
    private let lock = NSLock()
    /// Caption pictures by their text, made the first time each shows.
    private var captionImages: [String: CIImage] = [:]

    /// The longest side a movie is filmed at: 4K's.
    public static let largestSide = 3840.0
    /// A click's ring, as the rings shown while recording draw it: from 18 to 54 points over 0.4 s, easing
    /// out as it fades.
    static let ringDuration = 0.4
    static let ringSize = 54.0
    static let ringStart = 18.0 / 54
    /// Room around a caption's capsule for its shadow, in points.
    static let captionRoom = 12.0

    /// How long the camera takes to fill the recording, or to go back to its bubble.
    static let cameraFade = 0.25

    /// The camera's bubble, made once: where it sits (in the movie's pixels, y up), its shape, the shadow
    /// under it, and the white ring over it, as the bubble on screen draws them.
    struct CameraLook {
        let bubble: CGRect
        let mask: CIImage
        let shadow: CIImage
        let ring: CIImage
        let mirrored: Bool
        /// When it fills the recording, in the recording's seconds.
        let fills: [ClosedRange<Double>]
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
    public init(
        telemetry: StudioTelemetry, project: StudioProject, duration: Double, recordingSize: CGSize, background: CGImage?,
        largestSide: Double = StudioRenderer.largestSide, ringColor: RingColor = .systemBlue
    ) {
        self.project = project
        self.recordingSize = recordingSize
        pixelsPerPoint = telemetry.width > 0 ? Double(recordingSize.width) / telemetry.width : telemetry.pixelsPerPoint
        track = StudioTrack(telemetry: telemetry, project: project, duration: duration)
        let layout = Self.layout(recordingSize: recordingSize, project: project, largestSide: largestSide)
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
        let rounded = CIFilter.roundedRectangleGenerator()
        rounded.extent = layout.frame
        rounded.radius = Float(radius)
        rounded.color = .white
        mask = rounded.outputImage?.cropped(to: layout.frame) ?? CIImage(color: .white).cropped(to: layout.frame)

        shadow = Self.shadowImage(frame: layout.frame, radius: radius, strength: project.shadow, unit: pixelsPerPoint * layout.scale, canvas: canvas)
        cursors = telemetry.cursors.map { cursor in
            guard let source = CGImageSourceCreateWithData(cursor.png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (CIImage(cgImage: image), cursor)
        }
        clicks = telemetry.clicks.sorted { $0.time < $1.time }
        captions = project.showsKeys ? Self.captions(for: telemetry.keys, mode: project.keystrokeMode) : []
        rings = (Self.ringImage(color: ringColor, strokeAlpha: 0.9), Self.ringImage(color: ringColor, strokeAlpha: 0.55))
        let unit = pixelsPerPoint * layout.scale
        let recording = CGSize(width: telemetry.width, height: telemetry.height)
        camera = project.camera.isShown ? telemetry.camera.map { take in
            Self.cameraLook(take: take, settings: project.camera, layout: layout, recording: recording, unit: unit)
        } : nil
    }

    /// Where everything goes for a recording `recordingSize` pixels with `project`'s padding and shape.
    public static func layout(recordingSize: CGSize, project: StudioProject, largestSide: Double = largestSide) -> Layout {
        let width = Double(recordingSize.width), height = Double(recordingSize.height)
        let padding = max(0, project.padding) * min(width, height)
        var canvas = CGSize(width: width + padding * 2, height: height + padding * 2)
        if let ratio = project.aspect.ratio {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        let scale = min(1, largestSide / max(canvas.width, canvas.height))
        let evenWidth = max(2, Int((canvas.width * scale).rounded())) & ~1
        let evenHeight = max(2, Int((canvas.height * scale).rounded())) & ~1
        let size = CGSize(width: evenWidth, height: evenHeight)
        let frame = CGRect(
            x: ((size.width - width * scale) / 2).rounded(), y: ((size.height - height * scale) / 2).rounded(),
            width: width * scale, height: height * scale
        )
        return Layout(canvas: size, frame: frame, scale: scale)
    }

    /// The movie's frame at `time` (the recording's seconds) from the recording's frame `source` and, when
    /// there is one, the camera's frame then.
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

        // The camera, in its bubble or filling the frame. From one to the other, the bubble fades out over the
        // first half of the change and the frame fills over the second, as the bubble on screen fades out and
        // in: the person is never shown twice.
        let picture = camera.flatMap { look in cameraFrame.map { Self.oriented($0, mirrored: look.mirrored) } }
        let filling = camera.map { Self.fillLevel($0.fills, at: time) } ?? 0
        let bubbleOpacity = picture == nil ? 0 : max(0, 1 - 2 * filling)
        let fillOpacity = picture == nil ? 0 : max(0, 2 * filling - 1)

        var scene: CIImage
        if let picture, fillOpacity > 0.999 {
            // Covered by the camera: nothing under it is drawn.
            scene = Self.filling(picture, into: frame)
        } else {
            // The recording as the camera shows it, exposed over the shutter while the camera moves.
            let views = project.motionBlur ? exposures(at: time) : [shown]
            let exposed = views.count > 1 ? blurred(source, over: views, around: shown) : screen(source, shown)
            scene = exposed.cropped(to: frame)
            // Rings under the cursor, at each click still showing.
            if project.cursor.showsClicks {
                for click in clicks where click.time <= time && time - click.time < Self.ringDuration {
                    // Easing out, as Core Animation's ease-out does for the rings shown while recording.
                    let progress = (time - click.time) / Self.ringDuration
                    let eased = 1 - (1 - progress) * (1 - progress)
                    let diameter = Self.ringSize * pixelsPerPoint * k * (Self.ringStart + (1 - Self.ringStart) * eased)
                    let point = onMovie(click.x, click.y)
                    let ring = click.button == .primary ? rings.primary : rings.secondary
                    let scaled = ring.transformed(by: CGAffineTransform(scaleX: diameter / ring.extent.width, y: diameter / ring.extent.height))
                    let placed = scaled.transformed(by: CGAffineTransform(translationX: point.x - diameter / 2, y: point.y - diameter / 2))
                    scene = Self.faded(placed, opacity: 1 - eased).composited(over: scene)
                }
            }
            // The cursor, its hot spot on the pointer's place.
            if state.cursorOpacity > 0.01, state.cursor < cursors.count, let cursor = cursors[state.cursor] {
                let imageScale = cursor.image.extent.width / cursor.telemetry.width
                let size = project.cursor.size * pixelsPerPoint * k / imageScale
                let hotSpot = CGPoint(
                    x: cursor.telemetry.hotSpotX * imageScale * size,
                    y: (cursor.telemetry.height - cursor.telemetry.hotSpotY) * imageScale * size
                )
                let point = onMovie(state.cursorX, state.cursorY)
                let placed = cursor.image
                    .transformed(by: CGAffineTransform(scaleX: size, y: size))
                    .transformed(by: CGAffineTransform(translationX: point.x - hotSpot.x, y: point.y - hotSpot.y))
                scene = Self.faded(placed, opacity: state.cursorOpacity).composited(over: scene)
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
        movie = scene.composited(over: movie)
        if let look = camera, let picture, bubbleOpacity > 0.001 { movie = bubble(look, picture: picture, opacity: bubbleOpacity, over: movie) }
        if let caption = caption(at: time) { movie = caption.composited(over: movie) }
        return movie.cropped(to: CGRect(origin: .zero, size: layout.canvas))
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

    /// How far the camera fills the recording at `time`, from 0 (its bubble) to 1, easing over `cameraFade`
    /// after each change.
    static func fillLevel(_ fills: [ClosedRange<Double>], at time: Double) -> Double {
        var level = 0.0
        for fill in fills where time >= fill.lowerBound {
            let rising = min(1, (time - fill.lowerBound) / cameraFade)
            let falling = min(1, max(0, (time - fill.upperBound) / cameraFade))
            level = max(level, rising - falling)
        }
        return min(max(level, 0), 1)
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
    static func cameraLook(take: StudioTelemetry.Camera, settings: StudioProject.Camera, layout: Layout, recording: CGSize, unit: Double) -> CameraLook {
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
        return CameraLook(bubble: bubble, mask: mask, shadow: shadow, ring: ring, mirrored: settings.mirrored, fills: take.fills)
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
        guard let caption = captions.last(where: { $0.start <= time && time < $0.end }) else { return nil }
        let image: CIImage
        lock.lock()
        if let cached = captionImages[caption.text] {
            image = cached
            lock.unlock()
        } else {
            lock.unlock()
            let made = captionImage(caption.text)
            lock.lock()
            captionImages[caption.text] = made
            lock.unlock()
            image = made
        }
        let fadeIn = min(1, (time - caption.start) / 0.12)
        let fadeOut = min(1, (caption.end - time) / 0.12)
        // Only a caption's first appearance fades in; one that follows another replaces it at once.
        let follows = captions.contains { $0.end == caption.start && $0.text != caption.text }
        let opacity = min(follows ? 1 : fadeIn, fadeOut)
        // The capsule's foot 28 points above the recording's, centered; the picture has room around it.
        let x = (layout.canvas.width - image.extent.width) / 2
        let y = layout.frame.minY + (28 - Self.captionRoom) * pixelsPerPoint * layout.scale
        return Self.faded(image.transformed(by: CGAffineTransform(translationX: x, y: y)), opacity: opacity)
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

    /// A click's ring as the rings shown while recording draw it, drawn once at 256 pixels: a 3-point line
    /// of the accent (at `strokeAlpha`) over a wash of it, which holds on white pages as on dark ones.
    private static func ringImage(color: RingColor, strokeAlpha: Double) -> CIImage {
        let side = 256
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        let unit = Double(side) / ringSize
        let line = 3 * unit
        let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 2 * unit, dy: 2 * unit)
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 0.18))
        context.fillEllipse(in: rect)
        context.setStrokeColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: strokeAlpha))
        context.setLineWidth(line)
        context.strokeEllipse(in: rect)
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }

    /// A color for the clicks' rings, in sRGB.
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
