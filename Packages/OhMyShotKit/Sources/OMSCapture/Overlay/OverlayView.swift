import AppKit
import CoreGraphics
import OMSCore
import OMSDesign
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
    func overlayViewDidRequestDisplayCapture(_ view: OverlayView)
    func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags)
    /// A part of a window chosen with the scroll wheel, in global points.
    func overlayView(_ view: OverlayView, didSelectElement rect: CGRect, modifiers: NSEvent.ModifierFlags)
    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags)
    func overlayView(_ view: OverlayView, didSelectWindows targets: [WindowTarget], modifiers: NSEvent.ModifierFlags)
    /// Multi-window selection changed on one display; the controller mirrors it across all displays.
    func overlayView(_ view: OverlayView, didChangeSelectedWindows targets: [WindowTarget])
    func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode)
    func overlayViewDidRequestWindowPicker(_ view: OverlayView)
    func overlayViewDidCancel(_ view: OverlayView)
    /// A color taken at a point in global space (a click, Return, or C), with the keys held then; `keyboard`
    /// says it was a key, so what follows can take the keyboard too.
    func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool)
    /// Copies at the mouse press without ending the session. True consumes the whole mouse gesture,
    /// including when the display's first frame has not arrived yet.
    func overlayView(_ view: OverlayView, copyColorAt point: CGPoint) -> Bool

    /// Tab cycled the color notation while picking a color.
    func overlayView(_ view: OverlayView, didChangeColorFormat format: ColorFormat)

    /// The arrow keys moved the crosshair by whole pixels, down positive: the corner being dragged, when an area is
    /// being dragged out.
    func overlayView(_ view: OverlayView, didNudge pixels: CGVector)
    /// Tab: the area being chosen (or one around the crosshair) is framed for a size typed and a shape kept.
    func overlayViewDidRequestSizing(_ view: OverlayView)
    /// L: recalls the last captured area, framed to adjust or take again.
    func overlayViewDidRequestLastArea(_ view: OverlayView)
    /// Backspace or right-click during a drag: resets the current drag back to the crosshair without closing the overlay.
    func overlayViewDidResetDrag(_ view: OverlayView)
    /// The ruler's measurement, to copy; `ending` closes the overlay after it (Return).
    func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool)
    /// F: the display's frozen frame, to keep as a capture with the ruler's measurement on it as marks.
    func overlayView(_ view: OverlayView, didCaptureMeasurement measurement: RulerMeasurement, of frame: CapturedFrame)
    func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit)
    func overlayView(_ view: OverlayView, didChangeTolerance tolerance: MeasureTolerance)
    /// All-In-One's bar or keys chose what the next area is for: its text, a scrolling capture, or a recording.
    func overlayView(_ view: OverlayView, didChooseMode choice: AllInOneChoice)
    /// All-In-One's Measure (M): the overlay turns into Measure, on the screen as it is held.
    func overlayViewDidRequestMeasure(_ view: OverlayView)
    /// The user switched the temporary Self-Timer delay from the overlay's delay bar or keyboard shortcuts.
    func overlayView(_ view: OverlayView, didChangeSelfTimerDelay seconds: Int)
    /// ?: the keys of the overlay's purpose show by the edge of the display under the pointer, or go when they show.
    func overlayViewDidToggleKeys(_ view: OverlayView)
    /// A key other than ?: the keys go wherever they show. True when they showed.
    func overlayViewDidPutKeysAway(_ view: OverlayView) -> Bool
}

extension OverlayViewDelegate {
    func overlayViewDidRequestDisplayCapture(_ view: OverlayView) {
        overlayView(view, didSelect: view.display.frame, modifiers: [])
    }
    func overlayView(_ view: OverlayView, didSelectElement rect: CGRect, modifiers: NSEvent.ModifierFlags) {
        overlayView(view, didSelect: rect, modifiers: modifiers)
    }
    func overlayView(_ view: OverlayView, didSelectWindows targets: [WindowTarget], modifiers: NSEvent.ModifierFlags) {
        if let first = targets.first {
            overlayView(view, didSelectWindow: first, modifiers: modifiers)
        }
    }
    func overlayView(_ view: OverlayView, didChangeSelectedWindows targets: [WindowTarget]) {}
    func overlayView(_ view: OverlayView, didChangeColorFormat format: ColorFormat) {}
    func overlayViewDidRequestWindowPicker(_ view: OverlayView) {}
    func overlayViewDidRequestLastArea(_ view: OverlayView) {}
    func overlayViewDidResetDrag(_ view: OverlayView) {}
    func overlayView(_ view: OverlayView, didChangeSelfTimerDelay seconds: Int) {}
    func overlayViewDidToggleKeys(_ view: OverlayView) { view.toggleKeys(view.keyHelp) }
    func overlayViewDidPutKeysAway(_ view: OverlayView) -> Bool { view.putKeysAway() }
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
    var onCanvasCursorUpdate: ((CGPoint) -> Void)?
    private var ownsCanvasCursor = false
    var onToolbarVisibilityToggle: (() -> Void)?
    let display: DisplayInfo

    private(set) var mode: Mode = .area
    private var windows: [WindowTarget] = []
    private(set) var hoveredWindow: WindowTarget? {
        didSet { if hoveredWindow != oldValue { leaveElements() } }
    }
    private(set) var selectedWindows: [WindowTarget] = []
    /// The window All-In-One highlights under the pointer before anything is chosen, when it is on this display: drawn
    /// as window mode draws its window, until a drag makes a selection.
    private(set) var highlightedWindow: OverlayController.HoveredWindow?
    /// Every display, for turning points between AppKit's space and the one Accessibility uses.
    var displayLayout = DisplayLayout(displays: [])

    /// Window mode's scroll wheel goes into the hovered window and back out: how far in it is (0, the window itself),
    /// the parts under the pointer it steps through (smallest first, read once the wheel first turns in), and what is
    /// left of a trackpad's travel toward the next step.
    private var elementDepth = 0
    private var elementChain: [WindowElement] = []
    private var elementLookup: Task<Void, Never>?
    private var wheelTravel: CGFloat = 0
    /// Trackpad travel, in points, for one step in or out.
    static let wheelStep: CGFloat = 24
    /// Reads the parts of a window under a point (`ElementChain`), off the main thread; tests put in their own.
    var readElements: @Sendable (CGPoint, CGRect, pid_t, DisplayLayout) -> [WindowElement] = { point, window, pid, layout in
        ElementChain.elements(at: point, window: window, pid: pid, layout: layout)
    }
    /// Whether Accessibility lets OhMyShot read other apps' windows; tests say.
    var canReadElements: () -> Bool = { AppText.isAllowed }
    /// The part of the hovered window the wheel has gone into; nil at the window itself.
    var pickedElement: WindowElement? {
        guard elementDepth > 0, elementDepth <= elementChain.count else { return nil }
        return elementChain[elementChain.count - elementDepth]
    }
    /// The controller's selection, of which this display draws its part.
    private var selection: SelectionModel
    /// Whether this display shows the selection's size: only one does.
    private var showsReading = false
    private var capturedFrame: CapturedFrame?
    private var pointer: CGPoint?
    /// Where the pointer currently sits in this view's coordinates; nil when it is off this display.
    var currentPointer: CGPoint? { pointer }
    /// Whether the user is actively dragging a Measure box on this display.
    private(set) var isDraggingMeasureBox = false
    /// Every display receives the first area press, even before the selection has any size. Once it
    /// begins, the picker stays out of the way until a new capture session resets the view.
    private var hasStartedAreaSelection = false
    private var captureLoupeSize: CaptureLoupeSize = .small
    private var captureLoupeMagnification: CaptureLoupeMagnification = .four
    /// Set by `simulate`, so the real (hidden) pointer cannot move a scripted render.
    private var isSimulated = false
    /// In-place annotation has the display: its interface takes the input and draws the selection.
    private(set) var isAnnotating = false
    /// An All-In-One session: its modes on the bar, its letter keys.
    private(set) var isAllInOne = false
    /// Whether the selection's edges snap to text, which the help then says.
    private var snapsToText = false
    private var increasedContrast = false

    private let backdrop = CALayer()
    private let transientContent = CALayer()
    private let room = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let border = CAShapeLayer()
    /// The edges of the selection that snapped to text, drawn over `border` in the accent.
    private let snapEdges = CAShapeLayer()
    /// Outlines for locked windows during Shift-click multi-selection, distinct from the hovered window.
    private let lockedOutline = CAShapeLayer()
    private let lockedBorder = CAShapeLayer()
    /// Numbered order badges (1, 2, …) shown at the top-left of each locked window on this display.
    private var lockedBadges: [ReadingCapsule] = []
    private let sizePill = ReadingCapsule()
    /// Subtle bottom-center shortcut hint shown in Pick Color and Window modes.
    private let hintPill = ReadingCapsule()
    /// The keys of what is being chosen, a sentence a line, shown by ? near the display's edge.
    private let keyList = ReadingCapsule()
    private let crosshairOutline = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let loupeShadow = CAShapeLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeGridOutline = CAShapeLayer()
    private let loupeCenter = CAShapeLayer()
    /// An opposite-color outline keeps the adaptive center cell visible over neighboring pixels.
    private let loupeCenterOutline = CAShapeLayer()
    /// Fixed-size ticks make a one-pixel target findable even at low magnification.
    private let loupeTarget = CAShapeLayer()
    private let loupeTargetOutline = CAShapeLayer()
    private static let reticleWhite = ScreenColor(srgbRed: 1, green: 1, blue: 1)!
    private static let reticleBlack = ScreenColor(srgbRed: 0, green: 0, blue: 0)!
    private let loupeRim = CAShapeLayer()
    private let loupePill = ReadingCapsule(showsSwatch: true)
    private let toolbar = AllInOneBar()
    private var offersToolbar = false
    private(set) var toolbarHiddenByUser = false
    private var toolbarOrigin: CGPoint?
    private let selfTimerBar = SelfTimerDelayBar()
    /// Active Self-Timer delay for this session (seconds), or nil when the session is not a Self-Timer capture.
    private var selfTimerDelay: Int?
    private var showsSelfTimerBar = false

