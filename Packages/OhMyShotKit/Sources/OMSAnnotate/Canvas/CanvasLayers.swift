import AppKit
import CoreImage.CIFilterBuiltins
import CoreText
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
/// box in the accent, and distinct handles for corners, edges, arrow heads/tails, controls, and rotation.
nonisolated final class SelectionLayer: StillLayer {
    enum HandleKind: Equatable {
        /// Corner resize handle: crisp white rounded square ringed in the accent.
        case corner
        /// Side midpoint resize handle: subtle white circle ringed in the accent.
        case edge
        /// Arrow or line tail/start handle: white circle ringed in the accent.
        case tail
        /// Arrow head (end) handle: accent-filled circle with a white rim so head vs tail is unmistakable.
        case arrowHead
        /// Bend, callout pointer, or magnifier source control handle: white diamond ringed in the accent.
        case control
    }

    struct HandleMarker: Equatable {
        var point: CGPoint
        var kind: HandleKind
    }

    struct Outline: Equatable {
        /// In view points.
        var box: CGRect?
        var handles: [HandleMarker]
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
            if let knob = outline.knob {
                context.setStrokeColor(accent)
                context.setLineWidth(line)
                context.strokeLineSegments(between: [knob.base, knob.point])
                drawRotationKnob(at: knob.point, line: line, in: context)
            }
            for marker in outline.handles {
                drawHandle(marker, line: line, in: context)
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

    private func drawHandle(_ marker: HandleMarker, line: CGFloat, in context: CGContext) {
        let point = marker.point
        let shadowY: CGFloat = contentsAreFlipped() ? 1 : -1
        switch marker.kind {
        case .corner:
            let size: CGFloat = 8.5
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            let radius: CGFloat = 2
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: shadowY), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
            let inset = rect.insetBy(dx: line / 2, dy: line / 2)
            let strokeRadius = max(radius - line / 2, 0.5)
            context.setStrokeColor(accent)
            context.setLineWidth(line)
            context.addPath(CGPath(roundedRect: inset, cornerWidth: strokeRadius, cornerHeight: strokeRadius, transform: nil))
            context.strokePath()
        case .edge:
            let size: CGFloat = 8
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: shadowY), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: rect)
            context.restoreGState()
            context.setStrokeColor(accent)
            context.setLineWidth(line)
            context.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
        case .tail:
            let size = Self.handleSize
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: shadowY), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: rect)
            context.restoreGState()
            context.setStrokeColor(accent)
            context.setLineWidth(line + 0.5)
            context.strokeEllipse(in: rect.insetBy(dx: (line + 0.5) / 2, dy: (line + 0.5) / 2))
        case .arrowHead:
            let size: CGFloat = 10
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: shadowY), blur: 2, color: CGColor(gray: 0, alpha: 0.32))
            context.setFillColor(accent)
            context.fillEllipse(in: rect)
            context.restoreGState()
            let ring: CGFloat = 1.5
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(ring)
            context.strokeEllipse(in: rect.insetBy(dx: ring / 2, dy: ring / 2))
        case .control:
            let half: CGFloat = 5
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: point.x, y: point.y - half))
            diamond.addLine(to: CGPoint(x: point.x + half, y: point.y))
            diamond.addLine(to: CGPoint(x: point.x, y: point.y + half))
            diamond.addLine(to: CGPoint(x: point.x - half, y: point.y))
            diamond.closeSubpath()
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: shadowY), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(diamond)
            context.fillPath()
            context.restoreGState()
            context.setStrokeColor(accent)
            context.setLineWidth(line)
            context.setLineJoin(.round)
            context.addPath(diamond)
            context.strokePath()
        }
    }

    private func drawRotationKnob(at point: CGPoint, line: CGFloat, in context: CGContext) {
        let size: CGFloat = 13
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let shadowY: CGFloat = contentsAreFlipped() ? 1 : -1
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: shadowY), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: rect)
        context.restoreGState()
        context.setStrokeColor(accent)
        context.setLineWidth(line)
        context.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
        // Crisp curved rotation icon inside the knob.
        context.saveGState()
        context.setStrokeColor(accent)
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        let arcRadius: CGFloat = 3.1
        let startAngle: CGFloat = -.pi * 0.75
        let endAngle: CGFloat = .pi * 0.65
        context.addArc(center: point, radius: arcRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        context.strokePath()
        // Tiny arrowhead at endAngle.
        let tip = CGPoint(x: point.x + cos(endAngle) * arcRadius, y: point.y + sin(endAngle) * arcRadius)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: tip.x + 2.0, y: tip.y - 0.8))
        head.addLine(to: tip)
        head.addLine(to: CGPoint(x: tip.x + 0.4, y: tip.y - 2.3))
        context.addPath(head)
        context.strokePath()
        context.restoreGState()
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
    var isDark = false {
        didSet { if isDark != oldValue { setNeedsDisplay() } }
    }
    /// Live pixel dimensions pill text (e.g., "1200 × 720 px") anchored beside the crop frame.
    var dimensionText: String? {
        didSet { if dimensionText != oldValue { setNeedsDisplay() } }
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

        if let text = dimensionText, !text.isEmpty, frame.width > 0, frame.height > 0 {
            drawDimensionPill(text, around: frame, in: context)
        }
    }

    private func drawDimensionPill(_ text: String, around frame: CGRect, in context: CGContext) {
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let font = NSFont(descriptor: baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor, size: 12) ?? baseFont
        let ink = isDark ? CGColor(gray: 1, alpha: 0.92) : CGColor(gray: 0, alpha: 0.85)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let pillWidth = ceil(textWidth) + 22
        let pillHeight: CGFloat = 24
        let margin: CGFloat = 8
        let gap: CGFloat = 10

        let minX = bounds.minX + margin
        let maxX = max(minX, bounds.maxX - margin - pillWidth)
        let x = min(max(frame.midX - pillWidth / 2, minX), maxX)
        var y = frame.minY - gap - pillHeight
        if y < bounds.minY + margin {
            let below = frame.maxY + gap
            if below + pillHeight <= bounds.maxY - margin {
                y = below
            } else {
                y = min(max(frame.minY + gap, bounds.minY + margin), max(bounds.minY + margin, bounds.maxY - margin - pillHeight))
            }
        }
        let pill = CGRect(x: x.rounded(), y: y.rounded(), width: pillWidth, height: pillHeight)
        let radius = pillHeight / 2
        let pillPath = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: contentsAreFlipped() ? 2 : -2), blur: 8, color: CGColor(gray: 0, alpha: 0.18))
        context.setFillColor(isDark ? CGColor(gray: 0.17, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96))
        context.addPath(pillPath)
        context.fillPath()
        context.restoreGState()

        let borderWidth: CGFloat = increasedContrast ? 1 : 0.5
        let borderColor = isDark
            ? CGColor(gray: 1, alpha: increasedContrast ? 0.5 : 0.12)
            : CGColor(gray: 0, alpha: increasedContrast ? 0.35 : 0.08)
        let borderRect = pill.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        context.setStrokeColor(borderColor)
        context.setLineWidth(borderWidth)
        context.addPath(CGPath(roundedRect: borderRect, cornerWidth: radius - borderWidth / 2, cornerHeight: radius - borderWidth / 2, transform: nil))
        context.strokePath()

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let baselineY = pill.midY + (ascent - descent) / 2
        context.textPosition = CGPoint(x: pill.minX + (pill.width - textWidth) / 2, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
