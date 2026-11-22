import AppKit
import OMSCore
import OMSDesign
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
    /// In place: a right-click on the canvas away from every mark, for the host to back out a step.
    public var onRightClickAway: (() -> Void)?

    /// A counter whose number the wheel is stepping: what is left of the travel toward the next step, the document
    /// as the last step left it (any other change since starts a new undo step), and the moment a mouse wheel's
    /// gesture ends without phases.
    private struct CounterWheel {
        let id: Annotation.ID
        var residue: CGFloat = 0
        var stepped: AnnotationDocument?
        var idle: DispatchWorkItem?
    }

    private var counterWheel: CounterWheel?
    /// Whether the momentum now arriving follows a gesture that stepped a counter.
    private var counterWheelCoasts = false
    /// Trackpad travel, in points, for one step of a counter's number.
    static let counterWheelStep: CGFloat = 12
    /// Chooses the pointer for a point in this view ahead of the canvas, for a host whose own controls
    /// reach over it (the in-place selection's edges); nil leaves it to the canvas.
    public var cursorOverride: ((CGPoint) -> NSCursor?)?
    public var onCopy: (() -> Void)?
    /// Return with nothing of its own to do (no crop or background to finish, no text mark to open): the editor copies
    /// and closes, as Return copies and finishes in place. Not called in place, where the toolbar has Return.
    public var onReturn: (() -> Void)?
    public var onSave: (() -> Void)?
    public var onSaveProject: (() -> Void)?
    public var onSaveAs: (() -> Void)?
    public var onPrint: (() -> Void)?
    /// Asks for the size to scale the picture to, which the host shows its own way.
    public var onImageSize: (() -> Void)?
    private enum Drag {
        /// A shape dragged out from `start`; `beyondClick` once the pointer has gone 4 points or more from
        /// it, so it draws rather than clicks.
        case creating(id: Annotation.ID, tool: AnnotationTool, start: CGPoint, beyondClick: Bool)
        case drawing(id: Annotation.ID)
        /// A highlighter drag: its points, and how it lies over the text when it started on some.
        case highlighting(id: Annotation.ID, points: [CGPoint], snapping: TextSnapping?)
        case moving(start: CGPoint, originals: [Annotation])
        case reshaping(handle: Handle, original: Annotation)
        /// A mark turned by its knob: as it was, what it turns about, and the pointer's angle from there at the start.
        case rotating(original: Annotation, pivot: CGPoint, start: CGFloat)
        /// Several marks resized together by a corner of the box around them, as it was when the drag began.
        case scaling(handle: Handle, originals: [Annotation], box: CGRect)
        case cropping(handle: Handle?, start: CGPoint, original: CGRect)
        case panning(start: CGPoint, originalFocus: CGPoint)
        case marquee(start: CGPoint, initialSelection: [Annotation.ID], additive: Bool)

        /// While a redaction is drawn by hand, the suggestions step aside; a click with the tool still
        /// covers the one under it. Part of the drag, so whatever ends the drag brings them back.
        var hidesSuggestions: Bool {
            if case .creating(_, .redact, _, true) = self { true } else { false }
        }

        /// Whether the drag draws or moves marks, which may go past the canvas's edge for it to grow to
        /// once the drag ends.
        var editsMarks: Bool {
            switch self {
            case .creating, .drawing, .highlighting, .moving, .reshaping, .scaling, .rotating: true
            case .cropping, .panning, .marquee: false
            }
        }
    }

    private final class TextEditing {
        let id: Annotation.ID
        let isNew: Bool
        let view: MarkTextView
        let undo = UndoManager()
        /// Where a turned block's first corner was on the picture when editing began: the field is upright, and the
        /// block grows from that corner, so it is put back there when editing ends.
        var turnedCorner: CGPoint?

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
    /// Where the redactions lay when erasures were last made, which they read nothing of, and the canvas they
    /// were kept inside.
    private var erasedAround: (covered: [CGRect], canvas: CGRect) = ([], .null)
    /// Erasures stretched over their boxes during a drag, to fill again once it ends.
    private var staleErasures: Set<Annotation.ID> = []
    /// The redactions drawn before each blur and pixelation, with what each drew, when it was last made over them.
    private var redactedBeneath: [Annotation.ID: [(item: Annotation, coverage: Redactor.Coverage?)]] = [:]
    /// The picture the image layer shows, which a turn, a flip, or a resize replaces.
    private var shownPicture: CGImage?
    private var markLayers: [Annotation.ID: MarkLayer] = [:]
    private let selectionLayer = SelectionLayer()
    private let cropLayer = CropLayer()
    /// The document's watermark, above every mark.
    private let watermarkLayer = WatermarkLayer()
    /// The redaction tool's suggestions, outlined over the picture, each covered by a click.
    private lazy var suggestions = SuggestionOverlay(on: self)
    /// Each mark's element for VoiceOver, kept while the mark is, so VoiceOver keeps its place on it.
    private var markElements: [Annotation.ID: MarkElement] = [:]

    private var displayOptions: NSObjectProtocol?
    private var userZoom: CGFloat?
    /// The capture point at the middle of the free area while zoomed in.
    private var focus: CGPoint?
    private var canvasFrame: CGRect = .zero
    private var drag: Drag? {
        didSet { updateCanvasClipping() }
    }
    private var editing: TextEditing?
    /// The crop being chosen while the crop tool is in hand, in capture pixels. The crop frame shows it,
    /// and shows only while there is one.
    private var cropRect: CGRect? {
        didSet {
            cropLayer.isHidden = cropRect == nil
            if let cropRect { cropLayer.frameRect = viewRect(cropRect) }
        }
    }
    /// Whether Space is held down: pans a zoomed-in canvas, or in place moves the capture selection.
    public private(set) var isSpaceHeld = false
    /// Whether the canvas color eyedropper (shortcut I) is currently active.
    public private(set) var isPickingColor = false
    /// Called when `isPickingColor` toggles so the style capsule can update its Eyedropper chip.
    var onColorPickerChange: (() -> Void)?

    /// The marquee selection rectangle currently drawn on the canvas, in view points.
    var marqueeRect: CGRect? { selectionLayer.marqueeRect }

    /// Active smart alignment guides drawn on the canvas, in view points.
    var alignmentGuides: [SelectionLayer.Guide] { selectionLayer.alignmentGuides }

    /// The document point centered in the viewport while zoomed in.
    var viewportFocus: CGPoint? { focus }

    public init(session: AnnotationSession) {
        self.session = session
        captureHasOpaqueCorners = PixelProbe.hasOpaqueCorners(session.base)
        super.init(frame: .zero)
        wantsLayer = true
        host.layer = StillLayer()
        host.wantsLayer = true
        // Required by AppKit when custom layers or their sublayers use Core Image filters.
        host.layerUsesCoreImageFilters = true
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
        watermarkLayer.zPosition = 10
        watermarkLayer.isHidden = true
        canvasLayer.addSublayer(watermarkLayer)
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
        suggestions.install(in: host.layer)
        suggestions.onPress = { [weak self] suggestion in self?.session.acceptRedactionSuggestion(suggestion) ?? false }
        host.layer?.addSublayer(selectionLayer)
        host.layer?.addSublayer(cropLayer)
        cropLayer.isHidden = true

        session.observe { [weak self] event in self?.sessionChanged(event) }
        syncMarks()
        // Magnifiers in a document opened with them show what is under them from the start.
        updateLenses()
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
        var backdrop: BackdropPainter.Surface?
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
                backdrop: BackdropPainter.Surface(fill: backdrop.fill, layout: layout, shadow: CardShadow(backdrop, scale: document.scale))
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
        for layer in [pictureLayer, canvasLayer, cardLayer, keptLayer, imageLayer, spotlightLayer, selectionLayer, cropLayer, watermarkLayer] {
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
        updateWatermarkLayer(frames: frames)
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
        let open = session.tool == .redact && drag?.hidesSuggestions != true ? session.openRedactionSuggestions : []
        suggestions.show(open, in: host.bounds, fadingIn: fadingIn) { viewRect(session.coveringRect(of: $0)) }
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let suggestion = session.redactionSuggestion(at: documentPoint(point)) else { return "" }
        return suggestion.label + "\n" + String(localized: "Click to redact", bundle: .module)
    }

    /// The marks, in drawing order, then the open suggestions.
    public override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + currentMarkElements() + suggestions.accessibilityElements
    }

    public override func accessibilitySelectedChildren() -> [Any]? {
        currentMarkElements().filter { session.selection.contains($0.id) }
    }

    /// Picks the marks up as a click would, any tool in hand put down.
    public override func setAccessibilitySelectedChildren(_ children: [Any]?) {
        let ids = (children ?? []).compactMap { ($0 as? MarkElement)?.id }
        guard !session.tool.isPictureMode else { return }
        if !ids.isEmpty { session.putToolDownToSelect() }
        session.select(ids)
    }

    /// The mark Tab or a click picked up, while it is the only one and the canvas has the keyboard: VoiceOver's
    /// cursor follows the keyboard onto it.
    public nonisolated override var accessibilityFocusedUIElement: Any? {
        MainActor.assumeIsolated { focusedMarkElement } ?? super.accessibilityFocusedUIElement
    }

    private var focusedMarkElement: MarkElement? {
        guard window?.firstResponder === self, editing == nil, session.selection.count == 1, let id = session.selection.first,
              session.document.item(id) != nil else { return nil }
        return currentMarkElements().first { $0.id == id }
    }

    /// Each mark's element in drawing order: made the first time it is asked for, let go with its mark.
    private func currentMarkElements() -> [MarkElement] {
        let items = session.document.items
        let ids = Set(items.map(\.id))
        markElements = markElements.filter { ids.contains($0.key) }
        return items.map { item in
            if let element = markElements[item.id] { return element }
            let element = MarkElement(id: item.id, canvas: self)
            markElements[item.id] = element
            return element
        }
    }

    /// What VoiceOver calls a mark: its kind and color, a text's words, a counter's number.
    func accessibilityName(ofMark id: Annotation.ID) -> String? {
        session.document.item(id).map(MarkElement.name(of:))
    }

    /// Where a mark is drawn, in screen coordinates.
    func accessibilityFrame(ofMark id: Annotation.ID) -> CGRect {
        guard let item = session.document.item(id), let window else { return .zero }
        return window.convertToScreen(convert(viewRect(item.bounds(scale: session.document.scale)), to: nil))
    }

    /// Picks a mark up for VoiceOver, as a click would, or lets it go.
    func setMark(_ id: Annotation.ID, selected: Bool) {
        if selected {
            guard !session.tool.isPictureMode, session.document.item(id) != nil else { return }
            session.putToolDownToSelect()
            session.select([id])
        } else {
            session.select(session.selection.filter { $0 != id })
        }
    }

    /// Deletes a mark for VoiceOver's Delete action.
    func deleteMark(_ id: Annotation.ID) -> Bool {
        guard !session.tool.isPictureMode, session.document.item(id) != nil else { return false }
        session.select([id])
        session.deleteSelection()
        return true
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

    /// Marks are cut at the canvas's edge, as they are kept; while one is drawn or moved past it, for the
    /// canvas to grow to once the drag ends, the part past the edge shows too.
    private func updateCanvasClipping() {
        let clips = !(drag?.editsMarks == true && session.growsCanvas)
        guard canvasLayer.masksToBounds != clips else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.masksToBounds = clips
        CATransaction.commit()
    }

    /// Places a mark's layer over the part of the mark on screen. Images lie in the kept part of the
    /// capture, under the spotlight; other marks over everything.
    /// The watermark over the part of the canvas on screen, or hidden without one.
    private func updateWatermarkLayer(frames: Frames) {
        guard let watermark = session.document.watermark, !watermark.isBlank else {
            watermarkLayer.isHidden = true
            watermarkLayer.watermark = nil
            return
        }
        let shown = frames.shown
        let canvas = session.document.canvas.standardized
        let whole = CGRect(x: (canvas.minX - shown.minX) * zoom, y: (canvas.minY - shown.minY) * zoom, width: canvas.width * zoom, height: canvas.height * zoom)
        let part = whole.intersection(visibleCanvasRect)
        watermarkLayer.isHidden = part.isNull || part.isEmpty
        guard !watermarkLayer.isHidden else { return }
        watermarkLayer.frame = part
        watermarkLayer.mapping = LayerMapping(origin: CGPoint(x: shown.minX + part.minX / zoom, y: shown.minY + part.minY / zoom), zoom: zoom)
        watermarkLayer.canvas = canvas
        watermarkLayer.cardCornerRadius = frames.backdrop == nil ? 0 : frames.cornerRadius
        watermarkLayer.watermark = watermark
    }

    private func position(_ layer: MarkLayer, frames: Frames) {
        if case .filtered = layer.coverage, frames.backdrop != nil || frames.matte != nil {
            layer.underlay = BackdropPainter.Underlay(
                surface: frames.backdrop, blur: frames.backdrop?.fill == .blur ? session.blurredCapture : nil,
                matte: frames.matte?.cgColor(in: baseColorSpace), canvas: frames.card, preview: backdropLayer.preview
            )
        } else {
            layer.underlay = nil
        }
        // The document point at the parent layer's corner.
        let parent = layer.superlayer === keptLayer ? frames.picture.origin : frames.shown.origin
        let bounds = layer.documentDrawingBounds
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
        // The canvas is the part of the screen chosen; marks past it are cut, as on any locked canvas.
        session.keepsCanvasFixed = true
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        unregisterDraggedTypes()
        // The frozen screen under the canvas is the capture already: drawing it again would only hold a
        // second copy of a whole display's pixels.
        imageLayer.isHidden = true
        needsLayout = true
    }

    /// The tools in-place annotation offers, in their order: those `isOfferedInPlace` admits.
    public static let inPlaceTools: [AnnotationTool] = AnnotationTool.allCases.filter(\.isOfferedInPlace)

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
        if renumberCounter(with: event) { return }
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

    /// The wheel over a selected counter, in Select, steps its number: up (away from you, as the device moves) counts
    /// up, down counts down, never below the first. A trackpad steps once per `counterWheelStep` points of travel and
    /// a mouse wheel once per notch; the momentum after a flick steps nothing. One gesture's steps are one undo step,
    /// which ends when the gesture does, or a moment after the last notch. True when the event was taken.
    private func renumberCounter(with event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), session.tool == .select, drag == nil, !isEditingText else {
            endCounterWheel()
            return false
        }
        if event.momentumPhase != [] {
            // A flick that stepped a counter coasts out swallowed, never a pan or more steps; others pass.
            if counterWheel != nil {
                endCounterWheel()
                counterWheelCoasts = true
            }
            let swallowed = counterWheelCoasts
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { counterWheelCoasts = false }
            return swallowed
        }
        counterWheelCoasts = false
        let point = documentPoint(convert(event.locationInWindow, from: nil))
        guard let item = hitItem(at: point), session.selection.contains(item.id), case .counter = item.shape else {
            endCounterWheel()
            return false
        }
        // Another change under way (a drag of the selection's frame) is left to finish first.
        if session.isInLiveChange { return true }
        if counterWheel?.id != item.id {
            endCounterWheel()
            counterWheel = CounterWheel(id: item.id)
        }
        let travel = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        var steps = 0
        if event.hasPreciseScrollingDeltas {
            counterWheel?.residue += travel
            let residue = counterWheel?.residue ?? 0
            steps = Int((residue / Self.counterWheelStep).rounded(.towardZero))
            counterWheel?.residue -= CGFloat(steps) * Self.counterWheelStep
        } else if travel != 0 {
            steps = travel > 0 ? 1 : -1
        }
        if steps != 0, let index = session.document.index(of: item.id), case .counter(var counter) = session.document.items[index].shape {
            let value = max(1, counter.value + steps)
            if value != counter.value {
                counter.value = value
                var document = session.document
                document.items[index].shape = .counter(counter)
                let name = String(localized: "Renumber Counter", bundle: .module)
                // The gesture's first step is an undo step; the rest join it, as long as nothing else changed the
                // document since (then they start another). Undo puts back the number before the gesture, and Redo
                // the one it ended on.
                if let stepped = counterWheel?.stepped, stepped == session.document, session.undoManager.undoActionName == name {
                    session.updateLive(document)
                } else {
                    session.commit(document, actionName: name)
                }
                counterWheel?.stepped = session.document
                VoiceOver.announce(counter.label, from: self)
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            endCounterWheel()
        } else if !event.hasPreciseScrollingDeltas || event.phase == [] {
            // A mouse wheel has no phases: its gesture ends when the notches stop.
            counterWheel?.idle?.cancel()
            let idle = DispatchWorkItem { [weak self] in self?.endCounterWheel() }
            counterWheel?.idle = idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: idle)
        }
        return true
    }

    /// The wheel's gesture is over: the next notch, even on the same counter, is a new undo step.
    private func endCounterWheel() {
        guard let wheel = counterWheel else { return }
        counterWheel = nil
        wheel.idle?.cancel()
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
                // Blurs and highlights read the picture, which is another now: in drawing order, so each blur reads the
                // redactions before it as they now are.
                for item in session.document.items {
                    guard let layer = markLayers[item.id] else { continue }
                    updateRedaction(layer)
                    updateGround(layer)
                }
                if session.tool == .crop { cropRect = session.document.canvas }
            }
            updateLenses()
            if frames != laidOut || picture {
                // What is shown changed (a crop, a background): laid out again at the zoom the person
                // chose, so a slider never makes a zoomed-in picture jump; a fitted picture fits again.
                updateViewport()
            } else {
                updateSelectionOutlines()
                // A watermark changes nothing of what is shown but itself.
                if let laidOut { updateWatermarkLayer(frames: laidOut) }
            }
            CATransaction.commit()
            updateAccessibility()
            onViewportChange?()
        case .selection:
            updateSelectionOutlines()
            onViewportChange?()
            if let focusedMarkElement { NSAccessibility.post(element: focusedMarkElement, notification: .focusedUIElementChanged) }
        case .tool:
            toolChanged()
        case .history:
            // A drag that moved an image has ended: blurs show what is now under them, and magnifiers show the blurs.
            refreshRedactionsIfNeeded()
            updateLenses()
        case .settings:
            break
        case .suggestions:
            let finished = !session.isFindingRedactions
            updateSuggestions(fadingIn: finished)
            updateAccessibility()
            let count = session.openRedactionSuggestions.count
            if finished, session.tool == .redact {
                // VoiceOver hears the end of the reading even when it found nothing, or failed.
                VoiceOver.announce(
                    session.couldNotFindRedactions
                        ? String(localized: "Couldn’t read text", bundle: .module)
                        : count > 0
                        ? String(localized: "\(count) suggestions to redact", bundle: .module)
                        : String(localized: "No suggestions to redact", bundle: .module),
                    from: self,
                    priority: .medium
                )
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
                VoiceOver.announce(
                    session.couldNotFindTextLines
                        ? String(localized: "Couldn’t read text", bundle: .module)
                        : count > 0
                        ? String(localized: "\(count) lines of text to highlight", bundle: .module)
                        : String(localized: "No text to highlight", bundle: .module),
                    from: self,
                    priority: .medium
                )
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
            redactedBeneath[id] = nil
        }
        spotlightLayer.spots = document.spots
        refreshRedactionsIfNeeded()
    }

    /// The layer that draws the mark `id`, as it stands.
    func markLayer(for id: Annotation.ID) -> MarkLayer? {
        markLayers[id]
    }

    /// Shows in each magnifier the picture under it with every redaction on it as the canvas draws them, so a
    /// lens never shows what a redaction hides; made again whenever the document changes, as it is small, but
    /// not at every step of a drag that moves an image, whose combined picture is made again once it ends.
    private func updateLenses() {
        let magnifiers = markLayers.values.compactMap { layer -> (MarkLayer, Magnifier)? in
            if case .magnifier(let magnifier) = layer.mark.shape { return (layer, magnifier) }
            return nil
        }
        let images = session.document.items.filter { if case .image = $0.shape { true } else { false } }
        guard !magnifiers.isEmpty, !session.isInLiveChange || images == redactionImages else { return }
        let redactions = session.document.items.compactMap { item -> (item: Annotation, coverage: Redactor.Coverage?)? in
            guard case .redaction = item.shape else { return nil }
            return (item, markLayers[item.id]?.coverage)
        }
        let picture = session.redactionSource ?? (session.picture, .zero)
        for (layer, magnifier) in magnifiers {
            layer.lens = MagnifierPainter.lensPicture(
                for: magnifier, picture: picture, canvas: session.document.canvas, redactions: redactions, scale: session.document.scale
            )
        }
    }

    private func updateRedaction(_ layer: MarkLayer) {
        guard case .redaction(let redaction) = layer.mark.shape, redaction.method != .solid else {
            layer.coverage = nil
            redactedBeneath[layer.mark.id] = nil
            return
        }
        let source = session.combinedRedactionSource ?? Redactor.Source(base: session.picture)
        // Filling an erasure reads and writes every pixel under it, too slow to repeat at each step of a drag: until the
        // drag ends, the last fill stretches over the box, covering it as it goes.
        if redaction.method == .erase, session.isInLiveChange, case .filtered(let image, _)? = layer.coverage {
            let rect = redaction.rect.standardized.integral.intersection(source.bounds).intersection(erasureCanvas.standardized.integral)
            layer.coverage = rect.isNull || rect.width < 1 || rect.height < 1 ? nil : .filtered(image, rect)
            staleErasures.insert(layer.mark.id)
            return
        }
        // A blur or pixelation reads the picture as the redactions drawn before it leave it, as their layers show them.
        let beneath = session.document.items.prefix { $0.id != layer.mark.id }.compactMap { item -> (item: Annotation, coverage: Redactor.Coverage?)? in
            guard case .redaction = item.shape else { return nil }
            return (item, markLayers[item.id]?.coverage)
        }
        // An erasure reads nothing any redaction lies over, so nothing is kept for it.
        redactedBeneath[layer.mark.id] = redaction.method == .erase ? nil : beneath
        layer.coverage = Redactor.coverage(
            for: redaction, id: layer.mark.id, source: source, scale: session.document.scale, covered: session.document.redactedRects,
            canvas: erasureCanvas, beneath: beneath
        )
    }

    /// What erasures keep inside: the canvas, or while cropping the whole picture shown, so an erasure past the
    /// canvas covers what a wider crop frame shows of it.
    private var erasureCanvas: CGRect {
        session.tool == .crop ? shownCanvas : session.document.canvas
    }

    /// What a highlight lies on, read from the picture blurs show, images included.
    private func updateGround(_ layer: MarkLayer) {
        guard layer.mark.multiplies else { return }
        let source = session.redactionSource
        layer.ground = HighlightGround.under(layer.mark, in: source?.image ?? session.picture, origin: source?.origin ?? .zero, scale: session.document.scale)
    }

    /// Makes blurs and pixelations again over images that moved, once a drag has ended, and reads again
    /// what highlights lie on: remaking them at every step of a drag would be slow, and they show the
    /// result on release. Erasures are made again as well when a redaction around them came, went, or moved,
    /// or the canvas they keep inside changed, and once the drag that stretched them ends; blurs and pixelations
    /// when a redaction drawn before them did, and a blurred background with the redactions as they now are.
    private func refreshRedactionsIfNeeded() {
        guard !session.isInLiveChange else { return }
        for id in staleErasures {
            guard let layer = markLayers[id] else { continue }
            updateRedaction(layer)
            position(layer, frames: frames)
        }
        staleErasures = []
        let images = session.document.items.filter { if case .image = $0.shape { true } else { false } }
        let around = (covered: session.document.redactedRects, canvas: erasureCanvas)
        if images != redactionImages {
            redactionImages = images
            erasedAround = around
            // In drawing order, so each blur reads the redactions before it as they now are.
            for item in session.document.items {
                guard let layer = markLayers[item.id] else { continue }
                if case .redaction = layer.mark.shape {
                    updateRedaction(layer)
                    position(layer, frames: frames)
                }
                updateGround(layer)
            }
        } else if around != erasedAround {
            erasedAround = around
            for layer in markLayers.values {
                guard case .redaction(let redaction) = layer.mark.shape, redaction.method == .erase else { continue }
                updateRedaction(layer)
                position(layer, frames: frames)
            }
        }
        var beneath: [(item: Annotation, coverage: Redactor.Coverage?)] = []
        for item in session.document.items {
            guard case .redaction(let redaction) = item.shape, let layer = markLayers[item.id] else { continue }
            let reads = redaction.method == .blur || redaction.method == .pixelate
            if reads, redactedBeneath[item.id].map({ !$0.elementsEqual(beneath) { $0.item == $1.item && $0.coverage == $1.coverage } }) ?? true {
                updateRedaction(layer)
                position(layer, frames: frames)
            }
            beneath.append((item, layer.coverage))
        }
        if backdropLayer.content?.fill == .blur, case let blur = session.blurredCapture, blur !== backdropLayer.blur {
            backdropLayer.blur = blur
            // A filtered redaction over the picture's clear pixels shows the background under it.
            for layer in markLayers.values where layer.underlay != nil {
                position(layer, frames: frames)
            }
        }
    }

    private func updateSelectionOutlines() {
        let scale = session.document.scale
        let single = session.selection.count == 1 && editing == nil
        let knob = rotationKnob()
        // The text being typed shows its own field instead of a selection.
        var outlines = session.selectedItems.filter { $0.id != editing?.id }.map { item in
            let handles = single ? item.handles(scale: scale).map { viewPoint($0.point) } : []
            if item.isTurned {
                // Its own frame, turned, rather than the upright box around it.
                let frame = viewRect(item.upright(scale: scale).bounds(scale: scale))
                return SelectionLayer.Outline(
                    box: frame, handles: handles, angle: item.angle,
                    knob: knob.flatMap { $0.id == item.id ? ($0.base, $0.point) : nil }
                )
            }
            // A single arrow or line shows its handles alone; anything else, or several, a box too.
            switch item.shape {
            case .arrow, .line:
                if single { return SelectionLayer.Outline(box: nil, handles: handles) }
            default:
                break
            }
            return SelectionLayer.Outline(
                box: viewRect(item.bounds(scale: scale)).integral, handles: handles,
                knob: knob.flatMap { $0.id == item.id ? ($0.base, $0.point) : nil }
            )
        }
        // Several marks: a box around them all as well, its corners resizing them together.
        if let box = groupBox, editing == nil {
            outlines.append(SelectionLayer.Outline(
                box: viewRect(box).integral, handles: Self.groupHandles(of: box).map { viewPoint($0.point) }
            ))
        }
        selectionLayer.outlines = outlines
    }

    private func toolChanged() {
        endEditing()
        if session.tool != .select { session.select([]) }
        if session.tool == .crop {
            cropRect = session.document.canvas
            // Each crop starts free: the frame is the whole canvas, which a ratio may not fit.
            session.setCropRatio(.free)
            // The whole capture shows while cropping.
            userZoom = nil
            focus = nil
            updateViewport()
        } else if let cropRect {
            self.cropRect = nil
            applyCrop(cropRect)
            userZoom = nil
            focus = nil
            updateViewport()
        }
        // Cropping shows the whole picture, which erasures past the canvas cover too.
        refreshRedactionsIfNeeded()
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
        cropRect = CropRatio.fitted(value, in: session.document.imageBounds.union(session.document.canvas.standardized))
    }

    /// Puts the crop frame back to the whole canvas.
    public func resetCrop() {
        guard session.tool == .crop else { return }
        session.setCropRatio(.free)
        cropRect = session.document.imageBounds
        applyCrop(session.document.imageBounds)
    }

    private func applyCrop(_ rect: CGRect) {
        let rect = rect.standardized.integral
        guard rect.width >= 4, rect.height >= 4, rect != session.document.canvas else { return }
        session.crop(to: rect)
        if session.tool == .crop { cropRect = session.document.canvas }
    }

    /// Toggles the canvas color eyedropper (shortcut I).
    public func toggleColorPicker() {
        if isPickingColor {
            cancelColorPicker()
        } else {
            endEditing()
            isPickingColor = true
            if let window {
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if bounds.contains(location) {
                    updateEyedropperPreview(at: location)
                    updateCursor(at: location)
                }
            }
            onColorPickerChange?()
        }
    }

    public func cancelColorPicker() {
        guard isPickingColor else { return }
        isPickingColor = false
        selectionLayer.eyedropperPreview = nil
        if let window {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(location) { updateCursor(at: location) }
        }
        onColorPickerChange?()
    }

    /// Samples the capture's pixel color at `documentPoint` (in document pixels).
    public func sampleColor(at documentPoint: CGPoint) -> RGBA? {
        PixelProbe.color(at: documentPoint, in: session.picture)
    }

    private func updateEyedropperPreview(at viewLocation: CGPoint) {
        guard isPickingColor, let color = sampleColor(at: documentPoint(viewLocation)) else {
            selectionLayer.eyedropperPreview = nil
            return
        }
        selectionLayer.eyedropperPreview = SelectionLayer.EyedropperPreview(point: viewLocation, color: color)
    }

    // MARK: Hit testing

    private var tolerance: CGFloat { 5 / zoom }

    /// The mark a press at `point` (pixels) takes hold of. With `pressing`, a press that would highlight
    /// text with the highlighter is left to highlight: the edges of highlights already there, which hug
    /// the lines above and below, do not catch it unless they are selected.
    private func hitItem(at point: CGPoint, pressing: Bool = false, includingInterior: Bool = false) -> Annotation? {
        let scale = session.document.scale
        let interiorForAll = session.tool == .select || includingInterior
        let highlighting = pressing && !includingInterior && session.tool == .highlighter && TextSnapping.line(at: point, in: session.textLines) != nil
        for item in session.document.items.reversed() {
            let selected = session.selection.contains(item.id)
            if highlighting, item.multiplies, !selected { continue }
            let interior = interiorForAll || selected
            if item.contains(point, tolerance: tolerance, scale: scale, interior: interior) { return item }
        }
        return nil
    }

    /// Any text mark at `point` (pixels), even when covered by an area mark.
    private func hitTextItem(at point: CGPoint) -> Annotation? {
        let scale = session.document.scale
        return session.document.items.reversed().first { item in
            guard case .text = item.shape else { return false }
            return item.contains(point, tolerance: tolerance, scale: scale, interior: true)
        }
    }

    /// How far above a mark its rotation knob stands, in view points.
    static let knobReach: CGFloat = 22

    /// The knob that turns the one selected mark, if it turns: where it is and the middle of the frame's top it stands
    /// above, in view points, and the middle the mark turns about, in pixels.
    private func rotationKnob() -> (id: Annotation.ID, point: CGPoint, base: CGPoint, pivot: CGPoint)? {
        guard session.selection.count == 1, session.tool == .select, editing == nil,
              let item = session.selectedItems.first, item.isRotatable else { return nil }
        let scale = session.document.scale
        let frame = item.upright(scale: scale).bounds(scale: scale)
        guard !frame.isNull else { return nil }
        let pivot = frame.middle
        let center = viewPoint(pivot)
        let top = viewPoint(CGPoint(x: frame.midX, y: frame.minY))
        let base = Annotation.turn(top, about: center, by: item.angle)
        let point = Annotation.turn(CGPoint(x: top.x, y: top.y - Self.knobReach), about: center, by: item.angle)
        return (item.id, point, base, pivot)
    }

    /// The box around the selected marks while there are several, in document pixels; nil otherwise.
    private var groupBox: CGRect? {
        guard session.selection.count >= 2, session.tool == .select else { return nil }
        let scale = session.document.scale
        let box = session.selectedItems.map { $0.bounds(scale: scale) }.filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
        return box.isNull || box.width < 1 || box.height < 1 ? nil : box
    }

    private static func groupHandles(of box: CGRect) -> [(handle: Handle, point: CGPoint)] {
        [
            (.topLeft, CGPoint(x: box.minX, y: box.minY)), (.topRight, CGPoint(x: box.maxX, y: box.minY)),
            (.bottomRight, CGPoint(x: box.maxX, y: box.maxY)), (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)),
        ]
    }

    /// The corner of the box around several selected marks under `viewPoint`.
    private func groupHandle(at viewPoint: CGPoint) -> (handle: Handle, box: CGRect)? {
        guard let box = groupBox else { return nil }
        let reach = SelectionLayer.handleSize / 2 + 4
        return Self.groupHandles(of: box).first { candidate in
            let point = self.viewPoint(candidate.point)
            return hypot(point.x - viewPoint.x, point.y - viewPoint.y) <= reach
        }.map { ($0.handle, box) }
    }

    /// Several marks scaled from `box` to `target` (document pixels): each carried by the same map, as a picture's
    /// resize carries them. Shapes, strokes, redactions and images stretch with the box, lines keeping their width;
    /// text and counters keep their size and move with the rest, by their middles, so a block's wrapping is kept too.
    /// A tail left to point its own way still does; one pointed somewhere goes where the map takes that place, unless
    /// that is on the mark itself, when it keeps its place beside the mark.
    static func scaled(_ marks: [Annotation], from box: CGRect, to target: CGRect, scale: CGFloat) -> [Annotation] {
        let a = target.width / box.width, d = target.height / box.height
        let mapping = PictureMapping(
            affine: CGAffineTransform(a: a, b: 0, c: 0, d: d, tx: target.minX - box.minX * a, ty: target.minY - box.minY * d),
            operation: .resize(to: target.size), lengthFactor: sqrt(a * d)
        )
        return marks.map { mark in
            var moved = mark.mapped(by: mapping, scale: scale)
            let frame = mark.bounds(scale: scale)
            let middle = mapping.point(CGPoint(x: frame.midX, y: frame.midY))
            let dx = middle.x - frame.midX, dy = middle.y - frame.midY
            func carried(_ tip: CGPoint?) -> CGPoint? {
                guard let tip else { return nil }
                let mapped = mapping.point(tip)
                return moved.bounds(scale: scale).contains(mapped) ? CGPoint(x: tip.x + dx, y: tip.y + dy) : mapped
            }
            switch (moved.shape, mark.shape) {
            case (.text(var block), .text(let before)):
                block.width = before.width
                block.origin = CGPoint(x: before.origin.x + dx, y: before.origin.y + dy)
                block.tail = nil
                moved.shape = .text(block)
                block.tail = carried(before.tail)
                moved.shape = .text(block)
            case (.counter(var counter), .counter(let before)):
                counter.tail = nil
                moved.shape = .counter(counter)
                counter.tail = carried(before.tail)
                moved.shape = .counter(counter)
            default:
                break
            }
            return moved
        }
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
        // A press ends the wheel's gesture on a counter: notches after it are a new undo step.
        endCounterWheel()
        if editing != nil {
            endEditing()
        }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if isPickingColor {
            if let sampled = sampleColor(at: documentPoint(location)) {
                session.changeSettings(String(localized: "Color", bundle: .module)) { $0.color = sampled }
                refreshEditingStyle()
            }
            cancelColorPicker()
            return
        }
        if isSpaceHeld, !isInPlace {
            let currentFocus = focus ?? documentPoint(CGPoint(x: freeArea.midX, y: freeArea.midY))
            drag = .panning(start: location, originalFocus: currentFocus)
            NSCursor.closedHand.set()
            return
        }
        // The background's controls set it; the picture itself takes no clicks meanwhile.
        if session.tool == .background { return }
        let point = documentPoint(location)
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
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

        // Double-clicking any existing text mark from any tool enters inline editing immediately.
        if event.clickCount == 2, let textItem = hitTextItem(at: point) {
            beginEditing(textItem.id, isNew: false)
            return
        }

        if let knob = rotationKnob(), hypot(knob.point.x - location.x, knob.point.y - location.y) <= SelectionLayer.handleSize / 2 + 4,
           let item = session.document.item(knob.id) {
            session.beginLiveChange()
            drag = .rotating(original: item, pivot: knob.pivot, start: atan2(point.y - knob.pivot.y, point.x - knob.pivot.x))
            NSCursor.closedHand.set()
            return
        }

        if session.selection.count == 1, let item = session.selectedItems.first, let handle = handle(at: location, of: item) {
            session.beginLiveChange()
            drag = .reshaping(handle: handle, original: item)
            return
        }

        if let (handle, box) = groupHandle(at: location) {
            session.beginLiveChange()
            drag = .scaling(handle: handle, originals: session.selectedItems, box: box)
            return
        }

        if let item = hitItem(at: point, pressing: true, includingInterior: command) {
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

        let tool = session.tool
        if tool == .select {
            if isInPlace, event.clickCount == 2 {
                onCopy?()
                return
            }
            if !shift { session.select([]) }
            drag = .marquee(start: point, initialSelection: shift ? session.selection : [], additive: shift)
            selectionLayer.marqueeRect = nil
            return
        }
        session.select([])
        if tool.dragsShape {
            // Dragged out from the press, corner to corner or end to end.
            session.beginLiveChange()
            drag = .creating(id: UUID(), tool: tool, start: point, beyondClick: false)
            return
        }
        let settings = session.settings(for: tool)
        switch tool {
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
            let shape = Shape.highlight(along: [point], snapping: snapping, freely: event.modifierFlags.contains(.command))
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
            session.commit(session.fitted(document, holding: [item.id]), selecting: [], actionName: String(localized: "Add Counter", bundle: .module))
        default:
            // Select, the crop, and the background draw nothing; the shapes were dragged out above.
            break
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
        case .creating(let id, let tool, let start, let beyondClick):
            if !beyondClick, hypot(location.x - viewPoint(start).x, location.y - viewPoint(start).y) >= 4 {
                self.drag = .creating(id: id, tool: tool, start: start, beyondClick: true)
                if tool == .redact { updateSuggestions() }
            }
            guard let mark = tool.mark(
                from: start, to: point, constrained: shift, settings: session.settings(for: tool), id: id, scale: document.scale, room: lensRoom
            ) else { return }
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
            if !event.modifierFlags.contains(.command), originals.count == 1 {
                // A single mark snaps to other marks' edges and middles and to the canvas's middle within
                // 4 points on screen.
                let snapped = AlignmentSnapping.snap(
                    originals[0], translatedBy: delta, in: session.document, threshold: 4 / max(zoom, 0.05),
                    axisLockedX: shift && delta.width == 0, axisLockedY: shift && delta.height == 0
                )
                delta = snapped.delta
                selectionLayer.alignmentGuides = snapped.guides.map { SelectionLayer.Guide(start: viewPoint($0.start), end: viewPoint($0.end)) }
            } else {
                selectionLayer.alignmentGuides = []
            }
            // A magnifier dragged on its own moves its lens alone; moved with other marks, it moves whole.
            for original in originals {
                guard let index = document.index(of: original.id) else { continue }
                document.items[index] = originals.count == 1 ? original.dragged(by: delta) : original.translated(by: delta)
            }
            session.updateLive(document)
        case .reshaping(let handle, let original):
            guard let index = document.index(of: original.id) else { return }
            document.items[index] = original.moving(handle, to: point, constrained: shift, scale: document.scale)
            session.updateLive(document)
        case .rotating(let original, let pivot, let start):
            guard let index = document.index(of: original.id) else { return }
            let turn = atan2(point.y - pivot.y, point.x - pivot.x) - start
            let angle = Annotation.snappedAngle(original.angle + turn, constrained: shift)
            document.items[index] = original.rotated(to: angle)
            session.updateLive(document)
        case .scaling(let handle, let originals, let box):
            // Shift keeps the box's shape; a corner dragged past the opposite one stops short of it, as the marks
            // are not turned over.
            let least: CGFloat = 4
            let left = handle == .topLeft || handle == .bottomLeft, up = handle == .topLeft || handle == .topRight
            let held = CGPoint(
                x: left ? min(point.x, box.maxX - least) : max(point.x, box.minX + least),
                y: up ? min(point.y, box.maxY - least) : max(point.y, box.minY + least)
            )
            let target = Geometry.resized(box, dragging: handle, to: held, keepingAspect: shift)
            guard target.width >= least, target.height >= least else { return }
            for mark in Self.scaled(originals, from: box, to: target, scale: document.scale) {
                guard let index = document.index(of: mark.id) else { continue }
                document.items[index] = mark
            }
            session.updateLive(document)
        case .cropping(let handle, let start, let original):
            var rect: CGRect
            if let handle {
                rect = croppedRect(original, dragging: handle, to: point, keepingShape: shift)
            } else {
                rect = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            }
            cropRect = rect.standardized
        case .panning(let start, let originalFocus):
            guard userZoom != nil else { return }
            let dx = location.x - start.x
            let dy = location.y - start.y
            focus = CGPoint(x: originalFocus.x - dx / zoom, y: originalFocus.y - dy / zoom)
            updateViewport()
            focus = documentPoint(CGPoint(x: freeArea.midX, y: freeArea.midY))
        case .marquee(let start, let initialSelection, let additive):
            let docRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            selectionLayer.marqueeRect = viewRect(docRect)
            let scale = session.document.scale
            let enclosed = session.document.items.compactMap { item -> Annotation.ID? in
                item.bounds(scale: scale).intersects(docRect) ? item.id : nil
            }
            if additive {
                var combined = initialSelection
                for id in enclosed where !combined.contains(id) {
                    combined.append(id)
                }
                session.select(combined)
            } else {
                session.select(enclosed)
            }
        }
    }

    /// Where a new lens fits, handles and all: on a canvas that cannot grow, such as Annotate Area's selection, the
    /// canvas less its handles' reach, so a lens is not cut off and can be resized. Nil where the canvas grows.
    private var lensRoom: CGRect? {
        guard !session.growsCanvas else { return nil }
        let reach = (SelectionLayer.handleSize / 2 + 4) / zoom
        return session.document.canvas.insetBy(dx: reach, dy: reach)
    }

    public override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        let location = convert(event.locationInWindow, from: nil)
        defer {
            // The drag has ended: suggestions a redaction drawn by hand set aside come back.
            updateSuggestions()
            updateCursor(at: location)
            // Controls hidden during the drag come back where the marks now are.
            onViewportChange?()
        }
        switch drag {
        case .creating(let id, let tool, let start, _):
            let startView = viewPoint(start)
            let clicked = hypot(location.x - startView.x, location.y - startView.y) < 4
            if clicked, tool == .magnifier,
               let mark = tool.mark(
                   from: start, to: start, constrained: false, settings: session.settings(for: tool), id: id, scale: session.document.scale, room: lensRoom
               ) {
                // A click puts the lens over what was clicked.
                var document = session.document
                if let index = document.index(of: id) { document.items[index] = mark } else { document.items.append(mark) }
                session.updateLive(document, selecting: [])
            } else if clicked || session.document.item(id) == nil {
                session.cancelLiveChange()
                // A click with the redaction tool on a suggestion covers it.
                if tool == .redact { session.acceptRedactionSuggestion(at: start) }
                return
            }
            session.fitCanvas(holding: [id])
            session.endLiveChange(actionName: tool.addName)
            session.select([id])
            // The shape is made: Select takes over, with the shape selected to adjust.
            session.putToolDown()
        case .drawing(let id):
            session.fitCanvas(holding: [id])
            session.endLiveChange(actionName: String(localized: "Draw", bundle: .module))
        case .highlighting(let id, _, _):
            guard let index = session.document.index(of: id), case .textHighlight(let highlight) = session.document.items[index].shape else {
                session.fitCanvas(holding: [id])
                session.endLiveChange(actionName: String(localized: "Draw", bundle: .module))
                return
            }
            session.updateLive(session.document.joiningHighlight(id, highlight))
            session.endLiveChange(actionName: String(localized: "Highlight", bundle: .module))
        case .moving(_, let originals):
            selectionLayer.alignmentGuides = []
            // A mark or an image moved past the canvas's edge takes the canvas with it; moved back in, the
            // canvas follows it back.
            session.fitCanvas(holding: originals.map(\.id))
            session.endLiveChange(actionName: String(localized: "Move", bundle: .module))
        case .scaling(_, let originals, _):
            session.fitCanvas(holding: originals.map(\.id))
            session.endLiveChange(actionName: String(localized: "Resize Marks", bundle: .module))
        case .rotating(let original, _, _):
            session.fitCanvas(holding: [original.id])
            session.endLiveChange(actionName: String(localized: "Rotate", bundle: .module))
        case .reshaping(let handle, let original):
            session.fitCanvas(holding: [original.id])
            let name = switch (handle, original.shape) {
            case (.bend, _): String(localized: "Bend Arrow", bundle: .module)
            case (.tail, _): String(localized: "Move Tail", bundle: .module)
            case (.start, .magnifier): String(localized: "Move Magnified Spot", bundle: .module)
            default: String(localized: "Resize", bundle: .module)
            }
            session.endLiveChange(actionName: name)
        case .cropping:
            cropLayer.showsThirds = false
            if let cropRect, cropRect.width < 8 || cropRect.height < 8 {
                // A click without a drag: keep the crop as it was.
                self.cropRect = session.document.canvas
            }
        case .panning:
            break
        case .marquee:
            selectionLayer.marqueeRect = nil
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
        document.items[index].shape = Shape.highlight(along: points, snapping: snapping, freely: event.modifierFlags.contains(.command))
        session.updateLive(document)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let freely = event.modifierFlags.contains(.command)
        if case .highlighting(let id, let points, let snapping) = drag, snapping != nil, let index = session.document.index(of: id) {
            // ⌘ frees the stroke from the text while it is held, mid-drag too.
            var document = session.document
            document.items[index].shape = Shape.highlight(along: points, snapping: snapping, freely: freely)
            session.updateLive(document)
        } else if drag == nil, let window {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(location) { updateCursor(at: location) }
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = documentPoint(convert(event.locationInWindow, from: nil))
        let item = hitItem(at: point)
        if let item, !session.selection.contains(item.id) {
            session.select([item.id])
        }
        guard isInPlace else { return super.rightMouseDown(with: event) }
        // In place, a right-click away from the marks backs out a step, as its host decides.
        guard item != nil else {
            onRightClickAway?()
            return
        }
        // The overlay's panel floats above the pop-up menu level; it steps just below while the menu is open, or
        // the menu would open under it.
        guard let menu = menu(for: event), let window else { return }
        let level = window.level
        if level >= .popUpMenu { window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        window.level = level
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
        if session.selectedItems.contains(where: \.isTurned) {
            add(String(localized: "Straighten", bundle: .module), #selector(straightenSelection(_:)), "arrow.uturn.backward")
        }
        menu.addItem(.separator())
        add(String(localized: "Delete", bundle: .module), #selector(delete(_:)), "trash")
        return menu
    }

    /// Turns the selected marks upright again.
    @objc func straightenSelection(_ sender: Any?) {
        var document = session.document
        var changed = false
        for id in session.selection {
            guard let index = document.index(of: id), document.items[index].isTurned else { continue }
            document.items[index] = document.items[index].rotated(to: 0)
            changed = true
        }
        guard changed else { return }
        session.commit(document, actionName: String(localized: "Straighten", bundle: .module))
    }

    // MARK: Combining

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
        let pictures = IncomingPicture.keep(from: pasteboard)
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
            place(IncomingPicture.keep(panel.urls), at: point)
        }
    }

    /// The menu for the empty canvas: combine a picture into the capture.
    private func pictureMenu(at point: CGPoint) -> NSMenu? {
        let menu = NSMenu()
        if IncomingPicture.isOffered(by: .general) {
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
        guard !(sender.draggingSource is CaptureDragSource), IncomingPicture.isOffered(by: sender.draggingPasteboard) else { return [] }
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
        let pictures = IncomingPicture.keep(from: sender.draggingPasteboard)
        guard !pictures.isEmpty else { return false }
        place(pictures, at: documentPoint(convert(sender.draggingLocation, from: nil)))
        return true
    }

    public override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        selectionLayer.dropFrame = nil
    }

    // MARK: Cursor

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isPickingColor { updateEyedropperPreview(at: location) }
        updateCursor(at: location)
    }

    public override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at location: CGPoint) {
        guard drag == nil else { return }
        if editing?.view.frame.contains(location) == true { return }
        if isPickingColor {
            NSCursor.crosshair.set()
            return
        }
        if let override = cursorOverride?(location) {
            override.set()
            return
        }
        if isSpaceHeld, !isInPlace {
            NSCursor.openHand.set()
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
        } else if let knob = rotationKnob(), hypot(knob.point.x - location.x, knob.point.y - location.y) <= SelectionLayer.handleSize / 2 + 4 {
            cursor = .openHand
        } else if session.selection.count == 1, let item = session.selectedItems.first, let handle = handle(at: location, of: item) {
            cursor = handle == .bend || handle == .tail || handle == .start || handle == .end
                ? .crosshair : Self.resizeCursor(for: handle.turned(by: item.angle))
        } else if let (handle, _) = groupHandle(at: location) {
            cursor = Self.resizeCursor(for: handle)
        } else if hitItem(at: documentPoint(location), pressing: true) != nil {
            cursor = .openHand
        } else if session.tool == .redact, session.redactionSuggestion(at: documentPoint(location)) != nil {
            cursor = .pointingHand
        } else {
            cursor = switch session.tool {
            case .select: .arrow
            case .text: .iBeam
            // Over text the highlighter snaps to it, which the text cursor says, until ⌘ frees it.
            case .highlighter:
                !NSEvent.modifierFlags.contains(.command) && TextSnapping.line(at: documentPoint(location), in: session.textLines) != nil
                    ? .iBeam : .crosshair
            // The crop and the background have theirs above.
            case .arrow, .line, .rectangle, .ellipse, .pen, .highlightBox, .counter, .redact, .spotlight, .magnifier, .crop, .background: .crosshair
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
        case .start, .end, .bend, .tail: .crosshair
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        endCounterWheel()
        if !handleKey(event) {
            super.keyDown(with: event)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceHeld = false
            if let window {
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if bounds.contains(location) { updateCursor(at: location) }
            }
            if isInPlace { super.keyUp(with: event) }
            return
        }
        super.keyUp(with: event)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 49 where editing == nil:
            isSpaceHeld = true
            if let window {
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if bounds.contains(location) { updateCursor(at: location) }
            }
            if isInPlace { return false }
            return true
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
        case 48 where editing == nil && drag == nil && !session.isInLiveChange && flags.subtracting([.shift, .capsLock]).isEmpty:
            return selectAdjacentMark(backward: flags.contains(.shift))
        case 53:
            if isPickingColor {
                cancelColorPicker()
            } else if case .marquee(_, let initialSelection, _) = drag {
                drag = nil
                selectionLayer.marqueeRect = nil
                session.select(initialSelection)
            } else if session.isInLiveChange {
                // Cleared before the document goes back, so the suggestions a redaction drawn by hand set
                // aside show again as it goes.
                drag = nil
                selectionLayer.alignmentGuides = []
                session.cancelLiveChange()
            } else if session.tool == .crop {
                // A drag under way ends here too, so the next move of the pointer can't bring its frame back, and
                // the controls it hid come back once the frame is settled, as at a drag's end.
                let endsDrag = drag != nil
                defer { if endsDrag { onViewportChange?() } }
                drag = nil
                cropLayer.showsThirds = false
                // A frame and shape left as they began have nothing to put back: Escape leaves Crop, cropping
                // nothing, as it leaves Background. Otherwise it puts them back first.
                if cropRect == session.document.canvas, session.cropRatio == .free {
                    session.leavePictureMode()
                } else {
                    session.setCropRatio(.free)
                    cropRect = session.document.canvas
                }
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
                session.leavePictureMode()
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
            // Digits from the keypad too, and brackets as typed, Option and all, for layouts that need Option for them.
            if editing == nil, flags.subtracting([.shift, .capsLock, .numericPad]).isEmpty,
               let digit = event.charactersIgnoringModifiers?.first?.wholeNumberValue, (1...9).contains(digit) {
                return chooseColor(at: digit - 1)
            }
            if editing == nil, flags.subtracting([.shift, .capsLock, .option]).isEmpty, let typed = event.characters, typed == "[" || typed == "]" {
                return stepSize(by: typed == "]" ? 1 : -1)
            }
            guard
                flags.subtracting([.shift, .capsLock]).isEmpty,
                let character = event.charactersIgnoringModifiers?.lowercased().first
            else { return false }
            if character == "i", editing == nil {
                toggleColorPicker()
                return true
            }
            guard
                let tool = AnnotationTool.allCases.first(where: { $0.key == character }),
                !isInPlace || tool.isOfferedInPlace
            else { return false }
            cancelColorPicker()
            session.tool = tool
            return true
        }
    }

    /// Tab and Shift-Tab: the next or previous mark in drawing order, picked up as a click picks it up (the tool put
    /// down first) and brought into view. Past the last, or before the first, nothing is left selected and false is
    /// returned, so the key goes on to the window and the keyboard moves on from the canvas rather than being held.
    func selectAdjacentMark(backward: Bool) -> Bool {
        let items = session.document.items
        guard !items.isEmpty, !session.tool.isPictureMode else { return false }
        let current = session.selection.last.flatMap { session.document.index(of: $0) }
        let next: Int? = switch current {
        case nil: backward ? items.count - 1 : 0
        case let index?: backward ? (index > 0 ? index - 1 : nil) : (index + 1 < items.count ? index + 1 : nil)
        }
        guard let next else {
            session.select([])
            return false
        }
        cancelColorPicker()
        session.putToolDownToSelect()
        session.select([items[next].id])
        reveal(items[next])
        return true
    }

    /// Brings a mark zoomed out of view back into it, centered as far as the picture's edges allow. A fitted
    /// picture, and the picture in place, show every mark already.
    private func reveal(_ item: Annotation) {
        let bounds = item.bounds(scale: session.document.scale)
        guard userZoom != nil, !freeArea.contains(viewRect(bounds)) else { return }
        focus = CGPoint(x: bounds.midX, y: bounds.midY)
        updateViewport()
        // Clamped by the edges: keep the focus where the picture actually is.
        focus = documentPoint(CGPoint(x: freeArea.midX, y: freeArea.midY))
        onViewportChange?()
    }

    /// The colors 1 to 9 choose for the selected marks or the tool in hand, as the style capsule numbers them;
    /// none with neither, or for a kind that takes no color.
    var keyedColors: [RGBA] {
        guard !session.selection.isEmpty || session.tool != .select else { return [] }
        return StyleCapsule.keyedColors(for: session.currentKind, settings: session.currentSettings, saved: SavedColors.shared.colors)
    }

    /// 1 to 9: the capsule's color of that number, as its chip would choose it. False when there is none.
    func chooseColor(at index: Int) -> Bool {
        let colors = keyedColors
        guard colors.indices.contains(index) else { return false }
        let color = colors[index]
        session.changeSettings(String(localized: "Color", bundle: .module)) { $0.color = color }
        refreshEditingStyle()
        return true
    }

    /// [ and ]: the capsule's next size down or up for the selected marks or the tool in hand, a width or for text
    /// a type size, stepping from the chip the capsule shows chosen; at either end nothing changes. False where no
    /// size applies.
    func stepSize(by step: Int) -> Bool {
        guard !session.selection.isEmpty || session.tool != .select, session.sizeApplies else { return false }
        let kind = session.currentKind
        let sizes = StyleCapsule.sizes(for: kind)
        guard !sizes.isEmpty else { return false }
        let isText = kind == .text
        let current = isText ? session.currentSettings.fontSize : session.currentSettings.lineWidth
        let index = sizes.firstIndex(of: StyleCapsule.nearest(current, in: sizes)) ?? 0
        let next = min(max(index + step, 0), sizes.count - 1)
        // At either end the size stays as it is, even one between the capsule's steps.
        guard next != index else { return true }
        let size = sizes[next]
        if isText {
            session.changeSettings(String(localized: "Text Size", bundle: .module)) { $0.fontSize = size }
        } else {
            session.changeSettings(String(localized: "Size", bundle: .module)) { $0.lineWidth = size }
        }
        refreshEditingStyle()
        return true
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

    /// The keys for marks and their style, chosen from the rail's menu, where the menu lists them.
    @objc func selectNextMark(_ sender: Any?) {
        _ = selectAdjacentMark(backward: false)
    }

    @objc func selectPreviousMark(_ sender: Any?) {
        _ = selectAdjacentMark(backward: true)
    }

    /// The color numbered by the item's tag, from 0.
    @objc func chooseKeyedColor(_ sender: NSMenuItem) {
        _ = chooseColor(at: sender.tag)
    }

    @objc func makeSmaller(_ sender: Any?) {
        _ = stepSize(by: -1)
    }

    @objc func makeLarger(_ sender: Any?) {
        _ = stepSize(by: 1)
    }

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

    /// ⌥⇧⌘S: a copy of the picture where and how the person chooses, in the Save panel.
    @objc public func saveScreenshotAs(_ sender: Any?) {
        onSaveAs?()
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

    /// Lock Canvas: the canvas stops growing to hold pictures combined and marks drawn past its edges.
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
        VoiceOver.announce(announcement, from: self, priority: .medium)
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
            return !isInPlace && IncomingPicture.isOffered(by: .general)
        case #selector(printCapture(_:)):
            return onPrint != nil
        case #selector(saveScreenshotAs(_:)):
            return onSaveAs != nil
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(flipHorizontal(_:)), #selector(flipVertical(_:)):
            return canTransformPicture
        case #selector(showImageSize(_:)):
            return canTransformPicture && onImageSize != nil
        case #selector(toggleCanvasLock(_:)):
            menuItem.state = session.locksCanvas ? .on : .off
            return !isInPlace
        case #selector(selectNextMark(_:)), #selector(selectPreviousMark(_:)):
            return editing == nil && !session.document.items.isEmpty && !session.tool.isPictureMode
        case #selector(chooseKeyedColor(_:)):
            return editing == nil && keyedColors.indices.contains(menuItem.tag)
        case #selector(makeSmaller(_:)), #selector(makeLarger(_:)):
            return editing == nil && (!session.selection.isEmpty || session.tool != .select) && session.sizeApplies
                && !StyleCapsule.sizes(for: session.currentKind).isEmpty
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
        if item.isTurned, case .text(let block) = item.shape {
            editing.turnedCorner = Annotation.turn(block.origin, about: item.pivot(scale: session.document.scale), by: item.angle)
        }
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

    /// Matches the editing field to the mark: same face, size, line height, and color. The field sets its
    /// text in the capture's pixels, as the mark's own layout does, and is scaled to the zoom as a whole
    /// (positionTextView): the system font spaces its letters by their size, so text set at the zoomed
    /// size would be wider or narrower than the mark, and break its lines elsewhere.
    private func styleTextView(for item: Annotation) {
        guard let view = editing?.view, case .text(let block) = item.shape else { return }
        let scale = session.document.scale
        let layout = Self.fieldLayout(of: block, scale: scale)
        let font = TextLayout.font(pointSize: CTFontGetSize(layout.font))
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = layout.lineHeight
        paragraph.maximumLineHeight = layout.lineHeight
        let ink: NSColor
        let fill = NSColor(cgColor: item.style.color.cgColor) ?? .systemRed
        view.outlineColor = nil
        view.labelFill = nil
        switch block.look {
        case .plain:
            ink = fill
        case .outlined:
            ink = fill
            view.outlineColor = item.style.color.prefersDarkOutline ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            view.outlineFontSize = block.fontSize * scale
            view.outlineWrapWidth = block.width
        case .label, .bubble:
            // A bubble is typed in on its plate; its tail shows again once typing ends.
            ink = item.style.color.prefersDarkInk ? NSColor(white: 0, alpha: 0.88) : .white
            view.labelFill = fill.cgColor
            view.labelCornerRadius = layout.cornerRadius
        }
        view.needsDisplay = true
        // The baseline sits where the renderer puts it: TextKit centers the font's box in a line taller
        // than the font, as the layout does.
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
        view.typingAttributes = attributes
        view.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        view.insertionPointColor = ink
        // Selected text keeps its ink; elsewhere than on a label the selection is the system selection
        // color at the strength text selection uses here.
        let dark = effectiveAppearance.isDark
        let wash = block.look.hasPlate ? Self.labelSelectionWash(on: item.style.color) : NSColor.selectedTextBackgroundColor.withAlphaComponent(dark ? 0.45 : 0.35)
        view.selectedTextAttributes = [.backgroundColor: wash, .foregroundColor: ink]
        view.textContainerInset = layout.inset
        view.textContainer?.lineFragmentPadding = 0
        // The field's frame follows the mark's layout (positionTextView), so it never sizes itself.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.minSize = .zero
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        // Wrapped where the mark's layout wraps.
        let wrap = block.width == nil ? CGFloat.greatestFiniteMagnitude : layout.textSize.width
        view.textContainer?.containerSize = CGSize(width: wrap, height: .greatestFiniteMagnitude)
        positionTextView()
    }

    /// The wash behind selected text on a label: opposite to the ink (light under dark ink, dark under
    /// white ink), so the label's color still shows and the text gains contrast rather than losing it.
    /// On a fill so near the wash's own shade that it would not show (white, black), it goes the ink's
    /// way instead.
    private static func labelSelectionWash(on fill: RGBA) -> NSColor {
        if fill.prefersDarkInk {
            return fill.luminance > 0.7 ? NSColor(white: 0, alpha: 0.16) : NSColor(white: 1, alpha: 0.35)
        }
        return fill.luminance < 0.1 ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.22)
    }

    /// Frames the field over the mark: laid out in the capture's pixels (its bounds) and scaled to the
    /// zoom (its frame).
    private func positionTextView() {
        guard let editing, let item = session.document.item(editing.id), case .text(let block) = item.shape else { return }
        let scale = session.document.scale
        let layout = Self.fieldLayout(of: block, scale: scale)
        let view = editing.view
        // A little room after the last character for the caret, outside a label (whose padding has it).
        let caret = block.width == nil && !block.look.hasPlate ? max(block.fontSize * scale * 0.6, 4 / zoom) : 0
        var size = CGSize(width: layout.size.width + caret, height: layout.size.height)
        // Should the field ever break a line where the mark's layout does not, its last line still shows.
        if let container = view.textContainer, let manager = view.layoutManager {
            manager.ensureLayout(for: container)
            size.height = max(size.height, ceil(manager.usedRect(for: container).maxY) + layout.inset.height * 2)
        }
        let origin = viewPoint(block.origin)
        view.frame = CGRect(x: origin.x, y: origin.y, width: size.width * zoom, height: size.height * zoom)
        view.bounds = CGRect(origin: .zero, size: size)
        onViewportChange?()
    }

    /// The layout a text mark's field follows: an empty one is laid out as a space, so its field keeps a
    /// line's height, its padding, and room for the caret before anything is typed.
    private static func fieldLayout(of block: TextBlock, scale: CGFloat) -> TextLayout {
        TextLayout(block.string.isEmpty ? TextBlock(origin: block.origin, string: " ", fontSize: block.fontSize, look: block.look, width: block.width) : block, scale: scale)
    }

    public func textDidChange(_ notification: Notification) {
        guard let editing, let index = session.document.index(of: editing.id), case .text(var block) = session.document.items[index].shape else { return }
        block.string = editing.view.string
        var document = session.document
        document.items[index].shape = .text(block)
        session.updateLive(document)
        positionTextView()
        editing.view.needsDisplay = true
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

    /// Finishes editing text: an empty text mark goes away, and a new one leaves no undo step. Text that
    /// was written puts the Text tool down, so the click that ended it does not start another.
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
                // What held the canvas out may be gone.
                session.fitCanvas(holding: [])
                session.endLiveChange(actionName: String(localized: "Delete", bundle: .module))
            }
        } else {
            if let corner = editing.turnedCorner, let index = session.document.index(of: editing.id),
               case .text(let block) = session.document.items[index].shape {
                let item = session.document.items[index]
                let now = Annotation.turn(block.origin, about: item.pivot(scale: session.document.scale), by: item.angle)
                var document = session.document
                var moved = item.translated(by: CGSize(width: corner.x - now.x, height: corner.y - now.y))
                // A bubble's tip stays on what it points at.
                if case .text(var placed) = moved.shape {
                    placed.tail = block.tail
                    moved.shape = .text(placed)
                }
                document.items[index] = moved
                session.updateLive(document)
            }
            session.fitCanvas(holding: [editing.id])
            session.endLiveChange(actionName: editing.isNew ? String(localized: "Add Text", bundle: .module) : String(localized: "Edit Text", bundle: .module))
            if session.tool == .text { session.putToolDown() }
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
            let dark = effectiveAppearance.isDark
            pictureLayer.borderWidth = Theme.PictureBorder.width(contrast: contrast)
            pictureLayer.borderColor = Theme.PictureBorder.color(dark: dark, contrast: contrast)
            selectionLayer.accent = NSColor.controlAccentColor.cgColor
            suggestions.applyAppearance(increasedContrast: contrast)
            backdropLayer.checker = Theme.Checkerboard.colors(dark: dark, increasedContrast: contrast)
            for layer in markLayers.values where layer.underlay?.surface?.fill == .clear {
                layer.underlay?.preview = backdropLayer.preview
            }
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
        // One count to a string, so each takes its language's plural: the marks in the label, the suggestions as its
        // value, which VoiceOver reads after it.
        setAccessibilityLabel(String(localized: "Capture, \(count) marks", bundle: .module))
        setAccessibilityValue(suggestions > 0 ? String(localized: "\(suggestions) suggestions to redact", bundle: .module) : nil)
    }
}

/// Hosts the canvas's layers with the view's own y-down coordinates: AppKit keeps a flipped view's
/// layer geometry flipped, where a flag set by hand on a hosted layer can be reset.
final class FlippedHostView: NSView {
    override var isFlipped: Bool { true }
}
