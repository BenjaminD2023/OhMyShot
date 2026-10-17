import AppKit
import OMSCore

/// What All-In-One does with an area: capture it (with a follow-up such as copying or pinning, or as Settings say),
/// read its text, capture it scrolling, or record it.
public enum AllInOneChoice: Equatable, Sendable {
    case screenshot(CaptureAction?)
    case text
    case scroll
    case record
}

/// What All-In-One shows once an area is chosen: the area framed on the dimmed screen with its corners and edges to
/// adjust it, as a recording's is, and a bar under it with every way to take it. A drag outside the frame chooses a
/// new area.
///
/// Keys: Return (or a double click inside) captures; ⌘C and ⌘S capture and copy or save; E annotates, P pins, U
/// uploads (when a destination is set up); O reads the text, S captures scrolling, R records; F captures the whole
/// display. The arrows move the area a point, ten with Shift; with Option they grow or shrink it from its right and
/// bottom edges. Escape ends an adjustment, then the whole capture.
///
/// Capture Area and Annotate Area open the same frame with Tab, for a size typed or a shape kept: its bar then holds
/// Capture, the size fields, the ratio chip, and Cancel, and its keys are Return, the arrows, Tab (to the width, to
/// type it), and Escape. The keys stay with the frame until Tab or a click gives them to a field, so Return captures.
///
/// Flipped: points from the display's top-left corner, as the frame's drawing expects.
final class AllInOneSetupView: NSView {
    /// What the frame is for: every way to take the area, or Capture Area's size and shape alone.
    enum Kind {
        case allInOne
        case sizing
    }

    /// A way to take the area was chosen: the choice and the area in global points.
    var onChoose: ((AllInOneChoice, CGRect) -> Void)?
    var onCancel: (() -> Void)?
    /// A shape was chosen on the ratio chip of Capture Area's size control: the shape Shift keeps from now on.
    var onShapeKept: ((AspectRatio) -> Void)?

    private enum Adjustment {
        case moving(start: CGPoint, original: CGRect)
        case resizing(AreaFrame.Handle, original: CGRect)
        case selecting(start: CGPoint)
    }

    private let display: DisplayInfo
    private let offersUpload: Bool
    private let kind: Kind
    /// The area in global points.
    private(set) var area: CGRect
    private let chrome = SelectionChromeView()
    private let bar: AllInOneActionBar
    private var adjustment: Adjustment?
    /// The shape kept while the area is resized or a size typed; nil for any shape.
    private(set) var ratio: AspectRatio?

