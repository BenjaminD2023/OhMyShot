import AppKit
import OMSCore
import QuartzCore

/// The ruler on one display, over its frozen frame: lines from the pointer out to the nearest change of
/// color each way, each with its length, and a box dragged out, snapped to what it holds, with its size.
///
/// Layers only, in the overlay view's coordinates (y up), with implicit animations off, so nothing trails
/// the pointer.
final class MeasureOverlay {
    let layer = CALayer()

    var unit: MeasureUnit = .points {
        didSet { if unit != oldValue { redraw() } }
    }

    private let display: DisplayInfo
    private var frame: CapturedFrame?
    private var grid: PixelGrid?
    private var gridBuild: Task<Void, Never>?
    private var pointer: CGPoint?
    /// Where the drag began, while it goes on.
    private var boxStart: CGPoint?
    /// The box in points: as dragged, or snapped to its content once the drag ends.
    private var box: CGRect?
    /// The box's size in pixels, as read.
    private var boxPixels: (width: Int, height: Int)?
    /// The two lines' lengths in pixels, for copying.
    private var cross: (width: Int, height: Int)?

    private let linesHalo = CAShapeLayer()
    private let lines = CAShapeLayer()
    private let boxHalo = CAShapeLayer()
    private let boxEdge = CAShapeLayer()
    private let widthReading = ReadingCapsule()
    private let heightReading = ReadingCapsule()
    private let boxReading = ReadingCapsule()

    /// Each line's caps, across it at both ends, in points.
    private static let capLength: CGFloat = 8

    init(display: DisplayInfo) {
        self.display = display
        layer.frame = CGRect(origin: .zero, size: display.frame.size)
        for shape in [linesHalo, boxHalo] {
            shape.strokeColor = .white
            shape.fillColor = nil
            shape.lineWidth = 3
            shape.lineCap = .square
        }
        for shape in [lines, boxEdge] {
            shape.fillColor = nil
            shape.lineWidth = 1
            shape.lineCap = .square
        }
        for reading in [widthReading, heightReading, boxReading] {
            reading.setScale(display.backingScale)
        }
        for sublayer in [boxHalo, boxEdge, linesHalo, lines, boxReading.layer, widthReading.layer, heightReading.layer] {
            layer.addSublayer(sublayer)
        }
        hideAll()
    }

    /// The display's frozen frame. Its pixels are copied out for measuring once the pointer comes to this
    /// display (a 6K display's take 80 MB), off the main thread; the lines show once they are in.
    func show(_ frame: CapturedFrame) {
        self.frame = frame
        grid = nil
        gridBuild?.cancel()
        gridBuild = nil
        if pointer != nil { buildGrid() }
    }

    private func buildGrid() {
        guard grid == nil, gridBuild == nil, let image = frame?.image else { return }
        gridBuild = Task { [weak self] in
            let grid = await Task.detached(priority: .userInitiated) { PixelGrid(image) }.value
            guard let self, !Task.isCancelled, self.frame?.image === image else { return }
            self.grid = grid
            self.redraw()
        }
    }

    /// Lets the frame and its pixels go, and forgets what was measured.
    func clear() {
        gridBuild?.cancel()
        gridBuild = nil
        frame = nil
        grid = nil
        pointer = nil
        boxStart = nil
        box = nil
        boxPixels = nil
        cross = nil
        withoutAnimation { hideAll() }
    }

    func applyAppearance(dark: Bool, contrast: Bool, accent: CGColor) {
        withoutAnimation {
            lines.strokeColor = accent
            boxEdge.strokeColor = accent
            // A white halo keeps the accent line on any background, the accent's own color included.
            let halo = CGColor(gray: 1, alpha: contrast ? 1 : 0.85)
            linesHalo.strokeColor = halo
            boxHalo.strokeColor = halo
            // A light wash of the accent, so the box reads as one shape over busy content.
            boxHalo.fillColor = accent.copy(alpha: 0.08)
            for reading in [widthReading, heightReading, boxReading] {
                reading.applyAppearance(dark: dark, contrast: contrast)
            }
        }
    }

