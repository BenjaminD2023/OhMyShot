import AppKit
import ImageIO
import OMSCore
import QuartzCore
import UniformTypeIdentifiers

/// The canvas: the capture with its marks, drawn and edited with the pointer and keyboard. It knows
/// nothing of the window around it, so the editor and in-place annotation can both host it.
///
/// Marks are layers drawn by the same renderer as exports; the capture is one layer the GPU scales.
/// Zooming redraws the marks at the new size, so they stay sharp.
public final class AnnotationCanvasView: NSView, NSTextViewDelegate, NSMenuItemValidation, NSViewToolTipOwner {
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
    /// Drawing in place over the capture overlay: the picture at the screen's own size under the frozen
    /// screen's pixels, no zoom, no window chrome, the drawing tools only. Set by `configureInPlace`.
    public private(set) var isInPlace = false
    /// Chooses the pointer for a point in this view ahead of the canvas, for a host whose own controls
    /// reach over it (the in-place selection's edges); nil leaves it to the canvas.
    public var cursorOverride: ((CGPoint) -> NSCursor?)?
    public var onCopy: (() -> Void)?
    /// Return with nothing of its own to do (no crop or background to finish, no text mark to open): the editor copies
    /// and closes, as Return copies and finishes in place. Not called in place, where the toolbar has Return.
    public var onReturn: (() -> Void)?
    public var onSave: (() -> Void)?
    public var onSaveProject: (() -> Void)?
    public var onPrint: (() -> Void)?
    /// Asks for the size to scale the picture to, which the host shows its own way.
    public var onImageSize: (() -> Void)?

    private enum Drag {
        case creating(id: Annotation.ID, tool: AnnotationTool, start: CGPoint)
        case drawing(id: Annotation.ID)
        /// A highlighter drag: its points, and how it lies over the text when it started on some.
        case highlighting(id: Annotation.ID, points: [CGPoint], snapping: TextSnapping?)
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
    private let backdropLayer = BackdropLayer()
    /// The capture as it sits on a background: rounded, with the room its inset adds in its edge color.
    private let cardLayer = StillLayer()
    /// The kept part of the capture, inside the card.
    private let keptLayer = StillLayer()
    /// False for a window captured with its shadow: no box is drawn around it.
    private let captureHasOpaqueCorners: Bool
    /// What the layers were last laid out for.
    private var laidOut: Frames?
    /// The images blurs and pixelations were last made over.
    private var redactionImages: [Annotation] = []
    /// The picture the image layer shows, which a turn, a flip, or a resize replaces.
    private var shownPicture: CGImage?
    private var markLayers: [Annotation.ID: MarkLayer] = [:]
    private let selectionLayer = SelectionLayer()
    private let cropLayer = CropLayer()
    /// The redaction tool's suggestions: dashed accent outlines around text reading found better covered,
    /// each covered by a click. Never part of the picture.
    private let suggestionLayer = CAShapeLayer()
    /// A white line under the dashes, so their gaps are white.
    private let suggestionHalo = CAShapeLayer()
    /// The suggestions as VoiceOver finds them, one button each.
    private var suggestionElements: [(suggestion: RedactionSuggestion, element: SuggestionElement)] = []
    /// While a redaction is drawn by hand, the suggestions step aside.
    private var hidesSuggestions = false

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
        captureHasOpaqueCorners = Self.hasOpaqueCorners(session.base)
        super.init(frame: .zero)
        wantsLayer = true
        host.layer = StillLayer()
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        imageLayer.contents = session.picture
        shownPicture = session.picture
        imageLayer.zPosition = -1
        keptLayer.masksToBounds = true
        keptLayer.addSublayer(imageLayer)
        cardLayer.masksToBounds = true
        cardLayer.addSublayer(keptLayer)
        cardLayer.addSublayer(spotlightLayer)
        cardLayer.zPosition = -2
        backdropLayer.zPosition = -3
        backdropLayer.contentsScale = 1
        backdropLayer.isHidden = true
        canvasLayer.masksToBounds = true
        canvasLayer.addSublayer(backdropLayer)
        canvasLayer.addSublayer(cardLayer)
        pictureLayer.shadowColor = .black
        pictureLayer.shadowOpacity = 0.12
        pictureLayer.shadowRadius = 10
        pictureLayer.shadowOffset = CGSize(width: 0, height: 4)
        pictureLayer.borderWidth = 0.5
        // A window captured with its shadow is transparent around the window: a box shadow or edge
        // around it would draw a rectangle that is not in the picture.
        pictureLayer.isHidden = !captureHasOpaqueCorners
        host.layer?.addSublayer(pictureLayer)
        host.layer?.addSublayer(canvasLayer)
        for layer in [suggestionHalo, suggestionLayer] {
            layer.fillColor = nil
            layer.isHidden = true
            layer.actions = ["path": NSNull(), "hidden": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            host.layer?.addSublayer(layer)
        }
        suggestionLayer.lineDashPattern = [4, 3]
        host.layer?.addSublayer(selectionLayer)
        host.layer?.addSublayer(cropLayer)
        cropLayer.isHidden = true

        session.observe { [weak self] event in self?.sessionChanged(event) }
        syncMarks()
        // An editor that opens with the redaction tool in hand reads the capture for its suggestions now,
        // and one that opens with the highlighter for its lines of text.
        if session.tool == .redact { session.findRedactionsIfNeeded() }
        if session.tool == .highlighter { session.findTextLinesIfNeeded() }
        // Pictures dropped on the canvas are combined into the capture.
        registerForDraggedTypes([.fileURL, .png, .tiff])
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

    /// The capture's lines of text, as far as they are known, in view points: for controls to keep clear
    /// of.
    var textLineFrames: [CGRect] {
        session.textLines.map { viewRect($0.rect) }
    }

    /// What is on screen, in the document's pixels.
    private struct Frames: Equatable {
        /// The part of the document on screen: the canvas; the whole picture with its background; or
        /// while cropping, the whole capture too, so the crop can grow back out.
        var shown: CGRect
        /// The capture's card: the canvas, or on a background the canvas with its inset and balance room.
        var card: CGRect
        /// The kept part of the capture.
        var picture: CGRect
        /// What the spotlight dims.
        var dimmed: CGRect
        /// The card's corners, in pixels.
        var cornerRadius: CGFloat
        var matte: RGBA?
        var backdrop: BackdropLayer.Content?
    }

    private var frames: Frames {
        let document = session.document
        let canvas = document.canvas.standardized
        if session.tool == .crop {
            let shown = document.imageBounds.union(canvas)
            return Frames(shown: shown, card: shown, picture: shown, dimmed: canvas, cornerRadius: 0, matte: nil, backdrop: nil)
        }
        if let backdrop = document.backdrop, let layout = session.backdropLayout {
            let card = layout.isBare ? layout.picture : layout.card
            return Frames(
                shown: layout.output, card: card, picture: layout.picture, dimmed: card, cornerRadius: layout.cornerRadius, matte: layout.matte,
                backdrop: BackdropLayer.Content(fill: backdrop.fill, layout: layout, shadow: backdrop.shadow, scale: document.scale)
            )
        }
        // Canvas reaching past the capture (combined images beside it) is filled as exports fill it.
        let matte = document.canvasReachesPastCapture ? document.canvasMatte(edges: session.edges) : nil
        return Frames(shown: canvas, card: canvas, picture: canvas, dimmed: canvas, cornerRadius: 0, matte: matte, backdrop: nil)
    }

    private var shownCanvas: CGRect { frames.shown }

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

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, window != nil { session.cancelReading() }
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
        for layer in [pictureLayer, canvasLayer, cardLayer, keptLayer, imageLayer, spotlightLayer, selectionLayer, cropLayer] {
            layer.contentsScale = scale
        }
        // The background is soft (gradients, blurs, a shadow): drawn at one pixel per point, its backing
        // store, the size of the whole view, takes a quarter of the memory; exports draw it at full size.
        backdropLayer.contentsScale = 1
        markLayers.values.forEach { $0.contentsScale = scale }
        updateViewport()
    }

