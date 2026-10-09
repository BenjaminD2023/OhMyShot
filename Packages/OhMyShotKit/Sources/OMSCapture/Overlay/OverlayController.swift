import AppKit
import CoreGraphics
import OMSCore
import OSLog
import QuartzCore

/// Runs one selection session across every display.
///
/// The overlay appears first and the captures follow: the panels order front on the hotkey, then each
/// display's frame loads in the background (the pointer's display first), for the loupe, or as the
/// backdrop when the screen is frozen. A frozen session lets the pointer through its panels and leaves
/// the keyboard where it is until the pointer's display is captured: whatever had them (a hover card, a
/// tooltip, an open menu) is still there when the frame is taken. Only then does the overlay take them.
public final class OverlayController {
    public enum Outcome: Sendable {
        /// `modifiers` are the keys held when the mouse was released (Capture Text opens the OCR panel
        /// with Option), read from that event: a later global read would race the keys' release.
        /// The area may cross displays; `display` is the one holding most of it. `frozen` is the area as it
        /// was frozen on screen, put together from each display's part; nil when the screen was live (or a
        /// display's frame had not arrived), and the area is captured now instead.
        case region(CGRect, display: DisplayInfo, modifiers: NSEvent.ModifierFlags, frozen: CapturedFrame?)
        case window(WindowTarget, modifiers: NSEvent.ModifierFlags)
        /// In-place annotation finished (`finishAnnotation`); its own handler has the result.
        case annotated
        /// A color taken off the frozen screen (the color picker, or C over a capture's magnifier), where
        /// it was, the keys held as it was taken (Option asks for the color card), and whether a key took it,
        /// so what follows can take the keyboard too.
        case color(ScreenColor, at: CGPoint, display: DisplayInfo, modifiers: NSEvent.ModifierFlags, keyboard: Bool)
        case cancelled
    }

    /// What the capture is for: a screenshot, or text to copy. Text gets a lighter overlay: no All-In-One
    /// bar (its modes are screenshot modes), no dimming, no magnifier or readings, the system crosshair.
    public enum Purpose: Sendable {
        case screenshot
        case text
        /// Mark up the selection in place: the screen freezes, and once an area (or a window) is chosen
        /// the overlay stays, handing its display's frozen frame to `onAnnotate`.
        case annotate
        /// Take a color off the frozen screen: a click, Return, or C takes the pixel under the crosshair.
        case color
        /// Measure the frozen screen: from the pointer out to the nearest edges, or a box snapped to what it
        /// holds.
        case measure
    }

    /// What in-place annotation is given once its area is chosen: the view to host its interface (the
    /// overlay of that display, y up, covering the display), the display, the chosen area in global
    /// points, and the display's frozen frame. End it with `finishAnnotation()` or `cancel()`.
    public struct AnnotationRequest {
        public let host: NSView
        public let display: DisplayInfo
        public let area: CGRect
        public let frame: CapturedFrame
    }

    /// Starts in-place annotation over the overlay; set by whoever owns the annotation interface.
    public var onAnnotate: ((AnnotationRequest) -> Void)?

    public enum Mode: Sendable {
        case area
        case window
    }

    /// Hold the screen still while selecting, so hover states and menus can be captured.
    public var freezesScreen = false
    /// The notation picked colors are copied in: the magnifier's reading shows it while picking.
    public var colorFormat: ColorFormat = .hex
    /// What the ruler reads in. Tab switches it during a session, and `onMeasureUnitChange` hears it.
    public var measureUnit: MeasureUnit = .points
    public var onMeasureUnitChange: ((MeasureUnit) -> Void)?
    /// The ruler's measurement to copy, where the crosshair is (global space), and whether the overlay is
    /// closing after it (Return) rather than staying, with "Copied" in its reading (⌘C).
    public var onCopyMeasurement: ((String, CGPoint?, Bool) -> Void)?
    private var hidesCursor = false

    public private(set) var isActive = false
    /// Whether the overlay has the keyboard and the pointer: at once on a live screen, once the
    /// pointer's display is captured on a frozen one.
    private var hasInput = false

    /// Whether this session shows the screen as it was when it began; in-place annotation, picking a
    /// color, and measuring always do: they read the frozen frame's pixels.
    private var holdsStill: Bool {
        freezesScreen || purpose == .annotate || purpose == .color || purpose == .measure
    }