    // MARK: Input

    /// The pointer, in the overlay's coordinates; nil when it is on another display.
    func movePointer(to point: CGPoint?) {
        pointer = point
        if point != nil { buildGrid() }
        guard boxStart == nil else { return }
        redraw()
    }

    func beginBox(at point: CGPoint) {
        boxStart = point
        box = nil
        boxPixels = nil
        redraw()
    }

    func dragBox(to point: CGPoint) {
        guard let start = boxStart else { return }
        pointer = point
        box = pixelAligned(CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)))
        boxPixels = box.map(pixelSize)
        redraw()
    }

    /// Ends the drag: the box shrinks to what it holds, or stays as drawn around nothing but background.
    /// A press without a drag clears it.
    func endBox() {
        defer {
            boxStart = nil
            redraw()
        }
        guard boxStart != nil, let drawn = box, drawn.width * scale >= 2, drawn.height * scale >= 2 else {
            box = nil
            boxPixels = nil
            return
        }
        if let grid, let snapped = grid.contentBounds(in: pixelRect(drawn)) {
            box = pointRect(snapped)
            boxPixels = (Int(snapped.width), Int(snapped.height))
        }
    }

    /// What is on screen, as copied: the box's size, or else the two lines' lengths.
    var measurement: String? {
        if let boxPixels {
            return unit.reading(width: boxPixels.width, height: boxPixels.height, pixelsPerPoint: scale)
        }
        guard let cross else { return nil }
        return unit.reading(width: cross.width, height: cross.height, pixelsPerPoint: scale)
    }

    /// What VoiceOver reads for the measurement on screen.
    var accessibilityValue: String? { measurement }

    // MARK: Drawing

    private var scale: CGFloat {
        frame?.pixelsPerPoint ?? display.pixelsPerPoint
    }

    private var size: CGSize {
        display.frame.size
    }

    private func redraw() {
        withoutAnimation {
            drawLines()
            drawBox()
        }
    }

    /// The lines from the pointer, while no box is drawn or shown: a box keeps the screen to itself until a
    /// click clears it, rather than lines running out from its corner.
    private func drawLines() {
        guard boxStart == nil, box == nil, let pointer, let grid, CGRect(origin: .zero, size: size).contains(pointer) else {
            cross = nil
            for layer in [linesHalo, lines, widthReading.layer, heightReading.layer] { layer.isHidden = true }
            return
        }
        let pixelX = min(max(Int((pointer.x * scale).rounded(.down)), 0), grid.width - 1)
        let pixelY = min(max(Int(((size.height - pointer.y) * scale).rounded(.down)), 0), grid.height - 1)
        let across = grid.span(throughX: pixelX, y: pixelY, horizontal: true)
        let down = grid.span(throughX: pixelX, y: pixelY, horizontal: false)
        cross = (across.count, down.count)

        // Lines through the middle of the pointer's pixel, on whole device pixels so they stay sharp.
        let row = deviceAligned(size.height - (CGFloat(pixelY) + 0.5) / scale)
        let column = deviceAligned((CGFloat(pixelX) + 0.5) / scale)
        let left = CGFloat(across.lowerBound) / scale, right = CGFloat(across.upperBound + 1) / scale
        let top = size.height - CGFloat(down.lowerBound) / scale, bottom = size.height - CGFloat(down.upperBound + 1) / scale
        let path = CGMutablePath()
        let cap = Self.capLength / 2
        path.addLines(between: [CGPoint(x: left, y: row), CGPoint(x: right, y: row)])
        path.addLines(between: [CGPoint(x: left, y: row - cap), CGPoint(x: left, y: row + cap)])
        path.addLines(between: [CGPoint(x: right, y: row - cap), CGPoint(x: right, y: row + cap)])
        path.addLines(between: [CGPoint(x: column, y: bottom), CGPoint(x: column, y: top)])
        path.addLines(between: [CGPoint(x: column - cap, y: bottom), CGPoint(x: column + cap, y: bottom)])
        path.addLines(between: [CGPoint(x: column - cap, y: top), CGPoint(x: column + cap, y: top)])
        lines.path = path
        linesHalo.path = path
        for layer in [linesHalo, lines] { layer.isHidden = false }

        // Each length by its line: above the middle of the line across, right of the middle of the line
        // down; on the other side where the display's edge is too close.
        widthReading.text = unit.reading(across.count, pixelsPerPoint: scale)
        heightReading.text = unit.reading(down.count, pixelsPerPoint: scale)
        let widthSize = widthReading.layer.bounds.size, heightSize = heightReading.layer.bounds.size
        var widthOrigin = CGPoint(x: (left + right) / 2 - widthSize.width / 2, y: row + 8)
        if widthOrigin.y + widthSize.height > size.height - 6 { widthOrigin.y = row - 8 - widthSize.height }
        var heightOrigin = CGPoint(x: column + 8, y: (top + bottom) / 2 - heightSize.height / 2)
        if heightOrigin.x + heightSize.width > size.width - 6 { heightOrigin.x = column - 8 - heightSize.width }
        widthReading.layer.frame.origin = clamped(widthOrigin, size: widthSize)
        heightReading.layer.frame.origin = clamped(heightOrigin, size: heightSize)
        widthReading.layer.isHidden = false
        heightReading.layer.isHidden = false
    }

    private func drawBox() {
        guard let box, let boxPixels else {
            for layer in [boxHalo, boxEdge, boxReading.layer] { layer.isHidden = true }
            return
        }
        let path = CGPath(rect: box, transform: nil)
        boxHalo.path = path
        boxEdge.path = path
        // Dashed while it is drawn, solid once it has snapped.
        boxEdge.lineDashPattern = boxStart == nil ? nil : [4, 3]
        for layer in [boxHalo, boxEdge] { layer.isHidden = false }
        boxReading.text = unit.reading(width: boxPixels.width, height: boxPixels.height, pixelsPerPoint: scale)
        let readingSize = boxReading.layer.bounds.size
        var origin = CGPoint(x: box.midX - readingSize.width / 2, y: box.minY - 10 - readingSize.height)
        if origin.y < 6 { origin.y = box.maxY + 10 }
        boxReading.layer.frame.origin = clamped(origin, size: readingSize)
        boxReading.layer.isHidden = false
    }

    private func hideAll() {
        for layer in [linesHalo, lines, boxHalo, boxEdge, widthReading.layer, heightReading.layer, boxReading.layer] {
            layer.isHidden = true
        }
    }

    // MARK: Geometry

    /// A rectangle in points, from the top left in pixels.
    private func pointRect(_ pixels: CGRect) -> CGRect {
        CGRect(x: pixels.minX / scale, y: size.height - pixels.maxY / scale, width: pixels.width / scale, height: pixels.height / scale)
    }

    /// A rectangle in pixels from the top left, from points.
    private func pixelRect(_ points: CGRect) -> CGRect {
        CGRect(x: points.minX * scale, y: (size.height - points.maxY) * scale, width: points.width * scale, height: points.height * scale).integral
    }

    private func pixelAligned(_ points: CGRect) -> CGRect {
        pointRect(pixelRect(points))
    }

    private func pixelSize(_ points: CGRect) -> (width: Int, height: Int) {
        let pixels = pixelRect(points)
        return (Int(pixels.width), Int(pixels.height))
    }

    private func deviceAligned(_ value: CGFloat) -> CGFloat {
        (value * display.backingScale).rounded() / display.backingScale
    }

    private func clamped(_ origin: CGPoint, size readingSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, 6), size.width - readingSize.width - 6),
            y: min(max(origin.y, 6), size.height - readingSize.height - 6)
        )
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
