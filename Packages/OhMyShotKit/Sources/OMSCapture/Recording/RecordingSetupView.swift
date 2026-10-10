import AppKit
import OMSCore

/// What the overlay shows once something to record is chosen, before recording starts: the choice framed
/// on the dimmed screen, as in-place annotation frames its selection, with the recording bar under it.
///
/// An area keeps its frame's corners and can still be moved and resized; a window or the whole display is
/// framed as it is. A drag outside the frame chooses a new area. Return records, Escape cancels.
///
/// Flipped: points from the display's top-left corner, as the frame's drawing expects.
final class RecordingSetupView: NSView {
    /// What is chosen changed: the choices on the bar, or the area once an adjustment ends.
    var onChange: ((RecordingTarget, RecordingChoices) -> Void)?
    var onRecord: ((RecordingTarget, RecordingChoices) -> Void)?
    var onCancel: (() -> Void)?

    private enum Handle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Adjustment {
        case moving(start: CGPoint, original: CGRect)
        case resizing(Handle, original: CGRect)
        case selecting(start: CGPoint)
    }

    private let display: DisplayInfo
    private(set) var target: RecordingTarget
    private(set) var choices: RecordingChoices
    private let chrome = SelectionChromeView()
    private let bar: RecordingBar
    private var adjustment: Adjustment?

    /// Corners reach this far for a press, edges this far, shrinking on small frames.
    private static let cornerReach: CGFloat = 12
    private static let edgeReach: CGFloat = 6
    /// The smallest area that can be recorded, in points.
    private static let smallest: CGFloat = 16

    init(display: DisplayInfo, target: RecordingTarget, choices: RecordingChoices) {
        self.display = display
        self.target = target
        self.choices = choices
        bar = RecordingBar(choices: choices, recordsWindow: { if case .window = target { true } else { false } }())
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        addSubview(bar)
        bar.onOutput = { [weak self] output in self?.choose(output) }
        bar.onToggle = { [weak self] toggle in self?.toggle(toggle) }
        bar.onMicrophone = { [weak self] id in self?.chooseMicrophone(id) }
        bar.onCamera = { [weak self] id in self?.chooseCamera(id) }
        bar.onCameraStyle = { [weak self] style in self?.setCameraStyle(style) }
        bar.onRecord = { [weak self] in self?.record() }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Recording area"))
        setAccessibilityHelp(String(localized: "Press Return to start recording, or Escape to cancel."))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Says what to do next, and what is chosen to begin with.
    func begin() {
        onChange?(target, choices)
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: String(localized: "Press Return to start recording, or Escape to cancel."),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// The frame of what is chosen, in this view's points from the top-left corner.
    private var frameRect: CGRect {
        switch target {
        case .area(let rect): local(rect)
        case .window(let window): local(window.frame).intersection(bounds)
        case .display: bounds
        }
    }

    /// The size the recording will have, in pixels: what the stream records, made even.
    private var pixelReading: String {
        let size: CGSize = switch target {
        case .area(let rect): rect.size
        case .window(let window): window.frame.size
        case .display: display.frame.size
        }
        let scale = display.pixelsPerPoint
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        return "\(width - width % 2) × \(height - height % 2)"
    }

    private func update() {
        chrome.selection = frameRect
        chrome.showsHandles = { if case .area = target { true } else { false } }()
        chrome.reading = {
            if case .window(let window) = target, !window.ownerName.isEmpty { return "\(window.ownerName)  ·  \(pixelReading)" }
            return pixelReading
        }()
        placeBar()
        setAccessibilityValue(pixelReading)
    }

    /// Under the frame, centered on it; above it when there is no room below; inside its bottom edge when
    /// neither has room (a whole display, a window filling the screen). Always on the display.
    private func placeBar() {
        let size = bar.fittingSize
        let frame = SelectionChromeView.drawnFrame(for: frameRect, in: bounds)
        let margin: CGFloat = 8
        let room = bounds.insetBy(dx: margin, dy: margin)
        let below = CGRect(x: frame.midX - size.width / 2, y: frame.maxY + 12, width: size.width, height: size.height)
        let above = CGRect(x: below.minX, y: frame.minY - 12 - size.height, width: size.width, height: size.height)
        let inside = CGRect(x: below.minX, y: frame.maxY - 40 - size.height, width: size.width, height: size.height)
        var placed = [below, above].first { room.contains($0) } ?? inside
        placed.origin.x = min(max(placed.minX, room.minX), room.maxX - size.width)
        placed.origin.y = min(max(placed.minY, room.minY), room.maxY - size.height)
        bar.frame = placed.integral
        bar.isHidden = adjustment != nil
        chrome.avoiding = bar.isHidden ? .null : bar.frame
        chrome.toolbarFrame = bar.isHidden ? .null : bar.frame
    }

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
        // A display chosen as an area that covers it whole is the display.
        if case .area(let rect) = target, rect.insetBy(dx: 0.5, dy: 0.5).contains(display.frame.insetBy(dx: 1, dy: 1)) {
            target = .display
        }
        onRecord?(target, choices)
    }

    // MARK: Input

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === bar || hit.isDescendant(of: bar) { return hit }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        guard adjustment == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bar.frame.contains(point) { return NSCursor.arrow.set() }
        guard case .area = target else { return (frameRect.contains(point) ? NSCursor.arrow : NSCursor.crosshair).set() }
        if let handle = handle(at: point) { return Self.cursor(for: handle).set() }
        (frameRect.contains(point) ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if case .area(let rect) = target {
            if let handle = handle(at: point) {
                begin(.resizing(handle, original: local(rect)))
                return
            }
            if local(rect).contains(point) {
                if event.clickCount == 2 { return record() }
                begin(.moving(start: point, original: local(rect)))
                NSCursor.closedHand.set()
                return
            }
        } else if frameRect.contains(point) {
            if event.clickCount == 2 { record() }
            return
        }
        // Outside the frame: a new area.
        begin(.selecting(start: point))
    }

    private func begin(_ adjustment: Adjustment) {
        self.adjustment = adjustment
        chrome.showsThirds = true
        placeBar()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let adjustment else { return }
        let point = convert(event.locationInWindow, from: nil)
        let limits = bounds
        let clamped = CGPoint(x: min(max(point.x, limits.minX), limits.maxX), y: min(max(point.y, limits.minY), limits.maxY))
        var rect: CGRect
        switch adjustment {
        case .moving(let start, let original):
            rect = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            rect.origin.x = min(max(rect.minX, limits.minX), limits.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, limits.minY), limits.maxY - rect.height)
        case .resizing(let handle, let original):
            rect = Self.resized(original, dragging: handle, to: clamped)
        case .selecting(let start):
            rect = CGRect(x: min(start.x, clamped.x), y: min(start.y, clamped.y), width: abs(clamped.x - start.x), height: abs(clamped.y - start.y))
        }
        rect = rect.intersection(limits)
        guard !rect.isNull, rect.width >= Self.smallest, rect.height >= Self.smallest else { return }
        target = .area(global(snapped(rect)))
        update()
    }