    /// Copying text gets a lighter overlay than a screenshot: no dimming, no magnifier or readings, the
    /// system crosshair, and a selection drawn like selected text.
    private var purpose: OverlayController.Purpose = .screenshot
    /// The notation picked colors are copied in, which the magnifier's reading shows while picking.
    private var colorFormat: ColorFormat = .hex
    private var colorCopyGesture: ColorCopyGesture = .option
    /// A claimed copy press never starts or releases a selection, even if its modifiers change.
    private var isCopyingColor = false
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
        toolbar.onMove = { [weak self] delta, point in self?.moveToolbar(by: delta, pointerInWindow: point) }
        toolbar.onHide = { [weak self] in self?.onToolbarVisibilityToggle?() }
        toolbar.isHidden = true
        addSubview(toolbar)
        selfTimerBar.onSelect = { [weak self] seconds in self?.chooseSelfTimerDelay(seconds) }
        selfTimerBar.isHidden = true
        addSubview(selfTimerBar)
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
    /// screen; O, S, and R for text, a scrolling capture, or a recording; M to measure. Only a screenshot is All-In-One,
    /// which `OverlayController.begin` sees to once for every display.
    func reset(
        pointer globalPointer: CGPoint, mode: Mode, windows: [WindowTarget], showsToolbar: Bool, showsPointer: Bool = true,
        purpose: OverlayController.Purpose = .screenshot, colorFormat: ColorFormat = .hex, colorCopyGesture: ColorCopyGesture = .option,
        captureLoupeSize: CaptureLoupeSize = .small, captureLoupeMagnification: CaptureLoupeMagnification = .four,
        measureUnit: MeasureUnit = .points,
        measureTolerance: MeasureTolerance = .medium, measureSnapsToContent: Bool = true,
        allInOne: Bool = false, snapsToText: Bool = false, selfTimerDelay: Int? = nil
    ) {
        endCanvasCursorOwnership()
        clearTransientContent()
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        selectedWindows = []
        highlightedWindow = nil
        selection.reset()
        hasStartedAreaSelection = false
        showsReading = false
        isSimulated = false
        isAnnotating = false
        isDraggingMeasureBox = false
        capturedFrame = nil
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        self.purpose = purpose
        self.captureLoupeSize = captureLoupeSize
        self.captureLoupeMagnification = captureLoupeMagnification
        self.colorFormat = colorFormat
        self.colorCopyGesture = colorCopyGesture
        isCopyingColor = false
        assert(!allInOne || purpose.mayBeAllInOne, "All-In-One is a screenshot’s alone")
        isAllInOne = allInOne
        self.snapsToText = snapsToText
        if purpose == .measure {
            let measure = self.measure ?? MeasureOverlay(display: display)
            measure.onRedraw = nil
            measure.onCapture = nil
            measure.clear()
            if measure.layer.superlayer == nil { layer?.insertSublayer(measure.layer, below: crosshairOutline) }
            measure.unit = measureUnit
            measure.tolerance = measureTolerance
            measure.snapsToContent = measureSnapsToContent
            measure.onRedraw = { [weak self] in self?.updateMeasureCrosshair() }
            measure.onCapture = { [weak self] area in
                guard let self, self.purpose == .measure else { return }
                self.delegate?.overlayView(self, didSelect: self.global(area), modifiers: [])
            }
            self.measure = measure
        } else {
            measure?.onRedraw = nil
            measure?.onCapture = nil
            measure?.clear()
            measure?.layer.removeFromSuperlayer()
            measure = nil
        }
        // The bar first: the size reading below steers clear of it.
        offersToolbar = showsToolbar
        toolbarHiddenByUser = false
        toolbarOrigin = nil

        toolbar.isHidden = !showsToolbar
        toolbar.alphaValue = 1
        toolbar.showModes(isAllInOne)
        let takesW = purpose == .screenshot || purpose == .record
        toolbar.usesWindowPreview(takesW, takesW: takesW)
        toolbar.markPurpose(nil)
        toolbar.select(mode == .area ? .area : .window)
        let normalizedDelay = selfTimerDelay.map { max($0, 1) }
        self.selfTimerDelay = normalizedDelay
        showsSelfTimerBar = showsToolbar && normalizedDelay != nil
        if let normalizedDelay {
            selfTimerBar.configure(selected: normalizedDelay)
        }
        selfTimerBar.isHidden = !showsSelfTimerBar
        selfTimerBar.alphaValue = 1
        layoutToolbar()
        layoutSelfTimerBar()
        window?.invalidateCursorRects(for: self)
        updateHelp()
        putKeysAway()
        withoutAnimation {
            layoutLoupe()
            applyAppearance()
            // The panels are reused: the edges in-place annotation hid come back with a new session, and a lens
            // raised over its frame while an edge was dragged goes back under the bar.
            border.isHidden = false
            border.lineDashPattern = nil
            snapEdges.isHidden = false
            lockedOutline.isHidden = false
            lockedBorder.isHidden = false
            for layer in [loupeShadow, loupe, loupeRim, loupePill.layer] { layer.zPosition = 0 }
            backdrop.contents = nil
            loupeImage.contents = nil
            updateSelectionLayers()
            updatePointer(showsPointer && display.frame.contains(globalPointer) ? local(globalPointer) : nil)
            updateHintPill()
        }
    }

