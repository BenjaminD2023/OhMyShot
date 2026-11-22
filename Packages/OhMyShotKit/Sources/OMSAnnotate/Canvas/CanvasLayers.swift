import AppKit
import CoreImage.CIFilterBuiltins
import OMSCore
import OMSDesign
import QuartzCore

/// Where the document sits in a layer: the document point at the layer's top left, and view points per
/// document pixel.
nonisolated struct LayerMapping: Equatable {
    var origin: CGPoint
    var zoom: CGFloat
}

/// A layer that never animates on its own: the canvas follows the pointer, and anything that trailed it
/// would read as lag. Layers are nonisolated like Core Animation; the canvas changes them on the main
/// actor and Core Animation draws them there.
nonisolated class StillLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { NSNull() }
}

nonisolated extension CALayer {
    /// Sets up the context of a layer in the canvas so its user space is document pixels, y down.
    /// Returns whether the layer's pixels are shown flipped, which the renderer needs for shadows.
    @discardableResult
    func prepareDocumentSpace(_ context: CGContext, mapping: LayerMapping) -> Bool {
        let flipped = contentsAreFlipped()
        if !flipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.scaleBy(x: mapping.zoom, y: mapping.zoom)
        context.translateBy(x: -mapping.origin.x, y: -mapping.origin.y)
        return flipped
    }
}

/// One mark, drawn by the renderer exports use.
nonisolated final class MarkLayer: StillLayer {
    override var frame: CGRect {
        didSet {
            if frame != oldValue { updateFilteredCompositingFilter() }
        }
    }
    override var bounds: CGRect {
        didSet {
            if bounds != oldValue { updateFilteredCompositingFilter() }
        }
    }
    override var contentsScale: CGFloat {
        didSet {
            if contentsScale != oldValue { updateFilteredCompositingFilter() }
        }
    }

    var mark: Annotation {
        didSet { if mark != oldValue { setNeedsDisplay() } }
    }
    private var filteredMaskExtent: CGRect?
    var scale: CGFloat = 2
    var mapping = LayerMapping(origin: .zero, zoom: 1) {
        didSet { if mapping != oldValue { setNeedsDisplay() } }
    }
    /// What to draw for a blur or pixelation, including the opaque cover on a render failure.
    var coverage: Redactor.Coverage? {
        didSet {
            blendIntoPicture()
            setNeedsDisplay()
        }
    }
    /// A filtered layer replaces its entire frame, so it must not include the usual drawing margin.
    var documentDrawingBounds: CGRect {
        if case .filtered(_, let rect) = coverage { return rect }
        return mark.drawingBounds(scale: scale)
    }
    var underlay: BackdropPainter.Underlay? {
        didSet { if underlay != oldValue { setNeedsDisplay() } }
    }
    /// What a magnifier shows, from `MagnifierPainter.lensPicture`.
    var lens: CGImage? {
        didSet { if lens !== oldValue { setNeedsDisplay() } }
    }
    /// What a highlight lies on: light ground takes it multiplied, dark ground screened.
    var ground = HighlightGround.light {
        didSet {
            guard ground != oldValue else { return }
            blendIntoPicture()
            setNeedsDisplay()
        }
    }

    init(mark: Annotation) {
        self.mark = mark
        super.init()
        needsDisplayOnBoundsChange = true
        blendIntoPicture()
    }

    override init(layer: Any) {
        let other = layer as! MarkLayer
        mark = other.mark
        scale = other.scale
        mapping = other.mapping
        coverage = other.coverage
        underlay = other.underlay
        lens = other.lens
        ground = other.ground
        super.init(layer: layer)
    }

    /// The white mask selects the filtered source even when its pixels are clear. Clip the composite
    /// to the layer's frame; layers above it still draw normally, as in the flattened export.
    private func blendIntoPicture() {
        if case .filtered = coverage {
            masksToBounds = true
            updateFilteredCompositingFilter()
        } else {
            masksToBounds = false
            filteredMaskExtent = nil
            compositingFilter = mark.multiplies ? (ground == .dark ? "screenBlendMode" : "multiplyBlendMode") : nil
        }
    }

    private func updateFilteredCompositingFilter() {
        guard case .filtered = coverage else {
            filteredMaskExtent = nil
            return
        }
        let width = bounds.width
        let height = bounds.height
        let x = frame.minX
        let y = frame.minY
        guard width.isFinite, height.isFinite, x.isFinite, y.isFinite, width > 0, height > 0 else {
            filteredMaskExtent = nil
            compositingFilter = nil
            return
        }
        let extent = CGRect(x: x, y: y, width: width, height: height)
        guard extent != filteredMaskExtent else { return }
        // Core Image cannot archive infinite masks; mask coordinates are superlayer points, independent of contentsScale.
        let blend = CIFilter.blendWithAlphaMask()
        blend.maskImage = CIImage(color: .white).cropped(to: extent)
        compositingFilter = blend
        filteredMaskExtent = extent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        let flipped = prepareDocumentSpace(context, mapping: mapping)
        AnnotationRenderer.draw(
            mark, in: context, scale: scale, coverage: coverage, ground: ground, flippedBacking: flipped, underlay: underlay, lens: lens
        )
    }
}

