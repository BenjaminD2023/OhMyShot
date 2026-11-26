import AppKit
import OMSCore
import OMSDesign
import QuartzCore

/// Annotation in place, over the capture overlay: the frozen screen stays where it is, the selection
/// keeps a frame whose corners and edges resize it, marks are drawn on the screen itself at its own
/// size, and a small toolbar and the style capsule stand beside the selection.
///
/// The document is the whole display's frozen frame and the selection is its canvas, so moving or
/// resizing the selection is a change of canvas that Undo takes back, and marks stay where they were
/// drawn on the screen. With no tool in hand the selection itself is adjusted: drag inside it to move
/// it, drag its corners or edges to resize it, double-click it to copy.
public final class InPlaceAnnotationView: NSView {
    /// The marked selection: the selection as captured, and the marks re-based to its own pixels.
    public struct Result {
        public let capture: CGImage
        public let document: AnnotationDocument
        /// Where the selection ended up, after any moving or resizing, in points from the display's
        /// top-left corner.
        public let area: CGRect
    }

    public struct Actions {
        public var copy: (Result) -> Void
        public var save: (Result) -> Void
        public var openInEditor: (Result) -> Void
        public var cancel: () -> Void
        /// Keeps the marked selection and pins it over the area; nil leaves Pin off the toolbar.
        public var pin: ((Result) -> Void)?
        /// Keeps the marked selection and uploads it; nil, as without a destination, leaves Upload off the toolbar.
        public var upload: ((Result) -> Void)?

        public init(copy: @escaping (Result) -> Void, save: @escaping (Result) -> Void, openInEditor: @escaping (Result) -> Void, cancel: @escaping () -> Void) {
            self.copy = copy
            self.save = save
            self.openInEditor = openInEditor
            self.cancel = cancel
        }
    }

    public let session: AnnotationSession
    /// While a corner or edge of the selection is dragged: the point (this view's points) of the pixel just inside
    /// where the dragged edges meet, for a magnifier over the frozen screen; nil once the drag ends.
    public var onEdgeDrag: ((CGPoint?) -> Void)?
    /// Finds the QR codes and barcodes in the selection, for chips over them; set before `begin`.
    public var codeFinder: CodeFinder?
    let canvas: AnnotationCanvasView
    private let chrome = SelectionChromeView()
    let codeChips = CodeChipsView(wording: .standard)
    private var codeScan: Task<Void, Never>?
    /// The canvas (pixels) the chips were last looked for in, so only a change of selection looks again.
    private var scannedCanvas: CGRect?
    let toolbar: InPlaceToolbar
    let capsule = StyleCapsule()
    private let actions: Actions
    private var adjustment: Adjustment?
    private var finished = false
    private var discard = InPlaceDiscardConfirmation()
    private var discardHint: Task<Void, Never>?
    enum PlacementZone: Equatable {
        case below
        case above
        case inside
    }

    private(set) var placementZone: PlacementZone?
    /// What the capsule was last shown for, so a new tool or selection fades it in.
    private var capsuleAnchor: String?

    private enum Adjustment {
        case moving(start: CGPoint, original: CGRect)
        /// `grip` is how far the handle lay from the press, so the edge moves with the pointer.
        case resizing(handle: Handle, original: CGRect, grip: CGVector)
        case selecting(start: CGPoint)
    }

    /// How close to the selection's edge a press resizes it, in points.
    private static let edgeReach: CGFloat = 6
    private static let cornerReach: CGFloat = 12
    /// The smallest selection, in points.
    private static let smallest: CGFloat = 8