    private struct Entry {
        let panel: OverlayPanel
        let view: OverlayView
    }

    private let topology: DisplayTopology
    private let capturer: ScreenCapturer
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var completion: ((Outcome) -> Void)?
    private var previousApp: NSRunningApplication?
    private var session = 0
    private var firstFrameArrived = false
    private var frameLeases: [ActiveResources.Lease] = []
    private var windowLease: ActiveResources.Lease?
    private var windows: [WindowTarget] = []
    private var purpose: Purpose = .screenshot
    /// An area chosen for annotation before its display's frame arrived.
    private var pendingAnnotation: (display: CGDirectDisplayID, area: CGRect)?
    /// The selection being dragged out: one for every display, since a drag may carry it onto another.
    /// In-place annotation keeps it on the display it began on, where its interface lives.
    private var selection = SelectionModel(bounds: .zero, pixelsPerPoint: 1)
    /// The display the drag began on, where the pointer is now in global space, and the highest it
    /// went; nil while no drag is going on.
    private var dragDisplay: DisplayInfo?
    private var dragPoint: CGPoint?
    private var dragTop: CGFloat = -.greatestFiniteMagnitude
    /// Space held during a drag moves the selection instead of resizing it.
    private var spaceHeld = false
    /// The pointer in global space, and whether the arrow keys moved the crosshair since the mouse last
    /// did: then a color is taken at the crosshair, not under the hidden pointer.
    private var pointer: CGPoint?
    private var nudged = false
    #if DEBUG
    /// Frames to show instead of capturing the screen, for scripted checks of the overlay that must never
    /// record what is on screen.
    public var injectedFrames: [CGDirectDisplayID: CapturedFrame]?
    #endif

    public init(topology: DisplayTopology, capturer: ScreenCapturer) {
        self.topology = topology
        self.capturer = capturer
    }

    /// Creates the panels for the current displays ahead of time, so the hotkey only has to show them.
    public func prepare() {
        let layout = topology.layout
        for (id, entry) in entries where layout.display(id: id) != entry.view.display {
            entry.panel.orderOut(nil)
            entries[id] = nil
        }
        for display in layout.displays where entries[display.id] == nil {
            let panel = OverlayPanel(frame: display.frame)
            let view = OverlayView(display: display)
            view.delegate = self
            panel.contentView = view
            entries[display.id] = Entry(panel: panel, view: view)
        }
    }

    public func begin(mode: Mode = .area, purpose: Purpose = .screenshot, completion: @escaping (Outcome) -> Void) {
        guard !isActive else { return }
        let beginning = LatencyProbe("overlay.begin")
        let visible = LatencyProbe("overlay.visible")
        let frozen = LatencyProbe("overlay.frozen")
        isActive = true
        session += 1
        firstFrameArrived = false
        self.purpose = purpose
        pendingAnnotation = nil
        selection = SelectionModel(bounds: .zero, pixelsPerPoint: 1)
        dragDisplay = nil
        dragPoint = nil
        spaceHeld = false
        pointer = nil
        nudged = false
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }

        prepare()
        let pointer = NSEvent.mouseLocation
        let layout = topology.layout
        let pointerDisplay = layout.display(at: pointer) ?? layout.primary

        // The window list is read only when windows are the target; area capture never pays for it.
        windows = mode == .window ? WindowCatalog.snapshot(layout: layout) : []
        let viewMode: OverlayView.Mode = mode == .window ? .window : .area
        let holdsStill = holdsStill
        for (id, entry) in entries {
            entry.panel.level = OverlayPanel.selectionLevel
            entry.view.reset(
                pointer: pointer, mode: viewMode, windows: windows,
                showsToolbar: id == pointerDisplay?.id && (purpose == .screenshot || purpose == .annotate),
                showsPointer: !holdsStill,
                purpose: purpose,
                colorFormat: colorFormat,
                measureUnit: measureUnit
            )
        }
        hasInput = false
        let session = self.session
        // Text without freezing shows no frame, but the pointer display's still arrives first: it tells
        // the watchdog that capturing works.
        let others = purpose == .text && !freezesScreen ? [] : layout.displays.filter { $0.id != pointerDisplay?.id }
        let ordered = [pointerDisplay].compactMap(\.self) + others
        if holdsStill {
            // The capture request goes out on the next turn, ahead of the panels' first flush; the panels
            // follow on the turn after, letting the pointer through, and the overlay takes the keyboard
            // and the pointer once the pointer's display is captured.
            Task { [weak self] in
                await self?.loadFrames(for: ordered, session: session, probe: frozen) { [weak self] in
                    self?.takeInput(pointerDisplay: pointerDisplay)
                }
            }
            Task { [weak self] in
                guard let self, isActive, session == self.session else { return }
                showPanels(probe: visible, acceptingInput: false)
            }
        } else {
            showPanels(probe: visible, acceptingInput: true)
            takeInput(pointerDisplay: pointerDisplay)
            Task { [weak self] in
                await self?.loadFrames(for: ordered, session: session, probe: frozen) {}
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.watchdog(session: session)
        }
        beginning.end()
    }

