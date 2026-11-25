import AppKit
import OMSCore
import OMSDesign

/// What the overlay shows once something to record is chosen, before recording starts: the choice framed
/// on the dimmed screen, as in-place annotation frames its selection, with the recording bar under it.
///
/// An area keeps its frame's corners and can still be moved and resized; a window or the whole display is
/// framed as it is. A drag outside the frame chooses a new area. Return records, Escape cancels.
///
/// Flipped: points from the display's top-left corner, as the frame's drawing expects.
final class RecordingSetupView: AreaSetupView<RecordingBar> {
    /// What is chosen changed: the choices on the bar, or the area once an adjustment ends.
    var onChange: ((RecordingTarget, RecordingChoices) -> Void)?
    var onRecord: ((RecordingTarget, RecordingChoices) -> Void)?
    /// The camera's menu asked the bubble to move or to fill what is recorded.
    var onCameraCommand: ((CameraBubbleCommand) -> Void)? {
        get { bar.onCameraCommand }
        set { bar.onCameraCommand = newValue }
    }
    /// Whether the camera fills what is recorded.
    var cameraFills: () -> Bool {
        get { bar.cameraFills }
        set { bar.cameraFills = newValue }
    }

    private(set) var target: RecordingTarget
    private(set) var choices: RecordingChoices
    /// Compact on-demand pixel size editor opened with Tab while adjusting a recording area.
    private let sizeCapsule = RecordingSizeCapsule()