    /// - Parameters:
    ///   - image: the display's frozen frame.
    ///   - scale: pixels per point of the display.
    ///   - size: the display's size in points, which this view covers.
    ///   - selection: the chosen area, in points from the display's top-left corner.
    public init(frame image: CGImage, scale: CGFloat, size: CGSize, selection: CGRect, actions: Actions) {
        var document = AnnotationDocument(pixelSize: CGSize(width: image.width, height: image.height), scale: scale)
        document.canvas = Self.pixels(selection, scale: scale, within: document.imageBounds)
        session = AnnotationSession(image: image, scale: scale, document: document, tool: .select)
        canvas = AnnotationCanvasView(session: session)
        toolbar = InPlaceToolbar(offersPin: actions.pin != nil, offersUpload: actions.upload != nil)
        self.actions = actions
        super.init(frame: CGRect(origin: .zero, size: size))
        canvas.configureInPlace()
        addSubview(canvas)
        addSubview(chrome)
        addSubview(codeChips)
        addSubview(capsule)
        addSubview(toolbar)
        capsule.alphaValue = 0
        // A web page a code points to opens once the overlay has gone, which would cover it: offered only while
        // nothing is drawn, as ending the capture would throw the marks away.
        codeChips.onOpen = { [weak self] url in
            self?.perform(.cancel)
            NSWorkspace.shared.open(url)
        }
        codeChips.canOpenLinks = { [weak self] in self?.session.document.items.isEmpty ?? false }
        codeChips.onCardClosed = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(canvas)
        }