/// The background behind the capture and the capture's shadow on it, drawn by the renderer exports use.
nonisolated final class BackdropLayer: StillLayer {
    var content: BackdropPainter.Surface? {
        didSet { if content != oldValue { setNeedsDisplay() } }
    }
    /// The blurred capture a blur fill shows.
    var blur: CGImage? {
        didSet { if blur !== oldValue { setNeedsDisplay() } }
    }
    var mapping = LayerMapping(origin: .zero, zoom: 1) {
        didSet { if mapping != oldValue { setNeedsDisplay() } }
    }
    /// The two squares of the checkerboard a clear background shows on screen, never in an export.
    var checker = Theme.Checkerboard.colors(dark: false, increasedContrast: false) {
        didSet { setNeedsDisplay() }
    }
    var preview: BackdropPainter.Underlay.Preview {
        .init(resolution: mapping.zoom * contentsScale, zoom: mapping.zoom, light: checker.light, dark: checker.dark)
    }
    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        let other = layer as! BackdropLayer
        content = other.content
        blur = other.blur
        mapping = other.mapping
        checker = other.checker
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        guard let content else { return }
        prepareDocumentSpace(context, mapping: mapping)
        BackdropPainter.Underlay(surface: content, blur: blur, matte: nil, canvas: content.layout.picture, preview: preview).paint(in: context)
    }
}

/// The spotlight dimming, shared by every spot.
nonisolated final class SpotlightLayer: StillLayer {
    var spots: [Spot] = [] {
        didSet { if spots != oldValue { setNeedsDisplay() } }
    }
    var canvas: CGRect = .zero {
        didSet { if canvas != oldValue { setNeedsDisplay() } }
    }
    var mapping = LayerMapping(origin: .zero, zoom: 1) {
        didSet { if mapping != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        guard !spots.isEmpty else { return }
        prepareDocumentSpace(context, mapping: mapping)
        AnnotationRenderer.drawSpotlight(spots, canvas: canvas, in: context)
    }
}

/// The watermark, tiled over the canvas above every mark as exports draw it, over the part of the canvas on screen.
nonisolated final class WatermarkLayer: StillLayer {
    var watermark: Watermark? {
        didSet { if watermark != oldValue { setNeedsDisplay() } }
    }
    /// The canvas, in document pixels.
    var canvas: CGRect = .zero {
        didSet { if canvas != oldValue { setNeedsDisplay() } }
    }
    /// The card's corners on a background, which the watermark keeps inside, in document pixels.
    var cardCornerRadius: CGFloat = 0 {
        didSet { if cardCornerRadius != oldValue { setNeedsDisplay() } }
    }
    var mapping = LayerMapping(origin: .zero, zoom: 1) {
        didSet { if mapping != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        guard let watermark else { return }
        prepareDocumentSpace(context, mapping: mapping)
        WatermarkPainter.paint(watermark, in: canvas, cornerRadius: cardCornerRadius, context: context)
    }
}

/// The selection, drawn in view points so its lines and handles keep their size at any zoom: a hairline
/// box in the accent, and white handles ringed in the accent.
nonisolated final class SelectionLayer: StillLayer {
    struct Outline: Equatable {
        /// In view points.
        var box: CGRect?
        var handles: [CGPoint]
        /// How far `box` is turned about its middle, in radians, clockwise.
        var angle: CGFloat = 0
        /// The rotation knob and the point on the box it stands above, in view points.
        var knob: (base: CGPoint, point: CGPoint)?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.box == rhs.box && lhs.handles == rhs.handles && lhs.angle == rhs.angle
                && lhs.knob?.base == rhs.knob?.base && lhs.knob?.point == rhs.knob?.point
        }
    }

    var outlines: [Outline] = [] {
        didSet { if outlines != oldValue { setNeedsDisplay() } }
    }
    var accent: CGColor = NSColor.controlAccentColor.cgColor {
        didSet { setNeedsDisplay() }
    }
    var increasedContrast = false {
        didSet { setNeedsDisplay() }
    }
    /// The picture's frame while pictures are dragged over it, to show they will be combined into it.
    var dropFrame: CGRect? {
        didSet { if dropFrame != oldValue { setNeedsDisplay() } }
    }
    /// The marquee rectangle being dragged in Select mode, in view points.
    var marqueeRect: CGRect? {
        didSet { if marqueeRect != oldValue { setNeedsDisplay() } }
    }
    struct Guide: Equatable {
        var start: CGPoint
        var end: CGPoint
    }
    /// Smart alignment guides shown while moving a mark that snaps to another mark or the canvas center, in view points.
    var alignmentGuides: [Guide] = [] {
        didSet { if alignmentGuides != oldValue { setNeedsDisplay() } }
    }
    struct EyedropperPreview: Equatable {
        var point: CGPoint
        var color: RGBA
    }
    /// Swatch preview shown near the pointer while the canvas color eyedropper is active.
    var eyedropperPreview: EyedropperPreview? {
        didSet { if eyedropperPreview != oldValue { setNeedsDisplay() } }
    }

    static let handleSize: CGFloat = 9

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        if !contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let line: CGFloat = increasedContrast ? 2 : 1
        if let dropFrame {
            // The accent ring Finder puts around a drop target, just outside the picture.
            context.setStrokeColor(accent)
            context.setLineWidth(3)
            context.stroke(dropFrame.insetBy(dx: -2.5, dy: -2.5))
        }
        if let marquee = marqueeRect, !marquee.isNull, !marquee.isEmpty {
            let rect = marquee.standardized
            if let fill = accent.copy(alpha: increasedContrast ? 0.18 : 0.10) {
                context.setFillColor(fill)
                context.fill(rect)
            }
            context.setStrokeColor(accent)
            context.setLineWidth(line)
            context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
        }
        if !alignmentGuides.isEmpty {
            context.saveGState()
            context.setStrokeColor(accent)
            context.setLineWidth(line)
            for guide in alignmentGuides {
                context.strokeLineSegments(between: [guide.start, guide.end])
            }
            context.restoreGState()
        }
        for outline in outlines {
            if let box = outline.box {
                context.saveGState()
                context.setStrokeColor(accent)
                context.setLineWidth(line)
                if outline.angle != 0 {
                    context.translateBy(x: box.midX, y: box.midY)
                    context.rotate(by: outline.angle)
                    context.translateBy(x: -box.midX, y: -box.midY)
                }
                context.stroke(box.insetBy(dx: -line / 2, dy: -line / 2))
                context.restoreGState()
            }
            var handles = outline.handles
            if let knob = outline.knob {
                context.setStrokeColor(accent)
                context.setLineWidth(line)
                context.strokeLineSegments(between: [knob.base, knob.point])
                handles.append(knob.point)
            }
            for point in handles {
                let size = Self.handleSize
                let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: contentsAreFlipped() ? 1 : -1), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillEllipse(in: rect)
                context.restoreGState()
                context.setStrokeColor(accent)
                context.setLineWidth(line)
                context.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
            }
        }
        if let preview = eyedropperPreview {
            let size: CGFloat = 22
            let center = CGPoint(x: preview.point.x + 16, y: preview.point.y - 16)
            let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: contentsAreFlipped() ? 1 : -1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
            context.setFillColor(preview.color.cgColor)
            context.fillEllipse(in: rect)
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(2)
            context.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
            context.setLineWidth(0.5)
            context.strokeEllipse(in: rect)
        }
    }
}

