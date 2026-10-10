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
    /// The arrow keys moved the crosshair by whole pixels; down is positive.
    func overlayView(_ view: OverlayView, didNudge pixels: CGVector)
    /// The ruler's measurement, to copy; `ending` closes the overlay after it (Return).
    func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool)
    func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit)
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
    /// Set by `simulate`, so the real (hidden) pointer cannot move a scripted render.
    private var isSimulated = false
    /// In-place annotation has the display: its interface takes the input and draws the selection.
    private(set) var isAnnotating = false
    private var increasedContrast = false

    private let backdrop = CALayer()
    private let room = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let border = CAShapeLayer()
    private let sizePill = ReadingCapsule()
    private let crosshairOutline = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let loupeShadow = CAShapeLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeCenter = CAShapeLayer()
    /// While picking, the center cell is drawn as the crosshair is, white over a dark outline, so it holds
    /// over the accent's own color: that cell is what a click copies.
    private let loupeCenterOutline = CAShapeLayer()
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
        setAccessibilityLabel(String(localized: "Capture overlay"))
        setAccessibilityHelp(String(localized: "Drag to capture an area. Press Space to capture a window instead. Press Escape to cancel."))
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
    func reset(
        pointer globalPointer: CGPoint, mode: Mode, windows: [WindowTarget], showsToolbar: Bool, showsPointer: Bool = true,
        purpose: OverlayController.Purpose = .screenshot, colorFormat: ColorFormat = .hex, measureUnit: MeasureUnit = .points
    ) {
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        selection.reset()
        showsReading = false
        isSimulated = false
        isAnnotating = false
        capturedFrame = nil
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        self.purpose = purpose
        self.colorFormat = colorFormat
        if purpose == .measure {
            let measure = self.measure ?? MeasureOverlay(display: display)
            if measure.layer.superlayer == nil { layer?.insertSublayer(measure.layer, below: crosshairOutline) }
            measure.unit = measureUnit
            measure.onRedraw = { [weak self] in self?.updateMeasureCrosshair() }
            self.measure = measure
        } else {
            measure?.layer.removeFromSuperlayer()
            measure = nil
        }
        // The bar first: the size reading below steers clear of it.
        toolbar.isHidden = !showsToolbar
        toolbar.alphaValue = 1
        toolbar.select(mode == .area ? .area : .window)
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        let help = switch purpose {
        case .text: String(localized: "Drag over text to copy it. Press Space to choose a window instead. Press Escape to cancel.")
        case .annotate: String(localized: "Drag over an area to mark it up. Press Space to choose a window instead. Press Escape to cancel.")
        case .screenshot: String(localized: "Drag to capture an area. Press Space to capture a window instead. Press Escape to cancel.")
        case .color: String(localized: "Click or press Return to copy the color under the crosshair; with Option, see it in every notation. The arrow keys move the crosshair a pixel, ten with Shift. Press Escape to cancel.")
        case .measure: String(localized: "Point at something to measure it, or drag a box around it. Command-C copies the measurement, Return copies it and closes, and Tab switches between points and pixels. The arrow keys move a pixel. Press Escape to cancel.")
        case .record: String(localized: "Drag over an area to record it, or click to record the whole screen. Press Space to choose a window instead. Press Escape to cancel.")
        }
        setAccessibilityHelp(help)
        withoutAnimation {
            applyAppearance()
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
        withoutAnimation {
            crosshair.isHidden = measure.showsLines
            crosshairOutline.isHidden = measure.showsLines
        }
    }

    #if DEBUG
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

    /// Hands the display to in-place annotation: the frozen screen stays; the selection, readings,
    /// crosshair, magnifier, and All-In-One bar go, since its interface draws its own.
    func enterAnnotation() {
        isAnnotating = true
        toolbar.isHidden = true
        withoutAnimation {
            for layer in [room, outline, border, crosshair, crosshairOutline, loupeShadow, loupe, loupeRim, sizePill.layer, loupePill.layer] {
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
        if !toolbar.isHidden { toolbar.alphaValue = isDragging && selection.rect != nil ? 0 : 1 }
        withoutAnimation { updateSelectionLayers() }
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
        case .screenshot, .text, .annotate, .record:
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
        case .screenshot, .text, .annotate, .record:
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
            measure?.endBox()
            setAccessibilityValue(measure?.accessibilityValue)
            announceValue()
        case .screenshot, .text, .annotate, .record:
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
        switch event.keyCode {
        case 53: // Escape
            delegate?.overlayViewDidCancel(self)
        case 49 where !picks:
            // While dragging, Space moves the selection; before a drag it switches between capturing a
            // region and capturing a window, as in macOS's own screenshot tool.
            delegate?.overlayView(self, didPressSpace: event.isARepeat)
        case 123, 124, 125, 126 where picks:
            // The arrows move the crosshair a pixel at a time, ten with Shift.
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let direction: CGVector = switch event.keyCode {
            case 123: CGVector(dx: -1, dy: 0)
            case 124: CGVector(dx: 1, dy: 0)
            case 125: CGVector(dx: 0, dy: 1)
            default: CGVector(dx: 0, dy: -1)
            }
            delegate?.overlayView(self, didNudge: CGVector(dx: direction.dx * step, dy: direction.dy * step))
        case 36, 76 where purpose == .color:
            if let pointer { delegate?.overlayView(self, didPickColorAt: global(pointer), modifiers: event.modifierFlags, keyboard: true) }
        case 36, 76 where purpose == .measure:
            if let text = measure?.measurement { delegate?.overlayView(self, didCopyMeasurement: text, ending: true) }
        case 48 where purpose == .measure:
            if let measure { delegate?.overlayView(self, didChangeUnit: measure.unit.toggled) }
        default:
            if character == "u", purpose == .measure, let measure {
                delegate?.overlayView(self, didChangeUnit: measure.unit.toggled)
            } else if character == "c", !event.modifierFlags.contains(.command), mode == .area, purpose != .text, purpose != .record, let pointer, capturedFrame != nil {
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

    private func toolbarChose(_ choice: AllInOneBar.Choice) {
        switch choice {
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

        let diameter = Theme.Loupe.diameter
        let lensBounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        loupe.bounds = lensBounds
        loupe.cornerRadius = diameter / 2
        loupe.masksToBounds = true
        loupe.backgroundColor = .white
        loupeImage.frame = lensBounds
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        loupeGrid.frame = lensBounds
        loupeGrid.strokeColor = CGColor(gray: 0, alpha: 0.08)
        loupeGrid.lineWidth = 1 / display.backingScale
        loupeGrid.path = Self.gridPath(size: diameter, cells: Theme.Loupe.pixelsAcross)
        let cell = diameter / CGFloat(Theme.Loupe.pixelsAcross)
        loupeCenter.frame = lensBounds
        loupeCenter.path = CGPath(
            roundedRect: CGRect(x: (diameter - cell) / 2, y: (diameter - cell) / 2, width: cell, height: cell),
            cornerWidth: 1.5, cornerHeight: 1.5, transform: nil
        )
        loupeCenter.fillColor = nil
        loupeCenter.lineWidth = 1.5
        loupeCenterOutline.frame = lensBounds
        loupeCenterOutline.path = loupeCenter.path
        loupeCenterOutline.fillColor = nil
        loupeCenterOutline.lineWidth = 3
        loupe.addSublayer(loupeImage)
        loupe.addSublayer(loupeGrid)
        loupe.addSublayer(loupeCenterOutline)
        loupe.addSublayer(loupeCenter)

        // A soft shadow under the lens and a white rim around it, both outside the masked lens.
        loupeShadow.bounds = lensBounds
        loupeShadow.path = CGPath(ellipseIn: lensBounds, transform: nil)
        loupeShadow.fillColor = .white
        loupeShadow.shadowPath = loupeShadow.path
        loupeShadow.shadowOpacity = 0.28
        loupeShadow.shadowRadius = 12
        loupeShadow.shadowOffset = CGSize(width: 0, height: -4)
        loupeRim.bounds = lensBounds
        loupeRim.path = CGPath(ellipseIn: lensBounds.insetBy(dx: -Theme.Loupe.rimWidth / 2, dy: -Theme.Loupe.rimWidth / 2), transform: nil)
        loupeRim.strokeColor = .white
        loupeRim.fillColor = nil
        loupeRim.lineWidth = Theme.Loupe.rimWidth

        sizePill.setScale(display.backingScale)
        loupePill.setScale(display.backingScale)
        for sublayer in [backdrop, room, outline, border, crosshairOutline, crosshair, loupeShadow, loupe, loupeRim, sizePill.layer, loupePill.layer] {
            root.addSublayer(sublayer)
        }
        withoutAnimation {
            applyAppearance()
            updateSelectionLayers()
        }
    }

    /// Colors that depend on appearance or accessibility settings. Read when a session starts and when
    /// the appearance changes, never per event.
    private func applyAppearance() {
        let dimming = increasedContrast ? Theme.Overlay.dimmingIncreasedContrast : Theme.Overlay.dimming
        room.fillColor = CGColor(gray: 0, alpha: dimming)
        let outlineOpacity = increasedContrast ? Theme.Overlay.outlineOpacityIncreasedContrast : Theme.Overlay.outlineOpacity
        outline.strokeColor = CGColor(gray: 0, alpha: outlineOpacity)
        crosshairOutline.strokeColor = CGColor(gray: 0, alpha: outlineOpacity)
        let picking = purpose == .color
        loupeCenter.strokeColor = picking ? .white : Theme.cgColor(.controlAccentColor, for: effectiveAppearance)
        loupeCenterOutline.strokeColor = CGColor(gray: 0, alpha: outlineOpacity)
        loupeCenterOutline.isHidden = !picking
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
    }

    private func updateSelectionLayers() {
        let roomPath = CGMutablePath()
        roomPath.addRect(bounds)
        let target = mode == .window ? hoveredWindow?.frame.intersection(display.frame) : selection.rect
        guard let globalRect = target, !globalRect.isNull, !globalRect.isEmpty else {
            room.path = roomPath
            outline.path = nil
            border.path = nil
            sizePill.layer.isHidden = true
            setAccessibilityValue(nil)
            return
        }
        let rect = local(globalRect)
        roomPath.addRect(rect)
        room.path = roomPath
        let edge = CGPath(rect: rect, transform: nil)
        let inset = Self.textSelectionEdge(increasedContrast: increasedContrast) / 2
        border.path = purpose == .text ? CGPath(rect: rect.integral.insetBy(dx: inset, dy: inset), transform: nil) : edge
        outline.path = edge

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

        // The magnifier sits below and right of the pointer, flipping away from the display's edges.
        let diameter = Theme.Loupe.diameter
        let offset = Theme.Loupe.offset
        var center = CGPoint(x: point.x + offset + diameter / 2, y: point.y - offset - diameter / 2)
        if center.x + diameter / 2 > bounds.maxX - 6 { center.x = point.x - offset - diameter / 2 }
        if center.y - diameter / 2 - 32 < bounds.minY + 6 { center.y = point.y + offset + diameter / 2 }
        for layer in [loupe, loupeRim, loupeShadow] { layer.position = center }

        let pixel = pixelCoordinate(at: point)
        if let frame = capturedFrame {
            loupeImage.contentsRect = Self.contentsRect(around: pixel, in: frame.image)
            let color = frame.color(atPixel: pixel.x, pixel.y)
            loupePill.swatch = color?.cgColor
            // The reading is what a click (or C) copies, in Settings' notation.
            let value = color.map { $0.string(in: colorFormat) }
            loupePill.text = value.map { "\(pixel.x), \(pixel.y)   \($0)" } ?? "\(pixel.x), \(pixel.y)"
            // VoiceOver hears the color under the crosshair while picking.
            if purpose == .color { setAccessibilityValue(value) }
            for layer in [loupe, loupeRim, loupeShadow] { layer.isHidden = false }
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
