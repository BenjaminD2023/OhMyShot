import CoreGraphics
import Foundation

/// Draws a magnifier in the capture overlay's loupe look: a thin white ring edged by a hairline, over the
/// loupe's soft shadow, holding the picture under it at its zoom with its pixels kept square; and, once the
/// lens stands apart, a thinner ring around what it magnifies joined to it by a line. Sizes are in points of
/// the screen the capture came from, scaled to its pixels as every mark's are.
nonisolated enum MagnifierPainter {
    /// The lens's white ring, as wide as the loupe's rim.
    static let ringWidth: CGFloat = 3
    /// The ring around what is magnified, and the line to the lens.
    static let lineWidth: CGFloat = 1.5
    /// The hairline along each side of every white line, so it holds on white.
    static let hairline: CGFloat = 0.5
    static let hairlineColor = CGColor(gray: 0, alpha: 0.25)
    /// The loupe's floating lens shadow.
    static let shadowBlur: CGFloat = 12
    static let shadowDrop: CGFloat = 4
    static let shadowOpacity: CGFloat = 0.28

    /// Everything drawing a magnifier may touch, its shadow included.
    static func drawingBounds(of magnifier: Magnifier, scale: CGFloat) -> CGRect {
        let reach = (ringWidth / 2 + hairline + shadowBlur * 2 + shadowDrop) * scale
        var bounds = magnifier.lensRect.insetBy(dx: -reach, dy: -reach)
        if magnifier.isDetached {
            let edge = (lineWidth / 2 + hairline) * scale
            bounds = bounds.union(magnifier.sourceRect.insetBy(dx: -edge, dy: -edge))
        }
        return bounds.insetBy(dx: -2, dy: -2)
    }

    /// The whole pixels the lens shows, in the document's pixels: those under `magnifier.sourceRect`.
    static func lensArea(of magnifier: Magnifier) -> CGRect {
        magnifier.sourceRect.integral
    }

    /// What a magnifier shows: `picture`'s pixels in its `lensArea` (the capture with any combined images, and
    /// where it lies), with every redaction drawn over them as it is drawn on the picture, so a lens never shows
    /// what a redaction hides, whatever lies above or below it. Only what lies inside `canvas` (the document's,
    /// which a crop or Annotate Area's selection makes) is shown, so a lens never shows what the picture leaves
    /// out either; beyond it, and beyond the picture, the lens is white. `redactions` are the document's
    /// redactions with what each draws (`Redactor.coverage`); no other mark is shown. Nil when no such picture
    /// can be made, which leaves the lens white.
    static func lensPicture(
        for magnifier: Magnifier, picture: (image: CGImage, origin: CGPoint), canvas: CGRect,
        redactions: [(item: Annotation, coverage: Redactor.Coverage?)], scale: CGFloat
    ) -> CGImage? {
        let area = lensArea(of: magnifier)
        guard
            area.width >= 1, area.height >= 1, let (width, height) = AnnotationRenderer.bitmapDimensions(for: area.size)
        else { return nil }
        let space = picture.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // y down, with the area's corner at the origin.
        context.translateBy(x: 0, y: area.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -area.minX, y: -area.minY)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(area)
        context.clip(to: canvas.standardized)
        let bounds = CGRect(origin: picture.origin, size: CGSize(width: picture.image.width, height: picture.image.height))
        let shown = area.intersection(bounds)
        if !shown.isNull, let part = picture.image.cropping(to: shown.offsetBy(dx: -bounds.minX, dy: -bounds.minY)) {
            AnnotationRenderer.drawImage(part, in: shown, context: context)
        }
        for (item, coverage) in redactions where item.bounds(scale: scale).intersects(area) {
            AnnotationRenderer.draw(item, in: context, scale: scale, coverage: coverage, ground: .light)
        }
        return context.makeImage()
    }

    /// Draws `magnifier` into a context whose user space is the capture's pixels, y down. `lens` is what it
    /// shows, from `lensPicture`; nil leaves the lens white. `flippedBacking` is as for
    /// `AnnotationRenderer.draw`.
    static func draw(_ magnifier: Magnifier, lens: CGImage?, in context: CGContext, scale: CGFloat, flippedBacking: Bool) {
        let circle = CGPath(ellipseIn: magnifier.lensRect, transform: nil)
        context.saveGState()
        defer { context.restoreGState() }
        if magnifier.isDetached {
            // The ring around what is magnified, and the line from it to the lens, under the lens.
            let dx = magnifier.center.x - magnifier.source.x, dy = magnifier.center.y - magnifier.source.y
            let length = hypot(dx, dy)
            let path = CGMutablePath()
            path.addEllipse(in: magnifier.sourceRect)
            path.move(to: CGPoint(x: magnifier.source.x + dx / length * magnifier.sourceRadius, y: magnifier.source.y + dy / length * magnifier.sourceRadius))
            path.addLine(to: CGPoint(x: magnifier.center.x - dx / length * magnifier.radius, y: magnifier.center.y - dy / length * magnifier.radius))
            stroke(path, width: lineWidth * scale, in: context, scale: scale)
        }
        // The lens on its shadow: blurs and drops are in the context's device pixels, y up unless shown flipped.
        context.saveGState()
        let toDevice = context.userSpaceToDeviceSpaceTransform
        let factor = sqrt(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c))
        let drop = shadowDrop * scale * factor
        context.setShadow(
            offset: CGSize(width: 0, height: flippedBacking ? drop : -drop), blur: shadowBlur * scale * factor,
            color: CGColor(gray: 0, alpha: shadowOpacity)
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(circle)
        context.fillPath()
        context.restoreGState()
        if let lens {
            // Each pixel a square of the zoom's size, as the loupe shows them.
            let zoom = CGFloat(magnifier.zoom.rawValue)
            let area = lensArea(of: magnifier)
            let shown = CGRect(
                x: magnifier.center.x + (area.minX - magnifier.source.x) * zoom, y: magnifier.center.y + (area.minY - magnifier.source.y) * zoom,
                width: area.width * zoom, height: area.height * zoom
            )
            context.saveGState()
            context.addPath(circle)
            context.clip()
            context.interpolationQuality = .none
            AnnotationRenderer.drawImage(lens, in: shown, context: context)
            context.restoreGState()
        }
        stroke(circle, width: ringWidth * scale, in: context, scale: scale)
    }

    /// A white line of `width` pixels along `path`, edged on each side by the hairline.
    private static func stroke(_ path: CGPath, width: CGFloat, in context: CGContext, scale: CGFloat) {
        context.setLineCap(.round)
        context.setStrokeColor(hairlineColor)
        context.setLineWidth(width + hairline * 2 * scale)
        context.addPath(path)
        context.strokePath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(width)
        context.addPath(path)
        context.strokePath()
    }
}
