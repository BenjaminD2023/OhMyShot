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
        case .highlighter:
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

    /// The finished picture at the capture's resolution: the canvas, the capture in it, every mark.
    /// Canvas beyond the capture's edges is transparent.
    @concurrent
    public static func render(_ document: AnnotationDocument, base: CGImage) async -> CGImage? {
        flatten(document, base: base)
    }

    /// `render`, on the caller's thread.
    public static func flatten(_ document: AnnotationDocument, base: CGImage) -> CGImage? {
        let canvas = document.canvas.standardized.integral
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        guard width > 0, height > 0 else { return nil }
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // y down, with the canvas's corner at the origin.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        drawImage(base, in: document.imageBounds, context: context)
        drawSpotlight(document.spots, canvas: canvas, in: context)
        for item in document.items {
            if case .spotlight = item.shape { continue }
            var redacted: (image: CGImage, rect: CGRect)?
            if case .redaction(let redaction) = item.shape {
                redacted = Redactor.image(for: redaction, id: item.id, base: base, scale: document.scale)
            }
            draw(item, in: context, scale: document.scale, redacted: redacted)
        }
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