/// The crop frame, drawn as the capture overlay draws a selection: the picture outside it dimmed 26%
/// (45% with Increase Contrast), a 1.5 pt white edge over a soft dark outline so it holds on white
/// pages, thirds while dragging, and thick corners.
nonisolated final class CropLayer: StillLayer {
    /// The kept area, in view points.
    var frameRect: CGRect = .zero {
        didSet { if frameRect != oldValue { setNeedsDisplay() } }
    }
    /// The picture on screen: only it dims outside the frame, never the window around it.
    var pictureRect: CGRect = .zero {
        didSet { if pictureRect != oldValue { setNeedsDisplay() } }
    }
    var showsThirds = false {
        didSet { if showsThirds != oldValue { setNeedsDisplay() } }
    }
    var increasedContrast = false {
        didSet { if increasedContrast != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        if !contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let frame = frameRect
        let outline = CGColor(gray: 0, alpha: increasedContrast ? 0.7 : 0.32)
        context.saveGState()
        context.addRect(pictureRect)
        context.addRect(frame.intersection(pictureRect).isNull ? .zero : frame.intersection(pictureRect))
        context.setFillColor(CGColor(gray: 0, alpha: increasedContrast ? 0.45 : 0.26))
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        let edge = frame.insetBy(dx: -0.75, dy: -0.75)
        context.setStrokeColor(outline)
        context.setLineWidth(3.5)
        context.stroke(edge)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.5)
        context.stroke(edge)
        if showsThirds {
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
            context.setLineWidth(0.5)
            for index in 1...2 {
                let x = frame.minX + frame.width * CGFloat(index) / 3
                let y = frame.minY + frame.height * CGFloat(index) / 3
                context.strokeLineSegments(between: [CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.maxY)])
                context.strokeLineSegments(between: [CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y)])
            }
        }
        // Thick white corners, the way Photos marks a crop, over the same dark outline.
        let arm = min(18, frame.width / 3, frame.height / 3)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: frame.minX - 1.5, y: frame.minY - 1.5), 1, 1),
            (CGPoint(x: frame.maxX + 1.5, y: frame.minY - 1.5), -1, 1),
            (CGPoint(x: frame.maxX + 1.5, y: frame.maxY + 1.5), -1, -1),
            (CGPoint(x: frame.minX - 1.5, y: frame.maxY + 1.5), 1, -1),
        ]
        let arms = CGMutablePath()
        for (corner, dx, dy) in corners {
            arms.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            arms.addLine(to: corner)
            arms.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(outline)
        context.setLineWidth(5.5)
        context.addPath(arms)
        context.strokePath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(3)
        context.addPath(arms)
        context.strokePath()
    }
}