    /// Puts the session's panels on screen. Until the overlay takes input they let the pointer through
    /// to what is under them, which keeps its hover state and its menus.
    private func showPanels(probe: LatencyProbe, acceptingInput: Bool) {
        // The panels are reused: the reset layers are committed before any panel is ordered in, so none
        // shows a frame of its previous session.
        CATransaction.flush()
        for entry in entries.values {
            entry.panel.ignoresMouseEvents = !acceptingInput
            entry.panel.orderFrontRegardless()
        }
        probe.end()
        windowLease = ActiveResources.shared.acquire(.window)
    }

    /// Gives the overlay the keyboard and the pointer; once.
    private func takeInput(pointerDisplay: DisplayInfo?) {
        guard isActive, !hasInput else { return }
        hasInput = true
        // Active, so the overlay owns the keyboard and the pointer. The app stays an accessory, so no
        // Dock icon appears, and the overlay covers the menu bar while it is ours.
        NSApp.activate()
        // On a frozen screen this comes a moment after the session began: the crosshair goes where the
        // pointer is now.
        let pointer = NSEvent.mouseLocation
        for entry in entries.values {
            entry.panel.ignoresMouseEvents = false
            entry.view.movePointer(to: pointer)
        }
        if let id = pointerDisplay?.id, let view = entries[id]?.view {
            let announcement = switch purpose {
            case .text: String(localized: "Drag over text to copy it, or press Space to choose a window.")
            case .annotate: String(localized: "Drag over an area to mark it up, or press Space to choose a window.")
            case .screenshot: String(localized: "Drag to capture an area, or press Space to capture a window.")
            case .color: String(localized: "Click or press Return to copy the color under the crosshair. The arrow keys move it a pixel.")
            case .measure: String(localized: "Point at something to measure it, or drag a box around it. Command-C copies the measurement.")
            }
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        if let id = pointerDisplay?.id, let entry = entries[id] {
            entry.panel.makeKey()
            entry.panel.makeFirstResponder(entry.view)
        }
        // A screenshot draws its own crosshair and magnifier; copying text keeps the system crosshair.
        hidesCursor = purpose != .text
        if hidesCursor { NSCursor.hide() }
        CATransaction.flush()
        // A frozen overlay asks for activation a moment after the shortcut, not while handling it: the log
        // says whether it was granted, which only a real shortcut press can show.
        let session = self.session
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, isActive, session == self.session else { return }
            Log.capture.notice("Overlay shown (\(self.holdsStill ? "frozen" : "live", privacy: .public)): app active \(NSApp.isActive, privacy: .public), keyboard \(NSApp.keyWindow is OverlayPanel, privacy: .public)")
        }
    }

    public func cancel() {
        end(.cancelled)
    }

    /// Ends in-place annotation: the overlay goes away and the previous app gets the keyboard back.
    public func finishAnnotation() {
        end(.annotated)
    }

    /// Whether in-place annotation is showing, for scripted checks.
    public var isAnnotating: Bool {
        isActive && entries.values.contains { $0.view.isAnnotating }
    }

    /// Draws a selection and pointer without mouse input, for scripted checks of the rendering.
    public func simulate(selection rect: CGRect, pointer: CGPoint) {
        guard isActive, let display = startDisplay(of: rect) else { return }
        place(rect, startingOn: display)
        if let under = topology.layout.display(at: pointer) { entries[under.id]?.view.simulate(pointer: pointer) }
    }

