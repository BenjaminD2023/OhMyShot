import AppKit
import CoreGraphics
import OMSCore
import QuartzCore

protocol OverlayViewDelegate: AnyObject {
    /// A press in area mode, at a point in global space: a selection begins. The selection is the
    /// controller's, shared by every display, since a drag may carry it onto another one.
    func overlayView(_ view: OverlayView, didPressAt point: CGPoint)
    /// The pointer dragged on, perhaps onto another display.
    func overlayView(_ view: OverlayView, didDragTo point: CGPoint, modifiers: NSEvent.ModifierFlags)
    /// The press ended; `modifiers` are the keys held then.
    func overlayView(_ view: OverlayView, didReleaseWith modifiers: NSEvent.ModifierFlags)
    /// Shift or Option changed; the key view hears it, wherever the drag is.
    func overlayView(_ view: OverlayView, didChangeModifiers modifiers: NSEvent.ModifierFlags)
    /// The pointer moved, wherever it is: the key panel hears every move, even over another display.
    func overlayView(_ view: OverlayView, didMovePointerTo point: CGPoint)
    /// Space went down: it moves a selection being dragged, or else switches modes.
    func overlayView(_ view: OverlayView, didPressSpace isRepeat: Bool)
    func overlayViewDidReleaseSpace(_ view: OverlayView)
    /// The whole display, chosen with the All-In-One bar.
    func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags)
    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags)
    func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode)
    func overlayViewDidCancel(_ view: OverlayView)
    /// A color taken at a point in global space (a click, Return, or C), with the keys held then; `keyboard`
    /// says it was a key, so what follows can take the keyboard too.
    func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool)
    /// The arrow keys moved the crosshair by whole pixels, down positive: the corner being dragged, when an area is
    /// being dragged out.
    func overlayView(_ view: OverlayView, didNudge pixels: CGVector)
    /// Tab: the area being chosen (or one around the crosshair) is framed for a size typed and a shape kept.
    func overlayViewDidRequestSizing(_ view: OverlayView)
    /// The ruler's measurement, to copy; `ending` closes the overlay after it (Return).
    func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool)
    func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit)
    func overlayView(_ view: OverlayView, didChangeTolerance tolerance: MeasureTolerance)
    /// All-In-One's bar or keys chose what the next area is for: its text, a scrolling capture, or a recording.
    func overlayView(_ view: OverlayView, didChooseMode choice: AllInOneChoice)
}

/// The capture overlay on one display: a lightly dimmed screen, the selection with its size, a small
/// crosshair, a magnifier for exact placement, and the All-In-One bar. Picking a color and measuring use
/// the same overlay, undimmed: the magnifier, or the ruler.
///
/// Everything is a layer whose geometry changes on input, with implicit animations off, so the overlay
/// never trails the pointer.
final class OverlayView: NSView {
    enum Mode: Sendable {
        /// Drag out a region.
        case area
        /// Click a window; the selection snaps to whichever window is under the pointer.
        case window
    }

    weak var delegate: OverlayViewDelegate?
    let display: DisplayInfo

    private(set) var mode: Mode = .area
    private var windows: [WindowTarget] = []
    private var hoveredWindow: WindowTarget?
    /// The controller's selection, of which this display draws its part.
    private var selection: SelectionModel
    /// Whether this display shows the selection's size: only one does.
    private var showsReading = false
    private var capturedFrame: CapturedFrame?
    private var pointer: CGPoint?
    /// Every display receives the first area press, even before the selection has any size. Once it
    /// begins, the actual-size lens stays out of the way, the crosshair staying, until a click with no drag
    /// leaves no selection or a new capture session resets the view.
    private var hasStartedAreaSelection = false
    private var captureLoupeStyle: CaptureLoupeStyle = .magnified
    private var captureLoupeSize: CaptureLoupeSize = .small
    /// Set by `simulate`, so the real (hidden) pointer cannot move a scripted render.
    private var isSimulated = false
    /// In-place annotation has the display: its interface takes the input and draws the selection.
    private(set) var isAnnotating = false
    /// An All-In-One session: its modes on the bar, its letter keys.
    private(set) var isAllInOne = false
    private var increasedContrast = false

    private let backdrop = CALayer()
    private let room = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let border = CAShapeLayer()
    /// The edges of the selection that snapped to text, drawn over `border` in the accent.
    private let snapEdges = CAShapeLayer()
    private let sizePill = ReadingCapsule()
    private let crosshairOutline = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let loupeShadow = CAShapeLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeCenter = CAShapeLayer()
    /// An opposite-color outline keeps the adaptive center cell visible over neighboring pixels.
    private let loupeCenterOutline = CAShapeLayer()
    private static let reticleWhite = ScreenColor(srgbRed: 1, green: 1, blue: 1)!
    private static let reticleBlack = ScreenColor(srgbRed: 0, green: 0, blue: 0)!
    private let loupeRim = CAShapeLayer()
    private let loupePill = ReadingCapsule(showsSwatch: true)
    private let toolbar = AllInOneBar()
    /// Copying text gets a lighter overlay than a screenshot: no dimming, no magnifier or readings, the
    /// system crosshair, and a selection drawn like selected text.
    private var purpose: OverlayController.Purpose = .screenshot
    /// The notation picked colors are copied in, which the magnifier's reading shows while picking.
    private var colorFormat: ColorFormat = .hex
    /// The ruler, while measuring.
    private var measure: MeasureOverlay?

