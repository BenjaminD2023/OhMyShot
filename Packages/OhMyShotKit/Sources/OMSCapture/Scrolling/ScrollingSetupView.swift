import AppKit
import OMSCore

/// What the overlay shows once an area is chosen for a scrolling capture, before it starts: the area framed on
/// the dimmed screen, as a recording's is, with its corners and edges to adjust it and the scrolling bar under
/// it. A drag outside the frame chooses a new area. Return starts, Escape cancels, and a double click inside
/// the frame starts as well.
///
/// Flipped: points from the display's top-left corner, as the frame's drawing expects.
final class ScrollingSetupView: NSView {
    /// Start was chosen: the area in global points, and whether the app scrolls it.
    var onStart: ((CGRect, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private enum Adjustment {
        case moving(start: CGPoint, original: CGRect)
        case resizing(AreaFrame.Handle, original: CGRect)
        case selecting(start: CGPoint)
    }

    private let display: DisplayInfo
    /// The area in global points.
    private(set) var area: CGRect
    private let chrome = SelectionChromeView()
    private let bar = ScrollingBar()
    private var adjustment: Adjustment?

    init(display: DisplayInfo, area: CGRect) {
        self.display = display
        self.area = area
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        addSubview(bar)
        bar.onStart = { [weak self] in self?.start(autoScrolls: false) }
        bar.onAutoScroll = { [weak self] in self?.start(autoScrolls: true) }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Scrolling capture area", bundle: .module))
        setAccessibilityHelp(Self.instructions)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static let instructions = String(localized: "Press Return to start, then scroll what is under the area. Press Escape to cancel.", bundle: .module)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Says what to do next.
    func begin() {
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: Self.instructions, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// The area in this view's points from the top-left corner.
    private var frameRect: CGRect {
        AreaFrame.local(area, on: display).intersection(bounds)
    }

    /// The area's size in pixels, as it will be captured.
    private var pixelReading: String {
        let scale = display.pixelsPerPoint
        return "\(Int((area.width * scale).rounded())) × \(Int((area.height * scale).rounded()))"
    }

    private func update() {
        chrome.selection = frameRect
        chrome.showsHandles = true
        chrome.reading = pixelReading
        placeBar()
        setAccessibilityValue(pixelReading)
    }

    private func placeBar() {
        bar.frame = AreaFrame.barFrame(size: bar.fittingSize, for: frameRect, in: bounds)
        bar.isHidden = adjustment != nil
        chrome.avoiding = bar.isHidden ? .null : bar.frame
        chrome.toolbarFrame = bar.isHidden ? .null : bar.frame
    }

    private func start(autoScrolls: Bool) {
        onStart?(area, autoScrolls)
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
        if let handle = AreaFrame.handle(at: point, of: frameRect, in: bounds) { return AreaFrame.cursor(for: handle).set() }
        (frameRect.contains(point) ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let local = AreaFrame.local(area, on: display)
        if let handle = AreaFrame.handle(at: point, of: frameRect, in: bounds) {
            begin(.resizing(handle, original: local))
            return
        }
        if local.contains(point) {
            if event.clickCount == 2 { return start(autoScrolls: false) }
            begin(.moving(start: point, original: local))
            NSCursor.closedHand.set()
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
            rect = AreaFrame.resized(original, dragging: handle, to: clamped)
        case .selecting(let start):
            rect = CGRect(x: min(start.x, clamped.x), y: min(start.y, clamped.y), width: abs(clamped.x - start.x), height: abs(clamped.y - start.y))
        }
        rect = rect.intersection(limits)
        guard !rect.isNull, rect.width >= AreaFrame.smallest, rect.height >= AreaFrame.smallest else { return }
        area = AreaFrame.global(AreaFrame.snapped(rect, pixelsPerPoint: display.pixelsPerPoint), on: display)
        update()
    }

    override func mouseUp(with event: NSEvent) {
        guard adjustment != nil else { return }
        adjustment = nil
        chrome.showsThirds = false
        placeBar()
        updateCursor(event)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape: an adjustment first, then the whole capture.
            if adjustment != nil {
                adjustment = nil
                chrome.showsThirds = false
                placeBar()
            } else {
                onCancel?()
            }
        case 36, 76: // Return, Enter
            start(autoScrolls: false)
        default:
            super.keyDown(with: event)
        }
    }

    #if DEBUG
    /// Presses Start or Auto-scroll as their chips would, for scripted checks.
    func debugStart(autoScrolls: Bool) {
        start(autoScrolls: autoScrolls)
    }
    #endif
}

#if DEBUG
/// Scrolling capture's controls on their own, for scripted renders.
public enum ScrollingRenders {
    /// The bar under a chosen area, alone in a window behind the desktop picture.
    public static func hiddenBarWindow(dark: Bool) -> NSWindow {
        let bar = ScrollingBar()
        let size = bar.fittingSize
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.backgroundColor = dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let screen = NSScreen.screens.first { window.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY)) }
        bar.frame = CGRect(x: 20, y: 20, width: size.width, height: size.height)
        window.contentView?.addSubview(bar)
        window.orderFront(nil)
        return window
    }
}
#endif

/// The bar under an area chosen for a scrolling capture: Start Capture (Return), Auto-scroll, and Cancel.
final class ScrollingBar: CapsuleBar {
    var onStart: (() -> Void)?
    var onAutoScroll: (() -> Void)?
    var onCancel: (() -> Void)?

    override init() {
        super.init()
        let start = addChip(
            symbol: "arrow.up.and.down.text.horizontal", title: String(localized: "Start Capture", bundle: .module),
            help: String(localized: "Start, then scroll what is under the area (Return)", bundle: .module), target: self, action: #selector(startClicked)
        )
        setTitle(String(localized: "Start Capture", bundle: .module), of: start, emphasized: true)
        _ = addChip(
            symbol: "arrow.down.circle", title: String(localized: "Auto-scroll", bundle: .module),
            help: String(localized: "Start scrolling automatically; adjust the speed in the capture panel", bundle: .module), target: self, action: #selector(autoScrollClicked)
        )
        addDivider()
        _ = addChip(symbol: "xmark", title: nil, help: String(localized: "Cancel (Esc)", bundle: .module), target: self, action: #selector(cancelClicked))
        setAccessibilityLabel(String(localized: "Scrolling Capture", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func startClicked() {
        onStart?()
    }

    @objc private func autoScrollClicked() {
        onAutoScroll?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
