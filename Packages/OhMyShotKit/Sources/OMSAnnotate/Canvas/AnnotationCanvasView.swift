import AppKit
import OMSCore
import QuartzCore

/// The canvas: the capture with its marks, drawn and edited with the pointer and keyboard. It knows
/// nothing of the window around it, so the editor and in-place annotation can both host it.
///
/// Marks are layers drawn by the same renderer as exports; the capture is one layer the GPU scales.
/// Zooming redraws the marks at the new size, so they stay sharp.
public final class AnnotationCanvasView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    public let session: AnnotationSession
    /// Room around the picture that it keeps clear of when fitted, such as the tool rail's.
    public var contentInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28) {
        didSet { needsLayout = true }
    }
    /// View points per capture pixel.
    public private(set) var zoom: CGFloat = 1
    /// Whether the picture is fitted to the view, rather than zoomed by the user.
    public var isFitted: Bool { userZoom == nil }
    /// Whether a mark is being drawn, moved, or reshaped, or the crop dragged.
    public var isDragging: Bool { drag != nil }
    /// Whether a text mark is being typed.
    public var isEditingText: Bool { editing != nil }
    /// After any change to where the picture or the selection is on screen.
    public var onViewportChange: (() -> Void)?
    public var onCopy: (() -> Void)?
    public var onSave: (() -> Void)?

    private enum Drag {
        case creating(id: Annotation.ID, tool: AnnotationTool, start: CGPoint)
        case drawing(id: Annotation.ID)
        case moving(start: CGPoint, originals: [Annotation])
        case reshaping(handle: Handle, original: Annotation)
        case cropping(handle: Handle?, start: CGPoint, original: CGRect)
    }

    private final class TextEditing {
        let id: Annotation.ID
        let isNew: Bool
        let view: MarkTextView
        let undo = UndoManager()

        init(id: Annotation.ID, isNew: Bool, view: MarkTextView) {
            self.id = id
            self.isNew = isNew
            self.view = view
        }
    }

    private let host = FlippedHostView()
    private let pictureLayer = StillLayer()
    private let canvasLayer = StillLayer()
    private let imageLayer = StillLayer()
    private let spotlightLayer = SpotlightLayer()
    private var markLayers: [Annotation.ID: MarkLayer] = [:]
    private let selectionLayer = SelectionLayer()
    private let cropLayer = CropLayer()

    private var displayOptions: NSObjectProtocol?
    private var userZoom: CGFloat?
    /// The capture point at the middle of the free area while zoomed in.
    private var focus: CGPoint?
    private var canvasFrame: CGRect = .zero
    private var drag: Drag?
    private var editing: TextEditing?
    /// The crop being chosen while the crop tool is in hand, in capture pixels.
    private var cropRect: CGRect?

    public init(session: AnnotationSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        host.layer = StillLayer()
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        imageLayer.contents = session.base
        imageLayer.zPosition = -2
        spotlightLayer.zPosition = -1
        canvasLayer.masksToBounds = true
        canvasLayer.addSublayer(imageLayer)
        canvasLayer.addSublayer(spotlightLayer)
        pictureLayer.shadowColor = .black
        pictureLayer.shadowOpacity = 0.12
        pictureLayer.shadowRadius = 10
        pictureLayer.shadowOffset = CGSize(width: 0, height: 4)
        pictureLayer.borderWidth = 0.5
        // A window captured with its shadow is transparent around the window: a box shadow or edge
        // around it would draw a rectangle that is not in the picture.
        pictureLayer.isHidden = !Self.hasOpaqueCorners(session.base)
        host.layer?.addSublayer(pictureLayer)
        host.layer?.addSublayer(canvasLayer)
        host.layer?.addSublayer(selectionLayer)
        host.layer?.addSublayer(cropLayer)
        cropLayer.isHidden = true

        session.observe { [weak self] event in self?.sessionChanged(event) }
        syncMarks()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// The selected marks' frame in view points, for placing controls beside it.
    public var selectionFrame: CGRect? {
        let scale = session.document.scale
        let frames = session.selectedItems.map { viewRect($0.bounds(scale: scale)) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The picture's frame in view points.
    public var pictureFrame: CGRect { canvasFrame }

    /// The part of the document on screen: the canvas, or while cropping the whole capture too, so the
    /// crop can grow back out.
    private var shownCanvas: CGRect {
        let document = session.document
        return session.tool == .crop ? document.imageBounds.union(document.canvas) : document.canvas
    }

    private var freeArea: CGRect {
        CGRect(
            x: bounds.minX + contentInsets.left,
            y: bounds.minY + contentInsets.top,
            width: max(bounds.width - contentInsets.left - contentInsets.right, 1),
            height: max(bounds.height - contentInsets.top - contentInsets.bottom, 1)
        )
    }

    /// The zoom that fits the canvas in the free area, never larger than it appeared on screen.
    private var fitZoom: CGFloat {
        let canvas = shownCanvas
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        let area = freeArea
        return min(1 / session.document.scale, area.width / canvas.width, area.height / canvas.height)
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        let canvas = shownCanvas
        return CGPoint(x: canvasFrame.minX + (point.x - canvas.minX) * zoom, y: canvasFrame.minY + (point.y - canvas.minY) * zoom)
    }

    private func documentPoint(_ point: CGPoint) -> CGPoint {
        let canvas = shownCanvas
        return CGPoint(x: canvas.minX + (point.x - canvasFrame.minX) / zoom, y: canvas.minY + (point.y - canvasFrame.minY) / zoom)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return rect }
        let origin = viewPoint(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * zoom, height: rect.height * zoom)
    }

    public override func layout() {
        super.layout()
        updateViewport()
    }

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        guard window != nil else { return }
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [pictureLayer, canvasLayer, imageLayer, spotlightLayer, selectionLayer, cropLayer] {
            layer.contentsScale = scale
        }
        markLayers.values.forEach { $0.contentsScale = scale }
        updateViewport()
    }

    private func updateViewport() {
        let canvas = shownCanvas
        let area = freeArea
        zoom = userZoom ?? fitZoom
        let size = CGSize(width: canvas.width * zoom, height: canvas.height * zoom)
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        if let focus {
            // Zoomed in: the focus point sits mid-area, but the picture never leaves an edge of the area
            // uncovered while it is larger than the area.
            origin.x = size.width > area.width ? min(max(area.midX - (focus.x - canvas.minX) * zoom, area.maxX - size.width), area.minX) : origin.x
            origin.y = size.height > area.height ? min(max(area.midY - (focus.y - canvas.minY) * zoom, area.maxY - size.height), area.minY) : origin.y
        }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        canvasFrame = CGRect(x: (origin.x / pixel).rounded() * pixel, y: (origin.y / pixel).rounded() * pixel, width: size.width, height: size.height)
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let canvas = shownCanvas
        pictureLayer.frame = canvasFrame
        pictureLayer.shadowPath = CGPath(rect: pictureLayer.bounds, transform: nil)
        canvasLayer.frame = canvasFrame
        imageLayer.frame = CGRect(
            x: -canvas.minX * zoom, y: -canvas.minY * zoom,
            width: session.document.pixelSize.width * zoom, height: session.document.pixelSize.height * zoom
        )
        // Pixels show as pixels once each covers two or more device pixels; smaller, they blend.
        let devicePerPixel = zoom * (window?.backingScaleFactor ?? 2)
        imageLayer.magnificationFilter = devicePerPixel >= 2 ? .nearest : .linear
        imageLayer.minificationFilter = .trilinear
        // Drawn layers cover only what is on screen: zoomed in on a large capture, a layer the size of a
        // whole mark would need a backing store of hundreds of megabytes.
        let visible = visibleCanvasRect
        let spot = canvasLayer.bounds.intersection(visible)
        spotlightLayer.frame = spot.isNull ? .zero : spot
        spotlightLayer.canvas = session.document.canvas
        spotlightLayer.mapping = LayerMapping(
            origin: CGPoint(x: canvas.minX + (spot.isNull ? 0 : spot.minX) / zoom, y: canvas.minY + (spot.isNull ? 0 : spot.minY) / zoom),
            zoom: zoom
        )
        for layer in markLayers.values {
            position(layer)
        }
        selectionLayer.frame = host.bounds
        cropLayer.frame = host.bounds
        cropLayer.pictureRect = canvasFrame
        if let cropRect { cropLayer.frameRect = viewRect(cropRect) }
        updateSelectionOutlines()
        CATransaction.commit()
        onViewportChange?()
    }

    /// The part of the canvas layer on screen, with a margin so small pans need no redraw at the edges,
    /// in the canvas layer's coordinates.
    private var visibleCanvasRect: CGRect {
        let margin: CGFloat = 64
        return bounds.insetBy(dx: -margin, dy: -margin).offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY)
    }

    private func position(_ layer: MarkLayer) {
        let canvas = shownCanvas
        let bounds = layer.mark.drawingBounds(scale: session.document.scale)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            layer.frame = .zero
            return
        }
        let whole = CGRect(x: (bounds.minX - canvas.minX) * zoom, y: (bounds.minY - canvas.minY) * zoom, width: bounds.width * zoom, height: bounds.height * zoom)
        let shown = whole.intersection(visibleCanvasRect)
        guard !shown.isNull, shown.width > 0, shown.height > 0 else {
            layer.frame = .zero
            return
        }
        layer.frame = shown
        // The document point at the layer's corner, so it draws just its visible part.
        layer.mapping = LayerMapping(origin: CGPoint(x: canvas.minX + shown.minX / zoom, y: canvas.minY + shown.minY / zoom), zoom: zoom)
    }

    #if DEBUG
    /// Where a capture point is in the window, for synthesized events.
    func windowPoint(forDocument point: CGPoint) -> CGPoint {
        convert(viewPoint(point), to: nil)
    }
    #endif

    // MARK: Zoom

    public func zoomToFit() {
        userZoom = nil
        focus = nil
        updateViewport()
    }

    /// Shows the capture at the size it had on screen.
    public func zoomToActualSize() {
        setZoom(1 / session.document.scale, around: nil)
    }

    public func zoomIn() {
        setZoom(zoom * 1.5, around: nil)
    }

    public func zoomOut() {
        setZoom(zoom / 1.5, around: nil)
    }

    /// Zooms keeping the capture point under `anchor` (view points) in place, or the middle.
    private func setZoom(_ newZoom: CGFloat, around anchor: CGPoint?) {
        let fit = fitZoom
        let clamped = min(max(newZoom, min(fit, 0.05)), 8)
        let area = freeArea
        let anchorView = anchor ?? CGPoint(x: area.midX, y: area.midY)
        let anchorDocument = documentPoint(anchorView)
        if abs(clamped - fit) < fit * 0.02 || clamped < fit {
            userZoom = clamped < fit ? clamped : nil
            focus = nil
        } else {
            userZoom = clamped
            // The point that must end mid-area so the anchor stays under the pointer.
            focus = CGPoint(
                x: anchorDocument.x - (anchorView.x - area.midX) / clamped,
                y: anchorDocument.y - (anchorView.y - area.midY) / clamped
            )
        }
        updateViewport()
    }

    public override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    public override func smartMagnify(with event: NSEvent) {
        if isFitted {
            setZoom(1 / session.document.scale, around: convert(event.locationInWindow, from: nil))
        } else {
            zoomToFit()
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            setZoom(zoom * factor, around: convert(event.locationInWindow, from: nil))
            return
        }
        guard userZoom != nil, let current = focus ?? Optional(documentPoint(CGPoint(x: freeArea.midX, y: freeArea.midY))) else {
            super.scrollWheel(with: event)
            return
        }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        focus = CGPoint(x: current.x - event.scrollingDeltaX * multiplier / zoom, y: current.y - event.scrollingDeltaY * multiplier / zoom)
        updateViewport()
        // Clamped by the edges: keep the focus where the picture actually is.
        focus = documentPoint(CGPoint(x: freeArea.midX, y: freeArea.midY))
    }

    // MARK: Session

    private func sessionChanged(_ event: AnnotationSession.Event) {
        switch event {
        case .document:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if canvasFrame.size != CGSize(width: shownCanvas.width * zoom, height: shownCanvas.height * zoom) {
                // What is shown changed size (a crop): fit again.
                userZoom = nil
                focus = nil
                syncMarks()
                updateViewport()
            } else {
                syncMarks()
                updateSelectionOutlines()
            }
            CATransaction.commit()
            updateAccessibility()
            onViewportChange?()
        case .selection:
            updateSelectionOutlines()
            onViewportChange?()
        case .tool:
            toolChanged()
        case .settings:
            break
        }
    }

    private func syncMarks() {
        let document = session.document
        let scale = window?.backingScaleFactor ?? 2
        var present = Set<Annotation.ID>()
        for (index, item) in document.items.enumerated() {
            if case .spotlight = item.shape { continue }
            present.insert(item.id)
            let layer: MarkLayer
            if let existing = markLayers[item.id] {
                layer = existing
                if layer.mark != item {
                    let reshaped = layer.mark.shape != item.shape
                    layer.mark = item
                    if reshaped { updateRedaction(layer) }
                }
            } else {
                layer = MarkLayer(mark: item)
                layer.scale = document.scale
                layer.contentsScale = scale
                markLayers[item.id] = layer
                canvasLayer.addSublayer(layer)
                updateRedaction(layer)
            }
            layer.zPosition = CGFloat(index)
            layer.isHidden = editing?.id == item.id
            position(layer)
        }
        for (id, layer) in markLayers where !present.contains(id) {
            layer.removeFromSuperlayer()
            markLayers[id] = nil
        }
        spotlightLayer.spots = document.spots
    }

    private func updateRedaction(_ layer: MarkLayer) {
        guard case .redaction(let redaction) = layer.mark.shape, redaction.method != .solid else {
            layer.redacted = nil
            return
        }
        layer.redacted = Redactor.image(for: redaction, id: layer.mark.id, base: session.base, scale: session.document.scale)
    }

    private func updateSelectionOutlines() {
        let scale = session.document.scale
        let single = session.selection.count == 1 && editing == nil
        // The text being typed shows its own field instead of a selection.
        selectionLayer.outlines = session.selectedItems.filter { $0.id != editing?.id }.map { item in
            let handles = single ? item.handles(scale: scale).map { viewPoint($0.point) } : []
            // A single arrow or line shows its handles alone; anything else, or several, a box too.
            switch item.shape {
            case .arrow, .line:
                if single { return SelectionLayer.Outline(box: nil, handles: handles) }
            default:
                break
            }
            return SelectionLayer.Outline(box: viewRect(item.bounds(scale: scale)).integral, handles: handles)
        }
    }

    private func toolChanged() {
        endEditing()
        if session.tool != .select { session.select([]) }
        if session.tool == .crop {
            cropRect = session.document.canvas
            cropLayer.isHidden = false
            // The whole capture shows while cropping.
            userZoom = nil
            focus = nil
            updateViewport()
        } else if let cropRect {
            self.cropRect = nil
            cropLayer.isHidden = true
            applyCrop(cropRect)
            userZoom = nil
            focus = nil
            updateViewport()
        }
        window?.invalidateCursorRects(for: self)
        onViewportChange?()
    }

    // MARK: Crop

    /// Applies the crop being chosen; the crop tool stays in hand.
    public func commitCrop() {
        guard let cropRect else { return }
        applyCrop(cropRect)
    }

    /// Puts the crop frame back to the whole canvas.
    public func resetCrop() {
        guard session.tool == .crop else { return }
        cropRect = session.document.imageBounds
        cropLayer.frameRect = viewRect(session.document.imageBounds)
        applyCrop(session.document.imageBounds)
    }

    private func applyCrop(_ rect: CGRect) {
        let rect = rect.standardized.integral
        guard rect.width >= 4, rect.height >= 4, rect != session.document.canvas else { return }
        session.crop(to: rect)
        if session.tool == .crop {
            cropRect = session.document.canvas
            cropLayer.frameRect = viewRect(session.document.canvas)
        }
    }

    // MARK: Hit testing

    private var tolerance: CGFloat { 5 / zoom }

    private func hitItem(at point: CGPoint) -> Annotation? {
        let scale = session.document.scale
        let interiorForAll = session.tool == .select
        for item in session.document.items.reversed() {
            let interior = interiorForAll || session.selection.contains(item.id)
            if item.contains(point, tolerance: tolerance, scale: scale, interior: interior) { return item }
        }
        return nil
    }

    private func handle(at viewPoint: CGPoint, of item: Annotation) -> Handle? {
        let reach = SelectionLayer.handleSize / 2 + 4
        let scale = session.document.scale
        return item.handles(scale: scale).first { candidate in
            let point = self.viewPoint(candidate.point)
            return hypot(point.x - viewPoint.x, point.y - viewPoint.y) <= reach
        }?.handle
    }

    private func cropHandle(at viewPoint: CGPoint) -> Handle? {
        guard let cropRect else { return nil }
        let frame = viewRect(cropRect)
        let reach: CGFloat = 10
        let points: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: frame.minX, y: frame.minY)), (.topRight, CGPoint(x: frame.maxX, y: frame.minY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.maxY)), (.bottomLeft, CGPoint(x: frame.minX, y: frame.maxY)),
        ]
        if let corner = points.first(where: { hypot($0.1.x - viewPoint.x, $0.1.y - viewPoint.y) <= reach + 4 }) {
            return corner.0
        }
        let insideX = viewPoint.x > frame.minX && viewPoint.x < frame.maxX
        let insideY = viewPoint.y > frame.minY && viewPoint.y < frame.maxY
        if insideX, abs(viewPoint.y - frame.minY) <= reach { return .top }
        if insideX, abs(viewPoint.y - frame.maxY) <= reach { return .bottom }
        if insideY, abs(viewPoint.x - frame.minX) <= reach { return .left }
        if insideY, abs(viewPoint.x - frame.maxX) <= reach { return .right }
        return nil
    }

    // MARK: Pointer

    public override func mouseDown(with event: NSEvent) {
        if editing != nil {
            endEditing()
        }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        let point = documentPoint(location)
        let shift = event.modifierFlags.contains(.shift)
        let scale = session.document.scale

        if session.tool == .crop, let cropRect {
            if let handle = cropHandle(at: location) {
                drag = .cropping(handle: handle, start: point, original: cropRect)
            } else if viewRect(cropRect).contains(location) {
                drag = .cropping(handle: nil, start: point, original: cropRect)
            } else {
                drag = .cropping(handle: .bottomRight, start: point, original: CGRect(origin: point, size: .zero))
            }
            cropLayer.showsThirds = true
            return
        }

        if session.selection.count == 1, let item = session.selectedItems.first, let handle = handle(at: location, of: item) {
            session.beginLiveChange()
            drag = .reshaping(handle: handle, original: item)
            return
        }

        if let item = hitItem(at: point) {
            if event.clickCount == 2, case .text = item.shape {
                beginEditing(item.id, isNew: false)
                return
            }
            if shift {
                var selection = session.selection
                if let index = selection.firstIndex(of: item.id) { selection.remove(at: index) } else { selection.append(item.id) }
                session.select(selection)
                return
            }
            if !session.selection.contains(item.id) { session.select([item.id]) }
            session.beginLiveChange()
            var originals = session.selectedItems
            if event.modifierFlags.contains(.option) {
                // Option-drag drags copies.
                var document = session.document
                originals = originals.map { original in
                    var copy = original
                    copy.id = UUID()
                    document.items.append(copy)
                    return copy
                }
                session.updateLive(document, selecting: originals.map(\.id))
            }
            drag = .moving(start: point, originals: originals)
            NSCursor.closedHand.set()
            return
        }

        session.select([])
        let tool = session.tool
        let settings = session.settings(for: tool)
        switch tool {
        case .select, .crop:
            break
        case .arrow, .line, .rectangle, .ellipse, .redact, .spotlight:
            session.beginLiveChange()
            drag = .creating(id: UUID(), tool: tool, start: point)
        case .pen, .highlighter:
            session.beginLiveChange()
            let stroke = Stroke(points: [point])
            let item = Annotation(shape: tool == .pen ? .pen(stroke) : .highlighter(stroke), style: settings.style)
            var document = session.document
            document.items.append(item)
            session.updateLive(document)
            drag = .drawing(id: item.id)
        case .text:
            session.beginLiveChange()
            let layout = TextLayout(TextBlock(origin: .zero, string: " ", fontSize: settings.fontSize, look: settings.textLook), scale: scale)
            // The click lands mid-line, at the start of the text, where a text caret would be.
            let origin = CGPoint(x: point.x - layout.inset.width, y: point.y - layout.size.height / 2)
            let item = Annotation(shape: .text(TextBlock(origin: origin, string: "", fontSize: settings.fontSize, look: settings.textLook)), style: settings.style)
            var document = session.document
            document.items.append(item)
            session.updateLive(document, selecting: [item.id])
            beginEditing(item.id, isNew: true)
        case .counter:
            let item = Annotation(shape: .counter(Counter(center: point, value: session.document.nextCounterValue, numbering: settings.numbering)), style: settings.style)
            var document = session.document
            document.items.append(item)
            session.commit(document, selecting: [item.id], actionName: String(localized: "Add Counter", bundle: .module))
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let location = convert(event.locationInWindow, from: nil)
        let point = documentPoint(location)
        let shift = event.modifierFlags.contains(.shift)
        var document = session.document
        switch drag {
        case .creating(let id, let tool, let start):
            guard let mark = tool.mark(from: start, to: point, constrained: shift, settings: session.settings(for: tool), id: id) else { return }
            if let index = document.index(of: id) { document.items[index] = mark } else { document.items.append(mark) }
            session.updateLive(document, selecting: [])
        case .drawing(let id):
            guard let index = document.index(of: id) else { return }
            switch document.items[index].shape {
            case .pen(var stroke):
                guard let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) * zoom >= 1.5 else { return }
                stroke.points.append(point)
                document.items[index].shape = .pen(stroke)
            case .highlighter(var stroke):
                guard let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) * zoom >= 1.5 else { return }
                // Shift keeps a highlighter level, as along a line of text.
                stroke.points.append(shift ? CGPoint(x: point.x, y: stroke.points[0].y) : point)
                document.items[index].shape = .highlighter(stroke)
            default:
                return
            }
            session.updateLive(document)
        case .moving(let start, let originals):
            var delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            if shift {
                if abs(delta.width) > abs(delta.height) { delta.height = 0 } else { delta.width = 0 }
            }
            for original in originals {
                guard let index = document.index(of: original.id) else { continue }
                document.items[index] = original.translated(by: delta)
            }
            session.updateLive(document)
        case .reshaping(let handle, let original):
            guard let index = document.index(of: original.id) else { return }
            document.items[index] = original.moving(handle, to: point, constrained: shift, scale: document.scale)
            session.updateLive(document)
        case .cropping(let handle, let start, let original):
            var rect: CGRect
            if let handle {
                rect = Geometry.resized(original, dragging: handle, to: point, keepingAspect: shift)
            } else {
                rect = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            }
            rect = rect.standardized
            cropRect = rect
            cropLayer.frameRect = viewRect(rect)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        let location = convert(event.locationInWindow, from: nil)
        defer {
            updateCursor(at: location)
            // Controls hidden during the drag come back where the marks now are.
            onViewportChange?()
        }
        switch drag {
        case .creating(let id, let tool, let start):
            let startView = viewPoint(start)
            guard hypot(location.x - startView.x, location.y - startView.y) >= 4, session.document.item(id) != nil else {
                session.cancelLiveChange()
                return
            }
            session.endLiveChange(actionName: Self.addName(for: tool))
            session.select([id])
        case .drawing:
            session.endLiveChange(actionName: String(localized: "Draw", bundle: .module))
        case .moving:
            session.endLiveChange(actionName: String(localized: "Move", bundle: .module))
        case .reshaping(let handle, _):
            session.endLiveChange(actionName: handle == .bend ? String(localized: "Bend Arrow", bundle: .module) : String(localized: "Resize", bundle: .module))
        case .cropping:
            cropLayer.showsThirds = false
            if let cropRect, cropRect.width < 8 || cropRect.height < 8 {
                // A click without a drag: keep the crop as it was.
                self.cropRect = session.document.canvas
                cropLayer.frameRect = viewRect(session.document.canvas)
            }
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = documentPoint(convert(event.locationInWindow, from: nil))
        if let item = hitItem(at: point), !session.selection.contains(item.id) {
            session.select([item.id])
        }
        super.rightMouseDown(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard !session.selection.isEmpty else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ symbol: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
        }
        add(String(localized: "Duplicate", bundle: .module), #selector(duplicateSelection(_:)), "plus.square.on.square")
        add(String(localized: "Bring to Front", bundle: .module), #selector(bringToFront(_:)), "square.3.layers.3d.top.filled")
        add(String(localized: "Send to Back", bundle: .module), #selector(sendToBack(_:)), "square.3.layers.3d.bottom.filled")
        menu.addItem(.separator())
        add(String(localized: "Delete", bundle: .module), #selector(delete(_:)), "trash")
        return menu
    }

    private static func addName(for tool: AnnotationTool) -> String {
        switch tool {
        case .arrow: String(localized: "Add Arrow", bundle: .module)
        case .line: String(localized: "Add Line", bundle: .module)
        case .rectangle: String(localized: "Add Rectangle", bundle: .module)
        case .ellipse: String(localized: "Add Ellipse", bundle: .module)
        case .redact: String(localized: "Add Redaction", bundle: .module)
        case .spotlight: String(localized: "Add Spotlight", bundle: .module)
        default: String(localized: "Add Mark", bundle: .module)
        }
    }

    // MARK: Cursor

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    public override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at location: CGPoint) {
        guard drag == nil else { return }
        if editing?.view.frame.contains(location) == true { return }
        let cursor: NSCursor
        if session.tool == .crop {
            if let handle = cropHandle(at: location) {
                cursor = Self.resizeCursor(for: handle)
            } else if let cropRect, viewRect(cropRect).contains(location) {
                cursor = .openHand
            } else {
                cursor = .crosshair
            }
        } else if session.selection.count == 1, let item = session.selectedItems.first, let handle = handle(at: location, of: item) {
            cursor = handle == .bend || handle == .start || handle == .end ? .crosshair : Self.resizeCursor(for: handle)
        } else if hitItem(at: documentPoint(location)) != nil {
            cursor = .openHand
        } else {
            cursor = switch session.tool {
            case .select: .arrow
            case .text: .iBeam
            default: .crosshair
            }
        }
        cursor.set()
    }

    private static func resizeCursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .topLeft: NSCursor.frameResize(position: .topLeft, directions: .all)
        case .top: NSCursor.frameResize(position: .top, directions: .all)
        case .topRight: NSCursor.frameResize(position: .topRight, directions: .all)
        case .right: NSCursor.frameResize(position: .right, directions: .all)
        case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .bottom: NSCursor.frameResize(position: .bottom, directions: .all)
        case .bottomLeft: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        case .left: NSCursor.frameResize(position: .left, directions: .all)
        case .start, .end, .bend: .crosshair
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        if !handleKey(event) {
            super.keyDown(with: event)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117:
            session.deleteSelection()
            return true
        case 123:
            session.nudgeSelection(by: CGSize(width: -step, height: 0))
            return true
        case 124:
            session.nudgeSelection(by: CGSize(width: step, height: 0))
            return true
        case 125:
            session.nudgeSelection(by: CGSize(width: 0, height: step))
            return true
        case 126:
            session.nudgeSelection(by: CGSize(width: 0, height: -step))
            return true
        case 53:
            if session.isInLiveChange {
                drag = nil
                session.cancelLiveChange()
            } else if session.tool == .crop {
                cropRect = session.document.canvas
                cropLayer.frameRect = viewRect(session.document.canvas)
            } else if !session.selection.isEmpty {
                session.select([])
            } else {
                return false
            }
            return true
        case 36, 76:
            if session.tool == .crop {
                commitCrop()
                return true
            }
            if session.selection.count == 1, let item = session.selectedItems.first, case .text = item.shape {
                beginEditing(item.id, isNew: false)
                return true
            }
            return false
        default:
            guard
                flags.subtracting([.shift, .capsLock]).isEmpty,
                let character = event.charactersIgnoringModifiers?.lowercased().first,
                let tool = AnnotationTool.allCases.first(where: { $0.key == character })
            else { return false }
            session.tool = tool
            return true
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "d" where flags == .command:
            session.duplicateSelection()
        case "=", "+":
            zoomIn()
        case "-":
            zoomOut()
        case "0":
            zoomToFit()
        case "]" where flags == [.command, .shift]:
            session.bringSelectionToFront()
        case "[" where flags == [.command, .shift]:
            session.sendSelectionToBack()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Menu actions

    @objc public func copy(_ sender: Any?) {
        onCopy?()
    }

    @objc public func save(_ sender: Any?) {
        onSave?()
    }

    @objc public override func selectAll(_ sender: Any?) {
        session.selectAll()
    }

    @objc public func delete(_ sender: Any?) {
        session.deleteSelection()
    }

    @objc func duplicateSelection(_ sender: Any?) {
        session.duplicateSelection()
    }

    @objc func bringToFront(_ sender: Any?) {
        session.bringSelectionToFront()
    }

    @objc func sendToBack(_ sender: Any?) {
        session.sendSelectionToBack()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)), #selector(duplicateSelection(_:)), #selector(bringToFront(_:)), #selector(sendToBack(_:)):
            !session.selection.isEmpty
        case #selector(selectAll(_:)):
            !session.document.items.isEmpty
        default:
            true
        }
    }

    // MARK: Text

    func beginEditing(_ id: Annotation.ID, isNew: Bool) {
        guard let item = session.document.item(id), case .text = item.shape else { return }
        if !isNew { session.beginLiveChange() }
        session.select([id])
        let view = MarkTextView(frame: .zero)
        view.delegate = self
        let editing = TextEditing(id: id, isNew: isNew, view: view)
        self.editing = editing
        if case .text(let block) = item.shape {
            view.string = block.string
        }
        styleTextView(for: item)
        addSubview(view)
        markLayers[id]?.isHidden = true
        updateSelectionOutlines()
        window?.makeFirstResponder(view)
        view.selectAll(nil)
    }

    /// Matches the editing field to the mark: same face, size, line height, and color, at the zoom.
    private func styleTextView(for item: Annotation) {
        guard let view = editing?.view, case .text(let block) = item.shape else { return }
        let scale = session.document.scale
        let layout = TextLayout(block.string.isEmpty ? TextBlock(origin: block.origin, string: " ", fontSize: block.fontSize, look: block.look, width: block.width) : block, scale: scale)
        let font = TextLayout.font(pointSize: block.fontSize * scale * zoom)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = layout.lineHeight * zoom
        paragraph.maximumLineHeight = layout.lineHeight * zoom
        let ink: NSColor
        let fill = NSColor(cgColor: item.style.color.cgColor) ?? .systemRed
        switch block.look {
        case .plain, .outlined:
            ink = fill
            view.drawsBackground = false
            view.layer?.backgroundColor = nil
        case .label:
            ink = item.style.color.prefersDarkInk ? NSColor(white: 0, alpha: 0.88) : .white
            view.drawsBackground = false
            view.wantsLayer = true
            view.layer?.backgroundColor = fill.cgColor
            view.layer?.cornerRadius = layout.cornerRadius * zoom
        }
        // The baseline sits where the renderer puts it: TextKit centers the font's box in a line taller
        // than the font, as the layout does.
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
        view.typingAttributes = attributes
        view.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        view.insertionPointColor = ink
        // Selected text keeps its ink. On a label the selection is a wash opposite to the ink (dark under
        // white ink, light under dark ink), so the label's color still shows and the text gains contrast
        // rather than losing it; elsewhere the system selection color at the strength text selection
        // uses here.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let labelWash = item.style.color.prefersDarkInk ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0, alpha: 0.22)
        let wash = block.look == .label ? labelWash : NSColor.selectedTextBackgroundColor.withAlphaComponent(dark ? 0.45 : 0.35)
        view.selectedTextAttributes = [.backgroundColor: wash, .foregroundColor: ink]
        view.textContainerInset = CGSize(width: layout.inset.width * zoom, height: layout.inset.height * zoom)
        view.textContainer?.lineFragmentPadding = 0
        // The field's frame follows the mark's layout (positionTextView), so it never sizes itself.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.minSize = .zero
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        let wrap = block.width.map { ($0 - layout.inset.width * 2) * zoom } ?? .greatestFiniteMagnitude
        view.textContainer?.containerSize = CGSize(width: wrap, height: .greatestFiniteMagnitude)
        positionTextView()
    }

    private func positionTextView() {
        guard let editing, let item = session.document.item(editing.id), case .text(let block) = item.shape else { return }
        let scale = session.document.scale
        let layout = TextLayout(block.string.isEmpty ? TextBlock(origin: block.origin, string: " ", fontSize: block.fontSize, look: block.look, width: block.width) : block, scale: scale)
        let origin = viewPoint(block.origin)
        // A little room after the last character for the caret, outside a label (whose padding has it).
        let caret = block.width == nil && block.look != .label ? max(block.fontSize * scale * zoom * 0.6, 4) : 0
        editing.view.frame = CGRect(x: origin.x, y: origin.y, width: layout.size.width * zoom + caret, height: layout.size.height * zoom)
        onViewportChange?()
    }

    public func textDidChange(_ notification: Notification) {
        guard let editing, let index = session.document.index(of: editing.id), case .text(var block) = session.document.items[index].shape else { return }
        block.string = editing.view.string
        var document = session.document
        document.items[index].shape = .text(block)
        session.updateLive(document)
        positionTextView()
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Escape finishes the text, unless an input method is composing (it takes Escape itself).
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
            endEditing()
            return true
        }
        return false
    }

    public func undoManager(for view: NSTextView) -> UndoManager? {
        editing?.undo
    }

    public func textDidEndEditing(_ notification: Notification) {
        endEditing()
    }

    /// Finishes editing text: an empty text mark goes away, and a new one leaves no undo step.
    func endEditing() {
        guard let editing else { return }
        self.editing = nil
        editing.view.delegate = nil
        editing.view.removeFromSuperview()
        markLayers[editing.id]?.isHidden = false
        let string: String
        if let item = session.document.item(editing.id), case .text(let block) = item.shape {
            string = block.string
        } else {
            string = ""
        }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var document = session.document
            document.items.removeAll { $0.id == editing.id }
            session.updateLive(document, selecting: [])
            if editing.isNew {
                session.cancelLiveChange()
            } else {
                session.endLiveChange(actionName: String(localized: "Delete", bundle: .module))
            }
        } else {
            session.endLiveChange(actionName: editing.isNew ? String(localized: "Add Text", bundle: .module) : String(localized: "Edit Text", bundle: .module))
        }
        updateSelectionOutlines()
        if window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(self)
        }
    }

    /// Reflects a style change made while text is being edited.
    func refreshEditingStyle() {
        guard let editing, let item = session.document.item(editing.id) else { return }
        styleTextView(for: item)
    }

    /// Whether the picture's four corners are opaque: false for a window captured with its shadow.
    private static func hasOpaqueCorners(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: break
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: image.width - 1, y: 0), CGPoint(x: 0, y: image.height - 1), CGPoint(x: image.width - 1, y: image.height - 1)]
        return corners.allSatisfy { corner in
            guard let crop = image.cropping(to: CGRect(origin: corner, size: CGSize(width: 1, height: 1))) else { return false }
            return pixel.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return raw[3] == 255
            }
        }
    }

    // MARK: Appearance and accessibility

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Resolved for the appearance, and again when it or the accessibility display options change:
    /// Increase Contrast thickens the picture's edge, the selection, and the crop frame.
    private func applyAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            pictureLayer.borderWidth = contrast ? 1 : 0.5
            pictureLayer.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.16) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.10)
            selectionLayer.accent = NSColor.controlAccentColor.cgColor
        }
        selectionLayer.increasedContrast = contrast
        cropLayer.increasedContrast = contrast
        if let editing, let item = session.document.item(editing.id) {
            styleTextView(for: item)
        }
    }

    private func updateAccessibility() {
        let count = session.document.items.count
        setAccessibilityLabel(String(localized: "Capture, \(count) marks", bundle: .module))
    }
}

/// Hosts the canvas's layers with the view's own y-down coordinates: AppKit keeps a flipped view's
/// layer geometry flipped, where a flag set by hand on a hosted layer can be reset.
final class FlippedHostView: NSView {
    override var isFlipped: Bool { true }
}

/// The field a text mark is edited in: plain text, no automatic substitutions, transparent.
final class MarkTextView: NSTextView {
    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        drawsBackground = false
        focusRingType = .none
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