    init(display: DisplayInfo, target: RecordingTarget, choices: RecordingChoices) {
        self.target = target
        self.choices = choices
        super.init(display: display, bar: RecordingBar(choices: choices, recordsWindow: { if case .window = target { true } else { false } }()))
        bar.onOutput = { [weak self] output in self?.choose(output) }
        bar.onToggle = { [weak self] toggle in self?.toggle(toggle) }
        bar.onMicrophone = { [weak self] id in self?.chooseMicrophone(id) }
        bar.onCamera = { [weak self] id in self?.chooseCamera(id) }
        bar.onCameraStyle = { [weak self] style in self?.setCameraStyle(style) }
        bar.onRecord = { [weak self] in self?.record() }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        sizeCapsule.isHidden = true
        sizeCapsule.onSize = { [weak self] width, height in self?.type(width: width, height: height) }
        sizeCapsule.onDone = { [weak self] in self?.dismissSizeCapsule() }
        addSubview(sizeCapsule)
        setAccessibilityLabel(String(localized: "Recording area", bundle: .module))
        setAccessibilityHelp(String(localized: "Press Return to start recording. The arrow keys move the area; with Option they resize it. Tab edits its size in pixels. Press Escape to cancel.", bundle: .module))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Says what to do next, and what is chosen to begin with.
    override func begin() {
        onChange?(target, choices)
        VoiceOver.announce(String(localized: "Press Return to start recording, or Escape to cancel.", bundle: .module), from: self)
    }

    /// An area can be moved and resized; a window or the whole display is framed as it is.
    override var adjustableArea: CGRect? {
        if case .area(let rect) = target { rect } else { nil }
    }

    override var frameRect: CGRect {
        switch target {
        case .area(let rect): AreaFrame.local(rect, on: display)
        case .window(let window): AreaFrame.local(window.frame, on: display).intersection(bounds)
        case .display: bounds
        }
    }

    override func areaAdjusted(_ area: CGRect) {
        target = .area(area)
        update()
    }

    override func primaryAction() {
        record()
    }

    override func adjustmentEnded() {
        onChange?(target, choices)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !sizeCapsule.isHidden {
            let local = convert(point, from: superview)
            if let hit = sizeCapsule.hitTest(local) { return hit }
        }
        return super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        if !sizeCapsule.isHidden, sizeCapsule.frame.contains(convert(event.locationInWindow, from: nil)) {
            NSCursor.iBeam.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if !sizeCapsule.isHidden, sizeCapsule.frame.contains(convert(event.locationInWindow, from: nil)) {
            NSCursor.iBeam.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if !sizeCapsule.isHidden { dismissSizeCapsule() }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if answersKeyList(event) { return }
        if event.keyCode == 48, adjustableArea != nil, !(window?.firstResponder is NSText) {
            showSizeCapsule()
            return
        }
        if event.keyCode == 53, !sizeCapsule.isHidden {
            dismissSizeCapsule()
            return
        }
        super.keyDown(with: event)
    }

    /// The size the recording will have, in pixels: what the stream records, made even.
    private var pixelSize: CGSize {
        let size: CGSize = switch target {
        case .area(let rect): rect.size
        case .window(let window): window.frame.size
        case .display: display.frame.size
        }
        let scale = display.pixelsPerPoint
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        return CGSize(width: width - width % 2, height: height - height % 2)
    }

    private var pixelReading: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    private func update() {
        let isWindow: Bool = if case .window = target { true } else { false }
        bar.update(choices, recordsWindow: isWindow)
        chrome.selection = frameRect
        chrome.showsHandles = adjustableArea != nil
        chrome.reading = {
            if case .window(let window) = target, !window.ownerName.isEmpty { return "\(window.ownerName)  ·  \(pixelReading)" }
            return pixelReading
        }()
        if !sizeCapsule.isHidden { sizeCapsule.show(pixelSize: pixelSize) }
        placeBar()
        setAccessibilityValue(pixelReading)
    }

    override func placeBar() {
        super.placeBar()
        if adjustment != nil || adjustableArea == nil {
            sizeCapsule.isHidden = true
        } else if !sizeCapsule.isHidden {
            let size = sizeCapsule.fittingSize
            let room = bounds.insetBy(dx: 8, dy: 8)
            var origin = CGPoint(x: bar.frame.midX - size.width / 2, y: bar.frame.minY - size.height - 8)
            if origin.y < room.minY { origin.y = bar.frame.maxY + 8 }
            origin.x = min(max(origin.x, room.minX), max(room.minX, room.maxX - size.width))
            origin.y = min(max(origin.y, room.minY), max(room.minY, room.maxY - size.height))
            sizeCapsule.frame = CGRect(origin: origin, size: size).integral
            chrome.avoiding = bar.frame.union(sizeCapsule.frame)
        }
    }

    private func showSizeCapsule() {
        sizeCapsule.show(pixelSize: pixelSize)
        sizeCapsule.isHidden = false
        placeBar()
        sizeCapsule.focusWidth()
    }

    private func dismissSizeCapsule() {
        let shouldRestoreFocus = window?.firstResponder is NSText || (window?.firstResponder as? NSView)?.isDescendant(of: sizeCapsule) == true
        sizeCapsule.isHidden = true
        if shouldRestoreFocus { window?.makeFirstResponder(self) }
        placeBar()
    }

    private func type(width: Int?, height: Int?) {
        guard case .area(let rect) = target else { return }
        let scale = display.pixelsPerPoint
        var size = rect.size
        if let width { size.width = CGFloat(width) / scale }
        if let height { size.height = CGFloat(height) / scale }
        size.width = max(size.width, AreaFrame.smallest)
        size.height = max(size.height, AreaFrame.smallest)
        let sized = AreaFrame.sized(AreaFrame.local(rect, on: display), to: size, in: bounds)
        if setArea(sized) {
            adjustmentEnded()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// Whether the on-demand pixel size editor is currently open, for tests.
    var isEditingSize: Bool { !sizeCapsule.isHidden }

    /// What the on-demand size fields show, for tests.
    var sizeFieldSummary: String { sizeCapsule.shownText }

    // MARK: Choices

    private func choose(_ output: RecordingOutput) {
        guard output != choices.output else { return }
        choices.output = output
        bar.update(choices)
        placeBar()
        onChange?(target, choices)
    }

    /// A camera by its unique ID (empty for the system's default), or none.
    private func chooseCamera(_ id: String?) {
        choices.camera = id != nil
        if let id { choices.cameraID = id }
        bar.update(choices)
        onChange?(target, choices)
    }

    private func setCameraStyle(_ style: CameraStyle) {
        choices.cameraStyle = style
        bar.update(choices)
        onChange?(target, choices)
    }

    /// A microphone by its unique ID (empty for the system's default), or none.
    private func chooseMicrophone(_ id: String?) {
        choices.microphone = id != nil
        if let id { choices.microphoneID = id }
        bar.update(choices)
        onChange?(target, choices)
    }

    private func toggle(_ toggle: RecordingBar.Toggle) {
        switch toggle {
        case .systemAudio: choices.systemAudio.toggle()
        case .microphone: choices.microphone.toggle()
        case .camera: choices.camera.toggle()
        case .clicks: choices.showsClicks.toggle()
        case .keystrokes: choices.showsKeystrokes.toggle()
        }
        bar.update(choices)
        onChange?(target, choices)
    }

    private func record() {
        if !sizeCapsule.isHidden { dismissSizeCapsule() }
        bar.stopLevelMonitoring()
        // A display chosen as an area that covers it whole is the display.
        if case .area(let rect) = target, rect.insetBy(dx: 0.5, dy: 0.5).contains(display.frame.insetBy(dx: 1, dy: 1)) {
            target = .display
        }
        onRecord?(target, choices)
    }

    #if DEBUG
    /// Presses Record as Return would, for scripted checks.
    func debugRecord() {
        record()
    }

    /// Turns a choice on or off as its chip would, for scripted checks.
    func debugToggle(_ toggle: RecordingBar.Toggle) {
        self.toggle(toggle)
    }

    /// Chooses Video or GIF as its chip would, for scripted checks.
    func debugChoose(_ output: RecordingOutput) {
        choose(output)
    }
    #endif
}

/// Compact capsule holding `AreaSizeFields`, shown above the recording bar on demand when Tab is pressed.
private final class RecordingSizeCapsule: CapsuleBar {
    var onSize: ((Int?, Int?) -> Void)?
    var onDone: (() -> Void)?
    private let sizeFields = AreaSizeFields()

    override init() {
        super.init()
        addView(sizeFields)
        sizeFields.onSize = { [weak self] width, height in self?.onSize?(width, height) }
        sizeFields.onDone = { [weak self] in self?.onDone?() }
        setAccessibilityLabel(String(localized: "Recording area size", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(pixelSize: CGSize) {
        sizeFields.show(pixelSize)
    }

    func focusWidth() {
        sizeFields.focusWidth()
    }

    var shownText: String { sizeFields.shownText }
}