    /// `ratio` is the shape already kept when the frame opens; the area is not reshaped to it here.
    init(display: DisplayInfo, area: CGRect, offersUpload: Bool, kind: Kind = .allInOne, ratio: AspectRatio? = nil) {
        self.display = display
        self.offersUpload = offersUpload
        self.kind = kind
        self.area = area
        self.ratio = ratio
        bar = AllInOneActionBar(offersUpload: offersUpload, sizingOnly: kind == .sizing)
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        addSubview(bar)
        bar.onChoose = { [weak self] choice in self?.choose(choice) }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        bar.onSize = { [weak self] width, height in self?.type(width: width, height: height) }
        bar.onRatio = { [weak self] ratio in self?.keep(ratio) }
        bar.onDoneTyping = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Capture area"))
        setAccessibilityHelp(instructions)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Every key, Upload's only while it is offered.
    private var instructions: String {
        if kind == .sizing {
            return String(localized: "Press Return to capture the area. The arrow keys move the area; with Option they resize it. Tab goes to its width and height in pixels, to type them, and the aspect ratio button keeps a shape. Press Escape to cancel.")
        }
        return offersUpload
            ? String(localized: "Press Return to capture the area, Command-C to copy it, or Command-S to save it. E annotates, P pins, U uploads, O copies its text, S starts a scrolling capture, R records it, and F captures the whole screen. The arrow keys move the area; with Option they resize it. Tab goes to its width and height in pixels, to type them. Press Escape to cancel.")
            : String(localized: "Press Return to capture the area, Command-C to copy it, or Command-S to save it. E annotates, P pins, O copies its text, S starts a scrolling capture, R records it, and F captures the whole screen. The arrow keys move the area; with Option they resize it. Tab goes to its width and height in pixels, to type them. Press Escape to cancel.")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Says what to do next.
    func begin() {
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: instructions, .priority: NSAccessibilityPriorityLevel.high.rawValue,
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

    /// What the bar shows of the size and the shape, for tests.
    var barSummary: String { bar.shownSummary }

    /// How many ways to take the area the bar offers, for tests.
    var barChoiceCount: Int { bar.choiceCount }

    /// The area's size in pixels.
    private var pixelSize: CGSize {
        let scale = display.pixelsPerPoint
        return CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
    }

    private func update() {
        chrome.selection = frameRect
        chrome.showsHandles = true
        bar.show(pixelSize: pixelSize, ratio: ratio)
        placeBar()
        setAccessibilityValue(pixelReading)
    }

    /// The size shows in the bar's fields; while the area is adjusted the bar steps aside and the size reading takes
    /// its place above the area's corner.
    private func placeBar() {
        bar.frame = AreaFrame.barFrame(size: bar.fittingSize, for: frameRect, in: bounds)
        bar.isHidden = adjustment != nil
        chrome.reading = bar.isHidden ? pixelReading : ""
        chrome.avoiding = bar.isHidden ? .null : bar.frame
        chrome.toolbarFrame = bar.isHidden ? .null : bar.frame
    }

    /// Keeps `ratio` (nil: any shape), reshaping the area to it at once around its middle.
    private func keep(_ ratio: AspectRatio?) {
        // A size being typed is set first, under the shape it was typed for.
        endTyping()
        self.ratio = ratio
        if let ratio {
            let local = AreaFrame.local(area, on: display)
            setArea(AreaFrame.shaped(local, to: ratio.value, in: bounds))
            if kind == .sizing { onShapeKept?(ratio) }
        } else {
            update()
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// A width or a height typed in pixels: the other follows the shape kept, if any; the area keeps its top-left
    /// corner and stays on the display.
    private func type(width: Int?, height: Int?) {
        let scale = display.pixelsPerPoint
        var size = area.size
        if let width { size.width = CGFloat(width) / scale }
        if let height { size.height = CGFloat(height) / scale }
        if let ratio {
            if width != nil { size.height = size.width / ratio.value } else if height != nil { size.width = size.height * ratio.value }
        }
        size.width = max(size.width, AreaFrame.smallest)
        size.height = max(size.height, AreaFrame.smallest)
        var sized = AreaFrame.sized(AreaFrame.local(area, on: display), to: size, in: bounds)
        // Cut to the display, a shape kept stays kept.
        if let ratio, abs(sized.width / sized.height - ratio.value) > 0.001 { sized = AreaFrame.shaped(sized, to: ratio.value, in: bounds) }
        setArea(sized)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func choose(_ choice: AllInOneChoice, area: CGRect? = nil) {
        if case .screenshot(.upload) = choice, !offersUpload { return NSSound.beep() }
        // A size being typed is set first: what is taken is what the fields say.
        endTyping()
        onChoose?(choice, area ?? self.area)
    }

    /// Sets a size being typed in the bar's fields, and takes the keys back from them.
    private func endTyping() {
        if window?.firstResponder is NSText { window?.makeFirstResponder(self) }
    }

    /// Sets the area to `rect` (this view's points), on the display's pixels and at least the smallest size; false
    /// when it does not fit on the display.
    @discardableResult
    private func setArea(_ rect: CGRect) -> Bool {
        // With a shape kept, cutting the area to the display would change its shape: it stops at the edge instead.
        if ratio != nil, !bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) { return false }
        let kept = rect.intersection(bounds)
        guard !kept.isNull, kept.width >= AreaFrame.smallest, kept.height >= AreaFrame.smallest else { return false }
        area = AreaFrame.global(AreaFrame.snapped(kept, pixelsPerPoint: display.pixelsPerPoint), on: display)
        update()
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
        if bar.frame.contains(point) {
            // The size fields take an I-beam: they can be typed in.
            let overField = bar.sizeFieldFrames.contains { convert($0, from: bar).insetBy(dx: -6, dy: -4).contains(point) }
            return (overField ? NSCursor.iBeam : NSCursor.arrow).set()
        }
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
            if event.clickCount == 2 { return choose(.screenshot(nil)) }
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
            rect = if let ratio {
                AreaFrame.resized(original, dragging: handle, to: clamped, keeping: ratio.value)
            } else {
                AreaFrame.resized(original, dragging: handle, to: clamped)
            }
        case .selecting(let start):
            rect = if let ratio {
                AreaFrame.resized(CGRect(origin: start, size: .zero), dragging: .bottomRight, to: clamped, keeping: ratio.value)
            } else {
                CGRect(x: min(start.x, clamped.x), y: min(start.y, clamped.y), width: abs(clamped.x - start.x), height: abs(clamped.y - start.y))
            }
        }
        setArea(rect)
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
            choose(.screenshot(nil))
        case 123, 124, 125, 126:
            nudge(event.keyCode, by: flags.contains(.shift) ? 10 : 1, resizing: flags.contains(.option))
        case 48: // Tab: to the width, to type it.
            bar.focusWidth()
        default:
            let character = event.charactersIgnoringModifiers?.lowercased()
            // Capture Area's size control has only its own keys: the letters take an area every other way.
            guard kind == .allInOne, !flags.contains(.command), !flags.contains(.control) else { return super.keyDown(with: event) }
            if character == "f" {
                // The whole display, at once.
                choose(.screenshot(nil), area: display.frame)
            } else if let choice = Self.choice(for: character) {
                choose(choice)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// ⌘C and ⌘S take the area here, before the main menu's Copy and Save would.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // While a size is typed, ⌘C and the others are the field's own.
        guard kind == .allInOne, flags == .command, !(window?.firstResponder is NSText) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": choose(.screenshot(.copy))
        case "s": choose(.screenshot(.save))
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// The letter keys' choices for the area (F, the whole display, aside).
    static func choice(for character: String?) -> AllInOneChoice? {
        switch character {
        case "e": .screenshot(.annotate)
        case "p": .screenshot(.pin)
        case "u": .screenshot(.upload)
        case "o": .text
        case "s": .scroll
        case "r": .record
        default: nil
        }
    }

    /// Moves the area by `step` points the arrow's way, or with `resizing` moves its right or bottom edge.
    private func nudge(_ keyCode: UInt16, by step: CGFloat, resizing: Bool) {
        var rect = AreaFrame.local(area, on: display)
        let (dx, dy): (CGFloat, CGFloat) = switch keyCode {
        case 123: (-step, 0)
        case 124: (step, 0)
        case 125: (0, step)
        default: (0, -step)
        }
        if resizing, let ratio {
            // With a shape kept, right and down grow the area, left and up shrink it, both sides together.
            rect.size.width += dx != 0 ? dx : dy
            rect.size.height = rect.width / ratio.value
        } else if resizing {
            rect.size.width += dx
            rect.size.height += dy
        } else {
            rect.origin.x = min(max(rect.minX + dx, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(rect.minY + dy, bounds.minY), bounds.maxY - rect.height)
        }
        if setArea(rect) { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    #if DEBUG
    /// Presses a key in the frame as the keyboard would (`return`, `escape`, a letter, `cmd-c`, `left`…), or
    /// with nil only reads; for scripted checks. Returns the area and its reading.
    func debugAct(_ action: String?) -> String {
        let summary = "area=\(NSStringFromRect(area)) reading=\(pixelReading) upload=\(offersUpload)"
        guard let action else { return summary + " ratio=\(ratio?.label ?? "free")" }
        if action.hasPrefix("size=") {
            let parts = action.dropFirst(5).split(separator: "x").map { Int($0) }
            type(width: parts.first ?? nil, height: parts.count > 1 ? parts[1] : nil)
            return summary
        }
        if action.hasPrefix("width=") { type(width: Int(action.dropFirst(6)), height: nil); return summary }
        if action.hasPrefix("height=") { type(width: nil, height: Int(action.dropFirst(7))); return summary }
        if action.hasPrefix("ratio=") {
            let parts = action.dropFirst(6).split(separator: ":").compactMap { Double($0) }
            keep(parts.count == 2 ? AspectRatio(width: parts[0], height: parts[1]) : nil)
            return summary
        }
        let keys: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "return": (36, "\r", []), "escape": (53, "\u{1b}", []), "left": (123, "", []), "right": (124, "", []),
            "down": (125, "", []), "up": (126, "", []), "opt-right": (124, "", .option), "shift-down": (125, "", .shift),
            "cmd-c": (8, "c", .command), "cmd-s": (1, "s", .command), "tab": (48, "\t", []),
            "cmd-a": (0, "a", .command), "cmd-z": (6, "z", .command), "backspace": (51, "\u{7F}", []),
        ]
        let (code, characters, flags) = keys[action] ?? (0, action, [])
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ) else { return summary }
        if flags.contains(.command) {
            // As AppKit does: the main menu's key equivalents first (Select All, Undo for a field being typed in),
            // then down the window's views, which reaches this view whatever has the keyboard.
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                let editor = window?.firstResponder as? NSTextView
                return summary + " (menu) text=\(editor?.string ?? "-") allowsUndo=\(editor?.allowsUndo ?? false) canUndo=\(editor?.undoManager?.canUndo ?? false)"
            }
            if let window { _ = window.contentView?.performKeyEquivalent(with: event) } else { _ = performKeyEquivalent(with: event) }
        } else if let window, window.firstResponder is NSText {
            // A size being typed: the key goes where a pressed one would, the field's editor.
            window.firstResponder?.keyDown(with: event)
            return summary + " typing=\((window.firstResponder as? NSText)?.string ?? "")"
        } else {
            keyDown(with: event)
        }
        return summary
    }
    #endif
}

/// The bar under All-In-One's area: Capture (Return), then capture-and-copy, -save, -annotate, -pin, and -upload
/// (with a destination set up), then the area's text, a scrolling capture, and a recording; and Cancel.
final class AllInOneActionBar: CapsuleBar {
    var onChoose: ((AllInOneChoice) -> Void)?
    var onCancel: (() -> Void)?
    /// A width or a height typed, in pixels; nil for the side not typed.
    var onSize: ((Int?, Int?) -> Void)?
    /// A shape chosen to keep, or nil for any.
    var onRatio: ((AspectRatio?) -> Void)?
    /// Typing ended (Return, Escape, or Tab past the height): the frame takes the keys again.
    var onDoneTyping: (() -> Void)?
    private var choices: [ObjectIdentifier: AllInOneChoice] = [:]
    private let sizeFields = AreaSizeFields()
    private var ratioChip: BarButton!
    /// The ratio chip's width while it shows its symbol alone.
    private var squareRatioChip: NSLayoutConstraint?
    private var ratio: AspectRatio?

    /// Shows the area's size and the shape kept; a field being typed in keeps what is typed.
    func show(pixelSize: CGSize, ratio: AspectRatio?) {
        sizeFields.show(pixelSize)
        guard ratio != self.ratio else { return }
        self.ratio = ratio
        // Kept, the chip names the shape beside its symbol; else it is the symbol alone, square.
        if let ratio {
            squareRatioChip?.isActive = false
            ratioChip.imagePosition = .imageLeading
            setTitle(ratio.label, of: ratioChip)
        } else {
            ratioChip.attributedTitle = NSAttributedString(string: "")
            ratioChip.imagePosition = .imageOnly
            squareRatioChip?.isActive = true
        }
        ratioChip.setAccessibilityLabel(String(localized: "Aspect Ratio"))
        ratioChip.setAccessibilityValue(ratio?.label ?? String(localized: "Any shape"))
        setOn(ratio != nil, ratioChip)
    }

    /// Puts the cursor in the width, to type it.
    func focusWidth() {
        sizeFields.focusWidth()
    }

    /// The size fields' frames in the bar's space, for the frame's cursor.
    var sizeFieldFrames: [CGRect] { sizeFields.fieldFrames.map { sizeFields.convert($0, to: self) } }

    /// How many ways to take the area the bar offers, for tests.
    var choiceCount: Int { choices.count }

    /// What the size fields and the ratio chip show, for tests: "640 × 360 16:9".
    var shownSummary: String {
        "\(sizeFields.shownText) \(ratioChip.attributedTitle.string.isEmpty ? "any" : ratioChip.attributedTitle.string)"
    }

    @objc private func ratioClicked() {
        let menu = NSMenu()
        let any = NSMenuItem(title: String(localized: "Any Shape"), action: #selector(ratioChosen(_:)), keyEquivalent: "")
        any.target = self
        any.state = ratio == nil ? .on : .off
        menu.addItem(any)
        menu.addItem(.separator())
        for (index, preset) in AspectRatio.presets.enumerated() {
            if index == 1 || index == 6 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: preset.label, action: #selector(ratioChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [preset.width, preset.height]
            item.state = ratio == preset ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, under: ratioChip)
    }

    @objc private func ratioChosen(_ sender: NSMenuItem) {
        guard let sides = sender.representedObject as? [CGFloat], sides.count == 2 else {
            onRatio?(nil)
            return
        }
        onRatio?(AspectRatio(width: sides[0], height: sides[1]))
    }

    /// The menu over the overlay: the panel sits just above pop-up menus, so it steps below them while the menu is open.
    private func popUp(_ menu: NSMenu, under button: NSButton) {
        let window = button.window
        let level = window?.level
        if let window, window.level >= .popUpMenu {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 6 : -6), in: button)
        if let window, let level { window.level = level }
    }

    /// `sizingOnly` is Capture Area's size control: Capture, the size, the shape, and Cancel, without the other ways to
    /// take the area.
    init(offersUpload: Bool, sizingOnly: Bool = false) {
        super.init()
        let capture = add(.screenshot(nil), symbol: "camera.viewfinder", title: String(localized: "Capture"), help: String(localized: "Capture the area (Return)"))
        setTitle(String(localized: "Capture"), of: capture, emphasized: true)
        if !sizingOnly {
            addDivider()
            add(.screenshot(.copy), symbol: "doc.on.doc", label: String(localized: "Copy"), help: String(localized: "Capture and copy (Command-C)"))
            add(.screenshot(.save), symbol: "square.and.arrow.down", label: String(localized: "Save"), help: String(localized: "Capture and save to the export folder (Command-S)"))
            add(.screenshot(.annotate), symbol: "pencil.tip.crop.circle", label: String(localized: "Annotate"), help: String(localized: "Capture and annotate (E)"))
            add(.screenshot(.pin), symbol: "pin", label: String(localized: "Pin"), help: String(localized: "Capture and pin to the screen (P)"))
            if offersUpload {
                add(.screenshot(.upload), symbol: "icloud.and.arrow.up", label: String(localized: "Upload"), help: String(localized: "Capture and upload (U)"))
            }
            addDivider()
            add(.text, symbol: "text.viewfinder", label: String(localized: "Capture Text"), help: String(localized: "Copy the text in the area (O)"))
            add(.scroll, symbol: "arrow.up.and.down.text.horizontal", label: String(localized: "Scrolling Capture"), help: String(localized: "Capture the area as it scrolls (S)"))
            add(.record, symbol: "record.circle", label: String(localized: "Record"), help: String(localized: "Record the area (R)"))
        }
        addDivider()
        addView(sizeFields)
        ratioChip = addChip(symbol: "aspectratio", title: nil, help: String(localized: "Keep a shape while resizing"), target: self, action: #selector(ratioClicked))
        ratioChip.setAccessibilityLabel(String(localized: "Aspect Ratio"))
        ratioChip.setAccessibilityValue(String(localized: "Any shape"))
        squareRatioChip = ratioChip.constraints.first { $0.firstAttribute == .width && $0.secondItem == nil }
        sizeFields.onSize = { [weak self] width, height in self?.onSize?(width, height) }
        sizeFields.onDone = { [weak self] in self?.onDoneTyping?() }
        addDivider()
        let cancel = addChip(symbol: "xmark", title: nil, help: String(localized: "Cancel (Esc)"), target: self, action: #selector(cancelClicked))
        cancel.setAccessibilityLabel(String(localized: "Cancel"))
        setAccessibilityLabel(sizingOnly ? String(localized: "Area size") : String(localized: "All-In-One"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A chip for `choice`: titled when `title` is given, else a symbol named `label` for VoiceOver.
    @discardableResult
    private func add(_ choice: AllInOneChoice, symbol: String, title: String? = nil, label: String? = nil, help: String) -> BarButton {
        let chip = addChip(symbol: symbol, title: title, help: help, target: self, action: #selector(chipClicked(_:)))
        if let label { chip.setAccessibilityLabel(label) }
        choices[ObjectIdentifier(chip)] = choice
        return chip
    }

    @objc private func chipClicked(_ sender: BarButton) {
        guard let choice = choices[ObjectIdentifier(sender)] else { return }
        onChoose?(choice)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

/// The area's width and height in pixels as two fields in All-In-One's bar: read like a reading until clicked (or
/// reached with Tab), then typed. Return or leaving a field sets the area; Escape puts the size back. Only digits go
/// in (full-width ones too), at most five. Behind each field a capsule as tall as the chips takes the chips' hover fill
/// under the pointer and their selected fill while typed in, doubled under Increase Contrast.
final class AreaSizeFields: NSView, NSTextFieldDelegate {
    var onSize: ((Int?, Int?) -> Void)?
    var onDone: (() -> Void)?
    private let width = AreaSizeField()
    private let height = AreaSizeField()
    private let times = NSTextField(labelWithString: "×")
    private let widthFill = CALayer()
    private let heightFill = CALayer()
    private var shown = CGSize.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for fill in [widthFill, heightFill] { layer?.addSublayer(fill) }
        for field in [width, height] {
            field.delegate = self
            field.onStateChange = { [weak self] in self?.applyAppearance() }
            addSubview(field)
        }
        // The digits hug the "×", as a reading has them.
        width.alignment = .right
        height.alignment = .left
        width.setAccessibilityLabel(String(localized: "Width in pixels"))
        height.setAccessibilityLabel(String(localized: "Height in pixels"))
        width.nextKeyView = height
        times.font = Theme.Typeface.reading(size: 12, weight: .medium)
        times.textColor = .secondaryLabelColor
        times.setAccessibilityElement(false)
        addSubview(times)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: CapsuleBar.chip).isActive = true
        widthAnchor.constraint(equalToConstant: Self.fieldWidth * 2 + Self.gap).isActive = true
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static let fieldWidth: CGFloat = 50
    /// Room for the "×" between the fields.
    private static let gap: CGFloat = 14
    private static let fillHeight: CGFloat = 24

    /// The fields' frames, for the frame's I-beam.
    var fieldFrames: [CGRect] { [width.frame, height.frame] }

    override func layout() {
        super.layout()
        // As tall as a line of the reading's face, so its digits sit on the chips' middle.
        let fieldHeight = ceil(width.intrinsicContentSize.height)
        let y = (bounds.height - fieldHeight) / 2
        let inset: CGFloat = 6
        width.frame = CGRect(x: 0, y: y, width: Self.fieldWidth - inset, height: fieldHeight)
        times.sizeToFit()
        times.frame.origin = CGPoint(x: Self.fieldWidth + (Self.gap - times.frame.width) / 2, y: (bounds.height - times.frame.height) / 2)
        height.frame = CGRect(x: Self.fieldWidth + Self.gap + inset, y: y, width: Self.fieldWidth - inset, height: fieldHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fillY = (bounds.height - Self.fillHeight) / 2
        widthFill.frame = CGRect(x: 0, y: fillY, width: Self.fieldWidth + 2, height: Self.fillHeight)
        heightFill.frame = CGRect(x: Self.fieldWidth + Self.gap - 2, y: fillY, width: Self.fieldWidth + 2, height: Self.fillHeight)
        for fill in [widthFill, heightFill] { fill.cornerRadius = Self.fillHeight / 2 }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// The capsules' fills for each field's state, resolved for this view's appearance.
    private func applyAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let boost: CGFloat = contrast ? 2 : 1
            let selected = dark ? CGColor(gray: 1, alpha: 0.16 * boost) : CGColor(gray: 0, alpha: 0.08 * boost)
            let hover = dark ? CGColor(gray: 1, alpha: 0.09 * boost) : CGColor(gray: 0, alpha: 0.045 * boost)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (field, fill) in [(width, widthFill), (height, heightFill)] {
                fill.backgroundColor = field.isEditing ? selected : field.isHovered ? hover : .clear
            }
            CATransaction.commit()
        }
    }

    /// The area's size in pixels; a field being typed in keeps what is typed unless `typedOver`.
    func show(_ size: CGSize, typedOver: Bool = false) {
        shown = size
        if typedOver || !width.isEditing { width.stringValue = String(Int(size.width)) }
        if typedOver || !height.isEditing { height.stringValue = String(Int(size.height)) }
    }

    func focusWidth() {
        window?.makeFirstResponder(width)
    }

    /// What the fields show: "640 × 360".
    var shownText: String { "\(width.stringValue) × \(height.stringValue)" }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? AreaSizeField else { return }
        // An input method still composing is left to finish; its digits are taken once they are in.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        let digits = String(Self.digits(in: field.stringValue).prefix(5))
        if digits != field.stringValue { field.stringValue = digits }
    }

    /// The ASCII digits in `text`, full-width ones (as Chinese and Japanese input gives them) turned into them.
    static func digits(in text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Character? in
            if ("0"..."9").contains(scalar) { return Character(scalar) }
            if (0xFF10...0xFF19).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) { return Character(ascii) }
            return nil
        })
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Marked text (an input method composing) is the input method's to finish.
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(control)
            onDone?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            show(shown, typedOver: true)
            onDone?()
            return true
        case #selector(NSResponder.insertTab(_:)) where control === height,
             #selector(NSResponder.insertBacktab(_:)) where control === width:
            commit(control)
            onDone?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSControl else { return }
        commit(field)
        applyAppearance()
    }

    /// Sets the side typed in `field`, when it changed; then both fields show the size the area took, which a display
    /// too small, the smallest area, or a shape kept may have changed.
    private func commit(_ field: NSControl) {
        if let value = Int(Self.digits(in: field.stringValue)), value > 0 {
            if field === width, CGFloat(value) != shown.width { onSize?(value, nil) }
            if field === height, CGFloat(value) != shown.height { onSize?(nil, value) }
        }
        show(shown, typedOver: true)
    }
}

/// One side of the area's size, in the reading's face; its capsule behind it is the fields' to draw.
final class AreaSizeField: NSTextField {
    var isEditing: Bool { currentEditor() != nil }
    private(set) var isHovered = false
    /// Hovered, or typed in, or not any more.
    var onStateChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = Theme.Typeface.reading(size: 12, weight: .medium)
        textColor = .labelColor
        usesSingleLineMode = true
        cell?.isScrollable = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // A little wider than the digits, as the capsule behind them is.
        addTrackingArea(NSTrackingArea(rect: bounds.insetBy(dx: -6, dy: -4), options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onStateChange?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onStateChange?()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onStateChange?() }
        return became
    }
}

#if DEBUG
/// All-In-One's surfaces on their own, for scripted renders: nothing shows, the window sits behind the desktop picture.
public enum AllInOneRenders {
    /// `setup`: the framed area with its bar over a plain two-tone page, as after a drag. Else the bar of modes shown
    /// before an area is chosen, Area marked.
    /// `marksText` shows the bar of modes with Window and Text both on; `actions` are pressed in the framed area first
    /// (as `allinone-act` takes them: "ratio=16:9", "size=1200x700").
    public static func hiddenWindow(setup: Bool, dark: Bool, offersUpload: Bool = true, marksText: Bool = false, actions: [String] = []) -> NSWindow {
        let size = setup ? CGSize(width: 1000, height: 620) : CGSize(width: 760, height: 90)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.94, alpha: 1)
        if let screen = NSScreen.screens.first { window.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)) }
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        if setup {
            // A page-like backdrop: a darker band on top, lighter blocks below, so the dimming and the frame read.
            let band = CALayer()
            band.frame = CGRect(x: 0, y: size.height - 120, width: size.width, height: 120)
            band.backgroundColor = (dark ? NSColor(white: 0.24, alpha: 1) : NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.93, alpha: 1)).cgColor
            content.layer?.addSublayer(band)
            for index in 0..<6 {
                let block = CALayer()
                block.frame = CGRect(x: 60 + CGFloat(index % 3) * 300, y: 60 + CGFloat(index / 3) * 200, width: 260, height: 160)
                block.backgroundColor = (dark ? NSColor(white: 0.3, alpha: 1) : NSColor.white).cgColor
                block.cornerRadius = 12
                content.layer?.addSublayer(block)
            }
            let display = DisplayInfo(
                id: 0, name: "Render", frame: CGRect(origin: .zero, size: size), pixelSize: CGSize(width: size.width * 2, height: size.height * 2),
                backingScale: 2, maximumPotentialEDR: 1
            )
            let setupView = AllInOneSetupView(display: display, area: CGRect(x: 240, y: 260, width: 520, height: 250), offersUpload: offersUpload)
            setupView.frame = content.bounds
            content.addSubview(setupView)
            window.contentView = content
            content.layoutSubtreeIfNeeded()
            for action in actions { _ = setupView.debugAct(action) }
        } else {
            let bar = AllInOneBar()
            bar.showModes(true)
            bar.select(marksText ? .window : .area)
            if marksText { bar.markPurpose(.text) }
            let fitting = bar.fittingSize
            bar.frame = CGRect(x: (size.width - fitting.width) / 2, y: (size.height - fitting.height) / 2, width: fitting.width, height: fitting.height)
            content.addSubview(bar)
        }
        window.contentView = content
        window.orderFront(nil)
        return window
    }
}
#endif
