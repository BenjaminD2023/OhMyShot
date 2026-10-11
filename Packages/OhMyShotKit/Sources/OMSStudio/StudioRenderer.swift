import AppKit
import CoreImage
import CoreText
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OMSCore

/// Films one frame of a Studio recording: the background, the recording framed on it with its shadow and
/// rounded corners, zoomed where the camera looks, the cursor drawn again over it, a ring at each click, and
/// the keys pressed at the foot. Core Image, so frames are drawn on the GPU; what does not change from frame
/// to frame (the background, the shadow, the cursors, each caption) is made once.
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

    /// The movie's frame at `time` (the recording's seconds) from the recording's frame `source`.
    public func image(source: CIImage, at time: Double) -> CIImage {
        let state = track.frame(at: time)
        let width = Double(recordingSize.width), height = Double(recordingSize.height)
        let frame = layout.frame
        // What the camera shows, in the recording's pixels, y up as the source image is.
        let visibleWidth = width / state.zoom, visibleHeight = height / state.zoom
        let visibleX = state.centerX * pixelsPerPoint - visibleWidth / 2
        let visibleY = height - state.centerY * pixelsPerPoint - visibleHeight / 2
        let k = frame.width / visibleWidth
        /// A point in the recording's points (y down) on the movie.
        func onMovie(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: frame.minX + (x * pixelsPerPoint - visibleX) * k, y: frame.minY + (height - y * pixelsPerPoint - visibleY) * k)
        }

        let screen = source
            .transformed(by: CGAffineTransform(translationX: -visibleX, y: -visibleY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
            .cropped(to: frame)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputMaskImageKey: mask, kCIInputBackgroundImageKey: CIImage.empty()])

        var scene = screen
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
        scene = scene.cropped(to: frame)

        var movie = background
        if let shadow { movie = shadow.composited(over: movie) }
        movie = scene.composited(over: movie)
        if let caption = caption(at: time) { movie = caption.composited(over: movie) }
        return movie.cropped(to: CGRect(origin: .zero, size: layout.canvas))
    }

    // MARK: Pieces

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