    init(display: DisplayInfo) {
        self.display = display
        selection = SelectionModel(bounds: display.frame, pixelsPerPoint: display.pixelsPerPoint)
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        let root = CALayer()
        root.contentsScale = display.backingScale
        layer = root
        wantsLayer = true
        buildLayers()
        toolbar.onSelect = { [weak self] choice in self?.toolbarChose(choice) }
        toolbar.isHidden = true
        addSubview(toolbar)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Capture overlay", bundle: .module))
        setAccessibilityHelp(String(localized: "Drag to capture an area. Press Space to capture a window instead. Press Escape to cancel.", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - State

    /// Starts a fresh session with the pointer at `globalPointer`. The All-In-One bar shows only on the
    /// display where the session started.
    /// `showsPointer` is false for a frozen screen until the overlay takes input: the system arrow is
    /// still showing then, and a crosshair under it would double it.
    /// `allInOne` adds All-In-One's modes to the bar and its letter keys: A, W, and F for an area, a window, or the
    /// screen; O, S, and R for text, a scrolling capture, or a recording.
    func reset(
        pointer globalPointer: CGPoint, mode: Mode, windows: [WindowTarget], showsToolbar: Bool, showsPointer: Bool = true,
        purpose: OverlayController.Purpose = .screenshot, colorFormat: ColorFormat = .hex,
        captureLoupeStyle: CaptureLoupeStyle = .magnified, captureLoupeSize: CaptureLoupeSize = .small, measureUnit: MeasureUnit = .points,
        measureTolerance: MeasureTolerance = .medium, measureSnapsToContent: Bool = true,
        allInOne: Bool = false, snapsToText: Bool = false
    ) {
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        selection.reset()
        hasStartedAreaSelection = false
        showsReading = false
        isSimulated = false
        isAnnotating = false
        capturedFrame = nil
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        self.purpose = purpose
        self.captureLoupeStyle = captureLoupeStyle
        self.captureLoupeSize = captureLoupeSize
        self.colorFormat = colorFormat
        isAllInOne = allInOne && purpose == .screenshot
        if purpose == .measure {
            let measure = self.measure ?? MeasureOverlay(display: display)
            measure.onRedraw = nil
            measure.clear()
            if measure.layer.superlayer == nil { layer?.insertSublayer(measure.layer, below: crosshairOutline) }
            measure.unit = measureUnit
            measure.tolerance = measureTolerance
            measure.snapsToContent = measureSnapsToContent
            measure.onRedraw = { [weak self] in self?.updateMeasureCrosshair() }
            self.measure = measure
        } else {
            measure?.onRedraw = nil
            measure?.clear()
            measure?.layer.removeFromSuperlayer()
            measure = nil
        }
        // The bar first: the size reading below steers clear of it.
        toolbar.isHidden = !showsToolbar
        toolbar.alphaValue = 1
        toolbar.showModes(isAllInOne)
        toolbar.markPurpose(nil)
        toolbar.select(mode == .area ? .area : .window)
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        let help = switch purpose {
        case .text: String(localized: "Drag over text to copy it. Press Space to choose a window instead. Press Escape to cancel.", bundle: .module)
        case .annotate: String(localized: "Drag over an area to mark it up. The arrow keys move the corner a pixel, ten with Shift. Hold Shift to keep its shape. Press Tab to type a size, or Space to choose a window instead. Press Escape to cancel.", bundle: .module)
        case .screenshot where isAllInOne: String(localized: "Drag over an area, then choose what to do with it. Press W or Space to capture a window, F the whole screen, O to copy text, S for a scrolling capture, or R to record. Press Escape to cancel.", bundle: .module)
        case .screenshot: String(localized: "Drag to capture an area. The arrow keys move the corner a pixel, ten with Shift. Hold Shift to keep its shape. Press Tab to type a size, or Space to capture a window instead. Press Escape to cancel.", bundle: .module)
        case .color: String(localized: "Click or press Return to copy the color under the crosshair; with Option, see it in every notation. The arrow keys move the crosshair a pixel, ten with Shift. Press Escape to cancel.", bundle: .module)
        case .measure: String(localized: "Point at something to measure it, or drag a box around it. Command-C copies the measurement, Return copies it and closes, and Tab switches between points and pixels. T cycles edge tolerance; plus and minus adjust it. The arrow keys move a pixel. Press Escape to cancel.", bundle: .module)
        case .record: String(localized: "Drag over an area to record it, or click to record the whole screen. Press Space to choose a window instead. Press Escape to cancel.", bundle: .module)
        case .scroll: String(localized: "Drag over the part that scrolls to capture all of it as one long picture. Press Space to choose a window instead. Press Escape to cancel.", bundle: .module)
        }
        setAccessibilityHelp(snapsToText ? help + " " + String(localized: "The selection's edges snap to text; hold Command to place them freely.", bundle: .module) : help)
        withoutAnimation {
            layoutLoupe()
            applyAppearance()
            // The panels are reused: the edges in-place annotation hid come back with a new session.
            border.isHidden = false
            snapEdges.isHidden = false
            backdrop.contents = nil
            loupeImage.contents = nil
            updateSelectionLayers()
            updatePointer(showsPointer && display.frame.contains(globalPointer) ? local(globalPointer) : nil)
        }
    }

    /// Hands the view this display's captured frame, which the magnifier enlarges. In freeze mode the
    /// frame also becomes the backdrop, so the screen holds still while selecting.
    func show(_ frame: CapturedFrame, frozen: Bool) {
        capturedFrame = frame
        measure?.show(frame)
        withoutAnimation {
            backdrop.contents = frozen ? frame.image : nil
            loupeImage.contents = frame.image
            updatePointer(pointer)
        }
    }

    /// Switches between dragging a region and clicking a window, keeping the pointer where it is.
    func switchMode(to mode: Mode, windows: [WindowTarget]) {
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        selection.reset()
        toolbar.select(mode == .area ? .area : .window)
        withoutAnimation {
            updateSelectionLayers()
            updatePointer(pointer)
        }
    }

    /// Drops the frame so its memory is released while the overlay is hidden, and takes away any
    /// interface in-place annotation put over it.
    func clear() {
        capturedFrame = nil
        measure?.clear()
        isAnnotating = false
        for subview in subviews where subview !== toolbar {
            subview.removeFromSuperview()
        }
        withoutAnimation {
            backdrop.contents = nil
            loupeImage.contents = nil
        }
    }

    /// The display's frame, once it has arrived.
    func frame() -> CapturedFrame? {
        capturedFrame
    }

    /// The color of the pixel at a point in global space, the one the magnifier centers on.
    func color(at globalPoint: CGPoint) -> ScreenColor? {
        let pixel = pixelCoordinate(at: local(globalPoint))
        return capturedFrame?.color(atPixel: pixel.x, pixel.y)
    }

    private func updateMeasureCrosshair() {
        guard purpose == .measure, let measure, pointer != nil else { return }
        setAccessibilityValue(measure.accessibilityValue)
        withoutAnimation {
            crosshair.isHidden = measure.showsLines
            crosshairOutline.isHidden = measure.showsLines
        }
    }

    #if DEBUG
    /// Whether the selection's white edge and its snapped edges are showing, for checking what a new session
    /// brings back after in-place annotation hid them.
    var debugEdgeLayersShow: (border: Bool, snapped: Bool) {
        (!border.isHidden, !snapEdges.isHidden)
    }

    var debugPointerLayers: (crosshair: Bool, loupe: CGRect?, colorReading: CGRect?) {
        (!crosshair.isHidden, loupe.isHidden ? nil : loupe.frame,
         loupePill.layer.isHidden ? nil : loupePill.layer.frame)
    }

    var debugLoupeCenterColors: (stroke: CGColor?, outline: CGColor?, outlineVisible: Bool) {
        (loupeCenter.strokeColor, loupeCenterOutline.strokeColor, !loupeCenterOutline.isHidden)
    }

    var debugLoupeImageGeometry: (frame: CGRect, contentsRect: CGRect, gridVisible: Bool) {
        (loupeImage.frame, loupeImage.contentsRect, !loupeGrid.isHidden)
    }

    /// Drags the ruler's box over `rect` (global space) and lets go, for scripted checks.
    func debugMeasureBox(_ rect: CGRect) {
        let box = local(rect)
        measure?.beginBox(at: CGPoint(x: box.minX, y: box.maxY))
        measure?.dragBox(to: CGPoint(x: box.maxX, y: box.minY))
        measure?.endBox()
    }

    var debugMeasurement: String? {
        measure?.measurement
    }

    /// Copies the ruler's measurement as ⌘C does, for scripted checks.
    func debugCopyMeasurement() {
        guard let text = measure?.measurement else { return }
        delegate?.overlayView(self, didCopyMeasurement: text, ending: false)
        measure?.flashCopied()
    }
    #endif

    func setMeasureUnit(_ unit: MeasureUnit) {
        measure?.unit = unit
        setAccessibilityValue(measure?.accessibilityValue)
        if measure?.accessibilityValue != nil { announceValue() }
    }

    func setMeasureTolerance(_ tolerance: MeasureTolerance) {
        measure?.tolerance = tolerance
        setAccessibilityValue(measure?.accessibilityValue)
        if measure?.accessibilityValue != nil { announceValue() }
    }

    /// Hands the display to in-place annotation: the frozen screen stays; the selection, readings,
    /// crosshair, magnifier, and All-In-One bar go, since its interface draws its own.
    func enterAnnotation() {
        isAnnotating = true
        toolbar.isHidden = true
        withoutAnimation {
            for layer in [room, outline, border, snapEdges, crosshair, crosshairOutline, loupeShadow, loupe, loupeRim, sizePill.layer, loupePill.layer] {
                layer.isHidden = true
            }
        }
    }

    /// Puts the crosshair and magnifier where the pointer is now, for an overlay that appears a moment
    /// after its session began.
    ///
    /// The crosshair and magnifier show only on the display the pointer is over; window mode highlights
    /// the window under it on every display the window reaches.
    func movePointer(to globalPointer: CGPoint) {
        guard !isSimulated, !isAnnotating else { return }
        let here = mode == .window || display.frame.contains(globalPointer)
        withoutAnimation { updatePointer(here ? local(globalPointer) : nil) }
    }

    /// Draws the controller's selection: the part of it on this display, the size reading if this
    /// display has it. The All-In-One bar steps out of the way while a region is being dragged.
    func show(selection: SelectionModel, showsReading: Bool, isDragging: Bool) {
        self.selection = selection
        self.showsReading = showsReading
        let hidesPicker = usesCenteredPicker && !hasStartedAreaSelection && (isDragging || selection.rect != nil)
        // A click with no drag leaves no selection: the lens comes back, so the hidden pointer is never lost.
        let restoresPicker = usesCenteredPicker && hasStartedAreaSelection && !isDragging && selection.rect == nil
        if hidesPicker { hasStartedAreaSelection = true }
        if restoresPicker { hasStartedAreaSelection = false }
        if !toolbar.isHidden { toolbar.alphaValue = isDragging && selection.rect != nil ? 0 : 1 }
        withoutAnimation {
            updateSelectionLayers()
            if hidesPicker || restoresPicker { updatePointer(pointer) }
        }
    }

    /// Puts the pointer somewhere without mouse input, for scripted checks; the real (hidden) pointer
    /// cannot move it after that.
    func simulate(pointer globalPointer: CGPoint) {
        isSimulated = true
        withoutAnimation { updatePointer(local(globalPointer)) }
    }

    override func layout() {
        super.layout()
        layoutToolbar()
    }

    /// Copying text keeps the system crosshair; a screenshot draws its own crosshair and magnifier.
    override func resetCursorRects() {
        super.resetCursorRects()
        if purpose == .text { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutAnimation { applyAppearance() }
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    // Pointer moves go to the controller, which passes them to every display: the key panel hears moves
    // over other displays too, and drawing them here left a stray magnifier at this display's edge.
    override func mouseMoved(with event: NSEvent) {
        if purpose == .text { NSCursor.crosshair.set() }
        guard !isSimulated, !isAnnotating else { return }
        delegate?.overlayView(self, didMovePointerTo: global(convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        // Cursor rects only work in the key panel; on other displays the crosshair is set here.
        if purpose == .text { NSCursor.crosshair.set() }
        guard !isSimulated, !isAnnotating else { return }
        delegate?.overlayView(self, didMovePointerTo: global(convert(event.locationInWindow, from: nil)))
    }

    /// The text selection's edge: 1 pt, or 2 pt with Increase Contrast so it holds over blue content.
    static func textSelectionEdge(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 2 : 1
    }

    override func mouseExited(with event: NSEvent) {
        guard !isSimulated, !isAnnotating else { return }
        withoutAnimation { updatePointer(nil) }
    }

    // Area mode hands the press to the controller, which keeps one selection for every display: drag
    // events keep coming here even once the pointer is over another display, in global space.
    // Picking a color takes the pixel when the mouse is released; the ruler draws its box here, on the
    // display the press began on.
    override func mouseDown(with event: NSEvent) {
        guard mode == .area, !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch purpose {
        case .color:
            break
        case .measure:
            measure?.beginBox(at: point)
        case .screenshot, .text, .annotate, .record, .scroll:
            delegate?.overlayView(self, didPressAt: global(point))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch purpose {
        case .color:
            delegate?.overlayView(self, didMovePointerTo: global(point))
        case .measure:
            let inside = CGPoint(x: min(max(point.x, 0), bounds.maxX), y: min(max(point.y, 0), bounds.maxY))
            measure?.dragBox(to: inside)
            delegate?.overlayView(self, didMovePointerTo: global(inside))
        case .screenshot, .text, .annotate, .record, .scroll:
            delegate?.overlayView(self, didDragTo: global(point), modifiers: event.modifierFlags)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isAnnotating else { return }
        if mode == .window {
            if let hoveredWindow { delegate?.overlayView(self, didSelectWindow: hoveredWindow, modifiers: event.modifierFlags) }
            return
        }
        switch purpose {
        case .color:
            delegate?.overlayView(self, didPickColorAt: global(convert(event.locationInWindow, from: nil)), modifiers: event.modifierFlags, keyboard: false)
        case .measure:
            let bypassSnap = !event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            measure?.endBox(snapping: !bypassSnap)
            setAccessibilityValue(measure?.accessibilityValue)
            announceValue()
        case .screenshot, .text, .annotate, .record, .scroll:
            delegate?.overlayView(self, didReleaseWith: event.modifierFlags)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard !isAnnotating else { return }
        delegate?.overlayView(self, didChangeModifiers: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        // In-place annotation answers its own keys; what it leaves reaches here and goes no further, so
        // Space never switches to choosing a window under it.
        guard !isAnnotating else {
            super.keyDown(with: event)
            return
        }
        let character = event.charactersIgnoringModifiers?.lowercased()
        let picks = purpose == .color || purpose == .measure
        if purpose == .measure, let measure,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let tolerance: MeasureTolerance? = switch character {
            case "t": measure.tolerance.next
            case "=", "+": measure.tolerance.increased
            case "-": measure.tolerance.decreased
            default: nil
            }
            if let tolerance {
                delegate?.overlayView(self, didChangeTolerance: tolerance)
                return
            }
        }
        switch event.keyCode {
        case 53: // Escape
            delegate?.overlayViewDidCancel(self)
        case 49 where !picks:
            // While dragging, Space moves the selection; before a drag it switches between capturing a
            // region and capturing a window, as in macOS's own screenshot tool.
            delegate?.overlayView(self, didPressSpace: event.isARepeat)
        // A case's `where` binds only its last pattern, so these test the purpose inside: as `case 36, 76 where
        // purpose == .color`, Return picked a color in every overlay (Measure's Return copied a color, a frozen
        // screenshot ended on one), and ←, →, ↓ moved the crosshair while capturing.
        case 123, 124, 125, 126:
            // While picking a color or measuring, the arrows move the crosshair a pixel at a time, ten with Shift; so
            // they do while choosing an area (before a drag, the crosshair; during one, the corner being dragged), but
            // not when choosing a window, which has no crosshair.
            guard picks || mode == .area else { return super.keyDown(with: event) }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let direction: CGVector = switch event.keyCode {
            case 123: CGVector(dx: -1, dy: 0)
            case 124: CGVector(dx: 1, dy: 0)
            case 125: CGVector(dx: 0, dy: 1)
            default: CGVector(dx: 0, dy: -1)
            }
            delegate?.overlayView(self, didNudge: CGVector(dx: direction.dx * step, dy: direction.dy * step))
        case 36, 76: // Return, and Enter on the keypad
            switch purpose {
            case .color:
                if let pointer { delegate?.overlayView(self, didPickColorAt: global(pointer), modifiers: event.modifierFlags, keyboard: true) }
            case .measure:
                if let text = measure?.measurement { delegate?.overlayView(self, didCopyMeasurement: text, ending: true) }
            case .screenshot, .text, .annotate, .record, .scroll:
                super.keyDown(with: event)
            }
        case 48 where purpose == .measure:
            if let measure { delegate?.overlayView(self, didChangeUnit: measure.unit.toggled) }
        case 48 where mode == .area && !isAllInOne && (purpose == .screenshot || purpose == .annotate):
            // Tab frames the area for a size typed and a shape kept; the drag itself needs none of this.
            delegate?.overlayViewDidRequestSizing(self)
        default:
            if character == "u", purpose == .measure, let measure {
                delegate?.overlayView(self, didChangeUnit: measure.unit.toggled)
            } else if isAllInOne, !event.modifierFlags.contains(.command), let choice = Self.allInOneKeys[character ?? ""] {
                toolbarChose(choice)
            } else if character == "c", !event.modifierFlags.contains(.command), mode == .area, purpose != .text, purpose != .record, purpose != .scroll, let pointer, capturedFrame != nil {
                // C takes the color under the crosshair, as in Snipaste: from the magnifier while capturing. With
                // Option it opens the color card, as an Option-click does.
                delegate?.overlayView(self, didPickColorAt: global(pointer), modifiers: event.modifierFlags.intersection(.option), keyboard: true)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// ⌘C copies the ruler's measurement; the overlay stays for the next one.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard purpose == .measure, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c",
              let text = measure?.measurement else { return super.performKeyEquivalent(with: event) }
        delegate?.overlayView(self, didCopyMeasurement: text, ending: false)
        measure?.flashCopied()
        return true
    }

    /// Tells VoiceOver what the crosshair is on now (the color, or the measurement), for keys that move it
    /// or change the reading; the pointer's own moves only update the value.
    func announceValue() {
        guard let value = accessibilityValue() as? String, !value.isEmpty else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: value,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { delegate?.overlayViewDidReleaseSpace(self) }
    }

    /// All-In-One's letter keys, before an area is chosen.
    static let allInOneKeys: [String: AllInOneBar.Choice] = [
        "a": .area, "w": .window, "f": .fullscreen, "o": .text, "s": .scroll, "r": .record,
    ]

    /// Marks what All-In-One's next area is for on the bar; nil for a plain capture.
    func markPurpose(_ choice: AllInOneBar.Choice?) {
        toolbar.markPurpose(choice)
    }

    /// Shows the screen as it is now instead of as it was frozen, for a recording set up from a frozen All-In-One.
    func showLive() {
        withoutAnimation { backdrop.contents = nil }
    }

    private func toolbarChose(_ choice: AllInOneBar.Choice) {
        switch choice {
        case .area where isAllInOne:
            // All-In-One's Area is a plain capture of an area: whatever the next area was for is let go.
            if mode != .area { delegate?.overlayView(self, didSwitchTo: .area) }
            delegate?.overlayView(self, didChooseMode: .screenshot(nil))
        case .text:
            delegate?.overlayView(self, didChooseMode: .text)
        case .scroll:
            delegate?.overlayView(self, didChooseMode: .scroll)
        case .record:
            delegate?.overlayView(self, didChooseMode: .record)
        case .area where mode != .area:
            delegate?.overlayView(self, didSwitchTo: .area)
        case .window where mode != .window:
            delegate?.overlayView(self, didSwitchTo: .window)
        case .fullscreen:
            delegate?.overlayView(self, didSelect: display.frame, modifiers: [])
        case .cancel:
            delegate?.overlayViewDidCancel(self)
        default:
            break
        }
    }

    // MARK: - Drawing

    private func buildLayers() {
        guard let root = layer else { return }
        backdrop.frame = bounds
        backdrop.contentsGravity = .resize
        backdrop.magnificationFilter = .nearest

        room.frame = bounds
        room.fillRule = .evenOdd

        for line in [outline, crosshairOutline] {
            line.lineWidth = Theme.Overlay.borderWidth + 2
            line.fillColor = nil
            line.lineJoin = .round
            line.lineCap = .round
        }
        for line in [border, crosshair] {
            line.strokeColor = .white
            line.lineWidth = Theme.Overlay.borderWidth
            line.fillColor = nil
            line.lineJoin = .round
            line.lineCap = .round
        }
        snapEdges.fillColor = nil
        snapEdges.lineCap = .round

        layoutLoupe()
        loupe.masksToBounds = true
        loupe.backgroundColor = .white
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        loupeGrid.strokeColor = CGColor(gray: 0, alpha: 0.08)
        loupeGrid.lineWidth = 1 / display.backingScale
        loupeCenter.fillColor = nil
        loupeCenter.lineWidth = 1.5
        loupeCenterOutline.fillColor = nil
        loupeCenterOutline.lineWidth = 3
        loupe.addSublayer(loupeImage)
        loupe.addSublayer(loupeGrid)
        loupe.addSublayer(loupeCenterOutline)
        loupe.addSublayer(loupeCenter)

        // A soft shadow under the lens and a white rim around it, both outside the masked lens.
        loupeShadow.fillColor = .white
        loupeShadow.shadowOpacity = 0.28
        loupeShadow.shadowRadius = 12
        loupeShadow.shadowOffset = CGSize(width: 0, height: -4)
        loupeRim.strokeColor = .white
        loupeRim.fillColor = nil
        loupeRim.lineWidth = Theme.Loupe.rimWidth

        sizePill.setScale(display.backingScale)
        loupePill.setScale(display.backingScale)
        for sublayer in [backdrop, room, outline, border, snapEdges, crosshairOutline, crosshair, loupeShadow, loupe, loupeRim, sizePill.layer, loupePill.layer] {
            root.addSublayer(sublayer)
        }
        withoutAnimation {
            applyAppearance()
            updateSelectionLayers()
        }
    }

    private var loupeDiameter: CGFloat { usesCenteredPicker ? captureLoupeSize.diameter : Theme.Loupe.diameter }

    /// Reused views may switch both size and purpose between sessions; keep every lens layer in sync.
    private func layoutLoupe() {
        let diameter = loupeDiameter
        let lensBounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        loupe.bounds = lensBounds
        loupe.cornerRadius = diameter / 2
        loupeImage.frame = lensBounds
        loupeGrid.frame = lensBounds
        loupeGrid.path = Self.gridPath(size: diameter, cells: Theme.Loupe.pixelsAcross)
        loupeGrid.isHidden = usesCenteredPicker
        let cell = diameter / CGFloat(Theme.Loupe.pixelsAcross)
        loupeCenter.frame = lensBounds
        loupeCenter.path = CGPath(
            roundedRect: CGRect(x: (diameter - cell) / 2, y: (diameter - cell) / 2, width: cell, height: cell),
            cornerWidth: 1.5, cornerHeight: 1.5, transform: nil
        )
        loupeCenterOutline.frame = lensBounds
        loupeCenterOutline.path = loupeCenter.path
        loupeShadow.bounds = lensBounds
        loupeShadow.path = CGPath(ellipseIn: lensBounds, transform: nil)
        loupeShadow.shadowPath = loupeShadow.path
        loupeRim.bounds = lensBounds
        loupeRim.path = CGPath(ellipseIn: lensBounds.insetBy(dx: -Theme.Loupe.rimWidth / 2, dy: -Theme.Loupe.rimWidth / 2), transform: nil)
    }

    /// Colors that depend on appearance or accessibility settings. Read when a session starts and when
    /// the appearance changes, never per event.
    private func applyAppearance() {
        let dimming = increasedContrast ? Theme.Overlay.dimmingIncreasedContrast : Theme.Overlay.dimming
        room.fillColor = CGColor(gray: 0, alpha: dimming)
        let outlineOpacity = increasedContrast ? Theme.Overlay.outlineOpacityIncreasedContrast : Theme.Overlay.outlineOpacity
        outline.strokeColor = CGColor(gray: 0, alpha: outlineOpacity)
        crosshairOutline.strokeColor = CGColor(gray: 0, alpha: outlineOpacity)
        // Let the original screen show through the centered preview, with an opaque reticle.
        // Both white backing discs must go as well, or lowering image opacity reveals only white.
        let translucentPicker = usesCenteredPicker && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        loupeImage.opacity = translucentPicker ? 0.75 : 1
        loupe.backgroundColor = translucentPicker ? .clear : .white
        loupeShadow.fillColor = translucentPicker ? .clear : .white
        loupeShadow.shadowOpacity = translucentPicker ? 0 : 0.28
        updateLoupeCenter(for: pointer.flatMap { color(at: global($0)) })
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        sizePill.applyAppearance(dark: isDark, contrast: increasedContrast)
        loupePill.applyAppearance(dark: isDark, contrast: increasedContrast)
        // Text: the selection reads as selected text (the system's selection color, lightly filled,
        // edged in the accent), over an undimmed screen. Screenshot: a white edge over a soft outline.
        let text = purpose == .text
        // Picking a color and measuring show the screen as it is: they choose no area.
        let undimmed = text || purpose == .color || purpose == .measure
        room.isHidden = undimmed
        outline.isHidden = undimmed
        measure?.applyAppearance(dark: isDark, contrast: increasedContrast, accent: Theme.cgColor(.controlAccentColor, for: effectiveAppearance))
        border.lineWidth = text ? Self.textSelectionEdge(increasedContrast: increasedContrast) : Theme.Overlay.borderWidth
        border.strokeColor = text ? Theme.cgColor(.controlAccentColor, for: effectiveAppearance) : .white
        // Resolved for this appearance before the alpha is applied: applying it first fixes the
        // dynamic color to its light value.
        border.fillColor = text
            ? Theme.cgColor(.selectedTextBackgroundColor, for: effectiveAppearance).copy(alpha: isDark ? 0.45 : 0.35)
            : nil
        // An edge that snapped is the accent and a half point heavier than the others (a point heavier on the
        // text selection's thin edge), so it reads without the color.
        snapEdges.strokeColor = Theme.cgColor(.controlAccentColor, for: effectiveAppearance)
        snapEdges.lineWidth = border.lineWidth + (text ? 1 : 0.5)
    }

    private func updateSelectionLayers() {
        let roomPath = CGMutablePath()
        roomPath.addRect(bounds)
        let target = mode == .window ? hoveredWindow?.frame.intersection(display.frame) : selection.rect
        guard let globalRect = target, !globalRect.isNull, !globalRect.isEmpty else {
            room.path = roomPath
            outline.path = nil
            border.path = nil
            snapEdges.path = nil
            sizePill.layer.isHidden = true
            setAccessibilityValue(nil)
            return
        }
        let rect = local(globalRect)
        roomPath.addRect(rect)
        room.path = roomPath
        let edge = CGPath(rect: rect, transform: nil)
        let inset = Self.textSelectionEdge(increasedContrast: increasedContrast) / 2
        let drawn = purpose == .text ? rect.integral.insetBy(dx: inset, dy: inset) : rect
        border.path = purpose == .text ? CGPath(rect: drawn, transform: nil) : edge
        outline.path = edge
        snapEdges.path = mode == .area ? Self.path(of: selection.snappedEdges, in: drawn) : nil

        let text: String
        if mode == .window, let hoveredWindow {
            let scale = display.pixelsPerPoint
            let width = Int((hoveredWindow.frame.width * scale).rounded())
            let height = Int((hoveredWindow.frame.height * scale).rounded())
            text = hoveredWindow.ownerName.isEmpty ? "\(width) × \(height)" : "\(hoveredWindow.ownerName)  ·  \(width) × \(height)"
        } else {
            let size = selection.pixelSize
            text = "\(size.width) × \(size.height)"
        }
        sizePill.text = text
        sizePill.layer.isHidden = purpose == .text || (mode == .area && !showsReading)
        // Text mode has no readings; a hovered window is named, without its size.
        setAccessibilityValue(purpose == .text ? (mode == .window ? hoveredWindow?.ownerName : nil) : text)
        // Centered under the selection; tucked inside when there is no room below, and lifted above the
        // All-In-One bar rather than covered by it (a window that fills the screen puts it right there).
        let pillSize = sizePill.layer.bounds.size
        var origin = CGPoint(x: rect.midX - pillSize.width / 2, y: rect.minY - pillSize.height - 10)
        if origin.y < 6 { origin.y = rect.minY + 10 }
        origin.x = max(6, min(origin.x, bounds.maxX - pillSize.width - 6))
        if !toolbar.isHidden, toolbar.alphaValue > 0,
           CGRect(origin: origin, size: pillSize).intersects(toolbar.frame.insetBy(dx: -8, dy: -8)) {
            origin.y = toolbar.frame.maxY + 10
        }
        sizePill.layer.frame.origin = origin
    }

    /// The sides of `rect` that snapped, as lines (the view's y is up, as the selection's is).
    private static func path(of edges: TextSnap.Edges, in rect: CGRect) -> CGPath? {
        guard !edges.isEmpty else { return nil }
        let path = CGMutablePath()
        if edges.contains(.left) { path.addLines(between: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)]) }
        if edges.contains(.right) { path.addLines(between: [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]) }
        if edges.contains(.bottom) { path.addLines(between: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)]) }
        if edges.contains(.top) { path.addLines(between: [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]) }
        return path
    }

    /// The actual-size lens, when Settings choose it for screenshots and Annotate Area: its center cell is the target,
    /// in place of the crosshair, until the first press. Pick Color and the live recording/scrolling selectors keep the
    /// magnified lens.
    private var usesCenteredPicker: Bool { captureLoupeStyle == .actualSize && (purpose == .screenshot || purpose == .annotate) }

    /// Choose against the sampled screen pixel, independent of the app's Light/Dark appearance.
    /// The opposite outline keeps the target legible when its neighboring pixels differ sharply.
    private func updateLoupeCenter(for color: ScreenColor?) {
        let picking = usesCenteredPicker || purpose == .color
        let lightStroke = color.map {
            $0.wcagContrast(with: Self.reticleWhite) >= $0.wcagContrast(with: Self.reticleBlack)
        } ?? true
        loupeCenter.strokeColor = picking
            ? (lightStroke ? .white : .black)
            : Theme.cgColor(.controlAccentColor, for: effectiveAppearance)
        let outlineOpacity = increasedContrast ? Theme.Overlay.outlineOpacityIncreasedContrast : Theme.Overlay.outlineOpacity
        loupeCenterOutline.strokeColor = CGColor(gray: lightStroke ? 0 : 1, alpha: outlineOpacity)
        loupeCenterOutline.isHidden = !picking
    }

    private func updatePointer(_ point: CGPoint?) {
        pointer = point
        let pointerLayers: [CALayer] = [crosshair, crosshairOutline, loupeShadow, loupe, loupeRim, loupePill.layer]
        if mode == .window {
            let hovered = point.flatMap { WindowCatalog.target(at: global($0), in: windows) }
            if hovered != hoveredWindow {
                hoveredWindow = hovered
                updateSelectionLayers()
            }
            pointerLayers.forEach { $0.isHidden = true }
            return
        }
        guard let point, purpose != .text else {
            pointerLayers.forEach { $0.isHidden = true }
            measure?.movePointer(to: nil)
            return
        }
        let crosshairPath = Self.crosshairPath(at: point)
        crosshair.path = crosshairPath
        crosshairOutline.path = crosshairPath
        crosshair.isHidden = false
        crosshairOutline.isHidden = false
        if purpose == .measure {
            // The ruler reads the screen itself; no magnifier. Its lines cross at the pointer, so the drawn
            // crosshair shows only while they do not: before the pixels are in, or while a box is up.
            for layer in [loupe, loupeRim, loupeShadow, loupePill.layer] { layer.isHidden = true }
            measure?.movePointer(to: point)
            updateMeasureCrosshair()
            setAccessibilityValue(measure?.accessibilityValue)
            return
        }

        // Once an area is begun, the lens and its reading go; the crosshair, drawn above, marks the pointer.
        if usesCenteredPicker, hasStartedAreaSelection {
            for layer in [loupeShadow, loupe, loupeRim, loupePill.layer] { layer.isHidden = true }
            return
        }

        // A capture's lens stays centered on the target, including at screen edges. Moving the lens
        // away to keep it on screen would make its center cell point at the wrong location.
        let diameter = loupeDiameter
        let offset = Theme.Loupe.offset
        var center = point
        if !usesCenteredPicker {
            center = CGPoint(x: point.x + offset + diameter / 2, y: point.y - offset - diameter / 2)
            if center.x + diameter / 2 > bounds.maxX - 6 { center.x = point.x - offset - diameter / 2 }
            if center.y - diameter / 2 - 32 < bounds.minY + 6 { center.y = point.y + offset + diameter / 2 }
        }
        for layer in [loupe, loupeRim, loupeShadow] { layer.position = center }

        let pixel = pixelCoordinate(at: point)
        if let frame = capturedFrame {
            if usesCenteredPicker {
                // Match the backdrop's coordinates exactly: this is a clear target, not a zoomed image.
                loupeImage.contentsRect = CGRect(
                    x: (point.x - diameter / 2) / bounds.width, y: (point.y - diameter / 2) / bounds.height,
                    width: diameter / bounds.width, height: diameter / bounds.height
                )
            } else {
                loupeImage.contentsRect = Self.contentsRect(around: pixel, in: frame.image)
            }
            let color = frame.color(atPixel: pixel.x, pixel.y)
            updateLoupeCenter(for: color)
            loupePill.swatch = color?.cgColor
            // The reading is what a click (or C) copies, in Settings' notation.
            let value = color.map { $0.string(in: colorFormat) }
            loupePill.text = value.map { "\(pixel.x), \(pixel.y)   \($0)" } ?? "\(pixel.x), \(pixel.y)"
            // VoiceOver hears the color under the crosshair while picking.
            if purpose == .color { setAccessibilityValue(value) }
            for layer in [loupe, loupeRim, loupeShadow] { layer.isHidden = false }
            if usesCenteredPicker {
                crosshair.isHidden = true
                crosshairOutline.isHidden = true
            }
        } else {
            loupePill.swatch = nil
            loupePill.text = "\(pixel.x), \(pixel.y)"
            for layer in [loupe, loupeRim, loupeShadow] { layer.isHidden = true }
        }
        loupePill.layer.isHidden = false
        let pillSize = loupePill.layer.bounds.size
        loupePill.layer.frame.origin = loupe.isHidden
            ? CGPoint(x: point.x + offset, y: point.y - offset - pillSize.height)
            : CGPoint(x: center.x - pillSize.width / 2, y: center.y - diameter / 2 - pillSize.height - 8)
        if usesCenteredPicker {
            var origin = loupePill.layer.frame.origin
            if origin.y < bounds.minY + 6 { origin.y = center.y + diameter / 2 + 8 }
            origin.x = min(max(origin.x, bounds.minX + 6), max(bounds.minX + 6, bounds.maxX - pillSize.width - 6))
            origin.y = min(max(origin.y, bounds.minY + 6), max(bounds.minY + 6, bounds.maxY - pillSize.height - 6))
            loupePill.layer.frame.origin = origin
        }
    }

    private func layoutToolbar() {
        let size = toolbar.fittingSize
        toolbar.frame = CGRect(x: (bounds.width - size.width) / 2, y: 40, width: size.width, height: size.height)
    }

    /// The captured pixel under a point, counted from the display's top-left corner.
    private func pixelCoordinate(at point: CGPoint) -> (x: Int, y: Int) {
        let scale = display.pixelsPerPoint
        let x = Int((point.x * scale).rounded(.down))
        let y = Int(((bounds.height - point.y) * scale).rounded(.down))
        let maxX = Int(display.pixelSize.width) - 1, maxY = Int(display.pixelSize.height) - 1
        return (min(max(x, 0), maxX), min(max(y, 0), maxY))
    }

    /// The part of the frame the magnifier shows: `pixelsAcross` pixels centered on `pixel`. Layer
    /// contents are addressed bottom-up, so the row is flipped.
    private static func contentsRect(around pixel: (x: Int, y: Int), in image: CGImage) -> CGRect {
        let across = CGFloat(Theme.Loupe.pixelsAcross)
        let half = (across - 1) / 2
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let left = CGFloat(pixel.x) - half
        let bottom = height - CGFloat(pixel.y) - 1 - half
        return CGRect(x: left / width, y: bottom / height, width: across / width, height: across / height)
    }

    /// A small crosshair with a gap at the center so the target pixel stays visible.
    private static func crosshairPath(at point: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let gap: CGFloat = 4, arm: CGFloat = 13
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            path.addLines(between: [
                CGPoint(x: point.x + dx * gap, y: point.y + dy * gap),
                CGPoint(x: point.x + dx * arm, y: point.y + dy * arm),
            ])
        }
        return path
    }

    private static func gridPath(size: CGFloat, cells: Int) -> CGPath {
        let path = CGMutablePath()
        let step = size / CGFloat(cells)
        for index in 1..<cells {
            let offset = CGFloat(index) * step
            path.addLines(between: [CGPoint(x: offset, y: 0), CGPoint(x: offset, y: size)])
            path.addLines(between: [CGPoint(x: 0, y: offset), CGPoint(x: size, y: offset)])
        }
        return path
    }

    // MARK: - Coordinates

    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + display.frame.minX, y: point.y + display.frame.minY)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