    #if DEBUG
    /// Chooses an area as a drag ending there would, without mouse input, for scripted checks. The area
    /// may cross displays.
    public func simulateSelection(_ rect: CGRect) {
        guard isActive, purpose != .annotate, let display = startDisplay(of: rect) else { return }
        place(rect, startingOn: display)
        guard let placed = selection.rect else { return }
        select(placed, startingOn: display, modifiers: [])
    }

    /// Puts the crosshair at a point in global space without the mouse, for scripted checks; the real
    /// (hidden) pointer cannot move it after that.
    public func simulatePointer(_ point: CGPoint) {
        guard isActive else { return }
        pointer = point
        nudged = true
        for entry in entries.values {
            if entry.view.display.frame.contains(point) { entry.view.simulate(pointer: point) } else { entry.view.movePointer(to: point) }
        }
    }

    /// Takes the color at a point in global space as a click there would, for scripted checks.
    public func simulatePick(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        guard isActive, purpose != .text, let display = topology.layout.display(at: point), let view = entries[display.id]?.view else { return }
        pointer = point
        nudged = true
        overlayView(view, didPickColorAt: point, modifiers: modifiers, keyboard: false)
    }

    /// Drags the ruler's box over `rect` in global space and lets go, for scripted checks.
    public func simulateMeasureBox(_ rect: CGRect) {
        guard isActive, purpose == .measure, let display = startDisplay(of: rect), let view = entries[display.id]?.view else { return }
        view.debugMeasureBox(rect)
    }

    /// Where the crosshair is, in global space, for scripted checks.
    public var debugPointer: CGPoint? { pointer }

    /// Copies the ruler's measurement as ⌘C does, for scripted checks.
    public func debugCopyMeasurement() {
        guard let point = pointer, let display = topology.layout.display(at: point) else { return }
        entries[display.id]?.view.debugCopyMeasurement()
    }

    /// The ruler's measurement on the display under the crosshair, for scripted checks.
    public var debugMeasurement: String? {
        guard let point = pointer, let display = topology.layout.display(at: point) else { return nil }
        return entries[display.id]?.view.debugMeasurement
    }

    /// Chooses an area for in-place annotation without mouse input, for scripted checks.
    public func simulateAnnotation(selection rect: CGRect) {
        guard isActive, purpose == .annotate, let display = startDisplay(of: rect) else { return }
        place(rect, startingOn: display)
        guard let placed = selection.rect else { return }
        startAnnotating(on: display.id, area: placed)
    }
    #endif

    /// Whether every display's frame has arrived, for scripted checks.
    public var hasFrames: Bool { frameLeases.count == entries.count }

    /// Panel visibility per display, for scripted checks.
    public var panelStates: String {
        entries.map { id, entry in
            "\(id): visible=\(entry.panel.isVisible) onActiveSpace=\(entry.panel.isOnActiveSpace) occluded=\(!entry.panel.occlusionState.contains(.visible)) key=\(entry.panel.isKeyWindow)"
        }.sorted().joined(separator: "; ")
    }