        toolbar.onTool = { [weak self] tool in self?.choose(tool) }
        toolbar.onLockTool = { [weak self] tool in self?.lock(tool) }
        toolbar.onAction = { [weak self] action in self?.perform(action) }
        // A color kept here shows in the capsule at once.
        capsule.bind(to: session, canvas: canvas) { [weak self] in self?.refreshCapsule() }
        canvas.onCopy = { [weak self] in self?.perform(.copy) }
        canvas.onSave = { [weak self] in self?.perform(.save) }
        canvas.onUndoStateChange = { [weak self] in self?.undoChanged() }
        canvas.onViewportChange = { [weak self] in self?.placeAccessories() }
        canvas.onRightClickAway = { [weak self] in self?.backOut() }
        canvas.cursorOverride = { [weak self] point in
            guard let self else { return nil }
            return cursor(at: convert(point, from: canvas), overCanvas: true)
        }
        session.observe { [weak self] event in self?.sessionChanged(event) }
        toolbar.select(nil)
        layoutSelection()
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Mark Up Selection", bundle: .module))
        setAccessibilityHelp(String(localized: "Choose a tool and draw on the selection. Press Return to copy it, or Escape to cancel.", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        discardHint?.cancel()
        codeScan?.cancel()
        capsule.releaseColorPanel()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, window != nil {
            clearDiscardHint()
            clearCodes()
            capsule.releaseColorPanel()
        }
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Takes the keyboard: the canvas answers tool keys, Delete, the arrows, and Undo; Return and Escape
    /// fall through to this view.
    public func begin() {
        window?.makeFirstResponder(canvas)
        VoiceOver.announce(String(localized: "Mark up the selection. Press Return to copy it, or Escape to cancel.", bundle: .module), from: self)
        refreshCodes()
    }

    // MARK: Codes

    /// Looks for QR codes and barcodes in the selection when it is not the one last looked at, for chips over them,
    /// when Settings want them. Chips for another selection go at once; the new ones come when the look is done.
    private func refreshCodes() {
        let document = session.document
        let pixels = document.canvas.standardized.integral.intersection(document.imageBounds)
        guard let finder = codeFinder, finder.isOn() else {
            clearCodes()
            scannedCanvas = nil
            return
        }
        guard pixels != scannedCanvas else { return }
        scannedCanvas = pixels
        clearCodes()
        guard !pixels.isNull, pixels.width >= 16, pixels.height >= 16, let picture = session.base.cropping(to: pixels) else { return }
        let scale = document.scale
        codeScan = Task { [weak self] in
            let found = await finder.find(picture)
            guard !Task.isCancelled, let self, self.scannedCanvas == pixels else { return }
            let codes = found.map { code in
                CodeChipsView.Code(
                    box: CGRect(
                        x: (pixels.minX + code.box.minX) / scale, y: (pixels.minY + code.box.minY) / scale,
                        width: code.box.width / scale, height: code.box.height / scale
                    ),
                    isMatrix: code.isMatrix, payload: code.payload, link: code.webURL
                )
            }
            self.codeChips.show(codes, in: self.selectionRect)
            self.updateCodeChipsVisibility()
            if !codes.isEmpty { VoiceOver.announce(CodeChipWording.found(codes.count), from: self, priority: .medium) }
        }
    }

    private func clearCodes() {
        codeScan?.cancel()
        codeScan = nil
        codeChips.clear()
    }

    /// The chips show only while the selection is as it is and nothing is being drawn or typed: a mark drawn to point
    /// at a chip would be copied without it.
    private func updateCodeChipsVisibility() {
        let hidden = session.tool != .select || adjustment != nil || canvas.isDragging || canvas.isEditingText
        if hidden { codeChips.dismissCard() }
        codeChips.isHidden = hidden
    }

    // MARK: Geometry

    /// The selection in this view's points.
    var selectionRect: CGRect {
        let canvas = session.document.canvas.standardized
        let scale = session.document.scale
        return CGRect(x: canvas.minX / scale, y: canvas.minY / scale, width: canvas.width / scale, height: canvas.height / scale)
    }

    /// Points from the display's top-left corner to whole pixels of its frame.
    static func pixels(_ rect: CGRect, scale: CGFloat, within bounds: CGRect) -> CGRect {
        let rect = rect.standardized
        let minX = (rect.minX * scale).rounded()
        let minY = (rect.minY * scale).rounded()
        let maxX = (rect.maxX * scale).rounded()
        let maxY = (rect.maxY * scale).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    private func layoutSelection() {
        let rect = selectionRect
        if canvas.frame != rect {
            canvas.frame = rect
            // Laid out now, not on the next pass, so the marks never sit a frame off the screen under them.
            canvas.layoutSubtreeIfNeeded()
        }
        chrome.frame = bounds
        codeChips.frame = bounds
        chrome.selection = rect
        let pixels = session.document.canvas.standardized
        if discard.deadline == nil { chrome.reading = "\(Int(pixels.width)) × \(Int(pixels.height))" }
        setAccessibilityValue(String(localized: "\(Int(pixels.width)) × \(Int(pixels.height)) pixels", bundle: .module))
        placeAccessories()
    }

    /// The toolbar 10 pt below the selection and the style capsule 6 pt below it, both against the
    /// selection's right edge; above the selection without room below, inside its bottom without room
    /// either way, and always on the display. The side is chosen with room for the capsule whether it
    /// shows or not, so the toolbar never jumps when a tool is picked. The toolbar hides while the
    /// selection is adjusted, the capsule also while a mark is drawn.
    private func placeAccessories() {
        let selection = selectionRect
        let bar = toolbar.fittingSize
        let showsCapsule = !(session.currentKind == .select && session.selection.isEmpty)
        let pill = capsule.fittingSize
        let gap: CGFloat = 10
        let between: CGFloat = 6
        let stack = bar.height + between + StyleCapsule.height
        let margin: CGFloat = 8
        let fitsBelow = selection.maxY + gap + stack <= bounds.maxY - margin
        let fitsAbove = selection.minY - gap - stack >= bounds.minY + margin
        var barX = min(max(selection.maxX - bar.width, margin), bounds.maxX - margin - bar.width)
        var barY: CGFloat
        var capsuleY: CGFloat
        let newZone: PlacementZone
        if fitsBelow {
            newZone = .below
            barY = selection.maxY + gap
            capsuleY = barY + bar.height + between
        } else if fitsAbove {
            newZone = .above
            barY = selection.minY - gap - bar.height
            capsuleY = barY - between - pill.height
        } else {
            newZone = .inside
            // Inside the selection: 10 pt clear of the frame as drawn, which steps in at the display's edge.
            let drawn = SelectionChromeView.drawnFrame(for: selection, in: bounds)
            barY = drawn.maxY - gap - bar.height
            capsuleY = barY - between - pill.height
            barX = min(max(drawn.maxX - gap - bar.width, margin), bounds.maxX - margin - bar.width)
        }
        barY = min(max(barY, margin), bounds.maxY - margin - bar.height)
        let targetToolbarFrame = CGRect(x: barX, y: barY, width: bar.width, height: bar.height).integral
        // Against the toolbar's right edge, wherever the toolbar went.
        let capsuleX = min(max(targetToolbarFrame.maxX - pill.width, margin), bounds.maxX - margin - pill.width)
        let targetCapsuleFrame = CGRect(x: capsuleX, y: capsuleY, width: pill.width, height: pill.height).integral
        let zoneFlipped = placementZone != nil && placementZone != newZone
        placementZone = newZone
        if zoneFlipped, adjustment == nil, !toolbar.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toolbar.animator().frame = targetToolbarFrame
                capsule.animator().frame = targetCapsuleFrame
            }
        } else {
            toolbar.frame = targetToolbarFrame
            capsule.frame = targetCapsuleFrame
        }
        // The size reading steps aside for the toolbar and capsule when they stand above the selection.
        chrome.avoiding = showsCapsule ? targetToolbarFrame.union(targetCapsuleFrame) : targetToolbarFrame
        chrome.toolbarFrame = targetToolbarFrame
        toolbar.isHidden = adjustment != nil
        updateCodeChipsVisibility()
        let visible = showsCapsule && adjustment == nil && !canvas.isDragging
        let anchor = "\(session.currentKind.rawValue)|\(session.selection.map(\.uuidString).joined())"
        let fades = visible && (capsule.alphaValue == 0 || anchor != capsuleAnchor)
        capsuleAnchor = visible ? anchor : nil
        if !visible {
            capsule.alphaValue = 0
        } else if fades, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // As in the editor: a new tool or selection fades the capsule in; nothing else moves it.
            capsule.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.fade
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                capsule.animator().alphaValue = 1
            }
        } else {
            capsule.alphaValue = 1
        }
    }

    // MARK: Session

    private func sessionChanged(_ event: AnnotationSession.Event) {
        switch event {
        case .document, .selection, .settings, .tool: clearDiscardHint()
        case .history, .suggestions, .textLines: break
        }
        switch event {
        case .document:
            layoutSelection()
            // The selection changed by Undo or Redo is looked at again; a drag looks once it ends.
            if adjustment == nil { refreshCodes() }
            if !session.selection.isEmpty || session.tool == .counter || capsule.countsStaleSuggestions(of: session) { refreshCapsule() }
        case .selection, .settings:
            refreshCapsule()
        case .tool:
            toolbar.select(session.tool == .select ? nil : session.tool, locked: session.isToolLocked)
            refreshCapsule()
            window?.invalidateCursorRects(for: self)
        case .history:
            undoChanged()
        case .suggestions:
            if session.tool == .redact || session.currentKind == .redact { refreshCapsule() }
        case .textLines:
            if session.tool == .highlighter { refreshCapsule() }
        }
    }

    private func undoChanged() {
        let manager = canvas.activeUndoManager
        toolbar.canUndo = manager.canUndo
        toolbar.canRedo = manager.canRedo
    }

    private func refreshCapsule() {
        capsule.refresh(from: session, canvas: canvas)
        placeAccessories()
    }

    /// The chip of the tool in hand puts it down again: the selection itself or its marks are adjusted then.
    private func choose(_ tool: AnnotationTool) {
        clearDiscardHint()
        if tool == .select {
            session.tool = .select
        } else {
            session.tool = session.tool == tool ? .select : tool
        }
        window?.makeFirstResponder(canvas)
    }

    private func lock(_ tool: AnnotationTool) {
        guard tool.isPutDownAfterMark else { return }
        clearDiscardHint()
        if session.tool == tool, session.isToolLocked {
            session.isToolLocked = false
            VoiceOver.announce(String(localized: "\(tool.name) unlocked", bundle: .module), from: toolbar)
        } else {
            session.lockTool(tool)
            VoiceOver.announce(String(localized: "\(tool.name) locked", bundle: .module), from: toolbar)
        }
        window?.makeFirstResponder(canvas)
    }

    private func perform(_ action: InPlaceToolbar.Action) {
        if action != .cancel { clearDiscardHint() }
        switch action {
        case .undo:
            canvas.undo(nil)
        case .redo:
            canvas.redo(nil)
        case .cancel:
            canvas.endEditing()
            if discard.mayDiscard(hasMarks: hasMarks) {
                finish { $0.cancel() }
            } else if let deadline = discard.deadline {
                let hint = String(localized: "Press Esc again or click Cancel to discard your marks.", bundle: .module)
                chrome.reading = hint
                VoiceOver.announce(hint, from: self)
                discardHint?.cancel()
                discardHint = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    self?.clearDiscardHint()
                }
            }
        case .copy:
            finish(with: actions.copy)
        case .save:
            finish(with: actions.save)
        case .openInEditor:
            finish(with: actions.openInEditor)
        case .pin:
            if let pin = actions.pin { finish(with: pin) }
        case .upload:
            if let upload = actions.upload { finish(with: upload) }
        }
    }

    /// Whether any marks are drawn: what Escape and Cancel ask about before throwing them away.
    var hasMarks: Bool {
        !session.document.items.isEmpty
    }

    /// Finishes as Open in Editor does when the overlay has to go without being asked to (its display changed), so marks
    /// are kept rather than thrown away. A text mark being written ends first, and an empty one goes, as it does when
    /// its editing ends; with no marks left nothing is done, and the overlay is cancelled as before.
    public func openInEditorIfMarked() {
        canvas.endEditing()
        guard hasMarks else { return }
        perform(.openInEditor)
    }

    private func clearDiscardHint() {
        guard discard.deadline != nil || discardHint != nil else { return }
        discard = InPlaceDiscardConfirmation()
        discardHint?.cancel()
        discardHint = nil
        let pixels = session.document.canvas.standardized
        chrome.reading = "\(Int(pixels.width)) × \(Int(pixels.height))"
    }

    private func finish(with action: (Result) -> Void) {
        guard let result = result() else {
            NSSound.beep()
            return
        }
        finish { (_: Actions) in action(result) }
    }

    private func finish(_ body: (Actions) -> Void) {
        guard !finished else { return }
        finished = true
        clearDiscardHint()
        clearCodes()
        capsule.releaseColorPanel()
        canvas.endEditing()
        body(actions)
    }

    /// The selection as captured, copied out of the frame so the whole display's pixels are not kept
    /// for its sake, and the marks moved into its own pixels.
    func result() -> Result? {
        canvas.endEditing()
        let document = session.document
        let pixels = document.canvas.standardized.integral.intersection(document.imageBounds)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, let cropped = session.base.cropping(to: pixels) else { return nil }
        let space = session.base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(cropped, in: CGRect(origin: .zero, size: pixels.size))
        guard let capture = context.makeImage() else { return nil }
        var marks = AnnotationDocument(pixelSize: pixels.size, scale: document.scale)
        marks.items = document.items.map { $0.translated(by: CGSize(width: -pixels.minX, height: -pixels.minY)) }
        let scale = document.scale
        let area = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        return Result(capture: capture, document: marks, area: area)
    }

    // MARK: Input

    /// Presses on the selection's frame, with Space held inside it, or with no tool in hand on its empty
    /// inside before any marks are drawn, adjust the selection here; everything else goes to the canvas,
    /// the toolbar, and the capsule.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === toolbar || hit.isDescendant(of: toolbar) || hit === capsule || hit.isDescendant(of: capsule) { return hit }
        // The code chips answer only over a chip or the card, or anywhere while a card is open, to close it.
        if hit === codeChips || hit.isDescendant(of: codeChips) { return hit }
        let local = convert(point, from: superview)
        if canvas.isEditingText, hit !== self, hit.isDescendant(of: canvas) { return hit }
        if handle(at: local, toolInHand: session.tool != .select) != nil { return self }
        if hit === canvas || hit.isDescendant(of: canvas) {
            if canvas.isSpaceHeld { return self }
            if session.tool == .select, session.document.items.isEmpty, canvas.mark(at: convert(local, to: canvas)) == nil { return self }
            return hit
        }
        return self
    }

    /// The handle of the selection's frame under a point: its corners and edges. The reach shrinks with
    /// a small selection so its inside stays reachable; with a tool in hand only presses on the frame's
    /// line or outside it resize, so drawing runs right up to the edge.
    private func handle(at point: CGPoint, toolInHand: Bool = false) -> Handle? {
        // Measured from the frame as drawn, so a press on the white line resizes even where it steps in.
        let rect = SelectionChromeView.drawnFrame(for: selectionRect, in: bounds)
        if toolInHand, rect.insetBy(dx: 1.5, dy: 1.5).contains(point) { return nil }
        let cornerReach = min(Self.cornerReach, rect.width / 4, rect.height / 4)
        let edgeReach = min(Self.edgeReach, rect.width / 6, rect.height / 6)
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)), (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        ]
        if let corner = corners.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= max(cornerReach, 4) }) {
            return corner.0
        }
        let insideX = point.x > rect.minX && point.x < rect.maxX
        let insideY = point.y > rect.minY && point.y < rect.maxY
        let reach = max(edgeReach, 3)
        if insideX, abs(point.y - rect.minY) <= reach { return .top }
        if insideX, abs(point.y - rect.maxY) <= reach { return .bottom }
        if insideY, abs(point.x - rect.minX) <= reach { return .left }
        if insideY, abs(point.x - rect.maxX) <= reach { return .right }
        return nil
    }

    private func cursor(at point: CGPoint, overCanvas: Bool) -> NSCursor? {
        if let handle = handle(at: point, toolInHand: session.tool != .select) {
            return switch handle {
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
        if canvas.isSpaceHeld, selectionRect.contains(point) {
            return .openHand
        }
        if session.tool == .select, selectionRect.contains(point) {
            if session.document.items.isEmpty {
                return overCanvas && canvas.mark(at: convert(point, to: canvas)) != nil ? nil : .openHand
            }
            return nil
        }
        return overCanvas ? nil : (session.document.items.isEmpty ? .crosshair : .arrow)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
    }

    public override func cursorUpdate(with event: NSEvent) {
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        guard adjustment == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Over the canvas, the canvas asks this view first.
        guard !canvas.frame.contains(point) || handle(at: point, toolInHand: session.tool != .select) != nil else { return }
        (cursor(at: point, overCanvas: false) ?? .arrow).set()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(canvas)
        let point = convert(event.locationInWindow, from: nil)
        let rect = selectionRect
        if let handle = handle(at: point, toolInHand: session.tool != .select) {
            // Held by the line as drawn, which steps in where the selection meets the display's edge.
            let line = SelectionChromeView.drawnFrame(for: rect, in: bounds)
            begin(.resizing(handle: handle, original: rect, grip: Geometry.grip(of: handle, on: line, pressedAt: point)))
            showEdgeLoupe(for: handle, near: point)
        } else if rect.contains(point) {
            if event.clickCount == 2, session.document.items.isEmpty {
                perform(.copy)
                return
            }
            begin(.moving(start: point, original: rect))
            NSCursor.closedHand.set()
        } else if session.document.items.isEmpty {
            // Nothing drawn yet: a drag outside chooses a new area.
            begin(.selecting(start: point))
        } else {
            session.select([])
        }
    }

    private func begin(_ adjustment: Adjustment) {
        session.select([])
        session.beginLiveChange()
        self.adjustment = adjustment
        // The chips are for the selection as it was; it is looked at again once the drag ends.
        clearCodes()
        scannedCanvas = nil
        chrome.showsThirds = true
        placeAccessories()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let adjustment else { return }
        let point = convert(event.locationInWindow, from: nil)
        let limits = bounds
        var rect: CGRect
        switch adjustment {
        case .moving(let start, let original):
            rect = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            // Moved whole, kept on the display.
            rect.origin.x = min(max(rect.minX, limits.minX), limits.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, limits.minY), limits.maxY - rect.height)
        case .resizing(let handle, let original, let grip):
            // The edge where the pointer took hold of it, then held to the display.
            let held = CGPoint(x: point.x + grip.dx, y: point.y + grip.dy)
            let clamped = CGPoint(x: min(max(held.x, limits.minX), limits.maxX), y: min(max(held.y, limits.minY), limits.maxY))
            rect = Geometry.resized(original, dragging: handle, to: clamped, keepingAspect: event.modifierFlags.contains(.shift))
        case .selecting(let start):
            let clamped = CGPoint(x: min(max(point.x, limits.minX), limits.maxX), y: min(max(point.y, limits.minY), limits.maxY))
            rect = Geometry.rect(from: start, to: clamped, square: event.modifierFlags.contains(.shift))
        }
        rect = rect.intersection(limits)
        guard !rect.isNull, rect.width >= Self.smallest, rect.height >= Self.smallest else { return }
        var document = session.document
        document.canvas = Self.pixels(rect, scale: document.scale, within: document.imageBounds)
        session.updateLive(document)
        if case .resizing(let handle, _, _) = adjustment { showEdgeLoupe(for: handle, near: point) }
    }

    /// The magnifier on the pixel just inside where the dragged edges of the selection, as it is now, meet.
    private func showEdgeLoupe(for handle: Handle, near pointer: CGPoint) {
        let pixel = 1 / max(session.document.scale, 1)
        onEdgeDrag?(Geometry.edgePoint(of: handle, on: selectionRect, near: pointer, pixel: pixel))
    }

    public override func mouseUp(with event: NSEvent) {
        guard let adjustment else { return }
        self.adjustment = nil
        chrome.showsThirds = false
        onEdgeDrag?(nil)
        let name = switch adjustment {
        case .moving: String(localized: "Move Selection", bundle: .module)
        case .resizing: String(localized: "Resize Selection", bundle: .module)
        case .selecting: String(localized: "Select Area", bundle: .module)
        }
        session.endLiveChange(actionName: name)
        refreshCodes()
        placeAccessories()
        updateCursor(event)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// A right-click on the frame, outside it, or on the canvas away from the marks (marks keep their own menu).
    public override func rightMouseDown(with event: NSEvent) {
        backOut()
    }

    /// Backs out one step, as Escape does, but never throws marks away: a text being typed is finished, then the tool
    /// in hand is put down, then the selected marks are let go, and only a selection with nothing drawn on it is
    /// cancelled. With marks drawn the last step is Escape's, or the toolbar's.
    func backOut() {
        guard adjustment == nil, !finished else { return }
        clearDiscardHint()
        if canvas.isEditingText {
            canvas.endEditing()
        } else if session.tool != .select {
            session.tool = .select
        } else if !session.selection.isEmpty {
            session.select([])
        } else if session.document.items.isEmpty {
            perform(.cancel)
        }
    }

    /// ⌘E opens the marked selection in the editor; ⇧⌘P pins and ⇧⌘U uploads, as on a card, Caps Lock on or off;
    /// the tools keep their plain letters (P is the Pen).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "e", !canvas.isEditingText, !codeChips.isShowingCard {
            perform(.openInEditor)
            return true
        }
        guard flags == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p" where actions.pin != nil:
            perform(.pin)
        case "u" where actions.upload != nil:
            perform(.upload)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode != 53 { clearDiscardHint() }
        switch event.keyCode {
        case 53:
            guard !event.isARepeat else { return }
            // Reached once the canvas has nothing of its own to cancel: a code's open card goes first, then
            // an adjustment in progress, then the tool in hand is put down, and only then is the whole
            // thing cancelled.
            if codeChips.isShowingCard {
                codeChips.dismissCard()
            } else if adjustment != nil {
                adjustment = nil
                chrome.showsThirds = false
                onEdgeDrag?(nil)
                session.cancelLiveChange()
                placeAccessories()
            } else if session.tool != .select {
                session.tool = .select
            } else {
                perform(.cancel)
            }
        case 36, 76:
            perform(.copy)
        default:
            // Q goes through the codes' cards, one after another: the keyboard's way to the chips.
            if event.charactersIgnoringModifiers?.lowercased() == "q", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               !codeChips.isHidden, codeChips.openNextCard() { return }
            super.keyDown(with: event)
        }
    }

    // MARK: Debug

    #if DEBUG
    /// Drags with synthesized events, from and to points in this view, as a pointer would: on the
    /// selection's frame or inside it with no tool to adjust it, else on the canvas.
    public func simulateDrag(from start: CGPoint, to end: CGPoint, steps: Int = 8, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        guard let window else { return }
        let target = hitTest(convert(start, to: superview)) ?? self
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            )
        }
        if let down = event(.leftMouseDown, at: start) { target.mouseDown(with: down) }
        for step in 1...max(steps, 1) {
            let fraction = CGFloat(step) / CGFloat(max(steps, 1))
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            if let drag = event(.leftMouseDragged, at: point) { target.mouseDragged(with: drag) }
        }
        if let up = event(.leftMouseUp, at: end) { target.mouseUp(with: up) }
    }

    /// Presses a key as the keyboard would: plain keys go to the first responder, ⌘ keys through the
    /// window and then down the responder chain as the menu sends them.
    public func simulateKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { return }
        if modifiers.contains(.command) {
            if window.performKeyEquivalent(with: event) { return }
            let action: Selector? = switch characters.lowercased() {
            case "z": modifiers.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            case "c": #selector(NSText.copy(_:))
            case "s": #selector(NSDocument.save(_:))
            default: nil
            }
            if let action { NSApp.sendAction(action, to: nil, from: self) }
        } else {
            window.firstResponder?.keyDown(with: event)
        }
    }

    /// Types into the text mark being edited.
    public func simulateTyping(_ text: String) {
        (window?.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Presses a toolbar action as its chip would.
    public func simulateAction(_ name: String) {
        // Not a toolbar action: opens the first code's card, as its chip would, for a snapshot of it.
        if name == "openCodeCard", let payload = codeChips.shownPayloads.first { return codeChips.debugOpenCard(for: payload) }
        guard let action = InPlaceToolbar.Action.allCases.first(where: { "\($0)" == name }) else { return }
        perform(action)
    }

    /// A summary for scripted checks.
    public var debugSummary: String {
        let marks = session.document.items.map { item -> String in
            if case .textHighlight(let highlight) = item.shape { return "textHighlight(\(highlight.rects.map { NSStringFromRect($0) }.joined(separator: "|")))" }
            return AnnotationSession.tool(for: item).rawValue
        }.joined(separator: ",")
        return "codes=[\(codeChips.isHidden ? "hidden" : codeChips.shownPayloads.joined(separator: "|"))] selection=\(NSStringFromRect(selectionRect)) canvas=\(NSStringFromRect(session.document.canvas)) tool=\(session.tool.rawValue) marks=[\(marks)] toolbar=\(NSStringFromRect(toolbar.frame)) capsule=\(capsule.alphaValue > 0 ? NSStringFromRect(capsule.frame) : "hidden") undo=\(session.undoManager.canUndo ? session.undoManager.undoActionName : "-") canvasZoom=\(canvas.zoom) canvasPicture=\(NSStringFromRect(canvas.pictureFrame)) suggestions=\(session.isFindingRedactions ? "finding" : session.couldNotFindRedactions ? "failed" : "\(session.openRedactionSuggestions.count)") textlines=\(session.isFindingTextLines ? "finding" : session.couldNotFindTextLines ? "failed" : "\(session.textLines.count)")"
    }
    #endif
}

extension CodeChipsView.Wording {
    /// The words of the chips over a selection's codes, as Core says them for every place that shows them.
    static var standard: Self {
        Self(
            qrCode: CodeChipWording.qrCode, barcode: CodeChipWording.barcode, codes: CodeChipWording.codes,
            copy: CodeChipWording.copy, openLink: CodeChipWording.openLink, copied: CodeChipWording.copied
        )
    }
}