    /// The keys of what is being chosen, for VoiceOver's help and for ? to show: the purpose's while an area is chosen, and
    /// choosing a window's (after Space, or for Capture Window) outside All-In-One, which says both in one.
    private func updateHelp() {
        var help: String
        if mode == .window, !isAllInOne {
            help = String(localized: "Click a window to choose it, or press Tab to go through the windows and Return to choose one. Press Space to drag over an area instead. Press Escape to cancel.", bundle: .module)
        } else {
            help = switch purpose {
            case .text: String(localized: "Drag over text to copy it. Press Space to choose a window instead. Press Escape to cancel.", bundle: .module)
            case .annotate: String(localized: "Drag over an area to mark it up. The arrow keys move the corner a pixel, ten with Shift. Hold Shift to keep its shape. Press Tab to type a size, or Space to choose a window instead. Press Escape to cancel.", bundle: .module)
            case .screenshot where isAllInOne: String(localized: "Click a window or drag over an area, then choose what to do with it. Press W or Space to capture a window, F the whole screen, O to copy text, S for a scrolling capture, R to record, or M to measure. Press Escape to cancel.", bundle: .module)
            case .screenshot: String(localized: "Drag to capture an area. The arrow keys move the corner a pixel, ten with Shift. Hold Shift to keep its shape. Press Tab to type a size, or Space to capture a window instead. Press Escape to cancel.", bundle: .module)
            case .color: String(localized: "Click or press Return to copy the color under the crosshair; with Option, see it in every notation. Press Tab to switch notations. The arrow keys move the crosshair a pixel, ten with Shift. Press Escape to cancel.", bundle: .module)
            case .measure: String(localized: "Point at something to measure it, or drag a box around it. Click inside the selected box to take a screenshot. Command-C copies the measurement, Return copies it and closes, F captures the screen with the measurement on it, and Tab switches between points and pixels. T cycles edge tolerance; plus and minus adjust it. The arrow keys move a pixel. Press Escape to cancel.", bundle: .module)
            case .record: String(localized: "Drag over an area to record it, or click to record the whole screen. Press Space to choose a window instead. Press Escape to cancel.", bundle: .module)
            case .scroll: String(localized: "Drag over the part that scrolls to capture all of it as one long picture. Press Space to choose a window instead. Press Escape to cancel.", bundle: .module)
            }
            if snapsToText {
                help = Sentences.joined(help, String(localized: "The selection’s edges snap to text; hold Command to place them freely.", bundle: .module))
            }
        }
        if offersToolbar {
            help = Sentences.joined(help, String(localized: "Press H to hide or show the toolbar.", bundle: .module))
        }
        if selfTimerDelay != nil {
            help = Sentences.joined(help, String(localized: "Press D or 1–5 to change the Self-Timer delay for this capture.", bundle: .module))
        }
        setAccessibilityHelp(help)

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

    func showTransientContent(from snapshots: [TransientCaptureSnapshot]) {
        clearTransientContent()
        transientContent.isHidden = mode != .area
        for snapshot in snapshots {
            for region in snapshot.regions {
                guard let patch = snapshot.frame.cropped(to: region.intersection(display.frame)) else { continue }
                let image = CALayer()
                image.contents = patch.image
                image.contentsScale = display.backingScale
                image.contentsGravity = .resize
                image.frame = local(patch.frame)
                transientContent.addSublayer(image)
            }
        }
    }

    var debugTransientPatchCount: Int { transientContent.sublayers?.count ?? 0 }
    var debugTransientPatchFrames: [CGRect] { transientContent.sublayers?.map(\.frame) ?? [] }
    var debugTransientContentIsBelowDimmingAndSelection: Bool {
        guard let layers = layer?.sublayers,
              let transientIndex = layers.firstIndex(where: { $0 === transientContent }),
              let dimmingIndex = layers.firstIndex(where: { $0 === room }),
              let selectionIndex = layers.firstIndex(where: { $0 === outline }) else { return false }
        return transientIndex < dimmingIndex && transientIndex < selectionIndex
    }
    var debugTransientContentIsHidden: Bool { transientContent.isHidden }

    /// Turns this display's overlay into Measure where it stands (All-In-One's M): the frame it holds stays, and holds
    /// still even if the screen showed live, since the ruler reads that frame; the bar goes, as Measure has none, and the
    /// ruler takes the pointer at `globalPointer`.
    func turnToMeasure(
        pointer globalPointer: CGPoint, colorFormat: ColorFormat, unit: MeasureUnit, tolerance: MeasureTolerance, snapsToContent: Bool
    ) {
        let frame = capturedFrame
        reset(
            pointer: globalPointer, mode: .area, windows: [], showsToolbar: false, purpose: .measure, colorFormat: colorFormat,
            colorCopyGesture: colorCopyGesture, captureLoupeSize: captureLoupeSize, captureLoupeMagnification: captureLoupeMagnification, measureUnit: unit, measureTolerance: tolerance,
            measureSnapsToContent: snapsToContent
        )
        if let frame { show(frame, frozen: true) }
    }

    /// Switches between dragging a region and clicking a window, keeping the pointer where it is.
    func switchMode(to mode: Mode, windows: [WindowTarget]) {
        transientContent.isHidden = mode != .area
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        selectedWindows = []
        highlightedWindow = nil
        selection.reset()
        toolbar.select(mode == .area ? .area : .window)
        updateHelp()
        withoutAnimation {
            updateSelectionLayers()
            updatePointer(pointer)
            updateHintPill()
        }
    }

    /// Updates the color format shown in the magnifier reading (Tab in Pick Color mode).
    func setColorFormat(_ format: ColorFormat) {
        guard colorFormat != format else { return }
        colorFormat = format
        withoutAnimation {
            updatePointer(pointer)
            updateHintPill()
        }
        if purpose == .color { announceValue() }
    }

    /// Updates the active temporary Self-Timer delay from the controller so every display stays in sync.
    func setSelfTimerDelay(_ seconds: Int) {
        guard selfTimerDelay != nil else { return }
        let clamped = max(seconds, 1)
        selfTimerDelay = clamped
        selfTimerBar.select(clamped)
        layoutSelfTimerBar()
        window?.invalidateCursorRects(for: self)
    }

    /// Drops the frame so its memory is released while the overlay is hidden, and takes away any
    /// interface in-place annotation put over it.
    func clear() {
        endCanvasCursorOwnership()
        clearTransientContent()
        capturedFrame = nil
        selectedWindows = []
        highlightedWindow = nil
        measure?.clear()
        isAnnotating = false
        isDraggingMeasureBox = false
        selfTimerDelay = nil
        showsSelfTimerBar = false
        selfTimerBar.isHidden = true
        putKeysAway()
        for subview in subviews where subview !== toolbar && subview !== selfTimerBar {
            subview.removeFromSuperview()
        }
        withoutAnimation {
            backdrop.contents = nil
            loupeImage.contents = nil
            hintPill.layer.isHidden = true
            lockedOutline.path = nil
            lockedBorder.path = nil
            for badge in lockedBadges { badge.layer.isHidden = true }
        }
    }

    /// The display's frame, once it has arrived.
    func frame() -> CapturedFrame? {
        capturedFrame
    }

    /// Whether the screen shows its frame, held still, rather than the live screen.
    var isFrozen: Bool {
        backdrop.contents != nil
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

    var debugSelfTimerBarFrame: CGRect? {
        (!selfTimerBar.isHidden && selfTimerBar.alphaValue > 0) ? selfTimerBar.frame : nil
    }

    var debugSelfTimerDelay: Int? {
        selfTimerDelay
    }

    var debugSelfTimerBar: SelfTimerDelayBar { selfTimerBar }


    var debugPointerLayers: (crosshair: Bool, loupe: CGRect?, colorReading: CGRect?) {
        (!crosshair.isHidden, loupe.isHidden ? nil : loupe.frame,
         loupePill.layer.isHidden ? nil : loupePill.layer.frame)
    }

    var debugToolbarFrame: CGRect { toolbar.frame }
    var debugToolbarIsHidden: Bool { toolbar.isHidden }
    func debugMoveToolbar(by delta: CGVector) { moveToolbar(by: delta, pointerInWindow: .zero) }
    /// What the size reading under the selection says.
    var debugSizeReading: String { sizePill.text }

    /// Visible locked-window order badge texts on this display, for tests.
    var debugSelectedWindowBadges: [String] {
        lockedBadges.filter { !$0.layer.isHidden }.map(\.text)
    }

    /// Whether distinct locked-window outline paths are drawn on this display, for tests.
    var debugHasLockedWindowPaths: Bool {
        lockedBorder.path != nil && lockedOutline.path != nil
    }

    /// Whether a separate hovered-window outline path is drawn on this display, for tests.
    var debugHasHoveredWindowPath: Bool {
        border.path != nil
    }

    /// Whether the hovered window border is dashed (indicating unlocked candidate while multi-selecting).
    var debugHoveredBorderDashed: Bool {
        border.lineDashPattern != nil
    }

    /// Visible bottom-center shortcut hint text and frame, for tests.
    var debugHintText: String? {
        hintPill.layer.isHidden ? nil : hintPill.text
    }

    var debugHintFrame: CGRect? {
        hintPill.layer.isHidden ? nil : hintPill.layer.frame
    }

    var debugLoupeCenterColors: (stroke: CGColor?, outline: CGColor?, outlineVisible: Bool) {
        (loupeCenter.strokeColor, loupeCenterOutline.strokeColor, !loupeCenterOutline.isHidden)
    }

    var debugLoupeTarget: (path: CGPath?, visible: Bool, stroke: CGFloat, outline: CGFloat) {
        (loupeTarget.path, !loupe.isHidden && !loupeTarget.isHidden, loupeTarget.lineWidth, loupeTargetOutline.lineWidth)
    }

    var debugLoupeImageGeometry: (frame: CGRect, contentsRect: CGRect, gridVisible: Bool) {
        (loupeImage.frame, loupeImage.contentsRect, !loupeGrid.isHidden)
    }

    var debugLoupePixelGeometry: (center: CGRect, grid: CGPath?, stroke: CGFloat, outline: CGFloat, gridStroke: CGFloat, gridOutline: CGFloat) {
        (loupeCenter.path?.boundingBoxOfPath ?? .zero, loupeGrid.path, loupeCenter.lineWidth, loupeCenterOutline.lineWidth,
         loupeGrid.lineWidth, loupeGridOutline.lineWidth)
    }

    /// Whether the lens is raised over what was handed over, as it is while an edge is dragged.
    var debugLensRaised: Bool {
        [loupeShadow, loupe, loupeRim, loupePill.layer].allSatisfy { $0.zPosition > 0 }
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
        endCanvasCursorOwnership()
        isAnnotating = true
        putKeysAway()
        toolbar.isHidden = true
        selfTimerBar.isHidden = true
        withoutAnimation {
            for layer in [room, outline, border, snapEdges, lockedOutline, lockedBorder, crosshair, crosshairOutline, loupeShadow, loupe, loupeRim, hintPill.layer, sizePill.layer, loupePill.layer] {
                layer.isHidden = true
            }
            for badge in lockedBadges { badge.layer.isHidden = true }
        }
    }

    /// Returns the display from a hosted setup view (such as All-In-One's framed area) back to the
    /// selection overlay, keeping its captured frame and frozen backdrop intact.
    func leaveAnnotation(mode: Mode, windows: [WindowTarget], showsToolbar: Bool, pointer globalPointer: CGPoint) {
        isAnnotating = false
        isDraggingMeasureBox = false
        putKeysAway()
        for subview in subviews where subview !== toolbar && subview !== selfTimerBar {
            subview.removeFromSuperview()
        }
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        leaveElements()
        selectedWindows = []
        highlightedWindow = nil
        selection.reset()
        hasStartedAreaSelection = false
        showsReading = false
        isDraggingSelection = false
        transientContent.isHidden = mode != .area
        toolbar.isHidden = !showsToolbar
        toolbar.alphaValue = 1
        toolbar.select(mode == .area ? .area : .window)
        showsSelfTimerBar = showsToolbar && selfTimerDelay != nil
        selfTimerBar.isHidden = !showsSelfTimerBar
        selfTimerBar.alphaValue = 1
        layoutToolbar()
        layoutSelfTimerBar()
        updateHelp()
        window?.invalidateCursorRects(for: self)
        withoutAnimation {
            layoutLoupe()
            applyAppearance()
            border.isHidden = false
            border.lineDashPattern = nil
            snapEdges.isHidden = false
            lockedOutline.isHidden = false
            lockedBorder.isHidden = false
            for layer in [loupeShadow, loupe, loupeRim, loupePill.layer] { layer.zPosition = 0 }
            updateSelectionLayers()
        }
        movePointer(to: globalPointer)
    }

    /// Puts the crosshair and magnifier where the pointer is now, for an overlay that appears a moment
    /// after its session began.
    ///
    /// The crosshair and magnifier show only on the display the pointer is over; window mode highlights
    /// the window under it on every display the window reaches, clearing stale pointer and hover state on
    /// displays the window does not intersect.
    func movePointer(to globalPointer: CGPoint) {
        guard !isSimulated, !isAnnotating else { return }
        if display.frame.contains(globalPointer) {
            withoutAnimation { updatePointer(local(globalPointer)) }
        } else if mode == .window {
            let hovered = WindowCatalog.target(at: globalPointer, in: windows)
            let spanning = hovered.flatMap { !$0.frame.intersection(display.frame).isEmpty ? $0 : nil }
            withoutAnimation {
                let hadElement = pickedElement != nil || showsElementHint
                let hadPointer = pointer != nil
                pointer = nil
                leaveElements()
                if hoveredWindow != spanning || hadElement || (hadPointer && !selectedWindows.isEmpty) {
                    hoveredWindow = spanning
                    updateSelectionLayers()
                }
                for layer in [crosshair, crosshairOutline, loupeShadow, loupe, loupeRim, loupePill.layer] {
                    layer.isHidden = true
                }
                updateHintPill()
            }
        } else {
            withoutAnimation { updatePointer(nil) }
        }
    }

    /// Shows the magnifier on `point` (this view's points) while a corner or edge of a selection that was handed
    /// over (in-place annotation, a set-up frame) is dragged, so the edge can be placed to the pixel; nil hides it.
    /// `point` is the pixel just inside the selection where the dragged edges meet, which the lens centers on. Only a
    /// frozen screen has pixels to enlarge; on a live one the lens stays hidden.
    func showEdgeLoupe(at point: CGPoint?) {
        let layers: [CALayer] = [loupeShadow, loupe, loupeRim, loupePill.layer]
        withoutAnimation {
            guard let point, isAnnotating, let frame = capturedFrame, backdrop.contents != nil else {
                for layer in layers {
                    layer.isHidden = true
                    layer.zPosition = 0
                }
                return
            }
            let center = magnifiedLensCenter(for: point)
            for layer in [loupe, loupeRim, loupeShadow] { layer.position = center }
            // Always enlarged and opaque: the actual-size picker's see-through lens is for aiming before a press.
            // The next session's appearance puts back what Settings chose.
            loupeImage.opacity = 1
            loupe.backgroundColor = .white
            loupeShadow.fillColor = .white
            loupeShadow.shadowOpacity = 0.28
            let pixel = pixelCoordinate(at: point)
            loupeImage.contentsRect = Self.contentsRect(around: pixel, in: frame.image, pixelsAcross: loupePixelsAcross)
            let color = frame.color(atPixel: pixel.x, pixel.y)
            updateLoupeCenter(for: color)
            loupePill.swatch = color?.cgColor
            let value = color.map { $0.string(in: colorFormat) }
            loupePill.text = value.map { "\(pixel.x), \(pixel.y)   \($0)" } ?? "\(pixel.x), \(pixel.y)"
            let pillSize = loupePill.layer.bounds.size
            loupePill.layer.frame.origin = CGPoint(x: center.x - pillSize.width / 2, y: center.y - loupeDiameter / 2 - pillSize.height - 8)
            // Above the frame and the dimming that what was handed over draws over the screen, as its views lie
            // over this view's own layers.
            for layer in layers {
                layer.isHidden = false
                layer.zPosition = 1
            }
        }
    }

    /// Where the magnified lens goes for a target at `point`: below and to the right of it, on the other side where
    /// the display's edge would cut it off.
    private func magnifiedLensCenter(for point: CGPoint) -> CGPoint {
        let diameter = loupeDiameter
        let offset = Theme.Loupe.offset
        var center = CGPoint(x: point.x + offset + diameter / 2, y: point.y - offset - diameter / 2)
        if center.x + diameter / 2 > bounds.maxX - 6 { center.x = point.x - offset - diameter / 2 }
        if center.y - diameter / 2 - 32 < bounds.minY + 6 { center.y = point.y + offset + diameter / 2 }
        return center
    }

    // MARK: Parts of a window

    /// In window mode, the wheel turned toward you goes into the part of the hovered window under the pointer, one
    /// level at a time (a panel, then the list in it, then a button), and turned away comes back out to the window. A
    /// click then takes that part as an area. The parts are read through Accessibility on the first turn in, for the
    /// window and point at hand; with the permission off the reading says how to give it.
    override func scrollWheel(with event: NSEvent) {
        guard mode == .window, !isAnnotating, purpose.takesPicture, selectedWindows.isEmpty, let window = hoveredWindow, let pid = window.pid else {
            return super.scrollWheel(with: event)
        }
        // Up (away from you, as the device moves) is out; a flick's momentum steps nothing.
        let travel = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        var steps = 0
        if event.hasPreciseScrollingDeltas {
            guard event.momentumPhase == [] else { return }
            wheelTravel += travel
            steps = Int((wheelTravel / Self.wheelStep).rounded(.towardZero))
            wheelTravel -= CGFloat(steps) * Self.wheelStep
        } else if travel != 0 {
            steps = travel > 0 ? 1 : -1
        }
        let inward = -steps
        guard inward != 0 else { return }
        guard canReadElements() else {
            showsElementHint = true
            withoutAnimation { updateSelectionLayers() }
            return
        }
        if inward > 0, elementChain.isEmpty {
            lookUpElements(in: window, pid: pid, going: inward)
            return
        }
        stepElements(by: inward)
    }

    /// Reads the parts of `window` under the pointer off the main thread, then goes `going` steps in.
    private func lookUpElements(in window: WindowTarget, pid: pid_t, going inward: Int) {
        guard elementLookup == nil, let pointer else { return }
        let point = global(pointer)
        let layout = displayLayout
        let read = readElements
        elementLookup = Task { [weak self] in
            let chain = await Task.detached(priority: .userInitiated) {
                read(point, window.frame, pid, layout)
            }.value
            guard let self, !Task.isCancelled else { return }
            elementLookup = nil
            guard hoveredWindow == window else { return }
            elementChain = chain
            stepElements(by: inward)
        }
    }

    private func stepElements(by steps: Int) {
        let depth = min(max(elementDepth + steps, 0), elementChain.count)
        guard depth != elementDepth else { return }
        elementDepth = depth
        withoutAnimation { updateSelectionLayers() }
        announceValue()
    }

    /// Back to the window itself, the parts read for another window or point forgotten.
    private func leaveElements() {
        elementLookup?.cancel()
        elementLookup = nil
        elementChain = []
        elementDepth = 0
        wheelTravel = 0
        showsElementHint = false
    }

    /// The reading says how to let the wheel go into windows: the Accessibility permission is off.
    private var showsElementHint = false

    /// Draws the controller's selection: the part of it on this display, the size reading if this
    /// display has it. The All-In-One bar steps out of the way while a region is being dragged.
    private(set) var isDraggingSelection = false

    func show(selection: SelectionModel, showsReading: Bool, isDragging: Bool) {
        self.selection = selection
        self.showsReading = showsReading
        self.isDraggingSelection = isDragging
        let hidesPicker = usesCenteredPicker && !hasStartedAreaSelection && (isDragging || selection.rect != nil)
        if hidesPicker { hasStartedAreaSelection = true }
        let toolbarAlpha: CGFloat = isDragging && selection.rect != nil ? 0 : 1
        let selfTimerAlpha: CGFloat = isDragging ? 0 : 1
        // The bars fading or coming back under the pointer hand the pointer between the arrow and the crosshair.
        let toolbarFades = (!toolbar.isHidden && toolbar.alphaValue != toolbarAlpha)
            || (!selfTimerBar.isHidden && selfTimerBar.alphaValue != selfTimerAlpha)

        if !toolbar.isHidden { toolbar.alphaValue = toolbarAlpha }
        if !selfTimerBar.isHidden { selfTimerBar.alphaValue = selfTimerAlpha }
        withoutAnimation {
            updateSelectionLayers()
            if hidesPicker || toolbarFades { updatePointer(pointer) }
            updateHintPill()
        }
    }

    /// The controller shares the hidden choice across displays, without making an unavailable bar appear.
    func setToolbarHidden(_ hidden: Bool) {
        let changed = toolbarHiddenByUser != hidden
        toolbarHiddenByUser = hidden
        toolbar.isHidden = !offersToolbar || hidden || isAnnotating
        window?.invalidateCursorRects(for: toolbar)
        withoutAnimation {
            updateSelectionLayers()
            updatePointer(pointer)
        }
        if changed, offersToolbar {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: hidden
                    ? String(localized: "Toolbar hidden. Press H to show it.", bundle: .module)
                    : String(localized: "Toolbar shown.", bundle: .module),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    /// Native controls borrow the system cursor from the canvas, including throughout a grip drag.
    func wantsSystemCursor(at globalPoint: CGPoint) -> Bool {
        guard !isAnnotating else { return false }
        let point = local(globalPoint)
        if !toolbar.isHidden && toolbar.alphaValue > 0 && (toolbar.isDragging || toolbar.frame.contains(point)) { return true }
        if !selfTimerBar.isHidden && selfTimerBar.alphaValue > 0 && selfTimerBar.frame.contains(point) { return true }
        return false
    }

    /// Cursor ownership starts only once the controller has taken input; other displays acquire the
    /// same policy without changing the cursor until the pointer reaches them.
    func beginCanvasCursorOwnership(at globalPoint: CGPoint) {
        ownsCanvasCursor = !isAnnotating && usesCenteredPicker
        window?.invalidateCursorRects(for: self)
        refreshCanvasCursor(at: globalPoint)
    }

    func refreshCanvasCursor(at globalPoint: CGPoint) {
        guard ownsCanvasCursor, !isAnnotating, display.frame.contains(globalPoint) else { return }
        let cursor: NSCursor
        if wantsSystemCursor(at: globalPoint) {
            let point = convert(local(globalPoint), to: toolbar)
            cursor = toolbar.isDragging ? .closedHand
                : (toolbar.dragHandleFrame.contains(point) ? .openHand : .arrow)
        } else {
            cursor = OverlayCursorVisibility.canvasCursor
        }
        if NSCursor.current !== cursor { cursor.set() }
    }

    private func endCanvasCursorOwnership() {
        guard ownsCanvasCursor else { return }
        ownsCanvasCursor = false
        window?.invalidateCursorRects(for: self)
        OverlayCursorVisibility.restoreCanvasCursor()
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
        layoutSelfTimerBar()
        withoutAnimation { updateHintPill() }
    }

    /// Copying text keeps the system crosshair; a screenshot draws its own crosshair and magnifier.
    override func resetCursorRects() {
        super.resetCursorRects()
        if purpose == .text { addCursorRect(bounds, cursor: .crosshair) }
        else if ownsCanvasCursor { addCursorRect(bounds, cursor: OverlayCursorVisibility.canvasCursor) }
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
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    // Pointer moves go to the controller, which passes them to every display: the key panel hears moves
    // over other displays too, and drawing them here left a stray magnifier at this display's edge.
    override func cursorUpdate(with event: NSEvent) {
        guard ownsCanvasCursor, !isAnnotating else { return }
        let point = global(convert(event.locationInWindow, from: nil))
        onCanvasCursorUpdate?(point)
        refreshCanvasCursor(at: point)
    }

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
        guard !isSimulated, !isAnnotating, pointer != nil else { return }
        withoutAnimation { updatePointer(nil) }
    }

    // Area mode hands the press to the controller, which keeps one selection for every display: drag
    // events keep coming here even once the pointer is over another display, in global space.
    // Picking a color takes the pixel when the mouse is released; the ruler draws its box here, on the
    // display the press began on.
    override func mouseDown(with event: NSEvent) {
        guard mode == .area, !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown, event.buttonNumber == 0,
           colorCopyGesture.matches(event.modifierFlags), selection.anchor == nil,
           purpose == .screenshot || purpose == .annotate || purpose == .color,
           delegate?.overlayView(self, copyColorAt: global(point)) == true {
            delegate?.overlayView(self, didMovePointerTo: global(point))
            isCopyingColor = true
            return
        }
        switch purpose {
        case .color:
            break
        case .measure:
            isDraggingMeasureBox = true
            let plain = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            measure?.beginBox(at: point, allowsCapture: plain)

        case .screenshot, .text, .annotate, .record, .scroll:
            delegate?.overlayView(self, didPressAt: global(point))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isCopyingColor {
            delegate?.overlayView(self, didMovePointerTo: global(point))
            return
        }
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

    /// Cycles through overlapping windows under the pointer, or all on-screen windows when fewer than two lie under it.
    func cycleWindow(backward: Bool = false) {
        guard mode == .window, !windows.isEmpty else { return }
        hoveredWindow = WindowCatalog.cycledTarget(
            from: hoveredWindow, at: pointer.map(global), in: windows, backward: backward
        )
        withoutAnimation { updateSelectionLayers() }
        announceValue()
    }

    private func toggleSelectedWindow(_ window: WindowTarget) {
        if let index = selectedWindows.firstIndex(of: window) {
            selectedWindows.remove(at: index)
        } else {
            selectedWindows.append(window)
        }
        if !selectedWindows.isEmpty { leaveElements() }
        withoutAnimation { updateSelectionLayers() }
        announceValue()
        delegate?.overlayView(self, didChangeSelectedWindows: selectedWindows)
    }

    override func mouseUp(with event: NSEvent) {
        if isCopyingColor {
            isCopyingColor = false
            return
        }
        guard !isAnnotating else { return }
        if mode == .window {
            let allowsMultiple = purpose.choosesSeveralWindows
            if allowsMultiple, event.modifierFlags.contains(.shift), let hoveredWindow {
                toggleSelectedWindow(hoveredWindow)
                return
            }
            if !selectedWindows.isEmpty {
                let targets = selectedWindows
                if targets.count == 1 {
                    delegate?.overlayView(self, didSelectWindow: targets[0], modifiers: event.modifierFlags)
                } else {
                    delegate?.overlayView(self, didSelectWindows: targets, modifiers: event.modifierFlags)
                }
                return
            }
            // A part of the window the wheel went into is taken as an area.
            if let element = pickedElement {
                delegate?.overlayView(self, didSelectElement: element.frame, modifiers: event.modifierFlags)
                return
            }
            if let hoveredWindow { delegate?.overlayView(self, didSelectWindow: hoveredWindow, modifiers: event.modifierFlags) }
            return
        }
        switch purpose {
        case .color:
            delegate?.overlayView(self, didPickColorAt: global(convert(event.locationInWindow, from: nil)), modifiers: event.modifierFlags, keyboard: false)
        case .measure:
            guard isDraggingMeasureBox else { return }
            isDraggingMeasureBox = false
            let bypassSnap = !event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            let point = convert(event.locationInWindow, from: nil)
            if let area = measure?.endBox(at: point, snapping: !bypassSnap, allowsCapture: !bypassSnap) {
                delegate?.overlayView(self, didSelect: global(area), modifiers: event.modifierFlags)
                return
            }
            setAccessibilityValue(measure?.accessibilityValue)
            announceValue()
        case .screenshot, .text, .annotate, .record, .scroll:
            delegate?.overlayView(self, didReleaseWith: event.modifierFlags)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isAnnotating else {
            super.rightMouseDown(with: event)
            return
        }
        if purpose == .measure, isDraggingMeasureBox {
            isDraggingMeasureBox = false
            measure?.cancelBox()
            setAccessibilityValue(measure?.accessibilityValue)
            return
        }
        if isDraggingSelection {
            delegate?.overlayViewDidResetDrag(self)
        } else {
            delegate?.overlayViewDidCancel(self)
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
        // ? shows the keys of what is being chosen by the display's edge; Escape, or any other key, puts them away, and
        // Escape does nothing more then.
        if event.charactersIgnoringModifiers == "?", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            delegate?.overlayViewDidToggleKeys(self)
            return
        }
        if delegate?.overlayViewDidPutKeysAway(self) == true, event.keyCode == 53 { return }
        let character = event.charactersIgnoringModifiers?.lowercased()
        if character == "h", purpose == .screenshot || purpose == .annotate || purpose == .record,
           let onToolbarVisibilityToggle,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            onToolbarVisibilityToggle()
            return
        }
        if selfTimerDelay != nil, !isDraggingSelection,
           event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
           let character {
            if character == "d" {
                if !event.isARepeat {
                    let next = selfTimerBar.cycleNext()
                    chooseSelfTimerDelay(next)
                }
                return
            }
            if let digit = Int(character), (1...9).contains(digit),
               let next = selfTimerBar.delay(atPresetIndex: digit - 1) {
                chooseSelfTimerDelay(next)
                return
            }

        }
        if character == "w", event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
           !isDraggingSelection, purpose == .screenshot || purpose == .record {
            delegate?.overlayViewDidRequestWindowPicker(self)
            return
        }
        let picks = purpose.picksPixels
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
            if purpose == .measure, isDraggingMeasureBox {
                isDraggingMeasureBox = false
                measure?.cancelBox()
                setAccessibilityValue(measure?.accessibilityValue)
                return
            }
            delegate?.overlayViewDidCancel(self)
        case 51 where isDraggingSelection && mode == .area, 117 where isDraggingSelection && mode == .area:
            delegate?.overlayViewDidResetDrag(self)
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
            if mode == .area, isAllInOne, purpose == .screenshot, !isDraggingSelection, !selectedWindows.isEmpty {
                delegate?.overlayView(self, didSelectWindows: selectedWindows, modifiers: event.modifierFlags.subtracting(.shift))
                return
            }
            if mode == .window {
                if !selectedWindows.isEmpty {
                    if selectedWindows.count == 1 {
                        delegate?.overlayView(self, didSelectWindow: selectedWindows[0], modifiers: event.modifierFlags)
                    } else {
                        delegate?.overlayView(self, didSelectWindows: selectedWindows, modifiers: event.modifierFlags)
                    }
                    return
                }
                if let element = pickedElement {
                    delegate?.overlayView(self, didSelectElement: element.frame, modifiers: event.modifierFlags)
                    return
                }
                if let hoveredWindow {
                    delegate?.overlayView(self, didSelectWindow: hoveredWindow, modifiers: event.modifierFlags)
                    return
                }
            }
            switch purpose {
            case .color:
                if let pointer { delegate?.overlayView(self, didPickColorAt: global(pointer), modifiers: event.modifierFlags, keyboard: true) }
            case .measure:
                if let text = measure?.measurement { delegate?.overlayView(self, didCopyMeasurement: text, ending: true) }
            case .screenshot, .text, .annotate, .record, .scroll:
                super.keyDown(with: event)
            }
        case 48 where purpose == .color:
            let all = ColorFormat.allCases
            if let index = all.firstIndex(of: colorFormat) {
                let step = event.modifierFlags.contains(.shift) ? -1 : 1
                let next = all[(index + step + all.count) % all.count]
                delegate?.overlayView(self, didChangeColorFormat: next)
            }
        case 48 where purpose == .measure:
            if let measure { delegate?.overlayView(self, didChangeUnit: measure.unit.toggled) }
        case 48 where mode == .window && !windows.isEmpty:
            cycleWindow(backward: event.modifierFlags.contains(.shift))
        case 48 where mode == .area && purpose.opensSizeControl(allInOne: isAllInOne):
            // Tab frames the area for a size typed and a shape kept; the drag itself needs none of this.
            delegate?.overlayViewDidRequestSizing(self)
        default:
            if mode == .window, !windows.isEmpty, character == "[" || character == "]",
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                cycleWindow(backward: character == "[")
            } else if character == "u", purpose == .measure, let measure {
                delegate?.overlayView(self, didChangeUnit: measure.unit.toggled)
            } else if character == "f", purpose == .measure, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                // The whole display, as F takes it while choosing an area, with what is measured on it. With nothing
                // measured yet there is nothing to show, as for Return.
                if let imprint = measure?.imprint { delegate?.overlayView(self, didCaptureMeasurement: imprint.measurement, of: imprint.frame) }
            } else if isAllInOne, !event.modifierFlags.contains(.command), let choice = character.flatMap(AllInOneBar.Choice.init(key:)) {
                // All-In-One's letters, before an area is chosen: A, W, and F, O, S, R, and M, as the bar has them.
                toolbarChose(choice)
            } else if character == "l", !event.modifierFlags.contains(.command), mode == .area, !isDraggingSelection,
                      purpose.recallsLastArea {
                delegate?.overlayViewDidRequestLastArea(self)
            } else if character == "c", !event.modifierFlags.contains(.command), mode == .area, purpose.picksColorWithC, let pointer, capturedFrame != nil {
                // C takes the color under the crosshair, as in Snipaste: from the magnifier while capturing. With
                // Option it opens the color card, as Option-Return does.
                delegate?.overlayView(self, didPickColorAt: global(pointer), modifiers: event.modifierFlags.intersection(.option), keyboard: true)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// ⌘C copies the ruler's measurement; the overlay stays for the next one. Any ⌘ key first puts away the keys ? showed,
    /// as any other key does, ⌘Z in a framed area too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { _ = delegate?.overlayViewDidPutKeysAway(self) ?? putKeysAway() }
        guard purpose == .measure, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c",
              let text = measure?.measurement else { return super.performKeyEquivalent(with: event) }
        delegate?.overlayView(self, didCopyMeasurement: text, ending: false)
        measure?.flashCopied()
        return true
    }

    // MARK: Keys

    /// The keys of the overlay's purpose, as its VoiceOver help says them.
    var keyHelp: String { accessibilityHelp() ?? "" }

    /// Whether the keys show on this display.
    var showsKeys: Bool { !keyList.layer.isHidden }

    /// What the keys show, a sentence a line, for tests.
    var debugKeys: String { keyList.text }

    /// Shows `help`'s keys a sentence a line in a reading capsule near this display's edge (`keysFrame`), over everything
    /// the overlay shows; it is part of the overlay, so it is never in a capture.
    func showKeys(_ help: String) {
        let lines = Sentences.split(help)
        guard !lines.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        withoutAnimation {
            keyList.maximumTextWidth = max(bounds.width - 2 * Self.keysInset - 22, 160)
            keyList.text = lines.joined(separator: "\n")
            var avoidingBar: CGRect?
            for rect in [
                (!toolbar.isHidden && toolbar.alphaValue > 0) ? toolbar.frame : nil,
                (!selfTimerBar.isHidden && selfTimerBar.alphaValue > 0) ? selfTimerBar.frame : nil,
                !hintPill.layer.isHidden ? hintPill.layer.frame : nil,
            ].compactMap(\.self) {
                avoidingBar = avoidingBar.map { $0.union(rect) } ?? rect
            }
            keyList.layer.frame = Self.keysFrame(
                size: keyList.layer.bounds.size, pointer: display.frame.contains(mouse) ? local(mouse) : pointer, in: bounds,
                avoiding: avoidingBar
            )
            keyList.layer.isHidden = false
        }
        VoiceOver.announce(help, from: self)
    }

    /// Shows `help`'s keys, or puts them away when they show.
    func toggleKeys(_ help: String) {
        if !putKeysAway() { showKeys(help) }
    }

    /// Puts the keys away; true when they showed.
    @discardableResult
    func putKeysAway() -> Bool {
        guard showsKeys else { return false }
        withoutAnimation { keyList.layer.isHidden = true }
        return true
    }

    /// How far in from the display's top or bottom edge the keys sit.
    static let keysInset: CGFloat = 40

    /// Where the keys go (y up, as this view lays out): centered across `bounds`, `keysInset` in from its top or bottom
    /// edge, whichever is further from `pointer` (the bottom without one), so they never cover what it points at; at the
    /// bottom, 12 pt over `bar` when it shows. Kept 6 pt inside, as every reading is.
    static func keysFrame(size: CGSize, pointer: CGPoint?, in bounds: CGRect, avoiding bar: CGRect?) -> CGRect {
        let bottom = max(bounds.minY + keysInset, (bar?.maxY ?? -.greatestFiniteMagnitude) + 12)
        let top = bounds.maxY - keysInset - size.height
        let pointsLow = pointer.map { $0.y < bounds.midY } ?? false
        let y = pointsLow ? top : bottom
        let room = bounds.insetBy(dx: 6, dy: 6)
        return CGRect(
            x: min(max(bounds.midX - size.width / 2, room.minX), room.maxX - size.width),
            y: min(max(y, room.minY), room.maxY - size.height), width: size.width, height: size.height
        )
    }

    /// Tells VoiceOver what the crosshair is on now (the color, or the measurement), for keys that move it
    /// or change the reading; the pointer's own moves only update the value.
    func announceValue() {
        guard let value = accessibilityValue() as? String, !value.isEmpty else { return }
        VoiceOver.announce(value, from: self, priority: .medium)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { delegate?.overlayViewDidReleaseSpace(self) }
    }

    /// Marks what All-In-One's next area is for on the bar; nil for a plain capture.
    func markPurpose(_ choice: AllInOneBar.Choice?) {
        toolbar.markPurpose(choice)
        let takesW = purpose == .screenshot || purpose == .record
        toolbar.usesWindowPreview(takesW && choice != .text && choice != .scroll, takesW: takesW)
        layoutToolbar()
        layoutSelfTimerBar()
    }

    private func chooseSelfTimerDelay(_ seconds: Int) {
        guard selfTimerDelay != nil else { return }
        let clamped = max(seconds, 1)
        let changed = clamped != selfTimerDelay
        selfTimerDelay = clamped
        selfTimerBar.select(clamped)
        layoutSelfTimerBar()
        window?.invalidateCursorRects(for: self)
        if changed {
            VoiceOver.announce(String(localized: "Self-Timer: \(clamped) seconds", bundle: .module), from: self)
            delegate?.overlayView(self, didChangeSelfTimerDelay: clamped)
        }
    }

    /// Highlights All-In-One's window under the pointer on this display, or nil for none.
    func highlight(_ window: OverlayController.HoveredWindow?) {
        guard window != highlightedWindow else { return }
        highlightedWindow = window
        withoutAnimation { updateSelectionLayers() }
    }

    /// Keeps multi-window selections (All-In-One area-mode Shift-clicks or window-mode cross-display
    /// Shift-clicks) visible and synchronized across every display.
    func setSelectedWindows(_ windows: [WindowTarget]) {
        guard selectedWindows != windows else { return }
        selectedWindows = windows
        if !selectedWindows.isEmpty { leaveElements() }
        withoutAnimation { updateSelectionLayers() }
    }

    static func roundedWindowPaths(_ rects: [CGRect]) -> [CGPath] {
        rects.filter { !$0.isNull && !$0.isEmpty }.map { CGPath.continuousRoundedRect($0, radius: 12) }
    }

    static func roundedWindowPath(_ rects: [CGRect]) -> CGPath {
        let path = CGMutablePath()
        for windowPath in roundedWindowPaths(rects) { path.addPath(windowPath) }
        return path
    }

    /// Shows the screen as it is now instead of as it was frozen, for a recording set up from a frozen All-In-One.
    func showLive() {
        withoutAnimation { backdrop.contents = nil }
    }

    private func toolbarChose(_ choice: AllInOneBar.Choice) {
        // Text, scrolling, or recording: what the next area is for.
        if let next = choice.purpose {
            delegate?.overlayView(self, didChooseMode: next)
            return
        }
        switch choice {
        case .area where isAllInOne:
            // All-In-One's Area is a plain capture of an area: whatever the next area was for is let go.
            if mode != .area { delegate?.overlayView(self, didSwitchTo: .area) }
            delegate?.overlayView(self, didChooseMode: .screenshot(nil))
        case .area where mode != .area:
            delegate?.overlayView(self, didSwitchTo: .area)
        case .window:
            if purpose == .screenshot || purpose == .record {
                delegate?.overlayViewDidRequestWindowPicker(self)
            } else if mode != .window {
                delegate?.overlayView(self, didSwitchTo: .window)
            }
        case .fullscreen:
            delegate?.overlayViewDidRequestDisplayCapture(self)
        case .measure:
            delegate?.overlayViewDidRequestMeasure(self)
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

        transientContent.frame = bounds
        transientContent.masksToBounds = true

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
        for line in [lockedOutline, lockedBorder] {
            line.fillColor = nil
            line.lineJoin = .round
            line.lineCap = .round
        }

        layoutLoupe()
        loupe.masksToBounds = true
        loupe.backgroundColor = .white
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        for shape in [loupeGridOutline, loupeGrid, loupeCenterOutline, loupeCenter, loupeTargetOutline, loupeTarget] {
            shape.contentsScale = display.backingScale
        }
        loupeCenter.fillColor = nil
        loupeCenterOutline.fillColor = nil
        loupe.addSublayer(loupeImage)
        loupe.addSublayer(loupeGridOutline)
        loupe.addSublayer(loupeGrid)
        loupe.addSublayer(loupeCenterOutline)
        loupe.addSublayer(loupeCenter)
        for shape in [loupeTargetOutline, loupeTarget] {
            shape.fillColor = nil
            loupe.addSublayer(shape)
        }

        // A soft shadow under the lens and a white rim around it, both outside the masked lens.
        loupeShadow.fillColor = .white
        loupeShadow.shadowOpacity = 0.28
        loupeShadow.shadowRadius = 12
        loupeShadow.shadowOffset = CGSize(width: 0, height: -4)
        loupeRim.strokeColor = .white
        loupeRim.fillColor = nil
        loupeRim.lineWidth = Theme.Loupe.rimWidth

        sizePill.setScale(display.backingScale)
        hintPill.setScale(display.backingScale)
        loupePill.setScale(display.backingScale)
        keyList.setScale(display.backingScale)
        // Over what a frame set up for its next step draws on this view (its views lie over this view's own layers),
        // and over the lens raised there.
        keyList.layer.zPosition = 2
        for sublayer in [backdrop, transientContent, room, outline, border, snapEdges, lockedOutline, lockedBorder, crosshairOutline, crosshair, loupeShadow, loupe, loupeRim, hintPill.layer, sizePill.layer, loupePill.layer, keyList.layer] {
            root.addSublayer(sublayer)
        }
        withoutAnimation {
            applyAppearance()
            updateSelectionLayers()
        }
    }

    private var loupeDiameter: CGFloat { usesCenteredPicker ? captureLoupeSize.diameter : Theme.Loupe.diameter }
    private var loupePixelsAcross: Int {
        usesCenteredPicker ? captureLoupeSize.pixelsAcross(backingScale: display.backingScale, magnification: captureLoupeMagnification) : Theme.Loupe.pixelsAcross
    }

    /// Reused views may switch both size and purpose between sessions; keep every lens layer in sync.
    private func layoutLoupe() {
        let diameter = loupeDiameter
        let cell = diameter / CGFloat(loupePixelsAcross)
        // Low zoom still needs an open cell interior; normal tools and the default 4× widths stay as before.
        let pixelStroke = usesCenteredPicker ? min(1 / display.backingScale, cell / 3) : 1 / display.backingScale
        let pixelOutline = usesCenteredPicker ? min(2 / display.backingScale, cell * 2 / 3) : 2 / display.backingScale
        let lensBounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        loupe.bounds = lensBounds
        loupe.cornerRadius = diameter / 2
        loupeImage.frame = lensBounds
        loupeGrid.frame = lensBounds
        loupeGrid.path = Self.gridPath(size: diameter, cells: loupePixelsAcross)
        loupeGrid.isHidden = false
        loupeGrid.lineWidth = pixelStroke
        loupeGrid.strokeColor = CGColor(gray: 0, alpha: usesCenteredPicker ? 0.28 : 0.08)
        loupeGridOutline.frame = lensBounds
        loupeGridOutline.path = loupeGrid.path
        loupeGridOutline.lineWidth = pixelOutline
        loupeGridOutline.strokeColor = CGColor(gray: 1, alpha: 0.35)
        loupeGridOutline.isHidden = !usesCenteredPicker
        loupeCenter.frame = lensBounds
        let centerCell = CGRect(x: (diameter - cell) / 2, y: (diameter - cell) / 2, width: cell, height: cell)
        loupeCenter.path = usesCenteredPicker ? CGPath(rect: centerCell, transform: nil)
            : CGPath(roundedRect: centerCell, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        loupeCenter.lineWidth = usesCenteredPicker ? pixelStroke : 1.5
        loupeCenterOutline.lineWidth = usesCenteredPicker ? pixelOutline : 3
        loupeCenterOutline.frame = lensBounds
        loupeCenterOutline.path = loupeCenter.path
        let target = CGMutablePath()
        let center = diameter / 2
        // Leave the exact cell and its outline clear; the ticks do not shrink with the pixel grid.
        let gap = max(5, cell / 2 + 3)
        for direction in [CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0),
                          CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1)] {
            target.move(to: CGPoint(x: center + direction.dx * gap, y: center + direction.dy * gap))
            target.addLine(to: CGPoint(x: center + direction.dx * (gap + 4), y: center + direction.dy * (gap + 4)))
        }
        for shape in [loupeTargetOutline, loupeTarget] {
            shape.frame = lensBounds
            shape.path = target
            shape.isHidden = !usesCenteredPicker
        }
        loupeTarget.lineWidth = 1
        loupeTargetOutline.lineWidth = 3
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
        let isDark = effectiveAppearance.isDark
        sizePill.applyAppearance(dark: isDark, contrast: increasedContrast)
        hintPill.applyAppearance(dark: isDark, contrast: increasedContrast)
        loupePill.applyAppearance(dark: isDark, contrast: increasedContrast)
        keyList.applyAppearance(dark: isDark, contrast: increasedContrast)
        for badge in lockedBadges { badge.applyAppearance(dark: isDark, contrast: increasedContrast) }
        // Text: the selection reads as selected text (the system's selection color, lightly filled,
        // edged in the accent), over an undimmed screen. Screenshot: a white edge over a soft outline.
        let text = purpose == .text
        // Picking a color and measuring show the screen as it is: they choose no area.
        let undimmed = !purpose.dimsScreen
        room.isHidden = undimmed
        outline.isHidden = undimmed
        let accent = Theme.cgColor(.controlAccentColor, for: effectiveAppearance)
        measure?.applyAppearance(dark: isDark, contrast: increasedContrast, accent: accent)
        border.lineWidth = text ? Self.textSelectionEdge(increasedContrast: increasedContrast) : Theme.Overlay.borderWidth
        border.strokeColor = text ? accent : .white
        // Resolved for this appearance before the alpha is applied: applying it first fixes the
        // dynamic color to its light value.
        border.fillColor = text
            ? Theme.cgColor(.selectedTextBackgroundColor, for: effectiveAppearance).copy(alpha: isDark ? 0.45 : 0.35)
            : nil
        // An edge that snapped is the accent and a half point heavier than the others (a point heavier on the
        // text selection's thin edge), so it reads without the color.
        snapEdges.strokeColor = accent
        snapEdges.lineWidth = border.lineWidth + (text ? 1 : 0.5)
        // Locked windows in multi-select wear an accent outline over a white contrast stroke so they stand
        // clearly apart from the hovered window.
        lockedOutline.strokeColor = CGColor(gray: 1, alpha: increasedContrast ? 1 : 0.85)
        lockedOutline.lineWidth = increasedContrast ? 5.5 : 4.5
        lockedBorder.strokeColor = accent
        lockedBorder.lineWidth = increasedContrast ? 3 : 2.5
    }

    private func hideLockedVisuals() {
        lockedOutline.path = nil
        lockedBorder.path = nil
        border.lineDashPattern = nil
        for badge in lockedBadges { badge.layer.isHidden = true }
    }

    private func positionSizePill(under rect: CGRect) {
        let pillSize = sizePill.layer.bounds.size
        var origin = CGPoint(x: rect.midX - pillSize.width / 2, y: rect.minY - pillSize.height - 10)
        if origin.y < 6 { origin.y = rect.minY + 10 }
        origin.x = max(6, min(origin.x, max(6, bounds.maxX - pillSize.width - 6)))
        let obstacles: [CGRect] = [
            (!toolbar.isHidden && toolbar.alphaValue > 0) ? toolbar.frame : nil,
            (!selfTimerBar.isHidden && selfTimerBar.alphaValue > 0) ? selfTimerBar.frame : nil,
            !hintPill.layer.isHidden ? hintPill.layer.frame : nil,
        ].compactMap(\.self)
        for _ in 0..<obstacles.count {
            var shifted = false
            for obstacle in obstacles where CGRect(origin: origin, size: pillSize).intersects(obstacle.insetBy(dx: -8, dy: -8)) {
                origin.y = max(origin.y, obstacle.maxY + 10)
                shifted = true
            }
            if !shifted { break }
        }
        origin.y = min(max(origin.y, 6), max(6, bounds.maxY - pillSize.height - 6))
        sizePill.layer.frame.origin = origin
    }

    private func updateSelectionLayers() {
        if mode == .window, !selectedWindows.isEmpty {
            updateMultiWindowSelectionLayers()
            return
        }
        hideLockedVisuals()
        let roomPath = CGMutablePath()
        roomPath.addRect(bounds)
        let element = mode == .window ? pickedElement : nil
        // All-In-One's window under the pointer stands for the selection until a drag makes one.
        let highlighted = mode == .area && selection.isTooSmall ? highlightedWindow : nil
        // A drag that passes the click threshold is an area selection, so its rectangular frame supersedes the
        // retained Shift-selected window outlines. Before then, keep those outlines and the live hover preview.
        var areaWindows: [WindowTarget] = mode == .area && selection.isTooSmall ? selectedWindows : []
        var roundedWindows: [CGRect] = areaWindows.compactMap { window in
            let part = window.frame.intersection(display.frame)
            return !part.isNull && !part.isEmpty ? part : nil
        }
        if let highlighted, !selectedWindows.contains(highlighted.window) {
            areaWindows.append(highlighted.window)
            roundedWindows.append(highlighted.area)
        }
        let selectedBounds = roundedWindows.dropFirst().reduce(roundedWindows.first) { $0?.union($1) }
        let target = mode == .window
            ? (element?.frame ?? hoveredWindow?.frame)?.intersection(display.frame)
            : (selection.isTooSmall ? selectedBounds : selection.rect)
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
        let windowRects = roundedWindows.map(local)
        let windowPath = Self.roundedWindowPath(windowRects)
        let windowMaskPath = SelectionChromeView.unionPath(Self.roundedWindowPaths(windowRects))
        roomPath.addPath(windowMaskPath ?? (windowPath.isEmpty ? CGPath(rect: rect, transform: nil) : windowPath))
        room.path = roomPath
        let edge = windowPath.isEmpty ? CGPath(rect: rect, transform: nil) : windowPath
        let inset = Self.textSelectionEdge(increasedContrast: increasedContrast) / 2
        let drawn = purpose == .text ? rect.integral.insetBy(dx: inset, dy: inset) : rect
        border.path = purpose == .text ? CGPath(rect: drawn, transform: nil) : edge
        outline.path = edge
        snapEdges.path = mode == .area && highlighted == nil ? Self.path(of: selection.snappedEdges, in: drawn) : nil

        let text: String
        if mode == .window, let element {
            let scale = display.pixelsPerPoint
            let size = "\(Int((element.frame.width * scale).rounded())) × \(Int((element.frame.height * scale).rounded()))"
            text = element.name.map { "\($0)  ·  \(size)" } ?? size
        } else if mode == .window, showsElementHint {
            text = String(localized: "Allow OhMyShot in Privacy & Security › Accessibility to pick parts of windows", bundle: .module)
        } else if mode == .window, let win = hoveredWindow {
            let scale = display.pixelsPerPoint
            let width = Int((win.frame.width * scale).rounded())
            let height = Int((win.frame.height * scale).rounded())
            text = win.ownerName.isEmpty ? "\(width) × \(height)" : "\(win.ownerName)  ·  \(width) × \(height)"
        } else if mode == .area, selection.isTooSmall, !roundedWindows.isEmpty {
            let scale = display.pixelsPerPoint
            let width = Int((globalRect.width * scale).rounded())
            let height = Int((globalRect.height * scale).rounded())
            if areaWindows.count > 1 {
                text = String(localized: "\(areaWindows.count) windows  ·  \(width) × \(height)", bundle: .module)
            } else if let win = areaWindows.first {
                let size = AreaFrame.pixelReading(globalRect.size, pixelsPerPoint: scale)
                text = win.ownerName.isEmpty ? size : "\(win.ownerName)  ·  \(size)"
            } else {
                text = AreaFrame.pixelReading(globalRect.size, pixelsPerPoint: scale)
            }
        } else {
            let size = selection.pixelSize
            text = "\(size.width) × \(size.height)"
        }
        sizePill.text = text
        sizePill.layer.isHidden = purpose == .text || (mode == .area && !showsReading && roundedWindows.isEmpty)
        // Text mode has no readings; a hovered window is named, without its size.
        setAccessibilityValue(purpose == .text ? (mode == .window ? hoveredWindow?.ownerName : nil) : text)
        positionSizePill(under: rect)
    }

    /// Draws locked windows in `selectedWindows` with distinct accent outlines and numbered order badges,
    /// keeping any separate unshifted hovered window in a dashed white outline so the user always sees what
    /// is locked versus merely hovered.
    private func updateMultiWindowSelectionLayers() {
        let lockedOnDisplay: [(index: Int, window: WindowTarget, rect: CGRect)] = selectedWindows.enumerated().compactMap { index, win in
            let intersection = win.frame.intersection(display.frame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (index, win, local(intersection))
        }
        let hoveredRect: CGRect? = hoveredWindow.flatMap { hovered in
            guard !selectedWindows.contains(hovered) else { return nil }
            let intersection = hovered.frame.intersection(display.frame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return local(intersection)
        }

        // Punch out every locked window and any hovered candidate without dark even-odd overlaps.
        var cutout: CGPath?
        for item in lockedOnDisplay {
            let piece = CGPath(rect: item.rect, transform: nil)
            cutout = cutout.map { $0.union(piece) } ?? piece
        }
        if let hoveredRect {
            let piece = CGPath(rect: hoveredRect, transform: nil)
            cutout = cutout.map { $0.union(piece) } ?? piece
        }
        let fullBounds = CGPath(rect: bounds, transform: nil)
        room.path = cutout.map { fullBounds.subtracting($0) } ?? fullBounds

        // Locked window outlines (solid accent over white contrast stroke).
        if lockedOnDisplay.isEmpty {
            lockedOutline.path = nil
            lockedBorder.path = nil
        } else {
            let lockedPath = CGMutablePath()
            for item in lockedOnDisplay { lockedPath.addRect(item.rect) }
            lockedOutline.path = lockedPath
            lockedBorder.path = lockedPath
        }

        // Order badges (1, 2, …) at the top-left of each locked window on this display.
        let isDark = effectiveAppearance.isDark
        while lockedBadges.count < lockedOnDisplay.count {
            let badge = ReadingCapsule()
            badge.setScale(display.backingScale)
            badge.applyAppearance(dark: isDark, contrast: increasedContrast)
            layer?.insertSublayer(badge.layer, above: lockedBorder)
            lockedBadges.append(badge)
        }
        for (slot, item) in lockedOnDisplay.enumerated() {
            let badge = lockedBadges[slot]
            badge.text = "\(item.index + 1)"
            let badgeSize = badge.layer.bounds.size
            let x = min(max(item.rect.minX + 8, 6), max(6, bounds.maxX - badgeSize.width - 6))
            let y = min(max(item.rect.maxY - badgeSize.height - 8, 6), max(6, bounds.maxY - badgeSize.height - 6))
            badge.layer.frame.origin = CGPoint(x: x, y: y)
            badge.layer.isHidden = false
        }
        for slot in lockedOnDisplay.count..<lockedBadges.count {
            lockedBadges[slot].layer.isHidden = true
        }

        // Candidate hovered window (not in `selectedWindows`): distinct dashed white outline.
        if let hoveredRect {
            let hoverEdge = CGPath(rect: hoveredRect, transform: nil)
            let inset = Self.textSelectionEdge(increasedContrast: increasedContrast) / 2
            let drawn = purpose == .text ? hoveredRect.integral.insetBy(dx: inset, dy: inset) : hoveredRect
            outline.path = hoverEdge
            border.path = purpose == .text ? CGPath(rect: drawn, transform: nil) : hoverEdge
            border.lineDashPattern = [6, 4]
        } else {
            outline.path = nil
            border.path = nil
            border.lineDashPattern = nil
        }
        snapEdges.path = nil

        // Size reading reflects only the locked windows that will actually be captured.
        let lockedUnion = selectedWindows.dropFirst().reduce(selectedWindows[0].frame) { $0.union($1.frame) }
        let scale = display.pixelsPerPoint
        let width = Int((lockedUnion.width * scale).rounded())
        let height = Int((lockedUnion.height * scale).rounded())
        let text: String
        if selectedWindows.count > 1 {
            text = String(localized: "\(selectedWindows.count) windows  ·  \(width) × \(height)", bundle: .module)
        } else {
            let win = selectedWindows[0]
            text = win.ownerName.isEmpty ? "\(width) × \(height)" : "\(win.ownerName)  ·  \(width) × \(height)"
        }
        sizePill.text = text
        setAccessibilityValue(purpose == .text ? selectedWindows.map(\.ownerName).joined(separator: ", ") : text)

        let anchorRect: CGRect? = if let firstLocked = lockedOnDisplay.first?.rect {
            lockedOnDisplay.dropFirst().reduce(firstLocked) { $0.union($1.rect) }
        } else {
            hoveredRect
        }
        if purpose == .text || pointer == nil {
            sizePill.layer.isHidden = true
        } else {
            sizePill.layer.isHidden = false
            positionSizePill(under: anchorRect ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0))
        }
    }

    /// Shows a compact, non-intrusive shortcut hint capsule at bottom-center in Pick Color and Window modes,
    /// hidden while dragging, annotating, or when the pointer is on another display.
    private func updateHintPill() {
        let text: String? = if isAnnotating || isDraggingSelection || pointer == nil {
            nil
        } else if mode == .window {
            if purpose.takesPicture && purpose.choosesSeveralWindows {
                String(localized: "Scroll Element · Tab Cycle · ⇧ Click Multi-select", bundle: .module)
            } else if purpose.choosesSeveralWindows {
                String(localized: "Tab Cycle · ⇧ Click Multi-select", bundle: .module)
            } else {
                String(localized: "Tab Cycle", bundle: .module)
            }
        } else if purpose == .color {
            String(localized: "⌥ Click for details · Tab Format", bundle: .module)
        } else {
            nil
        }
        guard let text else {
            hintPill.layer.isHidden = true
            return
        }
        hintPill.text = text
        let pillSize = hintPill.layer.bounds.size
        let toolbarVisible = !toolbar.isHidden && toolbar.alphaValue > 0
        let selfTimerVisible = !selfTimerBar.isHidden && selfTimerBar.alphaValue > 0
        var y: CGFloat = 18
        if toolbarVisible {
            let below = toolbar.frame.minY - pillSize.height - 8
            if below >= 6 {
                y = below
            } else {
                y = selfTimerVisible ? max(toolbar.frame.maxY, selfTimerBar.frame.maxY) + 8 : toolbar.frame.maxY + 8
            }
        } else if selfTimerVisible {
            let below = selfTimerBar.frame.minY - pillSize.height - 8
            y = below >= 6 ? below : selfTimerBar.frame.maxY + 8
        }
        let maxX = max(6, bounds.maxX - pillSize.width - 6)
        let maxY = max(6, bounds.maxY - pillSize.height - 6)
        let x = min(max((bounds.width - pillSize.width) / 2, 6), maxX)
        y = min(max(y, 6), maxY)
        if selfTimerVisible,
           CGRect(x: x, y: y, width: pillSize.width, height: pillSize.height).intersects(selfTimerBar.frame.insetBy(dx: -4, dy: -4)) {
            y = min(selfTimerBar.frame.maxY + 8, maxY)
        }
        hintPill.layer.frame.origin = CGPoint(x: x, y: y)
        hintPill.layer.isHidden = false
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

    /// The magnifier's center pixel is the capture target, replacing the separate crosshair until
    /// the first press. Scrolling capture shares this selector on the live screen; Pick Color and
    /// recording keep their own layout.
    private var usesCenteredPicker: Bool { purpose == .screenshot || purpose == .annotate || purpose == .scroll }

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
        loupeTarget.strokeColor = loupeCenter.strokeColor
        loupeTargetOutline.strokeColor = CGColor(gray: lightStroke ? 0 : 1, alpha: 0.9)
    }

    private func updatePointer(_ point: CGPoint?) {
        let hadPointer = pointer != nil
        pointer = point
        updateHintPill()
        let pointerLayers: [CALayer] = [crosshair, crosshairOutline, loupeShadow, loupe, loupeRim, loupePill.layer]
        if let point, wantsSystemCursor(at: global(point)) {
            pointerLayers.forEach { $0.isHidden = true }
            if hoveredWindow != nil {
                hoveredWindow = nil
                updateSelectionLayers()
            }
            measure?.movePointer(to: nil)
            return
        }
        if mode == .window {
            let hovered = point.flatMap { WindowCatalog.target(at: global($0), in: windows) }
            if hovered != hoveredWindow || (hadPointer != (point != nil) && !selectedWindows.isEmpty) {
                hoveredWindow = hovered
                updateSelectionLayers()
            } else if let point, !elementChain.isEmpty {
                // Out of the part the wheel went into (or, at the window, out of the smallest part read), the parts
                // read are for somewhere else: back to the window, read again on the next turn in.
                let here = global(point)
                let held = pickedElement?.frame ?? elementChain[0].frame
                if !held.contains(here) {
                    leaveElements()
                    updateSelectionLayers()
                }
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

        if usesCenteredPicker, hasStartedAreaSelection {
            pointerLayers.forEach { $0.isHidden = true }
            return
        }

        // A capture's lens stays centered on the target, including at screen edges. Moving the lens
        // away to keep it on screen would make its center cell point at the wrong location.
        let diameter = loupeDiameter
        let offset = Theme.Loupe.offset
        let center = usesCenteredPicker ? point : magnifiedLensCenter(for: point)
        for layer in [loupe, loupeRim, loupeShadow] { layer.position = center }

        let pixel = pixelCoordinate(at: point)
        if let frame = capturedFrame {
            loupeImage.contentsRect = Self.contentsRect(around: pixel, in: frame.image, pixelsAcross: loupePixelsAcross)
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
        let origin = toolbarOrigin ?? CGPoint(x: (bounds.width - size.width) / 2, y: 40)
        toolbar.frame = CGRect(
            x: min(max(origin.x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - size.width - 8)),
            y: min(max(origin.y, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - size.height - 8)),
            width: size.width, height: size.height
        )
    }

    private func moveToolbar(by delta: CGVector, pointerInWindow: CGPoint) {
        toolbarOrigin = CGPoint(x: toolbar.frame.minX + delta.dx, y: toolbar.frame.minY + delta.dy)
        layoutToolbar()
        layoutSelfTimerBar()
        toolbarOrigin = toolbar.frame.origin
        window?.invalidateCursorRects(for: toolbar)
        withoutAnimation {
            updateSelectionLayers()
            updatePointer(convert(pointerInWindow, from: nil))
        }
        delegate?.overlayView(self, didMovePointerTo: global(convert(pointerInWindow, from: nil)))
    }

    private func layoutSelfTimerBar() {
        let size = selfTimerBar.fittingSize
        let above: CGFloat = !toolbar.isHidden ? toolbar.frame.maxY + 10 : 40
        let preferredY = above + size.height <= bounds.maxY - 8 ? above : toolbar.frame.minY - size.height - 10
        let y = min(max(preferredY, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - size.height - 8))
        let x = ((bounds.width - size.width) / 2).rounded()
        selfTimerBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
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
    private static func contentsRect(around pixel: (x: Int, y: Int), in image: CGImage, pixelsAcross: Int) -> CGRect {
        let across = CGFloat(pixelsAcross)
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

    private func clearTransientContent() {
        transientContent.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + display.frame.minX, y: point.y + display.frame.minY)
    }

    private func global(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