    /// Captures each display in turn, the pointer's first; `onFirstFrame` runs once that one is shown.
    private func loadFrames(for displays: [DisplayInfo], session: Int, probe: LatencyProbe, onFirstFrame: () -> Void) async {
        for (index, display) in displays.enumerated() {
            do {
                let frame: CapturedFrame
                let capturing = index == 0 ? LatencyProbe("overlay.capture") : nil
                #if DEBUG
                if let injected = injectedFrames?[display.id] {
                    frame = injected
                } else {
                    frame = try await capturer.captureDisplay(display)
                }
                #else
                frame = try await capturer.captureDisplay(display)
                #endif
                capturing?.end()
                guard isActive, session == self.session else { return }
                entries[display.id]?.view.show(frame, frozen: holdsStill)
                frameLeases.append(ActiveResources.shared.acquire(.frameBuffer))
                if index == 0 {
                    firstFrameArrived = true
                    probe.end()
                    onFirstFrame()
                }
                if let pending = pendingAnnotation, pending.display == display.id {
                    pendingAnnotation = nil
                    startAnnotating(on: display.id, area: pending.area)
                }
            } catch {
                Log.capture.error("Overlay frame for display \(display.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if index == 0, isActive, session == self.session { end(.cancelled) }
                return
            }
        }
    }

    /// The first frame normally lands within about 50 ms. If it has not after half a second, macOS is
    /// most likely asking the user to confirm Screen Recording, and the overlay would hide that prompt.
    private func watchdog(session: Int) {
        guard isActive, session == self.session, !firstFrameArrived else { return }
        Log.capture.notice("Overlay dismissed: no frame after 500 ms")
        end(.cancelled)
    }

    /// Hands the chosen area to in-place annotation, once its display's frozen frame is there.
    private func startAnnotating(on displayID: CGDirectDisplayID, area: CGRect) {
        guard let entry = entries[displayID] else { return }
        guard let frame = entry.view.frame(), let onAnnotate else {
            pendingAnnotation = (displayID, area)
            return
        }
        // The pointer is the system's again: marks need the arrow, the I-beam, and the resize cursors.
        if hidesCursor { NSCursor.unhide() }
        hidesCursor = false
        // Only this display stays: the others would start selections of their own.
        for (id, other) in entries where id != displayID {
            other.panel.orderOut(nil)
            other.view.clear()
        }
        entry.view.enterAnnotation()
        entry.panel.level = OverlayPanel.annotationLevel
        entry.panel.makeKey()
        onAnnotate(AnnotationRequest(host: entry.view, display: entry.view.display, area: area, frame: frame))
    }

    private func end(_ outcome: Outcome) {
        guard isActive else { return }
        isActive = false
        pendingAnnotation = nil
        dragPoint = nil
        spaceHeld = false
        pointer = nil
        nudged = false
        #if DEBUG
        injectedFrames = nil
        #endif
        for entry in entries.values {
            entry.panel.orderOut(nil)
            entry.view.clear()
        }
        if hidesCursor { NSCursor.unhide() }
        hidesCursor = false
        frameLeases.removeAll()
        windowLease = nil
        windows = []
        // A frozen overlay that never took the keyboard has nothing to give back.
        if hasInput, let previousApp {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        hasInput = false
        previousApp = nil
        MemoryRelief.returnFreedPages()
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }
}

// MARK: - Selecting

extension OverlayController {
    /// A fresh selection for a drag that begins on `display`: free to cross onto every display, at the
    /// sharpest one's pixels, except in place, where it stays on its own display.
    private func startSelection(on display: DisplayInfo) {
        let displays = purpose == .annotate ? [display] : topology.layout.displays
        selection = SelectionModel(
            bounds: displays.reduce(CGRect.null) { $0.union($1.frame) },
            pixelsPerPoint: displays.map(\.pixelsPerPoint).max() ?? display.pixelsPerPoint
        )
        dragDisplay = display
        dragTop = -.greatestFiniteMagnitude
    }

    /// Sets the selection to `rect`, as a drag from its top-left corner to its bottom-right would.
    private func place(_ rect: CGRect, startingOn display: DisplayInfo) {
        startSelection(on: display)
        selection.begin(at: CGPoint(x: rect.minX, y: rect.maxY))
        selection.drag(to: CGPoint(x: rect.maxX, y: rect.minY))
        showSelection()
    }

    /// The display a drag over `rect` from its top-left corner would begin on.
    private func startDisplay(of rect: CGRect) -> DisplayInfo? {
        let layout = topology.layout
        return layout.display(at: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
            ?? layout.displays.first { !$0.frame.intersection(rect).isEmpty }
    }

    /// Draws the selection on every display, each its own part. The size reading goes on the display
    /// under the middle of the selection's bottom edge, or else the pointer's.
    private func showSelection() {
        let layout = topology.layout
        let reading = selection.rect.flatMap { rect in
            layout.display(at: CGPoint(x: rect.midX, y: rect.minY)) ?? dragPoint.flatMap { layout.display(at: $0) } ?? dragDisplay
        }
        for (id, entry) in entries {
            entry.view.show(selection: selection, showsReading: id == reading?.id, isDragging: dragPoint != nil)
        }
    }

    /// Shift keeps the selection square; Option grows it from the center, except when copying text,
    /// where Option means "open the OCR panel" when the mouse is released.
    private func selectionModifiers(_ flags: NSEvent.ModifierFlags) -> SelectionModel.Modifiers {
        var modifiers: SelectionModel.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.square) }
        if flags.contains(.option), purpose != .text { modifiers.insert(.fromCenter) }
        return modifiers
    }

    /// Ends the session with an area: handed to in-place annotation, or kept as it was frozen on screen,
    /// or captured once the overlay has gone. `display` is where the drag began; the outcome names the
    /// display holding most of the area.
    private func select(_ rect: CGRect, startingOn display: DisplayInfo, modifiers: NSEvent.ModifierFlags) {
        if purpose == .annotate {
            startAnnotating(on: display.id, area: rect)
            return
        }
        let involved = topology.layout.displays.filter { !$0.frame.intersection(rect).isEmpty }
        let main = involved.max { Self.area(of: $0.frame.intersection(rect)) < Self.area(of: $1.frame.intersection(rect)) } ?? display
        // What was frozen on screen is what is kept: cut from the frames the selection was made on, not
        // captured again once the overlay has gone and whatever it held still has closed.
        let frozen = holdsStill ? frozenArea(rect, on: involved) : nil
        end(.region(rect, display: main, modifiers: modifiers, frozen: frozen))
    }

    /// The area as it was frozen on screen: cut from one display's frame, or put together from each
    /// display's part. Nil when a display's frame has not arrived; the area is then captured live, by
    /// which time a popup may have closed, so that is logged.
    private func frozenArea(_ rect: CGRect, on displays: [DisplayInfo]) -> CapturedFrame? {
        let parts = displays.compactMap { entries[$0.id]?.view.frame()?.cropped(to: rect) }
        guard !parts.isEmpty, parts.count == displays.count else {
            Log.capture.notice("Frozen area incomplete, \(parts.count, privacy: .public) of \(displays.count, privacy: .public) display(s): captured live")
            return nil
        }
        guard parts.count > 1 else { return parts[0] }
        let scale = displays.map(\.pixelsPerPoint).max() ?? parts[0].pixelsPerPoint
        return CapturedFrame.stitched(parts, covering: rect, pixelsPerPoint: scale)
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// One line per selection, for telling where a drag stopped: the area, the last and highest points
    /// the drag reached, and whether each panel covers its whole display.
    private func logSelection(_ rect: CGRect, from display: DisplayInfo, endingAt point: CGPoint) {
        let panels = entries.values.map { entry in
            entry.panel.frame == entry.view.display.frame
                ? "\(entry.view.display.id) covers its display"
                : "\(entry.view.display.id) at \(NSStringFromRect(entry.panel.frame)) on \(NSStringFromRect(entry.view.display.frame))"
        }.sorted().joined(separator: ", ")
        Log.capture.notice("Selection \(NSStringFromRect(rect), privacy: .public) from display \(display.id, privacy: .public), last point \(NSStringFromPoint(point), privacy: .public), highest y \(self.dragTop, privacy: .public); panels: \(panels, privacy: .public)")
    }
}

extension OverlayController: OverlayViewDelegate {
    func overlayView(_ view: OverlayView, didPressAt point: CGPoint) {
        Log.capture.notice("Selection began at \(NSStringFromPoint(point), privacy: .public) on display \(view.display.id, privacy: .public)")
        startSelection(on: view.display)
        selection.begin(at: point)
        dragPoint = point
        dragTop = point.y
        pointer = point
        nudged = false
        spaceHeld = false
        showSelection()
    }

    func overlayView(_ view: OverlayView, didDragTo point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let last = dragPoint else { return }
        if spaceHeld {
            selection.move(by: CGVector(dx: point.x - last.x, dy: point.y - last.y))
        } else {
            selection.drag(to: point, modifiers: selectionModifiers(modifiers))
        }
        dragPoint = point
        dragTop = max(dragTop, point.y)
        pointer = point
        nudged = false
        showSelection()
        // Drag events reach only the display the press began on: the crosshair and magnifier follow the
        // pointer onto whichever display it is over.
        for entry in entries.values {
            entry.view.movePointer(to: point)
        }
    }

    func overlayView(_ view: OverlayView, didReleaseWith modifiers: NSEvent.ModifierFlags) {
        guard let last = dragPoint, let display = dragDisplay else { return }
        dragPoint = nil
        spaceHeld = false
        guard let rect = selection.rect, !selection.isTooSmall else {
            selection.reset()
            showSelection()
            return
        }
        logSelection(rect, from: display, endingAt: last)
        select(rect, startingOn: display, modifiers: modifiers)
    }

    func overlayView(_ view: OverlayView, didChangeModifiers modifiers: NSEvent.ModifierFlags) {
        guard let last = dragPoint, !spaceHeld else { return }
        selection.drag(to: last, modifiers: selectionModifiers(modifiers))
        showSelection()
    }

    func overlayView(_ view: OverlayView, didMovePointerTo point: CGPoint) {
        pointer = point
        nudged = false
        for entry in entries.values {
            entry.view.movePointer(to: point)
        }
    }

    func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool) {
        // After the arrow keys the crosshair says where the color is.
        let location = nudged ? (pointer ?? point) : point
        guard isActive, let display = topology.layout.display(at: location), let color = entries[display.id]?.view.color(at: location) else { return }
        Log.capture.notice("Picked \(color.hex, privacy: .public) (\(color.displayP3, privacy: .public)\(color.isInSRGB ? "" : ", outside sRGB", privacy: .public)) at \(NSStringFromPoint(location), privacy: .public)")
        end(.color(color, at: location, display: display, modifiers: modifiers, keyboard: keyboard))
    }

    func overlayView(_ view: OverlayView, didNudge pixels: CGVector) {
        let base = pointer ?? NSEvent.mouseLocation
        let layout = topology.layout
        guard let display = layout.display(at: base) ?? layout.primary else { return }
        let scale = entries[display.id]?.view.frame()?.pixelsPerPoint ?? display.pixelsPerPoint
        // Down is positive in pixels and negative in global space. Onto a neighboring display if there is one
        // that way, else kept on this one: a display holds y below its top edge, so the top row stays in reach.
        var next = CGPoint(x: base.x + pixels.dx / scale, y: base.y - pixels.dy / scale)
        if layout.display(at: next) == nil {
            next = CGPoint(
                x: min(max(next.x, display.frame.minX), display.frame.maxX - 0.5 / scale),
                y: min(max(next.y, display.frame.minY), display.frame.maxY - 0.5 / scale)
            )
        }
        pointer = next
        nudged = true
        // The hidden system pointer goes along, so the mouse's next move carries on from the crosshair
        // instead of throwing the nudge away.
        if let primary = NSScreen.screens.first {
            CGWarpMouseCursorPosition(CGPoint(x: next.x, y: primary.frame.maxY - next.y))
        }
        for entry in entries.values {
            entry.view.movePointer(to: next)
        }
        if let under = layout.display(at: next) { entries[under.id]?.view.announceValue() }
    }

    func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool) {
        onCopyMeasurement?(text, pointer ?? NSEvent.mouseLocation, ending)
        if ending { end(.cancelled) }
    }

