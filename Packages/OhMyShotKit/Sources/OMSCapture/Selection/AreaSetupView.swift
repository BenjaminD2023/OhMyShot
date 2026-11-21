import AppKit
import OMSCore
import OMSDesign

/// What the overlay shows once something is chosen and set up for what comes next (a recording, a scrolling
/// capture, All-In-One's ways to take an area): the choice framed on the dimmed screen, its corners and edges to
/// adjust it while it can be, and a bar under it. A drag on the frame moves it, one on a handle resizes it, and one
/// outside it chooses a new area. Return, or a double click inside, does what the bar does first; Escape ends an
/// adjustment, then the whole setup. On a frozen screen B fits the area to the edges of what it holds, and B again or
/// Command-Z puts back the area as it was.
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
    /// How much neighboring pixels may differ before B takes them for an edge: Measure's, as Settings say.
    var edgeTolerance: MeasureTolerance = .medium
    /// The area (global points) before B fitted it, and as the fit left it: while it is still as the fit left it, B
    /// again or Command-Z puts it back.
    private var fit: (drawn: CGRect, fitted: CGRect)?
    /// The look for the edges in a large area, going on in the background.
    private var fitSearch: Task<Void, Never>?

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
        cancelFit()
        fit = nil
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

    // MARK: Fitting to what the area holds

    /// Whether B can fit the area to what it holds: an area that can be adjusted, on a frozen screen.
    var canFitToContent: Bool {
        guard adjustableArea != nil, let overlay = superview as? OverlayView else { return false }
        return overlay.isFrozen && overlay.frame() != nil
    }

    /// What VoiceOver's help adds where B can fit the area.
    static var fitHelp: String {
        String(localized: "B fits the area to the edges of what’s inside it; press B again or Command-Z to put it back.", bundle: .module)
    }

    /// Whether the edges of a large area are being looked for, for tests.
    var isFittingToContent: Bool { fitSearch != nil }

    /// Fits the area to the edges of what it holds on the frozen screen (B), as Measure fits a box: in the shape kept,
    /// if one is, and never smaller than the smallest area. With the area still as the last fit left it, puts back the
    /// area as it was instead. An area over 250,000 pixels is looked at in the background, and anything that changes
    /// the area first drops what is found. Nothing to fit to beeps.
    func fitToContent() {
        if let fit, adjustableArea == fit.fitted { return unfit() }
        guard adjustment == nil, canFitToContent, let area = adjustableArea, let frame = (superview as? OverlayView)?.frame() else {
            return NSSound.beep()
        }
        cancelFit()
        let tolerance = edgeTolerance
        let scale = frame.pixelsPerPoint
        guard area.width * scale * area.height * scale > 250_000 else {
            return applyFit(frame.contentBounds(in: area, tolerance: tolerance), to: area)
        }
        let worker = Task.detached(priority: .userInitiated) {
            frame.contentBounds(in: area, tolerance: tolerance)
        }
        fitSearch = Task { [weak self] in
            let content = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.adjustableArea == area, self.adjustment == nil else { return }
            self.fitSearch = nil
            self.applyFit(content, to: area)
        }
    }

    /// Takes the least area holding `content` (global points), the edges found in `drawn`, as the area: inside `drawn`,
    /// so nothing that wasn't framed comes in, and not at all when the smallest area or the shape kept can't fit there.
    private func applyFit(_ content: CGRect?, to drawn: CGRect) {
        let framed = AreaFrame.local(drawn, on: display).intersection(bounds)
        guard let content, case let held = AreaFrame.holding(AreaFrame.local(content, on: display), keeping: keptRatio, in: framed),
              held.width <= framed.width, held.height <= framed.height, setArea(held),
              let fitted = adjustableArea, fitted != drawn else {
            NSSound.beep()
            VoiceOver.announce(String(localized: "No edges to fit to inside the area", bundle: .module), from: self, priority: .medium)
            return
        }
        fit = (drawn, fitted)
        NSAccessibility.post(element: self, notification: .valueChanged)
        let reading = AreaFrame.pixelReading(fitted.size, pixelsPerPoint: display.pixelsPerPoint)
        VoiceOver.announce(String(localized: "Fitted to what’s inside: \(reading)", bundle: .module), from: self, priority: .medium)
    }

    /// Puts back the area as it was before B fitted it.
    private func unfit() {
        guard let fit else { return }
        self.fit = nil
        guard setArea(AreaFrame.local(fit.drawn, on: display)) else { return }
        NSAccessibility.post(element: self, notification: .valueChanged)
        let reading = AreaFrame.pixelReading(fit.drawn.size, pixelsPerPoint: display.pixelsPerPoint)
        VoiceOver.announce(String(localized: "Back to the area as drawn: \(reading)", bundle: .module), from: self, priority: .medium)
    }

    private func cancelFit() {
        fitSearch?.cancel()
        fitSearch = nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        guard newSuperview == nil else { return }
        cancelFit()
        (superview as? OverlayView)?.putKeysAway()
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
        cancelFit()
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

    /// ? shows the frame's keys (its VoiceOver help) by the display's edge, or puts them away; any other key puts them
    /// away, and Escape does nothing more then. True when the key is used up; a subclass asks before its own keys.
    func answersKeyList(_ event: NSEvent) -> Bool {
        guard let overlay = superview as? OverlayView else { return false }
        if event.charactersIgnoringModifiers == "?", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            overlay.toggleKeys(accessibilityHelp() ?? "")
            return true
        }
        return overlay.putKeysAway() && event.keyCode == 53
    }

    override func keyDown(with event: NSEvent) {
        if answersKeyList(event) { return }
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
            let character = event.charactersIgnoringModifiers?.lowercased()
            // Q goes through the codes' cards, one after another: the keyboard's way to the chips.
            if character == "q", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               codeChips.openNextCard() { return }
            if character == "b", event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty, adjustableArea != nil {
                return fitToContent()
            }
            super.keyDown(with: event)
        }
    }

    /// Command-Z puts back the area as it was while B's fit stands; a size being typed keeps the field's own Undo.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "z", !(window?.firstResponder is NSText),
              let fit, adjustableArea == fit.fitted else { return super.performKeyEquivalent(with: event) }
        unfit()
        return true
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
