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
        /// What to record and what to record with it, set on the recording bar; Record was pressed.
        case record(RecordingTarget, display: DisplayInfo, choices: RecordingChoices)
        /// The area of a scrolling capture, in global points, set on the scrolling bar; Start (or Auto-scroll,
        /// `autoScrolls`) was pressed.
        case scroll(CGRect, display: DisplayInfo, autoScrolls: Bool)
        /// All-In-One's area (global points, on one display) and what to do with it; `frozen` as for a region. A
        /// recording chosen there is set up in the same session, and ends it as `record`.
        case allInOne(AllInOneChoice, CGRect, display: DisplayInfo, frozen: CapturedFrame?)
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
        /// Choose what to record on the live screen: an area of one display, a window, or a click for the
        /// whole display. The overlay then stays, the choice framed with the recording bar under it, until
        /// Record or Escape.
        case record
        /// Choose the part of the live screen that scrolls, an area of one display or a window's frame, for a
        /// scrolling capture. The overlay then stays, the area framed with the scrolling bar under it, until
        /// Start or Escape.
        case scroll
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

    /// What the recording bar starts with; it changes as the bar is used.
    public var recordingChoices = RecordingChoices()
    /// What is chosen to record changed: a choice on the recording bar (to be remembered), or the area once
    /// it is adjusted; also told once when the bar appears.
    public var onRecordingSetupChange: ((RecordingTarget, DisplayInfo, RecordingChoices) -> Void)?

    public enum Mode: Sendable {
        case area
        case window
    }

    /// Hold the screen still while selecting, so hover states and menus can be captured.
    public var freezesScreen = false
    /// Whether screenshots show the pointer. A frozen screen is captured with it, where it was when the shortcut was
    /// pressed, so the area is cut from a screen that has it; a live one is captured later, by whoever began.
    public var showsPointer = false
    /// The area chosen is captured again once the overlay has gone (the Self-Timer's), so what the screen was frozen
    /// as is only what choosing is done on, and carries no pointer. Set before `begin`; every session ends with it
    /// off again.
    public var recapturesLive = false
    /// The shape Shift keeps while an area is dragged out; nil for a square. Set from Settings.
    public var keptShape: AspectRatio?
    /// A shape chosen on Capture Area's size control, which Shift keeps from now on: whoever keeps the setting sets
    /// `keptShape` to it.
    public var onKeptShapeChange: ((AspectRatio) -> Void)?
    /// Snaps a selection's edges to the blocks of text on a frozen screen when its `isOn` says so as a session
    /// begins; set once by whoever has a text detector.
    public var textBlocks: TextBlockFinder?
    /// A scrolling capture starts as soon as its area is chosen, without the scrolling bar (the URL API's
    /// `start=true`). Set before `begin`; every session ends with it off again.
    public var startsScrollingAtOnce = false
    /// All-In-One: a screenshot session whose area is framed to adjust, with a bar of every way to take it, rather
    /// than captured as the mouse goes up; its bar and letter keys also offer text, scrolling, and recording. Set
    /// before `begin`; every session ends with it off again.
    public var isAllInOne = false
    /// Whether All-In-One's bar offers Upload: only while a destination is set up.
    public var allInOneOffersUpload = false
    /// A recording is about to be set up outside Record Screen (from All-In-One): whoever records sets
    /// `recordingChoices` and `onRecordingSetupChange` for it.
    public var onWillSetUpRecording: (() -> Void)?
    /// Whether this session (or the one just ended) set up a recording, so whoever began it knows a cancel left a
    /// camera preview to put away.
    public private(set) var didSetUpRecording = false
    /// What All-In-One's next area is for, when a mode was chosen before dragging; nil frames it to choose then.
    private var allInOneMode: AllInOneChoice?
    /// An area given to `begin`, taken once the overlay has the keyboard: a frozen session gets it a moment later.
    private var chosenAhead: (area: CGRect, display: DisplayInfo)?
    /// The notation picked colors are copied in: the magnifier's reading shows it while picking.
    public var colorFormat: ColorFormat = .hex
    /// How screenshot and annotation sessions show the pixels at the pointer: magnified, or at their own size.
    public var captureLoupeStyle: CaptureLoupeStyle = .magnified
    /// The actual-size lens's size.
    public var captureLoupeSize: CaptureLoupeSize = .small
    /// What the ruler reads in. Tab switches it during a session, and `onMeasureUnitChange` hears it.
    public var measureUnit: MeasureUnit = .points
    public var onMeasureUnitChange: ((MeasureUnit) -> Void)?
    /// The ruler's pixel boundary tolerance. T cycles it during a session.
    public var measureTolerance: MeasureTolerance = .medium
    public var onMeasureToleranceChange: ((MeasureTolerance) -> Void)?
    /// Whether a drawn measurement box snaps to its content when released.
    public var measureSnapsToContent = true
    /// The ruler's measurement to copy, where the crosshair is (global space), and whether the overlay is
    /// closing after it (Return) rather than staying, with "Copied" in its reading (⌘C).
    public var onCopyMeasurement: ((String, CGPoint?, Bool) -> Void)?
    private let cursorVisibility = OverlayCursorVisibility()
    /// A session's choice is shared across displays, including the one with no visible bar.
    private var toolbarHiddenByUser = false
    /// Mouse input's location, separate from the crosshair the arrow keys may nudge.
    private var systemCursorPoint: CGPoint?

    public private(set) var isActive = false
    /// Whether the overlay has the keyboard and the pointer: at once on a live screen, once the
    /// pointer's display is captured on a frozen one.
    private var hasInput = false

    /// Whether this session shows the screen as it was when it began; in-place annotation, picking a
    /// color, and measuring always do: they read the frozen frame's pixels.
    private var holdsStill: Bool {
        (freezesScreen && purpose != .record && purpose != .scroll) || purpose == .annotate || purpose == .color || purpose == .measure
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
    /// This app's windows are no window to scroll: a scrolling capture's stream never sees them, and Auto-scroll
    /// would scroll what is behind them.
    private var windowsExcluded: pid_t? { purpose == .scroll ? getpid() : nil }
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
    /// The keys held at the drag's last move or change of keys: the arrow keys redraw the selection under them.
    private var dragModifiers: NSEvent.ModifierFlags = []
    /// Whether this session snaps selections to text, the blocks found so far on each display (global points),
    /// the snapping they make once any are, and the detections still running.
    private var snapsToText = false
    private var textBlocksByDisplay: [CGDirectDisplayID: [CGRect]] = [:]
    private var textSnap: TextSnap?
    private var textDetections: [Task<[CGRect], Never>] = []
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
            view.onToolbarVisibilityToggle = { [weak self] in self?.toggleToolbarVisibility() }
            panel.contentView = view
            entries[display.id] = Entry(panel: panel, view: view)
        }
    }

    /// - Parameter area: an area chosen already, in global points (the URL API's): a recording or a scrolling
    ///   capture frames it with its bar at once; a screenshot or text shows it chosen, and Return takes it, or a drag
    ///   chooses another.
    public func begin(mode: Mode = .area, purpose: Purpose = .screenshot, choosing area: CGRect? = nil, completion: @escaping (Outcome) -> Void) {
        guard !isActive else { return }
        cursorVisibility.end()
        toolbarHiddenByUser = false
        systemCursorPoint = nil
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
        dragModifiers = []
        pointer = nil
        nudged = false
        self.completion = completion
        allInOneMode = nil
        didSetUpRecording = false
        chosenAhead = nil
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }

        prepare()
        let pointer = NSEvent.mouseLocation
        let layout = topology.layout
        let pointerDisplay = layout.display(at: pointer) ?? layout.primary

        // The window list is read only when windows are the target; area capture never pays for it.
        windows = mode == .window ? WindowCatalog.snapshot(layout: layout, excludingPID: windowsExcluded) : []
        let viewMode: OverlayView.Mode = mode == .window ? .window : .area
        let holdsStill = holdsStill
        // Only a frozen screen holds still for its text to be found; the live one may change under a snapped edge.
        cancelTextDetections()
        snapsToText = holdsStill && (purpose == .screenshot || purpose == .text || purpose == .annotate) && textBlocks?.isOn() == true
        for (id, entry) in entries {
            entry.panel.level = OverlayPanel.selectionLevel
            entry.view.reset(
                pointer: pointer, mode: viewMode, windows: windows,
                showsToolbar: id == pointerDisplay?.id && (purpose == .screenshot || purpose == .annotate || purpose == .record),
                showsPointer: !holdsStill,
                purpose: purpose,
                colorFormat: colorFormat,
                captureLoupeStyle: captureLoupeStyle,
                captureLoupeSize: captureLoupeSize,
                measureUnit: measureUnit,
                measureTolerance: measureTolerance,
                measureSnapsToContent: measureSnapsToContent,
                allInOne: isAllInOne,
                snapsToText: snapsToText
            )
            entry.view.setToolbarHidden(false)
        }
        hasInput = false
        // Shown before the overlay takes input, which tells VoiceOver it is there; framed with its bar once the
        // overlay has the keyboard (`takeInput`), which a frozen session gets a moment later.
        let framesAhead = purpose == .record || purpose == .scroll || (isAllInOne && purpose == .screenshot)
        chosenAhead = mode == .area && framesAhead ? area.flatMap(choose) : nil
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

    /// Shows `area` chosen, as a drag over it would leave it, and returns it as placed (on its display's pixels).
    private func choose(_ area: CGRect) -> (area: CGRect, display: DisplayInfo)? {
        guard let display = startDisplay(of: area) else { return nil }
        place(area, startingOn: display)
        guard let placed = selection.rect, !selection.isTooSmall else {
            selection.reset()
            showSelection()
            return nil
        }
        Log.capture.notice("Area chosen ahead: \(NSStringFromRect(placed), privacy: .public) on display \(display.id, privacy: .public)")
        return (placed, display)
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
        self.pointer = pointer
        systemCursorPoint = pointer
        for entry in entries.values {
            entry.panel.ignoresMouseEvents = false
            entry.view.movePointer(to: pointer)
        }
        if let id = pointerDisplay?.id, let view = entries[id]?.view {
            let announcement = switch purpose {
            case .text: String(localized: "Drag over text to copy it, or press Space to choose a window.", bundle: .module)
            case .annotate: String(localized: "Drag over an area to mark it up, or press Space to choose a window.", bundle: .module)
            case .screenshot where isAllInOne: String(localized: "All-In-One. Drag over an area, then choose what to do with it.", bundle: .module)
            case .screenshot: String(localized: "Drag to capture an area, or press Space to capture a window.", bundle: .module)
            case .color: String(localized: "Click or press Return to copy the color under the crosshair. The arrow keys move it a pixel.", bundle: .module)
            case .measure: String(localized: "Point at something to measure it, or drag a box around it. Command-C copies the measurement.", bundle: .module)
            case .record: String(localized: "Drag over an area to record it, click to record the whole screen, or press Space to choose a window.", bundle: .module)
            case .scroll: String(localized: "Drag over the part that scrolls, or press Space to choose a window.", bundle: .module)
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
        // The canvas draws its own pointer; native controls retain the system cursor. This ownership
        // starts only after taking input, so early tracking events cannot hide the user's pointer.
        cursorVisibility.begin(drawsPointer: purpose != .text, overControls: wantsSystemCursor(at: pointer))
        CATransaction.flush()
        // A frozen overlay asks for activation a moment after the shortcut, not while handling it: the log
        // says whether it was granted, which only a real shortcut press can show.
        let session = self.session
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, isActive, session == self.session else { return }
            Log.capture.notice("Overlay shown (\(self.holdsStill ? "frozen" : "live", privacy: .public)): app active \(NSApp.isActive, privacy: .public), keyboard \(NSApp.keyWindow is OverlayPanel, privacy: .public)")
        }
        // An area given to `begin` is framed now: its bar takes the keyboard and the pointer from the overlay.
        if let chosen = chosenAhead {
            chosenAhead = nil
            select(chosen.area, startingOn: chosen.display, modifiers: [])
        }
    }

    public func cancel() {
        end(.cancelled)
    }

    private func wantsSystemCursor(at point: CGPoint) -> Bool {
        entries.values.contains { $0.view.wantsSystemCursor(at: point) }
    }

    private func updateCursorVisibility(at point: CGPoint) {
        systemCursorPoint = point
        cursorVisibility.update(overControls: wantsSystemCursor(at: point))
    }

    private func toggleToolbarVisibility() {
        guard isActive else { return }
        toolbarHiddenByUser.toggle()
        for entry in entries.values { entry.view.setToolbarHidden(toolbarHiddenByUser) }
        let point = systemCursorPoint ?? NSEvent.mouseLocation
        for entry in entries.values { entry.view.movePointer(to: pointer ?? point) }
        updateCursorVisibility(at: point)
    }

    /// Ends in-place annotation: the overlay goes away and the previous app gets the keyboard back.
    public func finishAnnotation() {
        end(.annotated)
    }

    /// Whether in-place annotation is showing, for scripted checks.
    public var isAnnotating: Bool {
        isActive && entries.values.contains { $0.view.isAnnotating }
    }

    /// The recording bar's view while a choice is framed, for scripted checks.
    var recordingSetup: RecordingSetupView? {
        guard isActive else { return nil }
        return entries.values.lazy.compactMap { entry in entry.view.subviews.lazy.compactMap { $0 as? RecordingSetupView }.first }.first
    }

    /// All-In-One's frame while its area is framed, for scripted checks.
    var allInOneSetup: AllInOneSetupView? {
        guard isActive else { return nil }
        return entries.values.lazy.compactMap { entry in entry.view.subviews.lazy.compactMap { $0 as? AllInOneSetupView }.first }.first
    }

    /// The scrolling bar's view while an area is framed, for scripted checks.
    var scrollingSetup: ScrollingSetupView? {
        guard isActive else { return nil }
        return entries.values.lazy.compactMap { entry in entry.view.subviews.lazy.compactMap { $0 as? ScrollingSetupView }.first }.first
    }

    /// Draws a selection and pointer without mouse input, for scripted checks of the rendering.
    public func simulate(selection rect: CGRect, pointer: CGPoint) {
        guard isActive, let display = startDisplay(of: rect) else { return }
        place(rect, startingOn: display)
        if let under = topology.layout.display(at: pointer) { entries[under.id]?.view.simulate(pointer: pointer) }
    }

    #if DEBUG
    /// Whether this controller currently owns one native cursor hide, for checks of bar handoffs.
    public var debugCursorIsHidden: Bool { cursorVisibility.isHidden }

    /// Chooses an area as a drag ending there would, without mouse input, for scripted checks. The area
    /// may cross displays.
    public func simulateSelection(_ rect: CGRect) {
        guard isActive, purpose != .annotate, let display = startDisplay(of: rect) else { return }
        place(rect, startingOn: display)
        guard let placed = selection.rect else { return }
        select(placed, startingOn: display, modifiers: [])
    }

    /// Drives the recording bar while a choice is framed, for scripted checks: "record", "cancel", "video",
    /// "gif", or a choice to toggle ("systemAudio", "microphone", "clicks"); nil only reads. Returns what is
    /// framed and the choices, or nil when no choice is framed.
    public func debugRecordingSetup(_ action: String?) -> String? {
        guard let setup = recordingSetup else { return nil }
        let summary = "target=\(setup.target) choices=\(setup.choices)"
        switch action {
        case "record": setup.debugRecord()
        case "cancel": cancel()
        case "systemAudio": setup.debugToggle(.systemAudio)
        case "microphone": setup.debugToggle(.microphone)
        case "clicks": setup.debugToggle(.clicks)
        case "keystrokes": setup.debugToggle(.keystrokes)
        case "video": setup.debugChoose(.video)
        case "gif": setup.debugChoose(.gif)
        case "studio": setup.debugChoose(.studio)
        default: break
        }
        return summary
    }

    /// Drives the scrolling bar while an area is framed, for scripted checks: "start", "auto", or "cancel"; nil
    /// only reads. Returns the area, or nil when none is framed.
    public func debugScrollingSetup(_ action: String?) -> String? {
        guard let setup = scrollingSetup else { return nil }
        let summary = "area=\(NSStringFromRect(setup.area))"
        switch action {
        case "start": setup.debugStart(autoScrolls: false)
        case "auto": setup.debugStart(autoScrolls: true)
        case "cancel": cancel()
        default: break
        }
        return summary
    }

    /// Presses a key in All-In-One's frame (`return`, `escape`, a letter, `cmd-c`, `left`, `opt-right`…), or with
    /// nil only reads, for scripted checks. Returns the frame's area, or nil when none is framed.
    public func debugAllInOneSetup(_ action: String?) -> String? {
        allInOneSetup?.debugAct(action)
    }

    /// Chooses All-In-One's mode before an area, as its bar or its letter key would: "text", "scroll", "record".
    public func debugChooseAllInOneMode(_ name: String) {
        guard let view = entries.values.first?.view else { return }
        let choice: AllInOneChoice? = switch name {
        case "text": .text
        case "scroll": .scroll
        case "record": .record
        default: nil
        }
        if let choice { overlayView(view, didChooseMode: choice) }
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
        let showsCursor = Self.framesShowPointer(showsPointer, purpose: purpose, holdsStill: holdsStill, allInOne: isAllInOne, recaptured: recapturesLive)
        for (index, display) in displays.enumerated() {
            do {
                let frame: CapturedFrame
                let capturing = index == 0 ? LatencyProbe("overlay.capture") : nil
                #if DEBUG
                if let injected = injectedFrames?[display.id] {
                    frame = injected
                } else {
                    frame = try await capturer.captureDisplay(display, showsCursor: showsCursor)
                }
                #else
                frame = try await capturer.captureDisplay(display, showsCursor: showsCursor)
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
                // After the frame is shown and the overlay has the input, and not waited for: the next display's
                // frame does not wait for this one's text.
                findTextBlocks(in: frame, on: display, session: session)
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

    /// Whether the frames captured for a session carry the pointer: only a screenshot's frozen ones, which are what is
    /// kept (a live screen is captured after the overlay has gone, as is a Self-Timer's area). Picking a color and
    /// measuring read the frames' pixels, and text is read from them, so the pointer would only be in the way: that is
    /// why All-In-One's, which may take its area's text, carry none either.
    static func framesShowPointer(_ setting: Bool, purpose: Purpose, holdsStill: Bool, allInOne: Bool = false, recaptured: Bool = false) -> Bool {
        setting && holdsStill && !allInOne && !recaptured && (purpose == .screenshot || purpose == .annotate)
    }

    /// Finds the blocks of text in a display's frozen frame, off the main actor and at low priority, when this
    /// session snaps selections to text. Nothing snaps until the blocks are in; a session that has ended, or
    /// that a new one replaced, drops them.
    private func findTextBlocks(in frame: CapturedFrame, on display: DisplayInfo, session: Int) {
        guard snapsToText, let find = textBlocks?.find else { return }
        let image = frame.image, area = frame.frame, scale = frame.pixelsPerPoint
        let probe = LatencyProbe("overlay.textblocks")
        let detection = Task.detached(priority: .utility) { await find(image) }
        textDetections.append(detection)
        Task { [weak self] in
            let found = await detection.value
            guard !detection.isCancelled else { return }
            probe.end()
            guard let self, isActive, session == self.session else { return }
            textBlocksByDisplay[display.id] = found.map { TextSnap.block(fromPixels: $0, in: area, pixelsPerPoint: scale) }
            textSnap = TextSnap(blocks: textBlocksByDisplay.values.flatMap(\.self))
            Log.capture.notice("Text blocks: \(found.count, privacy: .public) found on display \(display.id, privacy: .public)")
        }
    }

    private func cancelTextDetections() {
        textDetections.forEach { $0.cancel() }
        textDetections = []
        textBlocksByDisplay = [:]
        textSnap = nil
    }

    /// The first frame normally lands within about 50 ms. If it has not after half a second, macOS is
    /// most likely asking the user to confirm Screen Recording, and the overlay would hide that prompt.
    private func watchdog(session: Int) {
        guard isActive, session == self.session, !firstFrameArrived else { return }
        Log.capture.notice("Overlay dismissed: no frame after 500 ms")
        end(.cancelled)
    }

    /// Frames what is to be recorded on its display, with the recording bar under it: the other displays'
    /// panels go, the overlay's own selection, readings, crosshair, and bar step aside, and the pointer is
    /// the system's again, for the frame's resize cursors.
    private func startRecordingSetup(on display: DisplayInfo, target: RecordingTarget) {
        guard let entry = entries[display.id] else { return }
        cursorVisibility.end()
        for (id, other) in entries where id != display.id {
            other.panel.orderOut(nil)
            other.view.clear()
        }
        entry.view.enterAnnotation()
        entry.panel.level = OverlayPanel.annotationLevel
        entry.panel.makeKey()
        let setup = RecordingSetupView(display: display, target: target, choices: recordingChoices)
        setup.frame = entry.view.bounds
        setup.onChange = { [weak self] target, choices in
            self?.recordingChoices = choices
            self?.onRecordingSetupChange?(target, display, choices)
        }
        setup.onRecord = { [weak self] target, choices in
            self?.end(.record(target, display: display, choices: choices))
        }
        setup.onCancel = { [weak self] in self?.cancel() }
        entry.view.addSubview(setup)
        entry.panel.makeFirstResponder(setup)
        setup.begin()
    }

    /// Frames the area of a scrolling capture on its display, with the scrolling bar under it, as a recording's
    /// choice is framed.
    private func startScrollingSetup(on display: DisplayInfo, area: CGRect) {
        guard let entry = entries[display.id] else { return }
        let area = area.intersection(display.frame)
        guard !area.isNull, area.width >= AreaFrame.smallest, area.height >= AreaFrame.smallest else { return }
        if startsScrollingAtOnce { return end(.scroll(area, display: display, autoScrolls: false)) }
        cursorVisibility.end()
        for (id, other) in entries where id != display.id {
            other.panel.orderOut(nil)
            other.view.clear()
        }
        entry.view.enterAnnotation()
        entry.panel.level = OverlayPanel.annotationLevel
        entry.panel.makeKey()
        let setup = ScrollingSetupView(display: display, area: area)
        setup.frame = entry.view.bounds
        setup.onStart = { [weak self] area, autoScrolls in
            self?.end(.scroll(area, display: display, autoScrolls: autoScrolls))
        }
        setup.onCancel = { [weak self] in self?.cancel() }
        entry.view.addSubview(setup)
        entry.panel.makeFirstResponder(setup)
        setup.begin()
    }

    /// Frames All-In-One's area on its display with the bar of every way to take it, as a scrolling capture's area is
    /// framed: the other displays' panels go, the selection and crosshair step aside, the pointer is the system's.
    /// `sizing` is Capture Area's (or Annotate Area's) own frame, opened with Tab: the same frame with only Capture, the
    /// size, and the shape on its bar, keeping `ratio`.
    private func startAllInOneSetup(on display: DisplayInfo, area: CGRect, sizing: Bool = false, ratio: AspectRatio? = nil) {
        guard let entry = entries[display.id] else { return }
        let area = area.intersection(display.frame)
        guard !area.isNull, area.width >= AreaFrame.smallest, area.height >= AreaFrame.smallest else { return }
        cursorVisibility.end()
        for (id, other) in entries where id != display.id {
            other.panel.orderOut(nil)
            other.view.clear()
        }
        entry.view.enterAnnotation()
        entry.panel.level = OverlayPanel.annotationLevel
        entry.panel.makeKey()
        let setup = AllInOneSetupView(
            display: display, area: area, offersUpload: allInOneOffersUpload && !sizing,
            kind: sizing ? .sizing : .allInOne, ratio: sizing ? ratio : nil, toolbarHidden: toolbarHiddenByUser
        )
        setup.frame = entry.view.bounds
        setup.onShapeKept = { [weak self] shape in self?.onKeptShapeChange?(shape) }
        setup.onChoose = { [weak self, weak setup] choice, area in
            guard let self else { return }
            if sizing {
                // Taken as the drag would have taken it. In-place annotation hosts its interface in the overlay's view,
                // which the frame no longer covers.
                setup?.removeFromSuperview()
                select(area, startingOn: display, modifiers: [])
            } else if choice == .record {
                setup?.removeFromSuperview()
                setUpRecording(on: display, target: area == display.frame ? .display : .area(area))
            } else {
                endAllInOne(choice, area, on: display)
            }
        }
        setup.onCancel = { [weak self] in self?.cancel() }
        entry.view.addSubview(setup)
        entry.panel.makeFirstResponder(setup)
        setup.begin()
    }

    /// Ends All-In-One with what to do with `area`: on a frozen screen, the area as it was frozen goes along.
    private func endAllInOne(_ choice: AllInOneChoice, _ area: CGRect, on display: DisplayInfo) {
        let frozen = holdsStill ? frozenArea(area, on: [display]) : nil
        Log.capture.notice("All-In-One \(String(describing: choice), privacy: .public) on \(NSStringFromRect(area), privacy: .public)")
        end(.allInOne(choice, area, display: display, frozen: frozen))
    }

    /// A recording chosen in All-In-One, set up in the same session (another would have to take the keyboard back):
    /// the screen goes live again, as a recording shows it, and the recording bar frames what is chosen.
    private func setUpRecording(on display: DisplayInfo, target: RecordingTarget) {
        onWillSetUpRecording?()
        didSetUpRecording = true
        entries[display.id]?.view.showLive()
        startRecordingSetup(on: display, target: target)
    }

    /// Hands the chosen area to in-place annotation, once its display's frozen frame is there.
    private func startAnnotating(on displayID: CGDirectDisplayID, area: CGRect) {
        guard let entry = entries[displayID] else { return }
        guard let frame = entry.view.frame(), let onAnnotate else {
            pendingAnnotation = (displayID, area)
            return
        }
        // The pointer is the system's again: marks need the arrow, the I-beam, and the resize cursors.
        cursorVisibility.end()
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
        cursorVisibility.end()
        isActive = false
        startsScrollingAtOnce = false
        recapturesLive = false
        isAllInOne = false
        allInOneOffersUpload = false
        allInOneMode = nil
        chosenAhead = nil
        pendingAnnotation = nil
        dragPoint = nil
        spaceHeld = false
        pointer = nil
        nudged = false
        cancelTextDetections()
        snapsToText = false
        #if DEBUG
        injectedFrames = nil
        #endif
        for entry in entries.values {
            entry.panel.orderOut(nil)
            entry.view.clear()
        }
        toolbarHiddenByUser = false
        systemCursorPoint = nil
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
        let displays = purpose == .annotate || purpose == .record || purpose == .scroll || isAllInOne ? [display] : topology.layout.displays
        selection = SelectionModel(
            bounds: displays.reduce(CGRect.null) { $0.union($1.frame) },
            pixelsPerPoint: displays.map(\.pixelsPerPoint).max() ?? display.pixelsPerPoint
        )
        selection.shape = keptShape?.value ?? 1
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

    /// Shift keeps the selection's shape (a square, unless Settings keep another); Option grows it from the center,
    /// except when copying text, where Option means "open the OCR panel" when the mouse is released; Command keeps
    /// edges from snapping to text for the rest of the drag.
    private func selectionModifiers(_ flags: NSEvent.ModifierFlags) -> SelectionModel.Modifiers {
        var modifiers: SelectionModel.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.square) }
        if flags.contains(.option), purpose != .text { modifiers.insert(.fromCenter) }
        // Command places edges freely: the model keeps them so for the rest of the drag.
        if flags.contains(.command) { modifiers.insert(.unsnapped) }
        return modifiers
    }

    /// What a drag snaps to now.
    private var dragSnap: TextSnap? {
        Self.snap(textSnap, whileChoosing: allInOneMode)
    }

    /// `snap`, unless All-In-One's first drag is choosing a recording's or a scrolling capture's area: that
    /// area is live, so it snaps to nothing.
    static func snap(_ snap: TextSnap?, whileChoosing choice: AllInOneChoice?) -> TextSnap? {
        switch choice {
        case .record?, .scroll?: nil
        case .screenshot?, .text?, nil: snap
        }
    }

    /// Ends the session with an area: handed to in-place annotation, or kept as it was frozen on screen,
    /// or captured once the overlay has gone. `display` is where the drag began; the outcome names the
    /// display holding most of the area.
    private func select(_ rect: CGRect, startingOn display: DisplayInfo, modifiers: NSEvent.ModifierFlags) {
        if isAllInOne, purpose == .screenshot {
            switch allInOneMode {
            case .record?: setUpRecording(on: display, target: rect == display.frame ? .display : .area(rect))
            case let mode?: endAllInOne(mode, rect, on: display)
            case nil: startAllInOneSetup(on: display, area: rect)
            }
            return
        }
        if purpose == .annotate {
            startAnnotating(on: display.id, area: rect)
            return
        }
        if purpose == .record {
            startRecordingSetup(on: display, target: rect == display.frame ? .display : .area(rect))
            return
        }
        if purpose == .scroll {
            startScrollingSetup(on: display, area: rect)
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
        dragModifiers = []
        showSelection()
        updateCursorVisibility(at: point)
    }

    func overlayView(_ view: OverlayView, didDragTo point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let last = dragPoint else { return }
        dragModifiers = modifiers
        if spaceHeld {
            selection.move(by: CGVector(dx: point.x - last.x, dy: point.y - last.y))
        } else {
            selection.drag(to: point, modifiers: selectionModifiers(modifiers), snapping: dragSnap)
        }
        dragPoint = point
        dragTop = max(dragTop, point.y)
        showSelection()
        showCorner(pointer: point)
    }

    /// Puts the crosshair and magnifier on the corner being dragged: the pointer, or where the arrow keys moved the
    /// corner to. Drag events reach only the display the press began on, so they follow the corner onto whichever
    /// display it is over. The crosshair is what a color is taken at (C), so the controller's pointer is the corner too.
    private func showCorner(pointer point: CGPoint) {
        let shown = selection.isNudged ? (selection.corner ?? point) : point
        pointer = shown
        nudged = selection.isNudged
        for entry in entries.values {
            entry.view.movePointer(to: shown)
        }
        updateCursorVisibility(at: point)
    }

    func overlayView(_ view: OverlayView, didReleaseWith modifiers: NSEvent.ModifierFlags) {
        guard let last = dragPoint, let display = dragDisplay else { return }
        dragPoint = nil
        spaceHeld = false
        guard let rect = selection.rect, !selection.isTooSmall else {
            selection.reset()
            showSelection()
            updateCursorVisibility(at: last)
            // A click, not a drag: recording takes the whole display.
            if purpose == .record { startRecordingSetup(on: display, target: .display) }
            return
        }
        logSelection(rect, from: display, endingAt: last)
        select(rect, startingOn: display, modifiers: modifiers)
    }

    func overlayView(_ view: OverlayView, didChangeModifiers modifiers: NSEvent.ModifierFlags) {
        guard let last = dragPoint, !spaceHeld else { return }
        dragModifiers = modifiers
        selection.drag(to: last, modifiers: selectionModifiers(modifiers), snapping: dragSnap)
        showSelection()
    }

    func overlayView(_ view: OverlayView, didMovePointerTo point: CGPoint) {
        pointer = point
        nudged = false
        for entry in entries.values {
            entry.view.movePointer(to: point)
        }
        updateCursorVisibility(at: point)
    }

    func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool) {
        // After the arrow keys the crosshair says where the color is.
        let location = nudged ? (pointer ?? point) : point
        guard isActive, let display = topology.layout.display(at: location), let color = entries[display.id]?.view.color(at: location) else { return }
        Log.capture.notice("Picked \(color.hex, privacy: .public) (\(color.displayP3, privacy: .public)\(color.isInSRGB ? "" : ", outside sRGB", privacy: .public)) at \(NSStringFromPoint(location), privacy: .public)")
        end(.color(color, at: location, display: display, modifiers: modifiers, keyboard: keyboard))
    }

    func overlayView(_ view: OverlayView, didNudge pixels: CGVector) {
        if let last = dragPoint {
            nudgeDraggedCorner(by: pixels, pointer: last)
            return
        }
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

    /// Moves the corner being dragged by whole pixels (down positive) while the pointer stays where it is, so a selection
    /// can be set to the pixel. The corner stays that far from the pointer for the rest of the drag. Shift and Option
    /// keep their say: the shape still holds, and a selection from the center still grows both ways. While Space moves the
    /// selection, no corner is being set.
    private func nudgeDraggedCorner(by pixels: CGVector, pointer last: CGPoint) {
        guard !spaceHeld else { return }
        let scale = selection.pixelsPerPoint
        selection.nudge(by: CGVector(dx: pixels.dx / scale, dy: -pixels.dy / scale), modifiers: selectionModifiers(dragModifiers))
        showSelection()
        showCorner(pointer: last)
        // VoiceOver hears the size the corner made.
        let layout = topology.layout
        if let rect = selection.rect, let display = layout.display(at: CGPoint(x: rect.midX, y: rect.minY)) ?? layout.display(at: last) {
            entries[display.id]?.view.announceValue()
        }
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

    func overlayView(_ view: OverlayView, didChangeTolerance tolerance: MeasureTolerance) {
        guard isActive, purpose == .measure else { return }
        measureTolerance = tolerance
        for entry in entries.values {
            entry.view.setMeasureTolerance(tolerance)
        }
        onMeasureToleranceChange?(tolerance)
    }

    func overlayViewDidRequestSizing(_ view: OverlayView) {
        guard isActive, hasInput, !isAllInOne, purpose == .screenshot || purpose == .annotate, !isAnnotating else { return }
        let at = pointer ?? NSEvent.mouseLocation
        let display: DisplayInfo
        var dragged: CGRect?
        if dragPoint != nil, let began = dragDisplay, let rect = selection.rect?.intersection(began.frame),
           !rect.isNull, rect.width >= AreaFrame.smallest, rect.height >= AreaFrame.smallest {
            // The drag in hand becomes the frame, on the display it began on.
            display = began
            dragged = rect
        } else {
            // Nothing dragged yet (or too little): a start around the crosshair, for the size to be typed.
            display = topology.layout.display(at: at) ?? view.display
        }
        let start = Self.sizingStart(dragged: dragged, on: display, around: at, shapeLocked: dragModifiers.contains(.shift), kept: keptShape)
        // The press that began the drag may still be down: its moves and its end are no longer the selection's.
        dragPoint = nil
        spaceHeld = false
        selection.reset()
        showSelection()
        Log.capture.notice("Area framed to size: \(NSStringFromRect(start.area), privacy: .public) on display \(display.id, privacy: .public)")
        startAllInOneSetup(on: display, area: start.area, sizing: true, ratio: start.ratio)
    }

    /// The area the size control opens on, and the shape it keeps. A drag in hand is framed as it is, free; one dragged
    /// with Shift held was kept to a shape, `kept` or a square, and keeps it. With no drag, an area around `point` is
    /// framed free.
    static func sizingStart(
        dragged: CGRect?, on display: DisplayInfo, around point: CGPoint, shapeLocked: Bool, kept: AspectRatio?
    ) -> (area: CGRect, ratio: AspectRatio?) {
        guard let dragged else { return (AreaFrame.starting(around: point, on: display, keeping: nil), nil) }
        let ratio: AspectRatio? = shapeLocked ? kept ?? .square : nil
        return (AreaFrame.framed(dragged, on: display, keeping: ratio), ratio)
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
        // All-In-One's Screen (or F) takes the whole display at once; a mode chosen before takes it too.
        if isAllInOne, purpose == .screenshot, allInOneMode == nil {
            return endAllInOne(.screenshot(nil), rect, on: view.display)
        }
        select(rect, startingOn: view.display, modifiers: modifiers)
    }

    func overlayView(_ view: OverlayView, didChooseMode choice: AllInOneChoice) {
        guard isAllInOne, purpose == .screenshot, dragPoint == nil else { return }
        // Choosing the purpose in hand again, or a plain capture (Area, A), lets it go.
        let next: AllInOneChoice? = if case .screenshot = choice { nil } else if choice == allInOneMode { nil } else { choice }
        guard next != allInOneMode else { return }
        allInOneMode = next
        let mark: AllInOneBar.Choice? = switch next {
        case .text?: .text
        case .scroll?: .scroll
        case .record?: .record
        case .screenshot?, nil: nil
        }
        for entry in entries.values { entry.view.markPurpose(mark) }
        let announcement = switch next {
        case .text?: String(localized: "Text. Drag over text to copy it.", bundle: .module)
        case .scroll?: String(localized: "Scrolling capture. Drag over the part that scrolls.", bundle: .module)
        case .record?: String(localized: "Record. Drag over an area to record it.", bundle: .module)
        case .screenshot?, nil: String(localized: "Capture. Drag over an area, then choose what to do with it.", bundle: .module)
        }
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) {
        if isAllInOne, purpose == .screenshot, let mode = allInOneMode {
            switch mode {
            case .record: setUpRecording(on: view.display, target: .window(target))
            case .scroll, .text, .screenshot: endAllInOne(mode, target.frame.intersection(view.display.frame), on: view.display)
            }
            return
        }
        if purpose == .record {
            startRecordingSetup(on: view.display, target: .window(target))
            return
        }
        if purpose == .scroll {
            // A window's frame where it is on screen: its title bar and toolbar stay put, as a header does.
            startScrollingSetup(on: view.display, area: target.frame)
            return
        }
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
            windows = WindowCatalog.snapshot(layout: topology.layout, excludingPID: windowsExcluded)
        }
        for entry in entries.values {
            entry.view.switchMode(to: mode, windows: windows)
        }
    }

    func overlayViewDidCancel(_ view: OverlayView) {
        Log.capture.notice("Overlay cancelled with Escape\(self.dragPoint == nil ? "" : " during a drag", privacy: .public)")
        end(.cancelled)
    }

}
