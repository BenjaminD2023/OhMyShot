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

    var tolerance: MeasureTolerance = .medium {
        didSet {
            guard tolerance != oldValue else { return }
            cancelAreaSnap()
            if boxStart == nil { snapBox() }
            redraw()
        }
    }

    /// Pointer measurements remain available when boxes are placed freely.
    var snapsToContent = true {
        didSet {
            guard snapsToContent != oldValue, !snapsToContent else { return }
            cancelAreaSnap()
            if let originalBox {
                box = originalBox
                boxPixels = pixelSize(originalBox)
                self.originalBox = nil
            }
            redraw()
        }
    }

    /// Runs after every redraw, the lines' coming in included, for the overlay's crosshair.
    var onRedraw: (() -> Void)?
    /// A click released before a large selection finishes snapping, delivered when its final bounds are known.
    var onCapture: ((CGRect) -> Void)?

    var isFindingEdges: Bool {
        originalBox != nil && (areaSnap != nil || (grid == nil && gridBuild != nil))
    }

    /// Whether the lines from the pointer are up; they cross at the pointer, in place of the crosshair.
    var showsLines: Bool { !lines.isHidden }

    private let display: DisplayInfo
    private var frame: CapturedFrame?
    private var grid: PixelGrid?
    private var gridBuild: Task<Void, Never>?
    private var areaSnap: Task<Void, Never>?
    private var areaSnapWorker: Task<CGRect?, Never>?
    private var snapGeneration = 0
    private var queuedCapture: CGPoint?
    private var pointer: CGPoint?
    /// Where the drag began, while it goes on.
    private var boxStart: CGPoint?
    /// A press in the finished box stays a click until it moves far enough to start another selection.
    private var capturePress: CGPoint?
    /// The box in points: as dragged, or snapped to its content once the drag ends.
    private var box: CGRect?
    /// Keep the original selection so a lower tolerance can recover edges trimmed at a higher one.
    private var originalBox: CGRect?
    /// The box's size in pixels, as read.
    private var boxPixels: (width: Int, height: Int)?
    /// The two lines' lengths in pixels, for copying.
    private var cross: (width: Int, height: Int)?
    /// While set, the reading says "Copied", as a pin's reading does.
    private var copiedFeedback: Task<Void, Never>?

    private let linesHalo = CAShapeLayer()
    private let lines = CAShapeLayer()
    private let boxHalo = CAShapeLayer()
    private let boxEdge = CAShapeLayer()
    private let widthReading = ReadingCapsule()
    private let heightReading = ReadingCapsule()
    private let boxReading = ReadingCapsule()
    private let toleranceReading = ReadingCapsule()

    /// Each line's caps, across it at both ends, in points.
    private static let capLength: CGFloat = 8
    private static let clickTravel: CGFloat = 3

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
        for reading in [widthReading, heightReading, boxReading, toleranceReading] {
            reading.setScale(display.backingScale)
        }
        for sublayer in [boxHalo, boxEdge, linesHalo, lines, boxReading.layer, widthReading.layer, heightReading.layer, toleranceReading.layer] {
            layer.addSublayer(sublayer)
        }
        hideAll()
    }

    /// The display's frozen frame. Its pixels are copied out for measuring once the pointer comes to this
    /// display (a 6K display's take 80 MB), off the main thread; the lines show once they are in.
    func show(_ frame: CapturedFrame) {
        cancelAreaSnap()
        capturePress = nil
        self.frame = frame
        grid = nil
        gridBuild?.cancel()
        gridBuild = nil
        if pointer != nil { buildGrid() }
    }

    private func buildGrid() {
        guard grid == nil, gridBuild == nil, let frame else { return }
        let image = frame.image
        let pixelsPerPoint = frame.pixelsPerPoint
        let worker = Task.detached(priority: .userInitiated) { PixelGrid(image, pixelsPerPoint: pixelsPerPoint) }
        gridBuild = Task { [weak self] in
            let grid = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, self.frame?.image === image else { return }
            self.gridBuild = nil
            self.grid = grid
            if self.boxStart == nil, self.areaSnap == nil { self.snapBox() }
            self.redraw()
        }
    }

    /// Lets the frame and its pixels go, and forgets what was measured.
    func clear() {
        cancelAreaSnap()
        copiedFeedback?.cancel()
        copiedFeedback = nil
        gridBuild?.cancel()
        gridBuild = nil
        frame = nil
        grid = nil
        pointer = nil
        boxStart = nil
        capturePress = nil
        box = nil
        originalBox = nil
        boxPixels = nil
        cross = nil
        withoutAnimation { hideAll() }
    }

    func applyAppearance(dark: Bool, contrast: Bool, accent: CGColor) {
        withoutAnimation {
            lines.strokeColor = accent
            boxEdge.strokeColor = accent
            // Increase Contrast doubles the accent edges, as it does the overlay's other lines.
            lines.lineWidth = contrast ? 2 : 1
            boxEdge.lineWidth = contrast ? 2 : 1
            linesHalo.lineWidth = contrast ? 4 : 3
            boxHalo.lineWidth = contrast ? 4 : 3
            // A white halo keeps the accent line on any background, the accent's own color included.
            let halo = CGColor(gray: 1, alpha: contrast ? 1 : 0.85)
            linesHalo.strokeColor = halo
            boxHalo.strokeColor = halo
            // A light wash of the accent, so the box reads as one shape over busy content.
            boxHalo.fillColor = accent.copy(alpha: 0.08)
            for reading in [widthReading, heightReading, boxReading, toleranceReading] {
                reading.applyAppearance(dark: dark, contrast: contrast)
            }
        }
    }

    // MARK: Input

    /// The pointer, in the overlay's coordinates; nil when it is on another display, which lets this
    /// display's pixels go until the pointer comes back (copying them again takes tens of milliseconds).
    func movePointer(to point: CGPoint?) {
        pointer = point
        if point != nil {
            buildGrid()
        } else if queuedCapture == nil, !(gridBuild != nil && (originalBox != nil || boxStart != nil)) {
            gridBuild?.cancel()
            gridBuild = nil
            grid = nil
        }
        guard boxStart == nil else { return }
        redraw()
    }

    /// The reading says "Copied" for a moment: the box's, or else the line across's.
    func flashCopied() {
        copiedFeedback?.cancel()
        copiedFeedback = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            self.copiedFeedback = nil
            self.redraw()
        }
        redraw()
    }

    func beginBox(at point: CGPoint, allowsCapture: Bool = true) {
        queuedCapture = nil
        if allowsCapture, boxStart == nil, let box, box.contains(point) {
            capturePress = point
            return
        }
        cancelAreaSnap()
        capturePress = nil
        boxStart = point
        box = nil
        originalBox = nil
        boxPixels = nil
        redraw()
    }

    func dragBox(to point: CGPoint) {
        if let pressed = capturePress {
            guard hypot(point.x - pressed.x, point.y - pressed.y) > Self.clickTravel else { return }
            // A drag that began inside an old selection draws a new one from the press.
            cancelAreaSnap()
            capturePress = nil
            boxStart = pressed
            box = nil
            originalBox = nil
            boxPixels = nil
        }
        guard let start = boxStart else { return }
        pointer = point
        box = pixelAligned(CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)))
        boxPixels = box.map(pixelSize)
        redraw()
    }

    /// Ends the drag: the box shrinks to what it holds, or stays as drawn around nothing but background.
    /// A plain click inside the finished box returns its local area to capture; it never reads the screen.
    /// A press outside without a drag clears the selection.
    @discardableResult
    func endBox(at point: CGPoint? = nil, snapping: Bool = true, allowsCapture: Bool = true) -> CGRect? {
        if let pressed = capturePress {
            capturePress = nil
            guard allowsCapture, let point, let box, box.contains(point),
                  hypot(point.x - pressed.x, point.y - pressed.y) <= Self.clickTravel else { return nil }
            if isFindingEdges {
                queuedCapture = point
                return nil
            }
            return box
        }
        defer {
            boxStart = nil
            redraw()
        }
        guard boxStart != nil, let drawn = box, drawn.width * scale >= 2, drawn.height * scale >= 2 else {
            box = nil
            originalBox = nil
            boxPixels = nil
            return nil
        }
        originalBox = snapping && snapsToContent ? drawn : nil
        snapBox()
        if box != drawn {
            // A tap on the trackpad as the box takes its content's edges.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return nil
    }

    private func snapBox() {
        cancelAreaSnap(clearsCapture: false)
        guard let originalBox else { return }
        guard let grid else {
            box = originalBox
            boxPixels = pixelSize(originalBox)
            return
        }
        let pixels = pixelRect(originalBox)
        if pixels.width * pixels.height > 250_000, let image = frame?.image {
            let tolerance = tolerance
            let generation = snapGeneration
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as CGRect? }
                let bounds = grid.contentBounds(in: pixels, tolerance: tolerance)
                return Task.isCancelled ? nil : bounds
            }
            areaSnapWorker = worker
            areaSnap = Task { [weak self] in
                let snapped = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, generation == self.snapGeneration,
                      self.frame?.image === image, self.originalBox == originalBox,
                      self.tolerance == tolerance, self.boxStart == nil else { return }
                self.areaSnap = nil
                self.areaSnapWorker = nil
                self.applyBounds(snapped, original: originalBox)
                self.redraw()
                self.fulfillQueuedCapture()
            }
            return
        }
        applyBounds(grid.contentBounds(in: pixels, tolerance: tolerance), original: originalBox)
        fulfillQueuedCapture()
    }

    private func applyBounds(_ snapped: CGRect?, original: CGRect) {
        if let snapped {
            box = pointRect(snapped)
            boxPixels = (Int(snapped.width), Int(snapped.height))
        } else {
            box = original
            boxPixels = pixelSize(original)
        }
    }

    private func cancelAreaSnap(clearsCapture: Bool = true) {
        snapGeneration &+= 1
        areaSnap?.cancel()
        areaSnap = nil
        areaSnapWorker?.cancel()
        areaSnapWorker = nil
        if clearsCapture { queuedCapture = nil }
    }

    private func fulfillQueuedCapture() {
        guard let point = queuedCapture else { return }
        queuedCapture = nil
        guard let box, box.contains(point) else { return }
        onCapture?(box)
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
    var accessibilityValue: String? {
        guard let measurement else { return nil }
        if isFindingEdges {
            return String(localized: "\(measurement). Finding edges…", bundle: .module)
        }
        if box != nil, boxStart == nil {
            return String(localized: "\(measurement). Click inside the selection to capture it. Tolerance: \(tolerance.title).", bundle: .module)
        }
        return String(localized: "\(measurement). Tolerance: \(tolerance.title).", bundle: .module)
    }

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
            drawTolerance()
        }
        onRedraw?()
    }

    private var copiedText: String { String(localized: "Copied", bundle: .module) }

    /// The lines from the pointer, while no box is drawn or shown: a box keeps the screen to itself until a
    /// click outside clears it, rather than lines running out from its corner.
    private func drawLines() {
        guard boxStart == nil, box == nil, let pointer, let grid, CGRect(origin: .zero, size: size).contains(pointer) else {
            cross = nil
            for layer in [linesHalo, lines, widthReading.layer, heightReading.layer] { layer.isHidden = true }
            return
        }
        let pixelX = min(max(Int((pointer.x * scale).rounded(.down)), 0), grid.width - 1)
        let pixelY = min(max(Int(((size.height - pointer.y) * scale).rounded(.down)), 0), grid.height - 1)
        let across = grid.span(throughX: pixelX, y: pixelY, horizontal: true, tolerance: tolerance)
        let down = grid.span(throughX: pixelX, y: pixelY, horizontal: false, tolerance: tolerance)
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
        widthReading.text = copiedFeedback != nil ? copiedText : unit.reading(across.count, pixelsPerPoint: scale)
        heightReading.text = unit.reading(down.count, pixelsPerPoint: scale)
        let widthSize = widthReading.layer.bounds.size, heightSize = heightReading.layer.bounds.size
        var widthOrigin = CGPoint(x: (left + right) / 2 - widthSize.width / 2, y: row + 8)
        if widthOrigin.y + widthSize.height > size.height - 6 { widthOrigin.y = row - 8 - widthSize.height }
        var heightOrigin = CGPoint(x: column + 8, y: (top + bottom) / 2 - heightSize.height / 2)
        if heightOrigin.x + heightSize.width > size.width - 6 { heightOrigin.x = column - 8 - heightSize.width }
        widthOrigin = clamped(widthOrigin, size: widthSize)
        heightOrigin = clamped(heightOrigin, size: heightSize)
        // On something small both lines' middles are near the pointer: the length down steps below the line
        // across rather than overlap the length across.
        if CGRect(origin: widthOrigin, size: widthSize).insetBy(dx: -2, dy: -2).intersects(CGRect(origin: heightOrigin, size: heightSize)) {
            heightOrigin = clamped(CGPoint(x: heightOrigin.x, y: row - 8 - heightSize.height), size: heightSize)
        }
        widthReading.layer.frame.origin = widthOrigin
        heightReading.layer.frame.origin = heightOrigin
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
        // Lighter while it is drawn, solid once it has snapped.
        for layer in [boxHalo, boxEdge] {
            layer.isHidden = false
            layer.opacity = boxStart == nil ? 1 : 0.6
        }
        let dimensions = unit.reading(width: boxPixels.width, height: boxPixels.height, pixelsPerPoint: scale)
        boxReading.text = if copiedFeedback != nil {
            copiedText
        } else if isFindingEdges {
            String(localized: "\(dimensions) · Finding edges…", bundle: .module)
        } else if boxStart == nil {
            String(localized: "\(dimensions) · Click to capture", bundle: .module)
        } else {
            dimensions
        }
        let readingSize = boxReading.layer.bounds.size
        var origin = CGPoint(x: box.midX - readingSize.width / 2, y: box.minY - 10 - readingSize.height)
        if origin.y < 6 { origin.y = box.maxY + 10 }
        boxReading.layer.frame.origin = clamped(origin, size: readingSize)
        boxReading.layer.isHidden = false
    }

    private func hideAll() {
        for layer in [linesHalo, lines, boxHalo, boxEdge, widthReading.layer, heightReading.layer, boxReading.layer, toleranceReading.layer] {
            layer.isHidden = true
        }
    }

    private func drawTolerance() {
        guard frame != nil, pointer != nil || box != nil else {
            toleranceReading.layer.isHidden = true
            return
        }
        toleranceReading.text = String(localized: "Tolerance: \(tolerance.title) · T / + / −", bundle: .module)
        let readingSize = toleranceReading.layer.bounds.size
        toleranceReading.layer.frame.origin = clamped(CGPoint(x: (size.width - readingSize.width) / 2, y: 18), size: readingSize)
        toleranceReading.layer.isHidden = false
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
