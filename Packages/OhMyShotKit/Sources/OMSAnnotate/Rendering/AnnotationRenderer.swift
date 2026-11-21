import CoreGraphics
import OMSCore
import Foundation

/// Draws marks with Core Graphics. The canvas draws each mark through here on screen and exports draw
/// the whole document through here too, so what is exported is what was seen.
nonisolated public enum AnnotationRenderer {
    /// The soft shadow under marks, in points: a short drop and a wide blur, never a hard edge.
    static let shadowDrop: CGFloat = 1
    static let shadowBlur: CGFloat = 3
    static let shadowOpacity: CGFloat = 0.3
    /// How dark a spotlight leaves the rest of the picture.
    public static let spotlightDimming: CGFloat = 0.5

    /// Draws `item` into a context whose user space is the capture's pixels, y down. `redacted` is a
    /// blur, pixelation, or erasure's picture and where it goes, from `Redactor`; `ground` is what a highlight lies
    /// on, from `HighlightGround`; spots are drawn by `drawSpotlight` instead.
    /// `flippedBacking` says the context's pixels are shown upside down from Core Graphics' own y-up
    /// order, as a layer's are in a flipped view; shadows need to know which way is down.
    public static func draw(
        _ item: Annotation, in context: CGContext, scale: CGFloat, redacted: (image: CGImage, rect: CGRect)? = nil,
        ground: HighlightGround = .light, flippedBacking: Bool = false
    ) {
        draw(item, in: context, scale: scale, coverage: redacted.map { .filtered($0.image, $0.rect) }, ground: ground, flippedBacking: flippedBacking)
    }

    static func draw(
        _ item: Annotation, in context: CGContext, scale: CGFloat, coverage: Redactor.Coverage?,
        ground: HighlightGround, flippedBacking: Bool = false, underlay: BackdropPainter.Underlay? = nil
    ) {
        let color = item.style.color.cgColor
        context.saveGState()
        defer { context.restoreGState() }
        if item.isTurned {
            // Upright in a frame turned about its middle. Shadows keep falling down the page: their offset is the
            // page's, not the frame's.
            let upright = item.upright(scale: scale)
            let center = upright.bounds(scale: scale).middle
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: item.angle)
            context.translateBy(x: -center.x, y: -center.y)
            draw(upright, in: context, scale: scale, coverage: coverage, ground: ground, flippedBacking: flippedBacking, underlay: underlay)
            return
        }
        switch item.shape {
        case .arrow, .line, .rectangle, .ellipse, .pen:
            guard let path = MarkPaths.outline(of: item, scale: scale) else { return }
            if item.style.shadow { applyShadow(to: context, scale: scale, flippedBacking: flippedBacking) }
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        case .highlighter, .textHighlight, .highlightBox:
            guard let path = MarkPaths.outline(of: item, scale: scale) else { return }
            switch ground {
            case .light:
                // Darkens what is under it, as ink on paper does: text stays black, white turns yellow.
                context.setBlendMode(.multiply)
                context.setFillColor(color)
            case .dark:
                // Lightens what is under it with a deep tint: text stays white, black takes the tint.
                context.setBlendMode(.screen)
                context.setFillColor(item.style.color.deepTint.cgColor)
            }
            context.addPath(path)
            context.fillPath()
        case .text(let block):
            guard !block.string.isEmpty else { return }
            let layout = TextLayout(block, scale: scale)
            if item.style.shadow { applyShadow(to: context, scale: scale, flippedBacking: flippedBacking) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            switch block.look {
            case .plain:
                context.setFillColor(color)
            case .outlined:
                context.setStrokeColor(item.style.color.prefersDarkOutline ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
                context.setLineWidth(layout.outlineWidth)
                context.setLineJoin(.round)
                context.addPath(layout.glyphPath(at: block.origin))
                context.strokePath()
                context.setFillColor(color)
            case .label:
                let frame = CGRect(origin: block.origin, size: layout.size)
                context.setFillColor(color)
                context.addPath(CGPath(roundedRect: frame, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil))
                context.fillPath()
                context.setFillColor(item.style.color.prefersDarkInk ? CGColor(gray: 0, alpha: 0.88) : CGColor(gray: 1, alpha: 1))
            case .bubble:
                context.setFillColor(color)
                context.addPath(layout.bubblePath(of: block))
                context.fillPath()
                context.setFillColor(item.style.color.prefersDarkInk ? CGColor(gray: 0, alpha: 0.88) : CGColor(gray: 1, alpha: 1))
            }
            layout.drawLines(in: context, at: block.origin)
            context.endTransparencyLayer()
        case .counter(let counter):
            let layout = CounterLayout(counter, lineWidth: item.style.lineWidth, scale: scale)
            if item.style.shadow { applyShadow(to: context, scale: scale, flippedBacking: flippedBacking) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(color)
            context.addPath(CalloutPaths.counter(center: counter.center, diameter: layout.diameter, tip: counter.tail))
            context.fillPath()
            context.setFillColor(item.style.color.prefersDarkInk ? CGColor(gray: 0, alpha: 0.88) : CGColor(gray: 1, alpha: 1))
            layout.drawLabel(in: context, at: counter.center)
            context.endTransparencyLayer()
        case .redaction(let redaction):
            switch redaction.method {
            case .solid:
                context.setFillColor(color)
                context.fill(redaction.rect.standardized)
            case .blur, .pixelate, .erase:
                switch coverage {
                case let .filtered(image, rect):
                    context.clip(to: rect)
                    if let underlay {
                        context.clear(rect)
                        underlay.paint(in: context)
                        underlay.clipToPicture(in: context)
                    } else {
                        context.setBlendMode(.copy)
                    }
                    context.interpolationQuality = redaction.method == .pixelate ? .none : .high
                    drawImage(image, in: rect, context: context)
                case .opaque(let rect):
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(rect)
                case nil:
                    break
                }
            }
        case .spotlight:
            return
        case .image(let placed):
            let rect = placed.rect.standardized
            guard rect.width >= 1, rect.height >= 1 else { return }
            // Read at the size it is drawn, every pixel it has in an export.
            let toDevice = context.userSpaceToDeviceSpaceTransform
            let factor = sqrt(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c))
            let longest = Int((max(rect.width, rect.height) * factor).rounded(.up))
            guard let image = PictureStore.shared.image(named: placed.name, fitting: longest, limit: PictureStore.imageLimit) else {
                // The picture has gone from the folder: a quiet stand-in keeps its place.
                context.setFillColor(CGColor(gray: 0.5, alpha: 0.18))
                context.fill(rect)
                return
            }
            if item.style.shadow { applyShadow(to: context, scale: scale, flippedBacking: flippedBacking) }
            context.interpolationQuality = .high
            drawImage(image, in: rect, orientation: placed.orientation, context: context)
        }
    }

    /// Dims everything in `canvas` but the spots. Overlapping spots stay bright where they overlap.
    public static func drawSpotlight(_ spots: [Spot], canvas: CGRect, in context: CGContext) {
        guard !spots.isEmpty else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(CGColor(gray: 0, alpha: spotlightDimming))
        context.fill(canvas)
        context.setBlendMode(.clear)
        for spot in spots {
            let rect = spot.rect.standardized
            if spot.oval {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The finished picture at the capture's resolution: the background if there is one, the canvas
    /// and the capture in it, every mark. Canvas beyond the capture's edges takes the capture's edge
    /// color (white when its edge has no one color), except around a window captured with its shadow.
    @concurrent
    public static func render(_ document: AnnotationDocument, base: CGImage) async -> CGImage? {
        flatten(document, base: base)
    }

    /// `render`, on the caller's thread. `base` is the capture as it was taken: the picture is made from it
    /// and the document's turns and size.
    public static func flatten(_ document: AnnotationDocument, base: CGImage) -> CGImage? {
        flatten(document, base: base, redactionFilter: Redactor.apply)
    }

    typealias Composite = (AnnotationDocument, CGImage, CGRect) -> CGImage?

    static func bitmapDimensions(for size: CGSize) -> (width: Int, height: Int)? {
        let maxSide = 262_144
        let maxBytes = 1 << 30
        guard let width = Int(exactly: size.width), let height = Int(exactly: size.height),
              (1...maxSide).contains(width), (1...maxSide).contains(height),
              width * height * 4 <= maxBytes else { return nil }
        return (width, height)
    }

    private static func bitmapContext(for size: CGSize, space: CGColorSpace) -> CGContext? {
        guard let (width, height) = bitmapDimensions(for: size) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    static func flatten(
        _ document: AnnotationDocument, base: CGImage,
        redactionFilter: Redactor.Filter = Redactor.apply, composite: Composite = combinedPicture
    ) -> CGImage? {
        guard let base = document.picture(from: base) else { return nil }
        let canvas = document.canvas.standardized.integral
        let needsEdges = document.backdrop != nil || document.canvasReachesPastCapture
        let edges = needsEdges ? EdgeAnalysis.of(base, canvas: canvas) : nil
        let layout = edges.flatMap { document.backdropLayout(edges: $0) }
        let output = (layout?.output ?? canvas).integral
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = bitmapContext(for: output.size, space: space) else { return nil }
        context.interpolationQuality = .high
        // y down, with the picture's corner at the origin.
        context.translateBy(x: 0, y: output.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -output.minX, y: -output.minY)
        let surface = layout.flatMap { layout in
            document.backdrop.map { BackdropPainter.Surface(fill: $0.fill, layout: layout, shadow: CardShadow($0, scale: document.scale)) }
        }
        let matte = layout?.matte ?? edges.flatMap { document.canvasMatte(edges: $0) }
        let underlay = BackdropPainter.Underlay(
            surface: surface, blur: surface?.fill == .blur ? BackdropPainter.blurredCapture(base, canvas: canvas) : nil,
            matte: matte?.cgColor(in: space), canvas: canvas
        )
        underlay.paint(in: context)
        context.saveGState()
        underlay.clipToPicture(in: context)
        drawPicture(document, base: base, in: context)
        context.restoreGState()
        context.saveGState()
        if let layout, !layout.isBare {
            context.addPath(CGPath(roundedRect: layout.card, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil))
            context.clip()
        }
        drawSpotlight(document.spots, canvas: layout?.card ?? canvas, in: context)
        context.restoreGState()
        // Blurs and pixelations show what lies under them, and highlights take to it, images included.
        let readsPicture = document.items.contains { item in
            if case .redaction(let redaction) = item.shape { return redaction.method != .solid }
            return item.multiplies
        }
        let combined = readsPicture ? redactionSource(document, base: base, composite: composite) : nil
        let source = combined ?? Redactor.Source(base: base)
        let covered = document.redactedRects
        for item in document.items where !item.isPicturePart {
            var coverage: Redactor.Coverage?
            var ground = HighlightGround.light
            if case .redaction(let redaction) = item.shape {
                coverage = Redactor.coverage(
                    for: redaction, id: item.id, source: source, scale: document.scale, covered: covered, canvas: document.canvas,
                    filter: redactionFilter
                )
            } else if item.multiplies {
                let picture = source.picture ?? (base, .zero)
                ground = HighlightGround.under(item, in: picture.image, origin: picture.origin, scale: document.scale)
            }
            draw(item, in: context, scale: document.scale, coverage: coverage, ground: ground, underlay: surface == nil && matte == nil ? nil : underlay)
        }
        // Over every mark, across the canvas, inside the card's corners on a background.
        if let watermark = document.watermark {
            WatermarkPainter.paint(watermark, in: canvas, cornerRadius: layout?.cornerRadius ?? 0, context: context)
        }
        return context.makeImage()
    }

    /// The capture and the images combined into it, as they lie under every mark. `base` is the picture
    /// (`AnnotationDocument.picture(from:)`), in the document's own pixels.
    static func drawPicture(_ document: AnnotationDocument, base: CGImage, in context: CGContext) {
        drawImage(base, in: document.imageBounds, context: context)
        for item in document.items {
            if case .image = item.shape { draw(item, in: context, scale: document.scale) }
        }
    }

    /// The capture with the images combined into it, for blurring and pixelating what lies under a
    /// redaction. Nil means no composition is needed. A failed composition still carries its bounds.
    static func redactionSource(_ document: AnnotationDocument, base: CGImage, composite: Composite = combinedPicture) -> Redactor.Source? {
        let images = document.items.filter { if case .image = $0.shape { true } else { false } }
        guard !images.isEmpty else { return nil }
        let area = images.reduce(document.imageBounds) { $0.union($1.bounds(scale: document.scale)) }.integral
        return Redactor.Source(bounds: area, image: composite(document, base, area))
    }

    private static func combinedPicture(_ document: AnnotationDocument, base: CGImage, area: CGRect) -> CGImage? {
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = bitmapContext(for: area.size, space: space) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: area.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -area.minX, y: -area.minY)
        drawPicture(document, base: base, in: context)
        return context.makeImage()
    }

    /// Draws an image upright into `rect` of a y-down user space.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Draws an image turned or flipped into `rect` of a y-down user space: `rect` is the size it has once
    /// held that way.
    static func drawImage(_ image: CGImage, in rect: CGRect, orientation: Orientation?, context: CGContext) {
        guard let orientation, !orientation.isIdentity else {
            drawImage(image, in: rect, context: context)
            return
        }
        let source = CGSize(width: image.width, height: image.height)
        let held = orientation.size(of: source)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / held.width, y: rect.height / held.height)
        context.concatenate(orientation.transform(for: source))
        drawImage(image, in: CGRect(origin: .zero, size: source), context: context)
        context.restoreGState()
    }

    /// `base` held as `orientation` says and scaled to `size` pixels, or nil when no such picture can be made.
    static func picture(from base: CGImage, orientation: Orientation, size: CGSize) -> CGImage? {
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = bitmapContext(for: size, space: space) else { return nil }
        let held = orientation.size(of: CGSize(width: base.width, height: base.height))
        // Turning and flipping move whole pixels; only a change of size blends them.
        context.interpolationQuality = held == size ? .none : .high
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        drawImage(base, in: CGRect(origin: .zero, size: size), orientation: orientation, context: context)
        return context.makeImage()
    }

    /// The mark shadow, sized for the context. Shadow offsets and blurs are in the context's base space:
    /// device pixels with y up, whatever the current transform, so the drop is negative to fall down,
    /// unless the pixels are shown flipped.
    static func applyShadow(to context: CGContext, scale: CGFloat, flippedBacking: Bool) {
        let toDevice = context.userSpaceToDeviceSpaceTransform
        let factor = sqrt(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c))
        let drop = shadowDrop * scale * factor
        context.setShadow(offset: CGSize(width: 0, height: flippedBacking ? drop : -drop), blur: shadowBlur * scale * factor, color: CGColor(gray: 0, alpha: shadowOpacity))
    }
}

nonisolated extension AnnotationDocument {
    /// The picture the marks lie on: `base`, the capture as it was taken, turned, flipped, and resized as
    /// the document says, in exactly `imageBounds`' pixels. `base` itself while the capture is as taken; nil
    /// when the picture cannot be made, which the marks, lying in its pixels, must not be drawn on the
    /// capture instead of.
    public func picture(from base: CGImage) -> CGImage? {
        guard let transform, transform.normalized(for: pixelSize) != nil else { return base }
        return AnnotationRenderer.picture(from: base, orientation: transform.orientation, size: pictureSize)
    }

    /// Every spot, which share one dimming.
    public var spots: [Spot] {
        items.compactMap { item in
            if case .spotlight(let spot) = item.shape { return spot }
            return nil
        }
    }

    /// Where every redaction lies, whatever its method: an erasure reads none of it, so it never spreads
    /// what another redaction hides.
    var redactedRects: [CGRect] {
        items.compactMap { item in
            if case .redaction(let redaction) = item.shape { return redaction.rect }
            return nil
        }
    }
}