    override func mouseUp(with event: NSEvent) {
        guard adjustment != nil else { return }
        adjustment = nil
        chrome.showsThirds = false
        placeBar()
        updateCursor(event)
        NSAccessibility.post(element: self, notification: .valueChanged)
        onChange?(target, choices)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape: an adjustment first, then the whole recording.
            if adjustment != nil {
                adjustment = nil
                chrome.showsThirds = false
                placeBar()
            } else {
                onCancel?()
            }
        case 36, 76: // Return, Enter
            record()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Geometry

    /// The frame's handle under a point: its corners and edges, measured from the frame as drawn.
    private func handle(at point: CGPoint) -> Handle? {
        let rect = SelectionChromeView.drawnFrame(for: frameRect, in: bounds)
        let cornerReach = max(min(Self.cornerReach, rect.width / 4, rect.height / 4), 4)
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)), (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        ]
        if let corner = corners.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= cornerReach }) {
            return corner.0
        }
        let reach = max(min(Self.edgeReach, rect.width / 6, rect.height / 6), 3)
        let insideX = point.x > rect.minX && point.x < rect.maxX
        let insideY = point.y > rect.minY && point.y < rect.maxY
        if insideX, abs(point.y - rect.minY) <= reach { return .top }
        if insideX, abs(point.y - rect.maxY) <= reach { return .bottom }
        if insideY, abs(point.x - rect.minX) <= reach { return .left }
        if insideY, abs(point.x - rect.maxX) <= reach { return .right }
        return nil
    }

    private static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private static func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .topLeft: NSCursor.frameResize(position: .topLeft, directions: .all)
        case .top: NSCursor.frameResize(position: .top, directions: .all)
        case .topRight: NSCursor.frameResize(position: .topRight, directions: .all)
        case .right: NSCursor.frameResize(position: .right, directions: .all)
        case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .bottom: NSCursor.frameResize(position: .bottom, directions: .all)
        case .bottomLeft: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        case .left: NSCursor.frameResize(position: .left, directions: .all)
        }
    }

    /// Edges on the display's pixels, as the overlay's selection keeps them.
    private func snapped(_ rect: CGRect) -> CGRect {
        let scale = display.pixelsPerPoint
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX), maxX = snap(rect.maxX), minY = snap(rect.minY), maxY = snap(rect.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Global (y up) to this view's points from the display's top-left corner, and back.
    private func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func global(_ rect: CGRect) -> CGRect {
        CGRect(x: display.frame.minX + rect.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
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
