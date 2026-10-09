import CoreGraphics
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
    /// blur or pixelation's picture and where it goes, from `Redactor`; spots are drawn by
    /// `drawSpotlight` instead.
    /// `flippedBacking` says the context's pixels are shown upside down from Core Graphics' own y-up
    /// order, as a layer's are in a flipped view; shadows need to know which way is down.
    public static func draw(_ item: Annotation, in context: CGContext, scale: CGFloat, redacted: (image: CGImage, rect: CGRect)? = nil, flippedBacking: Bool = false) {
        let color = item.style.color.cgColor
        context.saveGState()
        defer { context.restoreGState() }
        switch item.shape {
        case .arrow, .line, .rectangle, .ellipse, .pen:
            guard let path = MarkPaths.outline(of: item, scale: scale) else { return }
            if item.style.shadow { applyShadow(to: context, scale: scale, flippedBacking: flippedBacking) }
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        case .highlighter, .textHighlight:
            guard let path = MarkPaths.outline(of: item, scale: scale) else { return }
            // Darkens what is under it, as ink on paper does: text stays black, white turns yellow.
            context.setBlendMode(.multiply)
            context.setFillColor(color)
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
                context.setStrokeColor(item.style.color.prefersDarkInk ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
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
            }
            layout.drawLines(in: context, at: block.origin)
            context.endTransparencyLayer()
        case .counter(let counter):
            let layout = CounterLayout(counter, lineWidth: item.style.lineWidth, scale: scale)
            if item.style.shadow { applyShadow(to: context, scale: scale, flippedBacking: flippedBacking) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(color)
            context.fillEllipse(in: layout.rect(at: counter.center))
            context.setFillColor(item.style.color.prefersDarkInk ? CGColor(gray: 0, alpha: 0.88) : CGColor(gray: 1, alpha: 1))
            layout.drawLabel(in: context, at: counter.center)
            context.endTransparencyLayer()
        case .redaction(let redaction):
            switch redaction.method {
            case .solid:
                context.setFillColor(color)
                context.fill(redaction.rect.standardized)
            case .blur, .pixelate:
                guard let redacted else { return }
                context.interpolationQuality = redaction.method == .pixelate ? .none : .high
                drawImage(redacted.image, in: redacted.rect, context: context)
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
            drawImage(image, in: rect, context: context)
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

    /// `render`, on the caller's thread.
    public static func flatten(_ document: AnnotationDocument, base: CGImage) -> CGImage? {
        let canvas = document.canvas.standardized.integral
        let layout = document.backdrop == nil ? nil : document.backdropLayout(edges: EdgeAnalysis.of(base, canvas: canvas))
        let output = (layout?.output ?? canvas).integral
        let width = Int(output.width)
        let height = Int(output.height)
        guard width > 0, height > 0 else { return nil }
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // y down, with the picture's corner at the origin.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -output.minX, y: -output.minY)
        if let layout, let backdrop = document.backdrop {
            let blur = backdrop.fill == .blur ? BackdropPainter.blurredCapture(base, canvas: canvas) : nil
            BackdropPainter.paint(backdrop.fill, in: output, context: context, blur: blur)
            BackdropPainter.drawCardShadow(layout, strength: backdrop.shadow, scale: document.scale, context: context)
            drawCard(layout, base: base, document: document, space: space, in: context)
        } else {
            if document.canvasReachesPastCapture, let matte = document.canvasMatte(edges: EdgeAnalysis.of(base, canvas: canvas)) {
                context.setFillColor(matte.cgColor(in: space))
                context.fill(canvas)
            }
            drawPicture(document, base: base, in: context)
            drawSpotlight(document.spots, canvas: canvas, in: context)
        }
        // Blurs and pixelations show what lies under them, images included.
        let blurs = document.items.contains { item in
            if case .redaction(let redaction) = item.shape { return redaction.method != .solid }
            return false
        }
        let source = blurs ? redactionSource(document, base: base) : nil
        for item in document.items where !item.isPicturePart {
            var redacted: (image: CGImage, rect: CGRect)?
            if case .redaction(let redaction) = item.shape {
                redacted = Redactor.image(for: redaction, id: item.id, base: source?.image ?? base, origin: source?.origin ?? .zero, scale: document.scale)
            }
            draw(item, in: context, scale: document.scale, redacted: redacted)
        }
        return context.makeImage()
    }

    /// The capture and the images combined into it, as they lie under every mark.
    static func drawPicture(_ document: AnnotationDocument, base: CGImage, in context: CGContext) {
        drawImage(base, in: document.imageBounds, context: context)
        for item in document.items {
            if case .image = item.shape { draw(item, in: context, scale: document.scale) }
        }
    }

    /// The capture with the images combined into it, for blurring and pixelating what lies under a
    /// redaction, and where its top-left corner is in the document; nil when nothing is combined.
    static func redactionSource(_ document: AnnotationDocument, base: CGImage) -> (image: CGImage, origin: CGPoint)? {
        let images = document.items.filter { if case .image = $0.shape { true } else { false } }
        guard !images.isEmpty else { return nil }
        let area = images.reduce(document.imageBounds) { $0.union($1.bounds(scale: document.scale)) }.integral
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: area.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -area.minX, y: -area.minY)
        drawPicture(document, base: base, in: context)
        return context.makeImage().map { ($0, area.origin) }
    }

    /// The capture on its card: the card's room in the capture's edge color, the kept part of the
    /// capture, and the spotlight over the card, all within the card's rounded corners.
    static func drawCard(_ layout: BackdropLayout, base: CGImage, document: AnnotationDocument, space: CGColorSpace, in context: CGContext) {
        context.saveGState()
        if !layout.isBare {
            context.addPath(CGPath(roundedRect: layout.card, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil))
            context.clip()
            if let matte = layout.matte {
                context.setFillColor(matte.cgColor(in: space))
                context.fill(layout.card)
            }
        }
        context.saveGState()
        context.clip(to: layout.picture)
        drawPicture(document, base: base, in: context)
        context.restoreGState()
        drawSpotlight(document.spots, canvas: layout.isBare ? layout.picture : layout.card, in: context)
        context.restoreGState()
    }

    /// Draws an image upright into `rect` of a y-down user space.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
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
    /// Every spot, which share one dimming.
    public var spots: [Spot] {
        items.compactMap { item in
            if case .spotlight(let spot) = item.shape { return spot }
            return nil
        }
    }
}