    func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit) {
        measureUnit = unit
        for entry in entries.values {
            entry.view.setMeasureUnit(unit)
        }
        onMeasureUnitChange?(unit)
    }

    func overlayView(_ view: OverlayView, didPressSpace isRepeat: Bool) {
        if dragPoint != nil {
            spaceHeld = true
        } else if !isRepeat {
            overlayView(view, didSwitchTo: view.mode == .area ? .window : .area)
        }
    }

    func overlayViewDidReleaseSpace(_ view: OverlayView) {
        spaceHeld = false
    }

    func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags) {
        select(rect, startingOn: view.display, modifiers: modifiers)
    }

    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) {
        if purpose == .annotate {
            // A window is annotated where it is on the frozen screen.
            let area = target.frame.intersection(view.display.frame)
            if !area.isNull, area.width >= 1, area.height >= 1 { startAnnotating(on: view.display.id, area: area) }
            return
        }
        end(.window(target, modifiers: modifiers))
    }

    func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode) {
        // Once an area is chosen for annotation, even while its frame is still on the way, it stays chosen.
        guard pendingAnnotation == nil, !isAnnotating else { return }
        selection.reset()
        dragPoint = nil
        spaceHeld = false
        if mode == .window, windows.isEmpty {
            windows = WindowCatalog.snapshot(layout: topology.layout)
        }
        for entry in entries.values {
            entry.view.switchMode(to: mode, windows: windows)
        }
    }

    func overlayViewDidCancel(_ view: OverlayView) {
        end(.cancelled)
    }
}