    private func updateViewport() {
        let canvas = shownCanvas
        let area = freeArea
        // In place the capture is shown at the size it has on screen, wherever the view's frame is.
        zoom = isInPlace ? 1 / session.document.scale : userZoom ?? fitZoom
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
        let frames = self.frames
        laidOut = frames
        let shown = frames.shown
        /// A document rect in the canvas layer's coordinates.
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - shown.minX) * zoom, y: (rect.minY - shown.minY) * zoom, width: rect.width * zoom, height: rect.height * zoom)
        }
        pictureLayer.frame = canvasFrame
        pictureLayer.shadowPath = CGPath(rect: pictureLayer.bounds, transform: nil)
        // On a clear background only the capture's own shadow marks the picture's edge.
        pictureLayer.isHidden = isInPlace || (frames.backdrop.map { $0.fill == .clear } ?? !captureHasOpaqueCorners)
        canvasLayer.frame = canvasFrame
        // Drawn layers cover only what is on screen: zoomed in on a large capture, a layer the size of a
        // whole mark would need a backing store of hundreds of megabytes.
        let visible = visibleCanvasRect

        if let content = frames.backdrop {
            let part = canvasLayer.bounds.intersection(visible)
            backdropLayer.isHidden = part.isNull
            backdropLayer.frame = part.isNull ? .zero : part
            backdropLayer.mapping = LayerMapping(
                origin: CGPoint(x: shown.minX + (part.isNull ? 0 : part.minX) / zoom, y: shown.minY + (part.isNull ? 0 : part.minY) / zoom),
                zoom: zoom
            )
            backdropLayer.blur = content.fill == .blur ? session.blurredCapture : nil
            backdropLayer.content = content
        } else {
            backdropLayer.isHidden = true
            backdropLayer.content = nil
            backdropLayer.blur = nil
        }

        let card = local(frames.card)
        cardLayer.frame = card
        cardLayer.cornerRadius = frames.cornerRadius * zoom
        cardLayer.backgroundColor = frames.matte.map { $0.cgColor(in: baseColorSpace) }
        keptLayer.frame = local(frames.picture).offsetBy(dx: -card.minX, dy: -card.minY)
        imageLayer.frame = CGRect(
            x: (session.document.imageBounds.minX - frames.picture.minX) * zoom, y: (session.document.imageBounds.minY - frames.picture.minY) * zoom,
            width: session.document.imageBounds.width * zoom, height: session.document.imageBounds.height * zoom
        )
        // Pixels show as pixels once each covers two or more device pixels; smaller, they blend.
        let devicePerPixel = zoom * (window?.backingScaleFactor ?? 2)
        imageLayer.magnificationFilter = devicePerPixel >= 2 ? .nearest : .linear
        imageLayer.minificationFilter = .trilinear
        let spot = cardLayer.bounds.intersection(visible.offsetBy(dx: -card.minX, dy: -card.minY))
        spotlightLayer.frame = spot.isNull ? .zero : spot
        spotlightLayer.canvas = frames.dimmed
        spotlightLayer.mapping = LayerMapping(
            origin: CGPoint(x: frames.card.minX + (spot.isNull ? 0 : spot.minX) / zoom, y: frames.card.minY + (spot.isNull ? 0 : spot.minY) / zoom),
            zoom: zoom
        )
        for layer in markLayers.values {
            position(layer, frames: frames)
        }
        selectionLayer.frame = host.bounds
        cropLayer.frame = host.bounds
        cropLayer.pictureRect = canvasFrame
        if let cropRect { cropLayer.frameRect = viewRect(cropRect) }
        updateSelectionOutlines()
        CATransaction.commit()
        updateSuggestions()
        onViewportChange?()
    }

    // MARK: Redaction suggestions

    /// Outlines the open suggestions while the redaction tool is in hand and nothing is being drawn, with
    /// each one's kind as its tooltip.
    /// - Parameter fadingIn: the outlines arrive with a short fade (a reading that just finished), or at once
    ///   with Reduce Motion.
    private func updateSuggestions(fadingIn: Bool = false) {
        let open = session.tool == .redact && !hidesSuggestions ? session.openRedactionSuggestions : []
        let path = CGMutablePath()
        for suggestion in open {
            path.addRoundedRect(in: viewRect(session.coveringRect(of: suggestion)), cornerWidth: 3, cornerHeight: 3)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [suggestionHalo, suggestionLayer] {
            layer.frame = host.bounds
            layer.path = path
            layer.isHidden = open.isEmpty
            if fadingIn, !open.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = 0.12
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "fade")
            }
        }
        CATransaction.commit()
        removeAllToolTips()
        for suggestion in open {
            addToolTip(viewRect(session.coveringRect(of: suggestion)), owner: self, userData: nil)
        }
        updateSuggestionElements(open)
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let suggestion = session.redactionSuggestion(at: documentPoint(point)) else { return "" }
        return suggestion.label + "\n" + String(localized: "Click to redact", bundle: .module)
    }

    /// One button per open suggestion for VoiceOver, kept while the suggestions stay the same so its focus
    /// holds, and moved with the picture.
    private func updateSuggestionElements(_ open: [RedactionSuggestion]) {
        if suggestionElements.map(\.suggestion) != open {
            suggestionElements = open.map { suggestion in
                let element = SuggestionElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(String(localized: "\(suggestion.label), suggested redaction", bundle: .module))
                element.setAccessibilityParent(self)
                element.press = { [weak self] in self?.session.acceptRedactionSuggestion(suggestion) ?? false }
                return (suggestion, element)
            }
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        for (suggestion, element) in suggestionElements {
            element.setAccessibilityFrameInParentSpace(viewRect(session.coveringRect(of: suggestion)))
        }
    }

    public override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        return suggestionElements.isEmpty ? children : children + suggestionElements.map(\.element)
    }

    private var baseColorSpace: CGColorSpace {
        session.base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// The part of the canvas layer on screen, with a margin so small pans need no redraw at the edges,
    /// in the canvas layer's coordinates.
    private var visibleCanvasRect: CGRect {
        let margin: CGFloat = 64
        return bounds.insetBy(dx: -margin, dy: -margin).offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY)
    }

    /// Places a mark's layer over the part of the mark on screen. Images lie in the kept part of the
    /// capture, under the spotlight; other marks over everything.
    private func position(_ layer: MarkLayer, frames: Frames) {
        // The document point at the parent layer's corner.
        let parent = layer.superlayer === keptLayer ? frames.picture.origin : frames.shown.origin
        let bounds = layer.mark.drawingBounds(scale: session.document.scale)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            layer.frame = .zero
            return
        }
        let whole = CGRect(x: (bounds.minX - parent.x) * zoom, y: (bounds.minY - parent.y) * zoom, width: bounds.width * zoom, height: bounds.height * zoom)
        let visible = visibleCanvasRect.offsetBy(dx: -(parent.x - frames.shown.minX) * zoom, dy: -(parent.y - frames.shown.minY) * zoom)
        let shown = whole.intersection(visible)
        guard !shown.isNull, shown.width > 0, shown.height > 0 else {
            layer.frame = .zero
            return
        }
        layer.frame = shown
        // The document point at the layer's corner, so it draws just its visible part.
        layer.mapping = LayerMapping(origin: CGPoint(x: parent.x + shown.minX / zoom, y: parent.y + shown.minY / zoom), zoom: zoom)
    }

    #if DEBUG
    /// Where a capture point is in the window, for synthesized events.
    func windowPoint(forDocument point: CGPoint) -> CGPoint {
        convert(viewPoint(point), to: nil)
    }

    /// Shows the drop target as a drag over the canvas does.
    func debugShowDropTarget(_ shown: Bool) {
        selectionLayer.dropFrame = shown ? canvasFrame : nil
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

    /// Draws in place over the capture overlay from now on: the view's frame is the selection, the
    /// picture shows at the screen's own size, nothing zooms, no window chrome is drawn, pictures are
    /// not combined in, and only the drawing tools (and Select) answer their keys.
    public func configureInPlace() {
        isInPlace = true
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        unregisterDraggedTypes()
        // The frozen screen under the canvas is the capture already: drawing it again would only hold a
        // second copy of a whole display's pixels.
        imageLayer.isHidden = true
        needsLayout = true
    }

    /// The tools in-place annotation offers: every drawing tool and Select, never the picture modes
    /// (cropping is the selection itself there, and a background would grow past it).
    public static let inPlaceTools: [AnnotationTool] = AnnotationTool.allCases.filter { !$0.isPictureMode }

    /// The mark under a point in this view, if any.
    public func mark(at viewPoint: CGPoint) -> Annotation.ID? {
        hitItem(at: documentPoint(viewPoint))?.id
    }

    public override func magnify(with event: NSEvent) {
        guard !isInPlace else { return }
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    public override func smartMagnify(with event: NSEvent) {
        guard !isInPlace else { return }
        if isFitted {
            setZoom(1 / session.document.scale, around: convert(event.locationInWindow, from: nil))
        } else {
            zoomToFit()
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard !isInPlace else { return }
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
            let picture = showCurrentPicture()
            syncMarks()
            if picture {
                // Blurs and highlights read the picture, which is another now.
                for layer in markLayers.values {
                    updateRedaction(layer)
                    updateGround(layer)
                }
                if session.tool == .crop {
                    cropRect = session.document.canvas
                    cropLayer.frameRect = viewRect(session.document.canvas)
                }
            }
            if frames != laidOut || picture {
                // What is shown changed (a crop, a background): laid out again at the zoom the person
                // chose, so a slider never makes a zoomed-in picture jump; a fitted picture fits again.
                updateViewport()
            } else {
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
        case .history:
            // A drag that moved an image has ended: blurs show what is now under them.
            refreshRedactionsIfNeeded()
        case .settings:
            break
        case .suggestions:
            let finished = !session.isFindingRedactions
            updateSuggestions(fadingIn: finished)
            updateAccessibility()
            let count = session.openRedactionSuggestions.count
            if finished, session.tool == .redact {
                // VoiceOver hears the end of the reading even when it found nothing, or failed.
                NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                    .announcement: session.couldNotFindRedactions
                        ? String(localized: "Couldn’t read text", bundle: .module)
                        : count > 0
                        ? String(localized: "\(count) suggestions to redact", bundle: .module)
                        : String(localized: "No suggestions to redact", bundle: .module),
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            }
        case .textLines:
            // A pointer resting on text takes the text cursor once the lines are known.
            if drag == nil, let window {
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if bounds.contains(location) { updateCursor(at: location) }
            }
            if !session.isFindingTextLines, session.tool == .highlighter {
                // VoiceOver hears whether highlights will snap, even when no text was found, or the reading
                // failed.
                let count = session.textLines.count
                NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                    .announcement: session.couldNotFindTextLines
                        ? String(localized: "Couldn’t read text", bundle: .module)
                        : count > 0
                        ? String(localized: "\(count) lines of text to highlight", bundle: .module)
                        : String(localized: "No text to highlight", bundle: .module),
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            }
        }
        // Covered suggestions go, and the tool's own come and go with it.
        if event == .document || event == .tool { updateSuggestions() }
        if event == .tool { updateAccessibility() }
    }

    /// Shows the picture the session has now, fitted to the view, when a turn, a flip, or a resize (or its
    /// undo) replaced it; true when it did.
    private func showCurrentPicture() -> Bool {
        let picture = session.picture
        guard picture !== shownPicture else { return false }
        shownPicture = picture
        imageLayer.contents = picture
        userZoom = nil
        focus = nil
        return true
    }

    private func syncMarks() {
        let document = session.document
        let scale = window?.backingScaleFactor ?? 2
        let frames = self.frames
        var present = Set<Annotation.ID>()
        for (index, item) in document.items.enumerated() {
            if case .spotlight = item.shape { continue }
            present.insert(item.id)
            let layer: MarkLayer
            if let existing = markLayers[item.id] {
                layer = existing
                if layer.scale != document.scale {
                    // Resizing the picture scales what point sizes come to in pixels.
                    layer.scale = document.scale
                    layer.setNeedsDisplay()
                }
                if layer.mark != item {
                    let reshaped = layer.mark.shape != item.shape
                    layer.mark = item
                    if reshaped {
                        updateRedaction(layer)
                        updateGround(layer)
                    }
                }
            } else {
                layer = MarkLayer(mark: item)
                layer.scale = document.scale
                layer.contentsScale = scale
                markLayers[item.id] = layer
                // Images are part of the picture: in the kept part of the capture, under the spotlight.
                if case .image = item.shape { keptLayer.addSublayer(layer) } else { canvasLayer.addSublayer(layer) }
                updateRedaction(layer)
                updateGround(layer)
            }
            layer.zPosition = CGFloat(index)
            layer.isHidden = editing?.id == item.id
            position(layer, frames: frames)
        }
        for (id, layer) in markLayers where !present.contains(id) {
            layer.removeFromSuperlayer()
            markLayers[id] = nil
        }
        spotlightLayer.spots = document.spots
        refreshRedactionsIfNeeded()
    }

    private func updateRedaction(_ layer: MarkLayer) {
        guard case .redaction(let redaction) = layer.mark.shape, redaction.method != .solid else {
            layer.redacted = nil
            return
        }
        let source = session.redactionSource
        layer.redacted = Redactor.image(
            for: redaction, id: layer.mark.id, base: source?.image ?? session.picture, origin: source?.origin ?? .zero, scale: session.document.scale
        )
    }

    /// What a highlight lies on, read from the picture blurs show, images included.
    private func updateGround(_ layer: MarkLayer) {
        guard layer.mark.multiplies else { return }
        let source = session.redactionSource
        layer.ground = HighlightGround.under(layer.mark, in: source?.image ?? session.picture, origin: source?.origin ?? .zero, scale: session.document.scale)
    }

    /// Makes blurs and pixelations again over images that moved, once a drag has ended, and reads again
    /// what highlights lie on: remaking them at every step of a drag would be slow, and they show the
    /// result on release.
    private func refreshRedactionsIfNeeded() {
        let images = session.document.items.filter { if case .image = $0.shape { true } else { false } }
        guard images != redactionImages, !session.isInLiveChange else { return }
        redactionImages = images
        for layer in markLayers.values {
            if case .redaction = layer.mark.shape { updateRedaction(layer) }
            updateGround(layer)
        }
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
            // Each crop starts free: the frame is the whole canvas, which a ratio may not fit.
            session.setCropRatio(.free)
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

    /// The crop frame with `handle` dragged to `point`: held to the chosen ratio, whatever the keys; with
    /// none chosen, Shift keeps the shape the frame had (a square when it was only a point).
    private func croppedRect(_ original: CGRect, dragging handle: Handle, to point: CGPoint, keepingShape shift: Bool) -> CGRect {
        if let ratio = session.cropRatio.value(forPicture: session.document.imageBounds.size) {
            return CropRatio.resized(original, dragging: handle, to: point, ratio: ratio)
        }
        guard shift else { return Geometry.resized(original, dragging: handle, to: point, keepingAspect: false) }
        let shape = original.width > 0 && original.height > 0 ? original.width / original.height : 1
        return CropRatio.resized(original, dragging: handle, to: point, ratio: shape)
    }

    /// Chooses the shape the crop frame keeps; a fixed one fits the frame to it at once, the largest the
    /// picture and the canvas have room for, centered. Not the frame as it is: ratios can be tried one
    /// after another, each the largest of its shape.
    public func chooseCropRatio(_ ratio: CropRatio) {
        session.setCropRatio(ratio)
        guard session.tool == .crop, cropRect != nil, let value = ratio.value(forPicture: session.document.imageBounds.size) else { return }
        let fitted = CropRatio.fitted(value, in: session.document.imageBounds.union(session.document.canvas.standardized))
        cropRect = fitted
        cropLayer.frameRect = viewRect(fitted)
    }

    /// Puts the crop frame back to the whole canvas.
    public func resetCrop() {
        guard session.tool == .crop else { return }
        session.setCropRatio(.free)
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

    /// The mark a press at `point` (pixels) takes hold of. With `pressing`, a press that would highlight
    /// text with the highlighter is left to highlight: the edges of highlights already there, which hug
    /// the lines above and below, do not catch it unless they are selected.
    private func hitItem(at point: CGPoint, pressing: Bool = false) -> Annotation? {
        let scale = session.document.scale
        let interiorForAll = session.tool == .select
        let highlighting = pressing && session.tool == .highlighter && TextSnapping.line(at: point, in: session.textLines) != nil
        for item in session.document.items.reversed() {
            let selected = session.selection.contains(item.id)
            if highlighting, item.multiplies, !selected { continue }
            let interior = interiorForAll || selected
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
        // The background's controls set it; the picture itself takes no clicks meanwhile.
        if session.tool == .background { return }
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

        if let item = hitItem(at: point, pressing: true) {
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
        case .select, .crop, .background:
            break
        case .arrow, .line, .rectangle, .ellipse, .highlightBox, .redact, .spotlight:
            session.beginLiveChange()
            drag = .creating(id: UUID(), tool: tool, start: point)
        case .pen:
            session.beginLiveChange()
            let item = Annotation(shape: .pen(Stroke(points: [point])), style: settings.style)
            var document = session.document
            document.items.append(item)
            session.updateLive(document)
            drag = .drawing(id: item.id)
        case .highlighter:
            session.beginLiveChange()
            // Started on text, it snaps to the text; a click there highlights the word.
            let snapping = TextSnapping(at: point, lines: session.textLines)
            let shape = Self.highlight(along: [point], snapping: snapping, freely: event.modifierFlags.contains(.command))
            let item = Annotation(shape: shape, style: settings.style)
            var document = session.document
            document.items.append(item)
            session.updateLive(document)
            drag = .highlighting(id: item.id, points: [point], snapping: snapping)
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
            let numbering = settings.numbering
            let item = Annotation(shape: .counter(Counter(center: point, value: session.document.nextCounterValue(for: numbering), numbering: numbering)), style: settings.style)
            var document = session.document
            document.items.append(item)
            // Not selected: counters go down one click after another, and the capsule stays with the
            // tool, so a change of numbering applies to the next counters rather than the last one.
            session.commit(document, selecting: [], actionName: String(localized: "Add Counter", bundle: .module))
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if case .highlighting = drag {
            continueHighlighting(with: event)
            return
        }
        guard let drag else { return }
        let location = convert(event.locationInWindow, from: nil)
        let point = documentPoint(location)
        let shift = event.modifierFlags.contains(.shift)
        var document = session.document
        switch drag {
        case .creating(let id, let tool, let start):
            if tool == .redact, !hidesSuggestions, hypot(location.x - viewPoint(start).x, location.y - viewPoint(start).y) >= 4 {
                hidesSuggestions = true
                updateSuggestions()
            }
            guard let mark = tool.mark(from: start, to: point, constrained: shift, settings: session.settings(for: tool), id: id) else { return }
            if let index = document.index(of: id) { document.items[index] = mark } else { document.items.append(mark) }
            session.updateLive(document, selecting: [])
        case .drawing(let id):
            guard let index = document.index(of: id) else { return }
            guard case .pen(var stroke) = document.items[index].shape,
                  let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) * zoom >= 1.5 else { return }
            stroke.points.append(point)
            document.items[index].shape = .pen(stroke)
            session.updateLive(document)
        case .highlighting:
            // Followed by continueHighlighting.
            break
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
                rect = croppedRect(original, dragging: handle, to: point, keepingShape: shift)
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
            hidesSuggestions = false
            updateSuggestions()
            updateCursor(at: location)
            // Controls hidden during the drag come back where the marks now are.
            onViewportChange?()
        }
        switch drag {
        case .creating(let id, let tool, let start):
            let startView = viewPoint(start)
            guard hypot(location.x - startView.x, location.y - startView.y) >= 4, session.document.item(id) != nil else {
                session.cancelLiveChange()
                // A click with the redaction tool on a suggestion covers it.
                if tool == .redact { session.acceptRedactionSuggestion(at: start) }
                return
            }
            session.endLiveChange(actionName: Self.addName(for: tool))
            session.select([id])
        case .drawing:
            session.endLiveChange(actionName: String(localized: "Draw", bundle: .module))
        case .highlighting(let id, _, _):
            guard let index = session.document.index(of: id), case .textHighlight(let highlight) = session.document.items[index].shape else {
                session.endLiveChange(actionName: String(localized: "Draw", bundle: .module))
                return
            }
            session.updateLive(Self.joiningHighlights(of: session.document, to: id, highlight))
            session.endLiveChange(actionName: String(localized: "Highlight", bundle: .module))
        case .moving(_, let originals):
            // An image moved past the canvas's edge takes the canvas with it.
            if originals.contains(where: { if case .image = $0.shape { true } else { false } }) { session.growCanvasToHoldImages() }
            session.endLiveChange(actionName: String(localized: "Move", bundle: .module))
        case .reshaping(let handle, let original):
            if case .image = original.shape { session.growCanvasToHoldImages() }
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

    /// Follows a highlighter drag to the pointer: its points grow in place, and the mark is drawn again.
    private func continueHighlighting(with event: NSEvent) {
        guard case .highlighting(let id, var points, var snapping) = drag, let index = session.document.index(of: id) else { return }
        let point = documentPoint(convert(event.locationInWindow, from: nil))
        guard let last = points.last, hypot(point.x - last.x, point.y - last.y) * zoom >= 1.5 else { return }
        // Let go of while the points grow, so they are not copied at every step.
        drag = nil
        // Shift keeps a stroke level, as along a line of text, and a snapped one on its first line.
        let next = event.modifierFlags.contains(.shift) ? CGPoint(x: point.x, y: points[0].y) : point
        points.append(next)
        snapping?.extend(to: next)
        drag = .highlighting(id: id, points: points, snapping: snapping)
        var document = session.document
        document.items[index].shape = Self.highlight(along: points, snapping: snapping, freely: event.modifierFlags.contains(.command))
        session.updateLive(document)
    }

    /// `document` with the new highlight `id` joined to the highlights of its color that it meets on a line:
    /// highlighting over a highlight extends it, so a word highlighted twice (a double click) is no darker
    /// and the overlap of two strokes along one line does not show. The joined highlight takes the place
    /// of the uppermost of them, so nothing that lay over another mark drops under it; a highlight that
    /// only covers what is highlighted already changes nothing.
    private static func joiningHighlights(of document: AnnotationDocument, to id: Annotation.ID, _ highlight: TextHighlight) -> AnnotationDocument {
        guard let color = document.item(id)?.style.color else { return document }
        var document = document
        var joined = highlight
        var absorbed: [Int] = []
        var found = true
        while found {
            found = false
            for (index, item) in document.items.enumerated() where item.id != id && item.style.color == color && !absorbed.contains(index) {
                guard case .textHighlight(let other) = item.shape, other.meets(joined) else { continue }
                joined = other.merged(with: joined)
                absorbed.append(index)
                found = true
            }
        }
        guard let keeper = absorbed.max() else { return document }
        document.items[keeper].shape = .textHighlight(joined)
        let removed = Set(absorbed.filter { $0 != keeper }.map { document.items[$0].id } + [id])
        document.items.removeAll { removed.contains($0.id) }
        return document
    }

    /// What a highlighter drag along `points` draws: bands over the text it ran along when it started on
    /// text, a free stroke when it started off text or while ⌘ is held.
    private static func highlight(along points: [CGPoint], snapping: TextSnapping?, freely: Bool) -> Shape {
        if let snapping, !freely { return .textHighlight(TextHighlight(rects: snapping.rects)) }
        return .highlighter(Stroke(points: points))
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let freely = event.modifierFlags.contains(.command)
        if case .highlighting(let id, let points, let snapping) = drag, snapping != nil, let index = session.document.index(of: id) {
            // ⌘ frees the stroke from the text while it is held, mid-drag too.
            var document = session.document
            document.items[index].shape = Self.highlight(along: points, snapping: snapping, freely: freely)
            session.updateLive(document)
        } else if drag == nil, let window {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(location) { updateCursor(at: location) }
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
        guard !session.selection.isEmpty else { return isInPlace ? nil : pictureMenu(at: documentPoint(convert(event.locationInWindow, from: nil))) }
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

    // MARK: Combining

    /// A picture coming in to be combined: its name in the picture store, its size in pixels, and its
    /// pixels per point.
    struct IncomingPicture {
        let name: String
        let pixelSize: CGSize
        let scale: CGFloat
    }

    /// Whether a pasteboard offers pictures, without reading them.
    static func offersPictures(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFileOptions)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private static let imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// The pictures a pasteboard offers, kept in the picture store: image files, or else image data.
    static func incomingPictures(from pasteboard: NSPasteboard) -> [IncomingPicture] {
        var names: [String] = []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: imageFileOptions) as? [URL] ?? []
        for url in urls {
            if let name = try? PictureStore.shared.add(url) { names.append(name) }
        }
        if names.isEmpty, let data = pasteboard.data(forType: .png) {
            if let name = try? PictureStore.shared.add(data, fileExtension: "png") { names.append(name) }
        } else if names.isEmpty, let data = pasteboard.data(forType: .tiff),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            // Kept as PNG: pasteboard TIFF is uncompressed.
            if let name = try? PictureStore.shared.add(image) { names.append(name) }
        }
        return describe(names)
    }

    /// Picture files, kept in the picture store.
    static func incomingPictures(from urls: [URL]) -> [IncomingPicture] {
        describe(urls.compactMap { try? PictureStore.shared.add($0) })
    }

    private static func describe(_ names: [String]) -> [IncomingPicture] {
        names.compactMap { name in
            guard let size = PictureStore.shared.pixelSize(named: name) else { return nil }
            return IncomingPicture(name: name, pixelSize: size, scale: resolution(of: name) ?? 0)
        }
    }

    /// Pixels per point a picture records, or nil when it records none (72 dpi).
    private static func resolution(of name: String) -> CGFloat? {
        guard
            let source = CGImageSourceCreateWithURL(PictureStore.shared.url(named: name) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 72.5
        else { return nil }
        // PNG keeps resolution per meter, so 144 dpi reads back as 143.99: quarter steps.
        return CGFloat((dpi / 72 * 4).rounded() / 4)
    }

    /// Combines pictures into the capture around `point` (pixels). A picture shows at the size it had
    /// on its own screen (one that records no resolution is taken at the capture's), never larger
    /// than the canvas.
    func place(_ pictures: [IncomingPicture], at point: CGPoint) {
        guard !pictures.isEmpty else { return }
        endEditing()
        let document = session.document
        let room = max(document.canvas.width, document.canvas.height)
        let sized = pictures.map { picture -> (name: String, size: CGSize) in
            let scale = picture.scale > 0 ? picture.scale : document.scale
            var size = CGSize(width: picture.pixelSize.width * document.scale / scale, height: picture.pixelSize.height * document.scale / scale)
            let longest = max(size.width, size.height)
            if longest > room, longest > 0 {
                size = CGSize(width: size.width * room / longest, height: size.height * room / longest)
            }
            return (picture.name, size)
        }
        if session.tool.isPictureMode { session.leavePictureMode() }
        session.addImages(sized, at: point)
        window?.makeFirstResponder(self)
    }

    /// Pastes pictures from `pasteboard` into the middle of what is on screen; false when it has none.
    @discardableResult
    func pastePictures(from pasteboard: NSPasteboard) -> Bool {
        let pictures = Self.incomingPictures(from: pasteboard)
        guard !pictures.isEmpty else { return false }
        place(pictures, at: documentPoint(CGPoint(x: freeArea.midX, y: freeArea.midY)))
        return true
    }

    /// ⌘V: pictures on the clipboard are combined into the capture.
    @objc public func paste(_ sender: Any?) {
        // In place the canvas is the selection; a picture combined in would grow it past the screen.
        guard !isInPlace else {
            NSSound.beep()
            return
        }
        if !pastePictures(from: .general) { NSSound.beep() }
    }

    /// Chooses picture files to combine into the capture at `point`.
    @objc func addImageFromPanel(_ sender: NSMenuItem) {
        guard let window else { return }
        let point = (sender.representedObject as? NSValue)?.pointValue ?? documentPoint(CGPoint(x: freeArea.midX, y: freeArea.midY))
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Add", bundle: .module)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            place(Self.incomingPictures(from: panel.urls), at: point)
        }
    }

    /// The menu for the empty canvas: combine a picture into the capture.
    private func pictureMenu(at point: CGPoint) -> NSMenu? {
        let menu = NSMenu()
        if Self.offersPictures(.general) {
            let paste = NSMenuItem(title: String(localized: "Paste", bundle: .module), action: #selector(paste(_:)), keyEquivalent: "")
            paste.target = self
            paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            menu.addItem(paste)
        }
        let add = NSMenuItem(title: String(localized: "Add Image…", bundle: .module), action: #selector(addImageFromPanel(_:)), keyEquivalent: "")
        add.target = self
        add.representedObject = NSValue(point: point)
        add.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)
        menu.addItem(add)
        return menu
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // The editor's own capture, dragged out from its toolbar, is not combined into itself.
        guard !(sender.draggingSource is DragOutView), Self.offersPictures(sender.draggingPasteboard) else { return [] }
        selectionLayer.dropFrame = canvasFrame
        return .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        selectionLayer.dropFrame == nil ? [] : .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        selectionLayer.dropFrame = nil
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        selectionLayer.dropFrame = nil
        let pictures = Self.incomingPictures(from: sender.draggingPasteboard)
        guard !pictures.isEmpty else { return false }
        place(pictures, at: documentPoint(convert(sender.draggingLocation, from: nil)))
        return true
    }

    public override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        selectionLayer.dropFrame = nil
    }

    private static func addName(for tool: AnnotationTool) -> String {
        switch tool {
        case .arrow: String(localized: "Add Arrow", bundle: .module)
        case .line: String(localized: "Add Line", bundle: .module)
        case .rectangle: String(localized: "Add Rectangle", bundle: .module)
        case .ellipse: String(localized: "Add Ellipse", bundle: .module)
        case .highlightBox: String(localized: "Add Highlight Box", bundle: .module)
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
        if let override = cursorOverride?(location) {
            override.set()
            return
        }
        let cursor: NSCursor
        if session.tool == .background {
            cursor = .arrow
        } else if session.tool == .crop {
            if let handle = cropHandle(at: location) {
                cursor = Self.resizeCursor(for: handle)
            } else if let cropRect, viewRect(cropRect).contains(location) {
                cursor = .openHand
            } else {
                cursor = .crosshair
            }
        } else if session.selection.count == 1, let item = session.selectedItems.first, let handle = handle(at: location, of: item) {
            cursor = handle == .bend || handle == .start || handle == .end ? .crosshair : Self.resizeCursor(for: handle)
        } else if hitItem(at: documentPoint(location), pressing: true) != nil {
            cursor = .openHand
        } else if session.tool == .redact, session.redactionSuggestion(at: documentPoint(location)) != nil {
            cursor = .pointingHand
        } else {
            cursor = switch session.tool {
            case .select: .arrow
            case .text: .iBeam
            // Over text the highlighter snaps to it, which the text cursor says, until ⌘ frees it.
            case .highlighter where !NSEvent.modifierFlags.contains(.command) && TextSnapping.line(at: documentPoint(location), in: session.textLines) != nil:
                .iBeam
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
                session.setCropRatio(.free)
                cropRect = session.document.canvas
                cropLayer.frameRect = viewRect(session.document.canvas)
            } else if session.tool == .background {
                session.leavePictureMode()
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
            if session.tool == .background {
                session.leavePictureMode()
                return true
            }
            if session.selection.count == 1, let item = session.selectedItems.first, case .text = item.shape {
                beginEditing(item.id, isNew: false)
                return true
            }
            // A drag under way ends first; typing in a text mark never comes here (its field has the keys).
            if let onReturn, !isInPlace, !session.isInLiveChange, editing == nil {
                onReturn()
                return true
            }
            return false
        default:
            guard
                flags.subtracting([.shift, .capsLock]).isEmpty,
                let character = event.charactersIgnoringModifiers?.lowercased().first,
                let tool = AnnotationTool.allCases.first(where: { $0.key == character }),
                !isInPlace || !tool.isPictureMode
            else { return false }
            session.tool = tool
            return true
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        // In place nothing zooms: ⌘+, ⌘−, and ⌘0 pass on.
        if isInPlace, ["=", "+", "-", "0"].contains(event.charactersIgnoringModifiers ?? "") { return super.performKeyEquivalent(with: event) }
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

    /// ⌘Z. Answered here, ahead of the window: the window's own undo manager belongs to the SwiftUI
    /// hosting it, not to the marks. While text is typed, Undo undoes typing.
    @objc public func undo(_ sender: Any?) {
        if let editing {
            if editing.undo.canUndo { editing.undo.undo() }
        } else {
            session.undo()
        }
    }

    /// ⇧⌘Z.
    @objc public func redo(_ sender: Any?) {
        if let editing {
            if editing.undo.canRedo { editing.undo.redo() }
        } else {
            session.redo()
        }
    }

    /// The undo manager Undo and Redo use now: the typing's while text is edited, else the marks'.
    var activeUndoManager: UndoManager {
        editing?.undo ?? session.undoManager
    }

    @objc public func copy(_ sender: Any?) {
        onCopy?()
    }

    @objc public func save(_ sender: Any?) {
        onSave?()
    }

    /// ⇧⌘S: a copy of the capture and its marks as a project, to open again with every mark editable.
    @objc public func saveProject(_ sender: Any?) {
        onSaveProject?()
    }

    /// ⌘P: the capture as it looks now, marks and background and all.
    @objc public func printCapture(_ sender: Any?) {
        onPrint?()
    }

    /// Turns the whole picture, its marks with it.
    @objc public func rotateLeft(_ sender: Any?) { transformPicture(.rotateLeft) }
    @objc public func rotateRight(_ sender: Any?) { transformPicture(.rotateRight) }
    @objc public func flipHorizontal(_ sender: Any?) { transformPicture(.flipHorizontally) }
    @objc public func flipVertical(_ sender: Any?) { transformPicture(.flipVertically) }

    /// Image Size…
    @objc public func showImageSize(_ sender: Any?) {
        guard canTransformPicture else { return }
        endEditing()
        onImageSize?()
    }

    /// The document as the Image Size sheet measures it: with the canvas a crop being chosen would make,
    /// which resizing makes first. The crop itself waits for Resize, so Cancel leaves it as it was.
    var documentForImageSize: AnnotationDocument {
        var document = session.document
        if let rect = pendingCrop { document.canvas = rect }
        return document
    }

    /// The crop frame as `applyCrop` would keep it; nil without one, or too small to crop to.
    var pendingCrop: CGRect? {
        guard let cropRect else { return nil }
        let rect = cropRect.standardized.integral
        return rect.width >= 4 && rect.height >= 4 ? rect : nil
    }

    /// Lock Canvas: the canvas stops growing to hold pictures combined past its edges.
    @objc public func toggleCanvasLock(_ sender: Any?) {
        guard !isInPlace else { return }
        session.locksCanvas.toggle()
    }

    /// Whether the picture can be turned or resized: not in place, where the canvas is the selection, and
    /// not while something is being dragged.
    private var canTransformPicture: Bool { !isInPlace && drag == nil }

    private func transformPicture(_ operation: PictureOperation) {
        guard canTransformPicture else {
            NSSound.beep()
            return
        }
        endEditing()
        endingPictureMode { apply(operation) }
    }

    /// Scales the picture, its marks with it, so the canvas is `size` pixels.
    public func resizePicture(to size: CGSize) {
        guard canTransformPicture else { return }
        endingPictureMode { apply(.resize(to: size)) }
    }

    /// Runs `change` once a crop or the background in hand is ended, the crop made first so the change
    /// takes the picture as it will be kept. A crop to make and the change are one undo step, whatever the
    /// undo manager groups by itself; a group is opened only for a crop, as an empty one still counts as a
    /// step to undo.
    private func endingPictureMode(then change: () -> Void) {
        guard session.tool.isPictureMode else {
            change()
            return
        }
        let undoManager = session.undoManager
        let makesCrop = pendingCrop.map { $0 != session.document.canvas } ?? false
        if makesCrop { undoManager.beginUndoGrouping() }
        session.leavePictureMode()
        change()
        if makesCrop { undoManager.endUndoGrouping() }
    }

    /// Applies `operation` and tells VoiceOver what was done: the name of the step, and for a resize the
    /// size it came to.
    private func apply(_ operation: PictureOperation) {
        let before = session.document
        session.apply(operation)
        guard session.document != before else { return }
        var announcement = session.undoManager.undoActionName
        if case .resize = operation {
            let canvas = session.document.canvas.standardized
            announcement = String(localized: "Resized to \(Int(canvas.width)) by \(Int(canvas.height)) pixels", bundle: .module)
        }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
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
        case #selector(undo(_:)):
            menuItem.title = activeUndoManager.undoMenuItemTitle
            return activeUndoManager.canUndo
        case #selector(redo(_:)):
            menuItem.title = activeUndoManager.redoMenuItemTitle
            return activeUndoManager.canRedo
        case #selector(delete(_:)), #selector(duplicateSelection(_:)), #selector(bringToFront(_:)), #selector(sendToBack(_:)):
            return !session.selection.isEmpty
        case #selector(selectAll(_:)):
            return !session.document.items.isEmpty
        case #selector(paste(_:)):
            return !isInPlace && Self.offersPictures(.general)
        case #selector(printCapture(_:)):
            return onPrint != nil
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(flipHorizontal(_:)), #selector(flipVertical(_:)):
            return canTransformPicture
        case #selector(showImageSize(_:)):
            return canTransformPicture && onImageSize != nil
        case #selector(toggleCanvasLock(_:)):
            menuItem.state = session.locksCanvas ? .on : .off
            return !isInPlace
        default:
            return true
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
            // No fill: the accent is never a fill behind text, and this is the text being judged.
            suggestionLayer.strokeColor = NSColor.controlAccentColor.cgColor
            suggestionLayer.lineWidth = contrast ? 2 : 1.5
            // As wide as the dashes, so their gaps are white: the outline holds on any content, blue link
            // text and dark pages included, without reaching onto the text it surrounds.
            suggestionHalo.strokeColor = CGColor(gray: 1, alpha: contrast ? 1 : 0.85)
            suggestionHalo.lineWidth = contrast ? 2 : 1.5
            // Quiet in either appearance, a little firmer with Increase Contrast.
            backdropLayer.checker = dark
                ? (CGColor(gray: 0.20, alpha: 1), CGColor(gray: contrast ? 0.30 : 0.25, alpha: 1))
                : (CGColor(gray: 1, alpha: 1), CGColor(gray: contrast ? 0.84 : 0.91, alpha: 1))
        }
        selectionLayer.increasedContrast = contrast
        cropLayer.increasedContrast = contrast
        if let editing, let item = session.document.item(editing.id) {
            styleTextView(for: item)
        }
    }

    private func updateAccessibility() {
        let count = session.document.items.count
        let suggestions = session.tool == .redact ? session.openRedactionSuggestions.count : 0
        setAccessibilityLabel(suggestions > 0
            ? String(localized: "Capture, \(count) marks, \(suggestions) suggestions to redact", bundle: .module)
            : String(localized: "Capture, \(count) marks", bundle: .module))
    }
}

/// A redaction suggestion as VoiceOver finds it: a button that covers the text.
nonisolated final class SuggestionElement: NSAccessibilityElement {
    /// Set and called on the main thread, where accessibility actions arrive.
    nonisolated(unsafe) var press: (@MainActor () -> Bool)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        return MainActor.assumeIsolated { press() }
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
