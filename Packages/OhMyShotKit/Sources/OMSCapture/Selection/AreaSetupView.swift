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
    /// Finds the codes in the area on a frozen screen, for chips over them; set by the overlay for the setups that
    /// take a picture (All-In-One's frame), never for a recording's or a scrolling capture's, which show the live
    /// screen.
    var codeFinder: CodeFinder?
    let codeChips = CodeChipsView(wording: .standard)
    private var codeScan: Task<Void, Never>?

    init(display: DisplayInfo, bar: Bar) {
        self.display = display
        self.bar = bar
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        codeChips.frame = bounds
        codeChips.autoresizingMask = [.width, .height]
        addSubview(codeChips)
        addSubview(bar)
        // A web page a code points to opens once the overlay has gone, which would cover it.
        codeChips.onOpen = { [weak self] url in
            self?.onCancel?()
            NSWorkspace.shared.open(url)
        }
        codeChips.onCardClosed = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
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
        // Moved by the keys or a typed size, the area is looked at again once the keys rest; a drag looks once it ends.
        if adjustment == nil { refreshCodes(after: .milliseconds(250)) } else { clearCodes() }
        return true
    }

    // MARK: Codes

    /// Looks for QR codes and barcodes in the area as it is now, for chips over them: on a frozen screen only, and
    /// only when Settings want them. Any chips shown go at once; the new ones come when the look is done.
    func refreshCodes(after delay: Duration = .zero) {
        clearCodes()
        guard let finder = codeFinder, finder.isOn(), let area = adjustableArea,
              let overlay = superview as? OverlayView, overlay.isFrozen, let frame = overlay.frame() else { return }
        // Not copied out (a frame across a whole 6K display is 80 MB): the decoder only reads it.
        let scale = frame.pixelsPerPoint
        let pixels = CGRect(
            x: ((area.minX - frame.frame.minX) * scale).rounded(), y: ((frame.frame.maxY - area.maxY) * scale).rounded(),
            width: (area.width * scale).rounded(), height: (area.height * scale).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))
        guard !pixels.isNull, pixels.width >= 16, pixels.height >= 16, let picture = frame.image.cropping(to: pixels) else { return }
        let local = AreaFrame.local(area, on: display)
        codeScan = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await finder.find(picture)
            guard !Task.isCancelled, let self, self.adjustableArea == area, self.adjustment == nil else { return }
            let codes = found.map { code in
                CodeChipsView.Code(
                    box: CGRect(x: local.minX + code.box.minX / scale, y: local.minY + code.box.minY / scale, width: code.box.width / scale, height: code.box.height / scale),
                    isMatrix: code.isMatrix, payload: code.payload, link: code.webURL
                )
            }
            self.codeChips.show(codes, in: local)
            if !codes.isEmpty { VoiceOver.announce(CodeChipWording.found(codes.count), from: self, priority: .medium) }
        }
    }

    private func clearCodes() {
        codeScan?.cancel()
        codeScan = nil
        codeChips.clear()
    }

    // MARK: Input

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === bar || hit.isDescendant(of: bar) { return hit }
        // The code chips answer only over a chip or the card, or anywhere while a card is open, to close it.
        if hit === codeChips || hit.isDescendant(of: codeChips) { return hit }
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
                // Held by the line as drawn, which steps in where the frame meets the display's edge.
                let line = SelectionChromeView.drawnFrame(for: frameRect, in: bounds)
                begin(.resizing(handle, original: area, grip: AreaFrame.grip(of: handle, on: line, pressedAt: point)))
                showEdgeLoupe(for: handle, on: area, near: point)
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
        clearCodes()
        placeBar()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let adjustment else { return }
        let point = convert(event.locationInWindow, from: nil)
        setArea(AreaFrame.adjusted(adjustment, to: point, in: bounds, keeping: keptRatio))
        if case .resizing(let handle, _, _) = adjustment { showEdgeLoupe(for: handle, on: frameRect, near: point) }
    }

    /// The overlay's magnifier on the pixel just inside where the dragged edges of `rect` meet; on a frozen screen
    /// only, which the overlay sees to.
    private func showEdgeLoupe(for handle: AreaFrame.Handle, on rect: CGRect, near pointer: CGPoint) {
        guard let overlay = superview as? OverlayView else { return }
        let point = AreaFrame.edgePoint(of: handle, on: rect, near: pointer, pixel: 1 / max(display.pixelsPerPoint, 1))
        overlay.showEdgeLoupe(at: overlay.convert(point, from: self))
    }

    private func hideEdgeLoupe() {
        (superview as? OverlayView)?.showEdgeLoupe(at: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard adjustment != nil else { return }
        adjustment = nil
        hideEdgeLoupe()
        chrome.showsThirds = false
        placeBar()
        updateCursor(event)
        NSAccessibility.post(element: self, notification: .valueChanged)
        adjustmentEnded()
        refreshCodes()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape: a code's card first, then an adjustment, then the whole setup.
            if codeChips.isShowingCard {
                codeChips.dismissCard()
            } else if adjustment != nil {
                adjustment = nil
                refreshCodes()
                hideEdgeLoupe()
                chrome.showsThirds = false
                placeBar()
            } else {
                onCancel?()
            }
        case 36, 76: // Return, Enter
            primaryAction()
        default:
            // Q goes through the codes' cards, one after another: the keyboard's way to the chips.
            if event.charactersIgnoringModifiers?.lowercased() == "q", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               codeChips.openNextCard() { return }
            super.keyDown(with: event)
        }
    }
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
