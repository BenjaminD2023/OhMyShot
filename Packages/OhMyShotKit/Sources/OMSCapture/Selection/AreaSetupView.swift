import AppKit
import OMSCore
import OMSDesign

/// What the overlay shows once something is chosen and set up for what comes next (a recording, a scrolling
/// capture, All-In-One's ways to take an area): the choice framed on the dimmed screen, its corners and edges to
/// adjust it while it can be, and a bar under it. A drag on the frame moves it, one on a handle resizes it, and one
/// outside it chooses a new area. Return, or a double click inside, does what the bar does first; Escape ends an
/// adjustment, then the whole setup.
///
/// What each setup has of its own comes from its subclass: the bar, what is framed, whether it can be adjusted and in
/// what shape, what keeps the adjusted area, and what Return does.
///
/// Flipped: points from the display's top-left corner, as the frame's drawing expects.
class AreaSetupView<Bar: NSView>: NSView {
    var onCancel: (() -> Void)?

    let display: DisplayInfo
    let chrome = SelectionChromeView()
    let bar: Bar
    /// The drag adjusting the frame, while one goes on.
    private(set) var adjustment: AreaFrame.Adjustment?

    init(display: DisplayInfo, bar: Bar) {
        self.display = display
        self.bar = bar
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        addSubview(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: What subclasses say

    /// Says what to do next, once the frame is up and has the keyboard.
    func begin() {}

    /// The area in global points while it can be moved and resized; nil while what is framed is as it is (a window,
    /// the whole display).
    var adjustableArea: CGRect? { nil }

    /// What is framed, in this view's points from the top-left corner.
    var frameRect: CGRect {
        adjustableArea.map { AreaFrame.local($0, on: display).intersection(bounds) } ?? bounds
    }

    /// The shape (width over height) the area keeps while it is resized or chosen anew; nil for any.
    var keptRatio: CGFloat? { nil }

    /// The area as adjusted, in global points: the subclass keeps it and shows it.
    func areaAdjusted(_ area: CGRect) {}

    /// What Return, Enter, and a double click inside the frame do.
    func primaryAction() {}

    /// The cursor over the bar at `point` (this view's points).
    func cursor(overBarAt point: CGPoint) -> NSCursor { .arrow }

    /// An adjustment ended with the mouse going up (not with Escape).
    func adjustmentEnded() {}

    // MARK: The frame and its bar

    /// Under the frame, as `AreaFrame.barFrame` places it; out of the way while the frame is adjusted.
    func placeBar() {
        bar.frame = AreaFrame.barFrame(size: bar.fittingSize, for: frameRect, in: bounds)
        bar.isHidden = adjustment != nil
        chrome.avoiding = bar.isHidden ? .null : bar.frame
        chrome.toolbarFrame = bar.isHidden ? .null : bar.frame
    }

    /// Sets the area to `rect` (this view's points), cut to the display and on its pixels, for `areaAdjusted` to keep;
    /// false when too little of it is on the display.
    @discardableResult
    func setArea(_ rect: CGRect) -> Bool {
        guard let kept = AreaFrame.fitted(rect, in: bounds) else { return false }
        areaAdjusted(AreaFrame.global(AreaFrame.snapped(kept, pixelsPerPoint: display.pixelsPerPoint), on: display))
        return true
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
        if bar.frame.contains(point) { return cursor(overBarAt: point).set() }
        guard adjustableArea != nil else { return (frameRect.contains(point) ? NSCursor.arrow : NSCursor.crosshair).set() }
        if let handle = AreaFrame.handle(at: point, of: frameRect, in: bounds) { return AreaFrame.cursor(for: handle).set() }
        (frameRect.contains(point) ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let area = adjustableArea.map({ AreaFrame.local($0, on: display) }) {
            if let handle = AreaFrame.handle(at: point, of: frameRect, in: bounds) {
                begin(.resizing(handle, original: area))
                return
            }
            if area.contains(point) {
                if event.clickCount == 2 { return primaryAction() }
                begin(.moving(start: point, original: area))
                NSCursor.closedHand.set()
                return
            }
        } else if frameRect.contains(point) {
            if event.clickCount == 2 { primaryAction() }
            return
        }
        // Outside the frame: a new area.
        begin(.selecting(start: point))
    }

    private func begin(_ adjustment: AreaFrame.Adjustment) {
        self.adjustment = adjustment
        chrome.showsThirds = true
        placeBar()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let adjustment else { return }
        let point = convert(event.locationInWindow, from: nil)
        setArea(AreaFrame.adjusted(adjustment, to: point, in: bounds, keeping: keptRatio))
    }

    override func mouseUp(with event: NSEvent) {
        guard adjustment != nil else { return }
        adjustment = nil
        chrome.showsThirds = false
        placeBar()
        updateCursor(event)
        NSAccessibility.post(element: self, notification: .valueChanged)
        adjustmentEnded()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape: an adjustment first, then the whole setup.
            if adjustment != nil {
                adjustment = nil
                chrome.showsThirds = false
                placeBar()
            } else {
                onCancel?()
            }
        case 36, 76: // Return, Enter
            primaryAction()
        default:
            super.keyDown(with: event)
        }
    }
}
