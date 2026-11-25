import AppKit
import CoreGraphics
import OMSCore
import OMSDesign
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
        case windows([WindowTarget], modifiers: NSEvent.ModifierFlags)
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
        /// All-In-One's selected windows are framed by the setup bar before the final action. The area is their union
        /// for text and scrolling actions; screenshots use the original targets for native multi-window capture.
        case allInOneWindows(AllInOneChoice, [WindowTarget], CGRect, display: DisplayInfo, frozen: CapturedFrame?)
        case cancelled

        /// The area this outcome took, in global points, for L to bring back: a region, All-In-One's area whatever it
        /// was for, a scrolling capture's, or what was recorded unless it was a window; nil for a window, a color, an
        /// annotation, or nothing.
        public var takenArea: CGRect? {
            switch self {
            case .region(let rect, _, _, _), .allInOne(_, let rect, _, _), .allInOneWindows(_, _, let rect, _, _), .scroll(let rect, _, _): rect
            case .record(.area(let rect), _, _): rect
            case .record(.display, let display, _): display.frame
            case .record(.window, _, _), .window, .windows, .annotated, .color, .cancelled: nil
            }
        }
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
        /// Shows the overlay's magnifier on a point in `host`'s points while the selection's edge is dragged; nil
        /// hides it.
        public let showEdgeLoupe: (CGPoint?) -> Void
        /// Finds the codes in the selection, for chips over them.
        public let codes: CodeFinder?
    }

    /// Starts in-place annotation over the overlay; set by whoever owns the annotation interface.
    public var onAnnotate: ((AnnotationRequest) -> Void)?

    /// What the recording bar starts with; it changes as the bar is used.
    public var recordingChoices = RecordingChoices()
    /// What is chosen to record changed: a choice on the recording bar (to be remembered), or the area once
    /// it is adjusted; also told once when the bar appears.
    public var onRecordingSetupChange: ((RecordingTarget, DisplayInfo, RecordingChoices) -> Void)?
    /// The recording bar's camera menu asked the camera's bubble to move to a corner or to fill what is recorded.
    public var onRecordingCameraCommand: ((CameraBubbleCommand) -> Void)?
    /// Whether the camera fills what is recorded, for the camera menu's checkmark.
    public var recordingCameraFills: () -> Bool = { false }

    public enum Mode: Sendable {
        case area
        case window
        /// Start directly in the app preview chooser, without capturing or covering every display.
        case windowPicker
    }

    /// What one session is begun with besides its purpose: given to `begin`, gone again when the session ends.
    public struct SessionOptions: Sendable {
        /// All-In-One: a screenshot session whose area is framed to adjust, with a bar of every way to take it, rather
        /// than captured as the mouse goes up; its bar and letter keys also offer text, scrolling, and recording. A
        /// screenshot's alone: with any other purpose `begin` lets it go.
        public var allInOne: AllInOneOptions?
        /// A scrolling capture starts as soon as its area is chosen, without the scrolling bar (the URL API's
        /// `start=true`).
        public var startsScrollingAtOnce: Bool
        /// The area chosen is captured again once the overlay has gone (the Self-Timer's), so what the screen was
        /// frozen as is only what choosing is done on, and carries no pointer.
        public var recapturesLive: Bool
        /// Active Self-Timer countdown delay (in seconds) for this session, shown in the overlay's temporary
        /// switcher bar above the mode toolbar; nil for non-timer sessions.
        public var selfTimerDelay: Int?

        public init(
            allInOne: AllInOneOptions? = nil, startsScrollingAtOnce: Bool = false, recapturesLive: Bool = false, selfTimerDelay: Int? = nil
        ) {
            self.allInOne = allInOne
            self.startsScrollingAtOnce = startsScrollingAtOnce
            self.recapturesLive = recapturesLive
            self.selfTimerDelay = selfTimerDelay
        }
    }

    /// What All-In-One's bar offers besides what it always does.
    public struct AllInOneOptions: Sendable, Equatable {
        /// Upload: only while a destination is set up.
        public var offersUpload: Bool
        /// A Copy chip: not while Settings copy every capture, which Capture then does.
        public var showsCopy: Bool

        public init(offersUpload: Bool = false, showsCopy: Bool = true) {
            self.offersUpload = offersUpload
            self.showsCopy = showsCopy
        }
    }

    /// A window All-In-One highlights under the pointer before anything is chosen: the window, and its part on the
    /// display there, which a click frames as the area.
    struct HoveredWindow: Equatable {
        let window: WindowTarget
        let area: CGRect
        let display: DisplayInfo
    }

    /// Hold the screen still while selecting, so hover states and menus can be captured.
    public var freezesScreen = false
    /// Transient window pixels captured before a live area selection took input.
    public private(set) var transientCaptureSnapshots: [TransientCaptureSnapshot] = []
    /// Whether screenshots show the pointer. A frozen screen is captured with it, where it was when the shortcut was
    /// pressed, so the area is cut from a screen that has it; a live one is captured later, by whoever began.
    public var showsPointer = false
    /// The session's options, as `begin` took them: All-In-One's only with a screenshot.
    private var options = SessionOptions()
    /// An All-In-One session, which only a screenshot's is.
    private var isAllInOne: Bool { options.allInOne != nil }
    /// The shape Shift keeps while an area is dragged out; nil for a square. Set from Settings.
    public var keptShape: AspectRatio?
    /// The area last captured, recalled with L before a drag begins.
    public var lastArea: CGRect?
    /// A shape chosen on Capture Area's size control, which Shift keeps from now on: whoever keeps the setting sets
    /// `keptShape` to it.
    public var onKeptShapeChange: ((AspectRatio) -> Void)?
    /// Snaps a selection's edges to the blocks of text on a frozen screen when its `isOn` says so as a session
    /// begins; set once by whoever has a text detector.
    public var textBlocks: TextBlockFinder?
    /// Finds the QR codes and barcodes in a selection that stays on a frozen screen (in-place annotation, All-In-One's
    /// frame), for chips over them; set once by whoever has a decoder.
    public var codes: CodeFinder?
    /// A recording is about to be set up outside Record Screen (from All-In-One): whoever records sets
    /// `recordingChoices` and `onRecordingSetupChange` for it.
    public var onWillSetUpRecording: (() -> Void)?
    /// All-In-One is about to turn into Measure (M), in its own session: whoever measures sets the ruler's unit,
    /// tolerance, and snapping, and what hears them and copies the measurement, as Measure would.
    public var onWillMeasure: (() -> Void)?
    /// Whether this session (or the one just ended) set up a recording, so whoever began it knows a cancel left a
    /// camera preview to put away.
    public private(set) var didSetUpRecording = false
    /// What All-In-One's next area is for, when a mode was chosen before dragging; nil frames it to choose then.
    private var allInOneMode: AllInOneChoice?
    /// An area given to `begin`, taken once the overlay has the keyboard: a frozen session gets it a moment later.
    private var chosenAhead: (area: CGRect, display: DisplayInfo)?
    /// The notation picked colors are copied in: the magnifier's reading shows it while picking.
    /// Tab cycles it during a Pick Color session, and `onColorFormatChange` hears it.
    public var colorFormat: ColorFormat = .hex
    public var onColorFormatChange: ((ColorFormat) -> Void)?
    /// The temporary Self-Timer delay (in seconds) active for the current session; nil when not a Self-Timer
    /// session. Switching it on the overlay updates this value and fires `onSelfTimerDelayChange` immediately.
    public private(set) var currentSelfTimerDelay: Int?
    public var onSelfTimerDelayChange: ((Int) -> Void)?
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
    /// The display's frozen frame and what the ruler measured on it, to keep as a capture (F). The overlay has
    /// closed by then.
    public var onCaptureMeasurement: ((CapturedFrame, RulerMeasurement) -> Void)?
    private let cursorVisibility = OverlayCursorVisibility()

    public private(set) var isActive = false
    /// Whether the overlay has the keyboard and the pointer: at once on a live screen, once the
    /// pointer's display is captured on a frozen one.
    private var hasInput = false

    /// Whether this session shows the screen as it was when it began; in-place annotation, picking a
    /// color, and measuring always do: they read the frozen frame's pixels.
    private var holdsStill: Bool {
        purpose.holdsStill(freezesScreen: freezesScreen)
    }

    private struct Entry {
        let panel: OverlayPanel
        let view: OverlayView
    }

    private let layoutProvider: () -> DisplayLayout
    private let capturer: ScreenCapturer
    private var currentLayout: DisplayLayout { layoutProvider() }
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var completion: ((Outcome) -> Void)?
    private var captureOwnWindowID: CGWindowID?
    private var captureTransientWantsHDR = false
    private var previousApp: NSRunningApplication?
    private var session = 0
    private var firstFrameArrived = false
    private var frameLeases: [CGDirectDisplayID: ActiveResources.Lease] = [:]
    private var windowLease: ActiveResources.Lease?
    private var windows: [WindowTarget] = []
    /// Windows locked with Shift-click across all displays during a multi-window selection session.
    private var selectedWindows: [WindowTarget] = []
    /// The windows All-In-One highlights under the pointer, front to back, OhMyShot's own left out: read off the main
    /// thread once the overlay has input, so neither its panels nor its frozen frame wait for the window list.
    private var hoverWindows: [WindowTarget] = []
    /// The window highlighted under the pointer while All-In-One has nothing chosen and no button is down.
    private var hovered: HoveredWindow?
    /// The window under the press, which the release frames while the press stays a click.
    private var pressedWindow: HoveredWindow?
    /// Windows selected with Shift while All-In-One stays in its live, area-mode hover picker.
    private var allInOneSelectedWindows: [WindowTarget] = []
    /// The selected windows carried through All-In-One's frozen setup bar, until its final action is chosen.
    private var allInOneCaptureWindows: [WindowTarget] = []
    /// The window a click framed, and the area it framed, in this session or the one just ended (`window(framing:)`).
    private var framed: (window: WindowTarget, area: CGRect)?
    private var windowPicker: WindowPickerController?
    /// The display whose panel currently holds keyboard focus.
    private(set) var keyDisplayID: CGDirectDisplayID?
    /// False in unit tests so panels never order onto screen or alter the real cursor/activation.
    var presentsPanels = true
    private var purpose: Purpose = .screenshot
    /// This app's windows are no window to scroll: a scrolling capture's stream never sees them, and Auto-scroll
    /// would scroll what is behind them.
    private var windowsExcluded: pid_t? { purpose == .scroll ? getpid() : nil }
    /// An area chosen for annotation before its display's frame arrived.
    private var pendingAnnotation: (display: CGDirectDisplayID, area: CGRect)?
    /// The display in-place annotation was handed, once it was: a frame set up there with its bar is not annotation.
    private var annotatedDisplay: CGDirectDisplayID?
    /// The frame with its bar hosted over a display (`host`), while its view holds it.
    private weak var setup: NSView?
    /// The selection being dragged out: one for every display, since a drag may carry it onto another.
    /// In-place annotation keeps it on the display it began on, where its interface lives.
    private var selection = SelectionModel(bounds: .zero, pixelsPerPoint: 1)
    /// The display the last drag began on, which the selection it left stays on.
    private var dragDisplay: DisplayInfo?

    /// A drag going on.
    private struct Drag {
        /// Where the pointer is now, in global space, and the highest it went.
        var point: CGPoint
        var top: CGFloat
        /// Space held moves the selection instead of resizing it.
        var spaceHeld = false
        /// The keys held at the last move or change of keys: the arrow keys redraw the selection under them.
        var modifiers: NSEvent.ModifierFlags = []
    }

    /// Nil while no drag is going on.
    private var drag: Drag?
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

    public convenience init(topology: DisplayTopology, capturer: ScreenCapturer) {
        self.init(layoutProvider: { topology.layout }, capturer: capturer)
    }

    init(layoutProvider: @escaping () -> DisplayLayout, capturer: ScreenCapturer) {
        self.layoutProvider = layoutProvider
        self.capturer = capturer
    }

    /// Creates the panels for the current displays ahead of time, so the hotkey only has to show them.
    public func prepare() {
        let layout = currentLayout
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

    /// - Parameters:
    ///   - options: what this session alone is begun with; All-In-One's only with a screenshot, let go otherwise.
    ///   - area: an area chosen already, in global points (the URL API's): a recording or a scrolling capture frames it
    ///     with its bar at once; a screenshot or text shows it chosen, and Return takes it, or a drag chooses another.
    ///   - includingOwnWindowID: an app-owned window the capture owner explicitly identified, for an area screenshot only.
    public func begin(
        mode: Mode = .area, purpose: Purpose = .screenshot, options: SessionOptions = SessionOptions(), choosing area: CGRect? = nil,
        includingOwnWindowID: CGWindowID? = nil, transientCaptureWantsHDR: Bool = false,
        completion: @escaping (Outcome) -> Void
    ) {
        guard !isActive else { return }
        cursorVisibility.end()
        let beginning = LatencyProbe("overlay.begin")
        let visible = LatencyProbe("overlay.visible")
        let frozen = LatencyProbe("overlay.frozen")
        isActive = true
        session += 1
        firstFrameArrived = false
        self.purpose = purpose
        captureOwnWindowID = Self.scopedOwnWindowID(mode: mode, purpose: purpose, requested: includingOwnWindowID)
        captureTransientWantsHDR = mode == .area && purpose == .screenshot && transientCaptureWantsHDR
        transientCaptureSnapshots = []
        // Said once here, so nothing after asks the purpose again: All-In-One's modes are a screenshot's.
        self.options = options
        if !purpose.mayBeAllInOne { self.options.allInOne = nil }
        self.currentSelfTimerDelay = options.selfTimerDelay.map { max($0, 1) }
        self.options.selfTimerDelay = self.currentSelfTimerDelay
        pendingAnnotation = nil
        selection = SelectionModel(bounds: .zero, pixelsPerPoint: 1)
        dragDisplay = nil
        drag = nil
        pointer = nil
        nudged = false
        self.completion = completion
        allInOneMode = nil
        didSetUpRecording = false
        chosenAhead = nil
        keyDisplayID = nil
        hoverWindows = []
        hovered = nil
        pressedWindow = nil
        allInOneSelectedWindows = []
        allInOneCaptureWindows = []
        framed = nil
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }

        prepare()
        let pointer = NSEvent.mouseLocation
        let layout = currentLayout
        let pointerDisplay = layout.display(at: pointer) ?? layout.primary
        if mode == .windowPicker, let pointerDisplay, purpose == .screenshot || purpose == .record {
            hasInput = true
            windowLease = ActiveResources.shared.acquire(.window)
            showWindowPicker(on: pointerDisplay)
            visible.end()
            frozen.end()
            beginning.end()
            return
        }

        // Standard window targets are read only for window mode; live area screenshots check for transient panels separately.
        windows = mode == .window ? WindowCatalog.snapshot(layout: layout, excludingPID: windowsExcluded) : []
        selectedWindows = []
        let viewMode: OverlayView.Mode = mode == .window ? .window : .area
        let holdsStill = holdsStill
        // Only a frozen screen holds still for its text to be found; the live one may change under a snapped edge.
        cancelTextDetections()
        snapsToText = holdsStill && purpose.snapsToText && textBlocks?.isOn() == true
        for (id, entry) in entries {
            entry.panel.level = OverlayPanel.selectionLevel
            entry.view.reset(
                pointer: pointer, mode: viewMode, windows: windows,
                showsToolbar: id == pointerDisplay?.id && purpose.showsModeBar,
                showsPointer: !holdsStill,
                purpose: purpose,
                colorFormat: colorFormat,
                captureLoupeStyle: captureLoupeStyle,
                captureLoupeSize: captureLoupeSize,
                measureUnit: measureUnit,
                measureTolerance: measureTolerance,
                measureSnapsToContent: measureSnapsToContent,
                allInOne: isAllInOne,
                snapsToText: snapsToText,
                selfTimerDelay: currentSelfTimerDelay
            )
            entry.view.displayLayout = layout
        }
        hasInput = false
        // Shown before the overlay takes input, which tells VoiceOver it is there; framed with its bar once the
        // overlay has the keyboard (`takeInput`), which a frozen session gets a moment later.
        let framesAhead = purpose.framesWithBar || isAllInOne
        chosenAhead = mode == .area && framesAhead ? area.flatMap(choose) : nil
        let session = self.session
        // Text without freezing shows no frame, but the pointer display's still arrives first: it tells
        // the watchdog that capturing works.
        let others = purpose == .text && !freezesScreen ? [] : layout.displays.filter { $0.id != pointerDisplay?.id }
        let ordered = [pointerDisplay].compactMap(\.self) + others
        let requestedOwnWindowID = captureOwnWindowID
        let transientWindows = presentsPanels && mode == .area && purpose == .screenshot && !holdsStill && !isAllInOne
            ? WindowCatalog.transientWindows(
                layout: layout, frontmostPID: previousApp?.processIdentifier, includingOwnWindowID: requestedOwnWindowID
            )
            : []
        let capturesTransients = Self.shouldCaptureLiveTransientContent(
            mode: mode, purpose: purpose, holdsStill: holdsStill, allInOne: isAllInOne, windowCount: transientWindows.count
        )
        if holdsStill {
            // The capture request goes out on the next turn, ahead of the panels' first flush; the panels
            // follow on the turn after, letting the pointer through, and the overlay takes the keyboard
            // and the pointer once the pointer's display is captured.
            Task { [weak self] in
                await self?.loadFrames(for: ordered, session: session, probe: frozen, includingOwnWindowID: requestedOwnWindowID) { [weak self] in
                    self?.takeInput(pointerDisplay: pointerDisplay)
                }
            }
            Task { [weak self] in
                guard let self, isActive, session == self.session else { return }
                showPanels(probe: visible, acceptingInput: false)
            }
        } else if capturesTransients {
            showPanels(probe: visible, acceptingInput: false, suppressingInputUntilComparison: true)
            Task { [weak self] in
                await self?.captureTransientFrames(
                    transientWindows, displays: ordered, pointerDisplay: pointerDisplay,
                    session: session, probe: frozen, requestedOwnWindowID: requestedOwnWindowID
                )
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



    /// Puts the session's panels on screen, suppressing input until transient comparison when requested.
    private func showPanels(
        probe: LatencyProbe, acceptingInput: Bool, suppressingInputUntilComparison: Bool = false
    ) {
        // The panels are reused: the reset layers are committed before any panel is ordered in, so none
        // shows a frame of its previous session.
        CATransaction.flush()
        for entry in entries.values {
            entry.panel.configureInput(
                acceptingInput: acceptingInput,
                suppressingInputUntilComparison: suppressingInputUntilComparison
            )
            if presentsPanels { entry.panel.orderFrontRegardless() }
        }
        probe.end()
        windowLease = ActiveResources.shared.acquire(.window)
    }

    /// Gives the overlay the keyboard and the pointer; once.
    private func takeInput(pointerDisplay: DisplayInfo?, suppressingInput: Bool = false) {
        guard isActive, !hasInput else { return }
        hasInput = true
        // A nonactivating panel can take key focus without activating OhMyShot. Activating the app
        // here can leave a game's full-screen Space or make the game minimize on loss of focus.
        // On a frozen screen this comes a moment after the session began: the crosshair goes where the
        // pointer is now.
        let pointer = NSEvent.mouseLocation
        for entry in entries.values {
            entry.panel.configureInput(acceptingInput: true, suppressingInputUntilComparison: suppressingInput)
            entry.view.movePointer(to: pointer)
        }
        if let id = pointerDisplay?.id, let view = entries[id]?.view {
            VoiceOver.announce(announcement, from: view)
        }
        giveKeyboard(to: pointerDisplay)
        // A screenshot draws its own crosshair and magnifier, but over the bar the system's arrow shows; copying text
        // keeps the system crosshair, from the start rather than the first move. Only once the overlay has input, so an
        // early move never hides the pointer. A nonactivating key panel owns selection input while the
        // previous app remains active. The arrow, for the bar and for the moment the hidden pointer comes back, in place of whatever
        // cursor was set last (an earlier text session's crosshair).
        if presentsPanels {
            BackgroundCursor.allow(true)
            (purpose == .text ? NSCursor.crosshair : NSCursor.arrow).set()
            cursorVisibility.begin(drawsPointer: purpose != .text, overControls: wantsSystemCursor(at: pointer))
        }
        CATransaction.flush()
        // Log key focus after AppKit has processed the nonactivating panel's request.
        let session = self.session
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, isActive, session == self.session else { return }
            Log.capture.notice("Overlay shown (\(self.holdsStill ? "frozen" : "live", privacy: .public)): app active \(NSApp?.isActive ?? false, privacy: .public), keyboard \(NSApp?.keyWindow is OverlayPanel, privacy: .public)")
        }
        // All-In-One highlights the window under the pointer until something is chosen; an area given to `begin` is
        // chosen now.
        if isAllInOne, chosenAhead == nil { loadHoverWindows() }
        // An area given to `begin` is framed now: its bar takes the keyboard and the pointer from the overlay.
        if let chosen = chosenAhead {
            chosenAhead = nil
            select(chosen.area, startingOn: chosen.display, modifiers: [])
        }
    }

    /// Gives the overlay on `display` the keyboard, so its view hears the keys: they act on what is under the crosshair
    /// there.
    private func giveKeyboard(to display: DisplayInfo?) {
        guard let id = display?.id, let entry = entries[id] else { return }
        keyDisplayID = id
        if presentsPanels, !entry.panel.isKeyWindow { entry.panel.makeKey() }
        if entry.panel.firstResponder !== entry.view { entry.panel.makeFirstResponder(entry.view) }
    }

    /// Moves keyboard focus to the display covering `point` when the user is hovering freely across displays,
    /// so keyboard shortcuts (`Return`, `⌘C`, `C`, `F`, `W`, `Tab`, `[`, `]`) act on the pointer's display.
    private func focusDisplay(at point: CGPoint) {
        guard isActive, hasInput, drag == nil, setup?.superview == nil, windowPicker == nil, !isAnnotating,
              !entries.values.contains(where: { $0.view.isDraggingMeasureBox }),
              (!presentsPanels || NSEvent.pressedMouseButtons == 0),
              let target = currentLayout.display(at: point),
              let entry = entries[target.id] else { return }
        if keyDisplayID == target.id, (!presentsPanels || entry.panel.isKeyWindow), entry.panel.firstResponder === entry.view {
            return
        }
        keyDisplayID = target.id
        if presentsPanels { entry.panel.makeKey() }
        entry.panel.makeFirstResponder(entry.view)
    }

    /// The window a click in All-In-One framed `area` from, in this session or the one just ended; nil for any other
    /// area, dragged out or changed after it was framed. Screenshot uses this exact match to retain native window
    /// corners and shadow; other choices use its app and title for naming.
    public func window(framing area: CGRect) -> WindowTarget? {
        Self.framedWindow(framed, matching: area)
    }

    static func framedWindow(_ framed: (window: WindowTarget, area: CGRect)?, matching area: CGRect) -> WindowTarget? {
        guard let framed, framed.area == area else { return nil }
        return framed.window
    }

    /// What VoiceOver says as the overlay takes input, or as All-In-One turns into Measure.
    private var announcement: String {
        switch purpose {
        case .text: String(localized: "Drag over text to copy it, or press Space to choose a window.", bundle: .module)
        case .annotate: String(localized: "Drag over an area to mark it up, or press Space to choose a window.", bundle: .module)
        case .screenshot where isAllInOne: String(localized: "All-In-One. Click a window or drag over an area, then choose what to do with it.", bundle: .module)
        case .screenshot: String(localized: "Drag to capture an area, or press Space to capture a window.", bundle: .module)
        case .color: String(localized: "Click or press Return to copy the color under the crosshair. The arrow keys move it a pixel.", bundle: .module)
        case .measure: String(localized: "Point at something to measure it, or drag a box around it. Command-C copies the measurement.", bundle: .module)
        case .record: String(localized: "Drag over an area to record it, click to record the whole screen, or press Space to choose a window.", bundle: .module)
        case .scroll: String(localized: "Drag over the part that scrolls, or press Space to choose a window.", bundle: .module)
        }
    }

    /// Reads the windows All-In-One highlights, off the main thread, then highlights the one under the pointer.
    private func loadHoverWindows() {
        let session = self.session, layout = currentLayout
        let probe = LatencyProbe("overlay.windows")
        Task { [weak self] in
            let windows = await Task.detached(priority: .userInitiated) {
                WindowCatalog.snapshot(layout: layout, excludingPID: getpid())
            }.value
            probe.end()
            guard let self, isActive, session == self.session else { return }
            hoverWindows = windows
            updateHover(at: pointer ?? NSEvent.mouseLocation)
        }
    }

    public func cancel() {
        end(.cancelled)
    }

    /// Whether the pointer is over a bar, where the system's arrow shows in place of the drawn crosshair.
    private func wantsSystemCursor(at point: CGPoint) -> Bool {
        entries.values.contains { $0.view.wantsSystemCursor(at: point) }
    }

    private func updateCursorVisibility(at point: CGPoint) {
        cursorVisibility.update(overControls: wantsSystemCursor(at: point))
    }

    /// Ends in-place annotation: the overlay goes away and the previous app gets the keyboard back.
    public func finishAnnotation() {
        end(.annotated)
    }

    /// Whether in-place annotation is showing, for scripted checks.
    public var isAnnotating: Bool {
        isActive && entries.values.contains { $0.view.isAnnotating }
    }

    /// The display in-place annotation is showing on, while it is; nil while a frame is set up with its bar (All-In-One,
    /// recording, scrolling, a typed size), which is not marked on.
    public var annotationDisplay: DisplayInfo? {
        guard isActive, let annotatedDisplay else { return nil }
        return entries[annotatedDisplay]?.view.display
    }

    /// Whether in-place annotation on `display` can go on once the displays are `layout`: only while that display is there
    /// as it was (where it was, as large, at the same scale), as the marks are drawn on its frozen frame. Displays
    /// plugged in, taken away, or moved around it leave it be, and so does its name changing, as macOS numbers it once
    /// a second display of its model is plugged in.
    public static func keepsAnnotating(on display: DisplayInfo, in layout: DisplayLayout) -> Bool {
        guard let now = layout.display(id: display.id) else { return false }
        return now.frame == display.frame && now.pixelSize == display.pixelSize && now.backingScale == display.backingScale
    }

    /// The recording bar's view while a choice is framed, for scripted checks.
    var recordingSetup: RecordingSetupView? { hostedSetup() }

    /// All-In-One's frame while its area is framed, for scripted checks.
    var allInOneSetup: AllInOneSetupView? { hostedSetup() }

    /// The scrolling bar's view while an area is framed, for scripted checks.
    var scrollingSetup: ScrollingSetupView? { hostedSetup() }

    /// The overlay view for `displayID`, for tests.
    func overlayView(for displayID: CGDirectDisplayID) -> OverlayView? {
        entries[displayID]?.view
    }

    /// The first responder on `displayID`'s panel, for tests.
    func firstResponder(on displayID: CGDirectDisplayID) -> NSResponder? {
        entries[displayID]?.panel.firstResponder
    }

    /// The active window picker, for tests.
    var activeWindowPicker: WindowPickerController? { windowPicker }

    /// The frame with its bar the overlay hosts now, when it is a `Setup`: one at a time, and gone once it is taken
    /// down (a frame that hands over to the next) or the overlay is cleared.
    private func hostedSetup<Setup: NSView>() -> Setup? {
        guard isActive, let setup, setup.superview != nil else { return nil }
        return setup as? Setup
    }

    /// Draws a selection and pointer without mouse input, for scripted checks of the rendering.
    public func simulate(selection rect: CGRect, pointer: CGPoint) {
        guard isActive, let display = startDisplay(of: rect) else { return }
        place(rect, startingOn: display)
        if let under = currentLayout.display(at: pointer) { entries[under.id]?.view.simulate(pointer: pointer) }
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
        guard isActive, purpose != .text, let display = currentLayout.display(at: point), let view = entries[display.id]?.view else { return }
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
        guard let point = pointer, let display = currentLayout.display(at: point) else { return }
        entries[display.id]?.view.debugCopyMeasurement()
    }

    /// The ruler's measurement on the display under the crosshair, for scripted checks.
    public var debugMeasurement: String? {
        guard let point = pointer, let display = currentLayout.display(at: point) else { return nil }
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

    static func shouldCaptureLiveTransientContent(
        mode: Mode, purpose: Purpose, holdsStill: Bool, allInOne: Bool, windowCount: Int
    ) -> Bool {
        mode == .area && purpose == .screenshot && !holdsStill && !allInOne && windowCount > 0
    }

    static func shouldObserveTransientDisappearance(
        _ candidates: [TransientWindow], onScreenOwners: [OnScreenWindowOwner]
    ) -> Bool {
        candidates.contains { candidate in
            !candidate.keepsWhenPresent && onScreenOwners.contains {
                $0.id == candidate.id && $0.ownerPID == candidate.ownerPID
            }
        }
    }

    #if DEBUG
    static func captureFrame(
        injected: CapturedFrame?, using capture: () async throws -> CapturedFrame
    ) async throws -> CapturedFrame {
        if let injected { return injected }
        return try await capture()
    }
    #endif

    static func scopedOwnWindowID(mode: Mode, purpose: Purpose, requested: CGWindowID?) -> CGWindowID? {
        mode == .area && purpose == .screenshot ? requested : nil
    }

    private func captureTransientFrames(
        _ windows: [TransientWindow], displays: [DisplayInfo], pointerDisplay: DisplayInfo?,
        session: Int, probe: LatencyProbe, requestedOwnWindowID: CGWindowID?
    ) async {
        guard isActive, session == self.session else { return }
        let transientProbe = LatencyProbe("overlay.transient")
        var ownWindowID = requestedOwnWindowID
        var candidates = windows
        if let requestedOwnWindowID, windows.contains(where: { $0.id == requestedOwnWindowID }) {
            do {
                let canIncludeWindow = try await capturer.hasOwnWindow(withID: requestedOwnWindowID)
                guard isActive, session == self.session else { return }
                if !canIncludeWindow {
                    ownWindowID = nil
                    candidates.removeAll { $0.id == requestedOwnWindowID }
                }
            } catch {
                guard isActive, session == self.session else { return }
                ownWindowID = nil
                candidates.removeAll { $0.id == requestedOwnWindowID }
            }
        } else {
            ownWindowID = nil
        }
        var capturedFrames: [CapturedFrame] = []
        for display in displays {
            guard isActive, session == self.session else { return }
            let regions = candidates.filter { $0.frame.intersects(display.frame) }.map(\.frame)
            guard !regions.isEmpty else { continue }
            do {
                let frame: CapturedFrame
                #if DEBUG
                frame = try await Self.captureFrame(injected: injectedFrames?[display.id]) {
                    try await capturer.captureDisplay(
                        display, dynamicRange: ScreenCapturer.dynamicRange(wantsHDR: captureTransientWantsHDR, on: display),
                        includingOwnWindowID: ownWindowID
                    )
                }
                #else
                frame = try await capturer.captureDisplay(
                    display, dynamicRange: ScreenCapturer.dynamicRange(wantsHDR: captureTransientWantsHDR, on: display),
                    includingOwnWindowID: ownWindowID
                )
                #endif
                guard isActive, session == self.session else { return }
                capturedFrames.append(frame)
                firstFrameArrived = true
            } catch {
                guard isActive, session == self.session else { return }
                Log.capture.error("Transient frame for display \(display.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard isActive, session == self.session else { return }
        takeInput(pointerDisplay: pointerDisplay, suppressingInput: true)
        await nextAppKitEventLoopTurn()
        guard isActive, session == self.session else { return }
        var visibleOwners = WindowCatalog.onScreenWindowOwners()
        if Self.shouldObserveTransientDisappearance(candidates, onScreenOwners: visibleOwners) {
            try? await Task.sleep(for: .milliseconds(100))
            guard isActive, session == self.session else { return }
            visibleOwners = WindowCatalog.onScreenWindowOwners()
        }
        let retainedWindows = WindowCatalog.transientWindowsToRestore(candidates, onScreenOwners: visibleOwners)
        let snapshots = capturedFrames.compactMap { frame -> TransientCaptureSnapshot? in
            let regions = retainedWindows.filter { $0.frame.intersects(frame.frame) }.map(\.frame)
            return regions.isEmpty ? nil : TransientCaptureSnapshot(frame: frame, regions: regions)
        }
        transientProbe.end()
        guard isActive, session == self.session else { return }
        transientCaptureSnapshots = snapshots
        for entry in entries.values { entry.view.showTransientContent(from: snapshots) }
        for entry in entries.values {
            entry.panel.configureInput(acceptingInput: true, suppressingInputUntilComparison: false)
        }
        Task { [weak self] in
            await self?.loadFrames(for: displays, session: session, probe: probe) {}
        }
    }

    private func nextAppKitEventLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Captures each display in turn, the pointer's first; `onFirstFrame` runs once that one is shown.
    private func loadFrames(
        for displays: [DisplayInfo], session: Int, probe: LatencyProbe, includingOwnWindowID: CGWindowID? = nil,
        cancelsOnFirstFailure: Bool = true, onFirstFrame: () -> Void
    ) async {
        guard isActive, session == self.session, windowPicker == nil else { return }
        let showsCursor = Self.framesShowPointer(showsPointer, purpose: purpose, holdsStill: holdsStill, allInOne: isAllInOne, recaptured: options.recapturesLive)
        for (index, display) in displays.enumerated() {
            guard isActive, session == self.session, windowPicker == nil else { return }
            do {
                let frame: CapturedFrame
                let capturing = index == 0 ? LatencyProbe("overlay.capture") : nil
                #if DEBUG
                frame = try await Self.captureFrame(injected: injectedFrames?[display.id]) {
                    try await capturer.captureDisplay(display, showsCursor: showsCursor, includingOwnWindowID: includingOwnWindowID)
                }
                #else
                frame = try await capturer.captureDisplay(display, showsCursor: showsCursor, includingOwnWindowID: includingOwnWindowID)
                #endif
                capturing?.end()
                guard isActive, session == self.session, windowPicker == nil else { return }
                let previewFrame = transientCaptureSnapshots.isEmpty
                    ? frame
                    : frame.restoringTransientContent(from: transientCaptureSnapshots) ?? frame
                entries[display.id]?.view.show(previewFrame, frozen: holdsStill)
                frameLeases[display.id] = ActiveResources.shared.acquire(.frameBuffer)
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
                if cancelsOnFirstFailure, index == 0, isActive, session == self.session, windowPicker == nil { end(.cancelled) }
                return
            }
        }
    }

    /// Whether the frames captured for a session carry the pointer: only a screenshot's frozen ones, which are what is
    /// kept (a live screen is captured after the overlay has gone, as is a Self-Timer's area). Picking a color and
    /// measuring read the frames' pixels, and text is read from them, so the pointer would only be in the way: that is
    /// why All-In-One's, which may take its area's text, carry none either.
    static func framesShowPointer(_ setting: Bool, purpose: Purpose, holdsStill: Bool, allInOne: Bool = false, recaptured: Bool = false) -> Bool {
        setting && holdsStill && !allInOne && !recaptured && purpose.takesPicture
    }

    static func watchdogShouldDismiss(firstFrameArrived: Bool, windowPickerIsOpen: Bool) -> Bool {
        !firstFrameArrived && !windowPickerIsOpen
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
        guard isActive, session == self.session,
              Self.watchdogShouldDismiss(firstFrameArrived: firstFrameArrived, windowPickerIsOpen: windowPicker != nil)
        else { return }
        Log.capture.notice("Overlay dismissed: no frame after 500 ms")
        end(.cancelled)
    }

    /// Hands `entry`'s display over to what is set up on it, a frame with its bar or in-place annotation: the pointer
    /// is the system's again (for the frame's resize cursors; marks need the arrow, the I-beam, and the resize
    /// cursors), only this display stays (the others would start selections of their own), and the overlay's own
    /// selection, readings, crosshair, and bar step aside, since what is set up draws its own.
    private func keepOnly(_ entry: Entry) {
        cursorVisibility.end()
        for (id, other) in entries where id != entry.view.display.id {
            other.panel.orderOut(nil)
            other.view.clear()
            frameLeases[id] = nil
        }
        entry.view.enterAnnotation()
        entry.panel.level = OverlayPanel.annotationLevel
        keyDisplayID = entry.view.display.id
        if presentsPanels { entry.panel.makeKey() }
    }

    /// Puts `setup` over `entry`'s display, which `keepOnly` has handed over, and gives it the keyboard; Escape there
    /// cancels the session.
    private func host<Bar>(_ setup: AreaSetupView<Bar>, in entry: Entry) {
        setup.frame = entry.view.bounds
        setup.onCancel = { [weak self] in self?.cancel() }
        entry.view.addSubview(setup)
        entry.panel.makeFirstResponder(setup)
        self.setup = setup
        setup.begin()
        setup.refreshCodes()
    }

    /// Frames what is to be recorded on its display, with the recording bar under it.
    private func startRecordingSetup(on display: DisplayInfo, target: RecordingTarget) {
        guard let entry = entries[display.id] else { return }
        keepOnly(entry)
        let setup = RecordingSetupView(display: display, target: target, choices: recordingChoices)
        setup.onChange = { [weak self] target, choices in
            self?.recordingChoices = choices
            self?.onRecordingSetupChange?(target, display, choices)
        }
        setup.onRecord = { [weak self] target, choices in
            self?.end(.record(target, display: display, choices: choices))
        }
        setup.onCameraCommand = { [weak self] command in self?.onRecordingCameraCommand?(command) }
        setup.cameraFills = { [weak self] in self?.recordingCameraFills() ?? false }
        host(setup, in: entry)
    }

    /// Frames the area of a scrolling capture on its display, with the scrolling bar under it, as a recording's
    /// choice is framed. False, and nothing framed, when too little of the area is on the display.
    @discardableResult
    private func startScrollingSetup(on display: DisplayInfo, area: CGRect) -> Bool {
        guard let entry = entries[display.id], let area = AreaFrame.fitted(area, in: display.frame) else { return false }
        if options.startsScrollingAtOnce {
            end(.scroll(area, display: display, autoScrolls: false))
            return true
        }
        keepOnly(entry)
        let setup = ScrollingSetupView(display: display, area: area)
        setup.onStart = { [weak self] area, autoScrolls in
            self?.end(.scroll(area, display: display, autoScrolls: autoScrolls))
        }
        host(setup, in: entry)
        return true
    }

    /// Frames All-In-One's area on its display with the bar of every way to take it, as a scrolling capture's area is
    /// framed. `sizing` is Capture Area's (or Annotate Area's) own frame, opened with Tab: the same frame with only
    /// Capture, the size, and the shape on its bar, keeping `ratio`. False, and nothing framed, when too little of the
    /// area is on the display.
    @discardableResult
    private func startAllInOneSetup(
        on display: DisplayInfo, area: CGRect, sizing: Bool = false, ratio: AspectRatio? = nil, windowFrames: [CGRect] = []
    ) -> Bool {
        guard let entry = entries[display.id], let area = AreaFrame.fitted(area, in: display.frame) else { return false }
        hovered = nil
        pressedWindow = nil
        allInOneSelectedWindows = []
        for entry in entries.values { entry.view.setSelectedWindows([]) }
        keepOnly(entry)
        let setup = AllInOneSetupView(
            display: display, area: area, offersUpload: (options.allInOne?.offersUpload ?? false) && !sizing,
            showsCopy: options.allInOne?.showsCopy ?? true, kind: sizing ? .sizing : .allInOne,
            ratio: sizing ? ratio : nil, windowFrames: windowFrames, annotates: sizing && purpose == .annotate
        )
        setup.onShapeKept = { [weak self] shape in self?.onKeptShapeChange?(shape) }
        setup.onAreaAdjusted = { [weak self] _ in
            self?.allInOneCaptureWindows = []
            self?.framed = nil
        }
        setup.codeFinder = codes
        setup.edgeTolerance = measureTolerance
        if !sizing {
            setup.onReturnToSelection = { [weak self, weak setup] target in
                guard let self else { return }
                setup?.removeFromSuperview()
                self.setup = nil
                allInOneCaptureWindows = []
                framed = nil
                switch target {
                case .area:
                    returnToAllInOneSelection(mode: .area, from: display)
                case .window:
                    returnToAllInOneSelection(mode: .window, from: display)
                case .windowPicker:
                    showWindowPicker(on: display, returningTo: .area)
                }
            }
        }
        setup.onChoose = { [weak self, weak setup] choice, area, wholeDisplay in
            guard let self else { return }
            if wholeDisplay {
                framed = nil
                allInOneSelectedWindows = []
                allInOneCaptureWindows = []
                for entry in entries.values { entry.view.setSelectedWindows([]) }
            }
            if sizing {
                // Taken as the drag would have taken it. In-place annotation hosts its interface in the overlay's view,
                // which the frame no longer covers.
                setup?.removeFromSuperview()
                select(area, startingOn: display, modifiers: [])
            } else if choice == .record {
                allInOneCaptureWindows = []
                setup?.removeFromSuperview()
                setUpRecording(on: display, target: area == display.frame ? .display : .area(area))
            } else {
                endAllInOne(choice, area, on: display)
            }
        }
        host(setup, in: entry)
        return true
    }

    /// Exits All-In-One's framed area without ending the session, restoring the selection overlay across all
    /// displays in `mode` (`.area` for Delete/Backspace, `.window` for Space) while keeping the display's frozen frame.
    private func returnToAllInOneSelection(mode: OverlayView.Mode, from display: DisplayInfo) {
        guard isActive else { return }
        setup?.removeFromSuperview()
        setup = nil
        selection.reset()
        selectedWindows = []
        hovered = nil
        pressedWindow = nil
        allInOneSelectedWindows = []
        allInOneCaptureWindows = []
        framed = nil
        drag = nil
        dragDisplay = nil
        allInOneMode = nil
        let pointer = NSEvent.mouseLocation
        self.pointer = pointer
        nudged = false
        let layout = currentLayout
        let pointerDisplay = layout.display(at: pointer) ?? display
        if mode == .window, windows.isEmpty {
            windows = WindowCatalog.snapshot(layout: layout, excludingPID: windowsExcluded)
        }
        CATransaction.flush()
        for (id, entry) in entries {
            entry.panel.level = OverlayPanel.selectionLevel
            entry.panel.configureInput(acceptingInput: true, suppressingInputUntilComparison: false)
            entry.view.leaveAnnotation(
                mode: mode,
                windows: windows,
                showsToolbar: id == pointerDisplay.id && purpose.showsModeBar,
                pointer: pointer
            )
            entry.view.markPurpose(nil)
            if presentsPanels, !entry.panel.isVisible {
                entry.panel.orderFrontRegardless()
            }
        }
        if let active = entries[pointerDisplay.id] {
            keyDisplayID = pointerDisplay.id
            if presentsPanels { active.panel.makeKey() }
            active.panel.makeFirstResponder(active.view)
            let announcement = mode == .window
                ? String(localized: "Click a window to capture it, or press Space to select an area.", bundle: .module)
                : String(localized: "Selection cleared. Drag over an area, or press Space to choose a window.", bundle: .module)
            VoiceOver.announce(announcement, from: active.view)
        }
        if presentsPanels {
            BackgroundCursor.allow(true)
            NSCursor.arrow.set()
            cursorVisibility.begin(drawsPointer: purpose != .text, overControls: wantsSystemCursor(at: pointer))
        }
        if mode == .area, isAllInOne {
            updateHover(at: pointer)
        }
        CATransaction.flush()
        let missing = layout.displays.filter { entries[$0.id]?.view.frame() == nil }
        if !missing.isEmpty {
            let session = self.session
            Task { [weak self] in
                await self?.loadFrames(for: missing, session: session, probe: LatencyProbe("overlay.refreeze"), cancelsOnFirstFailure: false) {}
            }
        }
    }

    /// Ends All-In-One with what to do with `area`: on a frozen screen, the area as it was frozen goes along.
    private func endAllInOne(_ choice: AllInOneChoice, _ area: CGRect, on display: DisplayInfo) {
        let frozen = holdsStill ? frozenArea(area, on: [display]) : nil
        Log.capture.notice("All-In-One \(String(describing: choice), privacy: .public) on \(NSStringFromRect(area), privacy: .public)")
        if allInOneCaptureWindows.isEmpty {
            end(.allInOne(choice, area, display: display, frozen: frozen))
        } else {
            end(.allInOneWindows(choice, allInOneCaptureWindows, area, display: display, frozen: frozen))
        }
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
        keepOnly(entry)
        annotatedDisplay = displayID
        onAnnotate(AnnotationRequest(
            host: entry.view, display: entry.view.display, area: area, frame: frame,
            showEdgeLoupe: { [weak view = entry.view] point in view?.showEdgeLoupe(at: point) },
            codes: codes
        ))
    }

    private func end(_ outcome: Outcome) {
        guard isActive else { return }
        windowPicker?.close()
        windowPicker = nil
        isActive = false
        options = SessionOptions()
        allInOneMode = nil
        allInOneSelectedWindows = []
        allInOneCaptureWindows = []
        chosenAhead = nil
        pendingAnnotation = nil
        annotatedDisplay = nil
        drag = nil
        pointer = nil
        nudged = false
        keyDisplayID = nil
        cancelTextDetections()
        snapsToText = false
        #if DEBUG
        injectedFrames = nil
        #endif
        for entry in entries.values {
            entry.panel.configureInput(acceptingInput: false, suppressingInputUntilComparison: false)
            entry.panel.orderOut(nil)
            entry.view.clear()
        }
        // The pointer comes back as the arrow, and is the active app's again.
        if presentsPanels, hasInput { NSCursor.arrow.set() }
        cursorVisibility.end()
        if presentsPanels { BackgroundCursor.allow(false) }
        frameLeases.removeAll()
        windowLease = nil
        windows = []
        selectedWindows = []
        hoverWindows = []
        hovered = nil
        pressedWindow = nil
        // Nonactivating panels return key focus themselves. Only yield activation if a child control
        // actually activated us; reactivating the old app unconditionally can switch Spaces again.
        if presentsPanels, hasInput, NSApp?.isActive == true, let previousApp, !previousApp.isActive {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        hasInput = false
        previousApp = nil
        MemoryRelief.returnFreedPages()
        let completion = self.completion
        let endedSession = session
        self.completion = nil
        completion?(outcome)
        if session == endedSession {
            currentSelfTimerDelay = nil
            transientCaptureSnapshots = []
            captureOwnWindowID = nil
            captureTransientWantsHDR = false
        }
    }
}

// MARK: - Selecting

extension OverlayController {
    /// A fresh selection for a drag that begins on `display`: free to cross onto every display, at the
    /// sharpest one's pixels, except in place, where it stays on its own display.
    private func startSelection(on display: DisplayInfo) {
        let displays = purpose.selectsOnOneDisplay || isAllInOne ? [display] : currentLayout.displays
        selection = SelectionModel(
            bounds: displays.reduce(CGRect.null) { $0.union($1.frame) },
            pixelsPerPoint: displays.map(\.pixelsPerPoint).max() ?? display.pixelsPerPoint
        )
        selection.shape = keptShape?.value ?? 1
        dragDisplay = display
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
        let layout = currentLayout
        return layout.display(at: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
            ?? layout.displays.first { !$0.frame.intersection(rect).isEmpty }
    }

    /// Draws the selection on every display, each its own part. The size reading goes on the display
    /// under the middle of the selection's bottom edge, or else the pointer's.
    private func showSelection() {
        let layout = currentLayout
        let reading = selection.rect.flatMap { rect in
            layout.display(at: CGPoint(x: rect.midX, y: rect.minY)) ?? drag.flatMap { layout.display(at: $0.point) } ?? dragDisplay
        }
        for (id, entry) in entries {
            entry.view.show(selection: selection, showsReading: id == reading?.id, isDragging: drag != nil)
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

    /// The window All-In-One highlights at `point` on `display`: the frontmost of `windows` there, cut to the display;
    /// nil where there is none, or too little of it is on the display to frame.
    static func hoveredWindow(at point: CGPoint, in windows: [WindowTarget], on display: DisplayInfo) -> HoveredWindow? {
        guard display.frame.contains(point), let window = WindowCatalog.target(at: point, in: windows),
              let area = AreaFrame.fitted(window.frame, in: display.frame) else { return nil }
        return HoveredWindow(window: window, area: area, display: display)
    }

    /// The window a press keeps to frame as it is released: kept while the selection it drags out is still a click (too
    /// small to be a drag), and let go for good once it is a drag, so a drag brought back to where it began frames nothing.
    static func pressedWindow(_ window: HoveredWindow?, after selection: SelectionModel) -> HoveredWindow? {
        selection.isTooSmall ? window : nil
    }

    /// Whether All-In-One highlights a window at `point` now: nothing chosen, no button down, choosing an area, and the
    /// pointer not over the bar.
    private func highlightsWindows(at point: CGPoint) -> Bool {
        isActive && isAllInOne && hasInput && drag == nil && windowPicker == nil && !isAnnotating
            && entries.values.allSatisfy { $0.view.mode == .area } && !wantsSystemCursor(at: point)
    }

    /// Highlights the window under `point`, while All-In-One highlights windows, on the display under it.
    private func updateHover(at point: CGPoint) {
        hovered = highlightsWindows(at: point)
            ? currentLayout.display(at: point).flatMap { Self.hoveredWindow(at: point, in: hoverWindows, on: $0) }
            : nil
        showHover()
    }

    /// Draws the window highlighted (during a press, the one pressed on while the press is a click) on its display alone.
    private func showHover() {
        let shown = drag == nil ? hovered : pressedWindow
        let syncAllInOneSelection = isAllInOne && allInOneMode == nil && entries.values.allSatisfy { $0.view.mode == .area }
        for (id, entry) in entries {
            if syncAllInOneSelection { entry.view.setSelectedWindows(allInOneSelectedWindows) }
            entry.view.highlight(id == shown?.display.id ? shown : nil)
        }
    }

    static func displayForSetup(targets: [WindowTarget], in layout: DisplayLayout) -> DisplayInfo? {
        layout.displays.max { first, second in
            func coveredArea(on display: DisplayInfo) -> CGFloat {
                targets.reduce(0) { total, target in
                    let part = target.frame.intersection(display.frame)
                    return total + (part.isNull ? 0 : part.width * part.height)
                }
            }
            return coveredArea(on: first) < coveredArea(on: second)
        }.flatMap { display in
            targets.contains { $0.frame.intersects(display.frame) } ? display : nil
        }
    }

    static func toggledWindow(_ target: WindowTarget, in selected: [WindowTarget]) -> [WindowTarget] {
        if let index = selected.firstIndex(of: target) {
            var selected = selected
            selected.remove(at: index)
            return selected
        }
        return selected + [target]
    }

    private func toggleAllInOneWindow(_ target: WindowTarget, on view: OverlayView) {
        allInOneSelectedWindows = Self.toggledWindow(target, in: allInOneSelectedWindows)
        showHover()
        view.announceValue()
    }

    /// Frames the window a click in All-In-One was on, its part on the display clicked on, as a drag over it would have:
    /// every way to take an area, and a mode chosen first, apply to it.
    private func frameWindow(_ clicked: HoveredWindow, modifiers: NSEvent.ModifierFlags) {
        hovered = nil
        showHover()
        place(clicked.area, startingOn: clicked.display)
        guard let rect = selection.rect, !selection.isTooSmall else { return }
        framed = (clicked.window, rect)
        Log.capture.notice("All-In-One window \(clicked.window.id, privacy: .public) clicked: \(NSStringFromRect(rect), privacy: .public) on display \(clicked.display.id, privacy: .public)")
        select(rect, startingOn: clicked.display, modifiers: modifiers, windowFrames: [clicked.window.frame])
    }

    /// Ends the session with an area: handed to in-place annotation, or kept as it was frozen on screen,
    /// or captured once the overlay has gone. `display` is where the drag began; the outcome names the
    /// display holding most of the area.
    private func select(_ rect: CGRect, startingOn display: DisplayInfo, modifiers: NSEvent.ModifierFlags, windowFrames: [CGRect] = []) {
        if isAllInOne {
            switch allInOneMode {
            case .record?: setUpRecording(on: display, target: rect == display.frame ? .display : .area(rect))
            case let mode?: endAllInOne(mode, rect, on: display)
            case nil: startAllInOneSetup(on: display, area: rect, windowFrames: windowFrames)
            }
            return
        }
        switch purpose {
        case .annotate:
            return startAnnotating(on: display.id, area: rect)
        case .record:
            return startRecordingSetup(on: display, target: rect == display.frame ? .display : .area(rect))
        case .scroll:
            startScrollingSetup(on: display, area: rect)
            return
        case .screenshot, .text, .color, .measure:
            break
        }
        let involved = currentLayout.displays.filter { !$0.frame.intersection(rect).isEmpty }
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
    private func logSelection(_ rect: CGRect, from display: DisplayInfo, endingAt point: CGPoint, highest top: CGFloat) {
        let panels = entries.values.map { entry in
            entry.panel.frame == entry.view.display.frame
                ? "\(entry.view.display.id) covers its display"
                : "\(entry.view.display.id) at \(NSStringFromRect(entry.panel.frame)) on \(NSStringFromRect(entry.view.display.frame))"
        }.sorted().joined(separator: ", ")
        Log.capture.notice("Selection \(NSStringFromRect(rect), privacy: .public) from display \(display.id, privacy: .public), last point \(NSStringFromPoint(point), privacy: .public), highest y \(top, privacy: .public); panels: \(panels, privacy: .public)")
    }
}

extension OverlayController: OverlayViewDelegate {
    func overlayView(_ view: OverlayView, didPressAt point: CGPoint) {
        Log.capture.notice("Selection began at \(NSStringFromPoint(point), privacy: .public) on display \(view.display.id, privacy: .public)")
        pressedWindow = highlightsWindows(at: point) ? Self.hoveredWindow(at: point, in: hoverWindows, on: view.display) : nil
        startSelection(on: view.display)
        selection.begin(at: point)
        drag = Drag(point: point, top: point.y)
        pointer = point
        nudged = false
        showHover()
        showSelection()
        updateCursorVisibility(at: point)
    }

    func overlayView(_ view: OverlayView, didDragTo point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var drag else { return }
        drag.modifiers = modifiers
        if drag.spaceHeld {
            selection.move(by: CGVector(dx: point.x - drag.point.x, dy: point.y - drag.point.y))
        } else {
            selection.drag(to: point, modifiers: selectionModifiers(modifiers), snapping: dragSnap)
        }
        drag.point = point
        drag.top = max(drag.top, point.y)
        self.drag = drag
        // Once the press is a drag, the window under it is no longer what it takes.
        if pressedWindow != nil {
            pressedWindow = Self.pressedWindow(pressedWindow, after: selection)
            showHover()
        }
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
        guard let drag, let display = dragDisplay else { return }
        self.drag = nil
        let clicked = Self.pressedWindow(pressedWindow, after: selection)
        pressedWindow = nil
        guard let rect = selection.rect, !selection.isTooSmall else {
            selection.reset()
            if let clicked {
                if isAllInOne, allInOneMode == nil, purpose == .screenshot, modifiers.contains(.shift) {
                    toggleAllInOneWindow(clicked.window, on: view)
                    updateHover(at: drag.point)
                    showSelection()
                    return
                }
                if isAllInOne, allInOneMode == nil, !allInOneSelectedWindows.isEmpty {
                    var targets = allInOneSelectedWindows
                    if !targets.contains(clicked.window) { targets.append(clicked.window) }
                    overlayView(view, didSelectWindows: targets, modifiers: modifiers)
                    return
                }
                // A click on the window All-In-One highlights frames that window.
                return frameWindow(clicked, modifiers: modifiers)
            }
            showSelection()
            updateCursorVisibility(at: drag.point)
            // A click, not a drag: recording takes the whole display.
            if purpose == .record { startRecordingSetup(on: display, target: .display) }
            updateHover(at: drag.point)
            return
        }
        allInOneSelectedWindows = []
        showHover()
        logSelection(rect, from: display, endingAt: drag.point, highest: drag.top)
        select(rect, startingOn: display, modifiers: modifiers)
    }

    func overlayView(_ view: OverlayView, didChangeModifiers modifiers: NSEvent.ModifierFlags) {
        guard let drag, !drag.spaceHeld else { return }
        self.drag?.modifiers = modifiers
        selection.drag(to: drag.point, modifiers: selectionModifiers(modifiers), snapping: dragSnap)
        showSelection()
    }

    func overlayView(_ view: OverlayView, didMovePointerTo point: CGPoint) {
        pointer = point
        nudged = false
        for entry in entries.values {
            entry.view.movePointer(to: point)
        }
        focusDisplay(at: point)
        updateCursorVisibility(at: point)
        updateHover(at: point)
    }

    func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool) {
        // After the arrow keys the crosshair says where the color is.
        let location = nudged ? (pointer ?? point) : point
        guard isActive, let display = currentLayout.display(at: location), let color = entries[display.id]?.view.color(at: location) else { return }
        Log.capture.notice("Picked \(color.hex, privacy: .public) (\(color.displayP3, privacy: .public)\(color.isInSRGB ? "" : ", outside sRGB", privacy: .public)) at \(NSStringFromPoint(location), privacy: .public)")
        end(.color(color, at: location, display: display, modifiers: modifiers, keyboard: keyboard))
    }

    func overlayView(_ view: OverlayView, didNudge pixels: CGVector) {
        if let drag {
            nudgeDraggedCorner(by: pixels, in: drag)
            return
        }
        let base = pointer ?? NSEvent.mouseLocation
        let layout = currentLayout
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
        if presentsPanels, let primary = NSScreen.screens.first {
            CGWarpMouseCursorPosition(CGPoint(x: next.x, y: primary.frame.maxY - next.y))
        }
        for entry in entries.values {
            entry.view.movePointer(to: next)
        }
        focusDisplay(at: next)
        updateHover(at: next)
        if let under = layout.display(at: next) { entries[under.id]?.view.announceValue() }
    }

    /// Moves the corner being dragged by whole pixels (down positive) while the pointer stays where it is, so a selection
    /// can be set to the pixel. The corner stays that far from the pointer for the rest of the drag. Shift and Option
    /// keep their say: the shape still holds, and a selection from the center still grows both ways. While Space moves the
    /// selection, no corner is being set.
    private func nudgeDraggedCorner(by pixels: CGVector, in drag: Drag) {
        guard !drag.spaceHeld else { return }
        let last = drag.point
        let scale = selection.pixelsPerPoint
        selection.nudge(by: CGVector(dx: pixels.dx / scale, dy: -pixels.dy / scale), modifiers: selectionModifiers(drag.modifiers))
        showSelection()
        showCorner(pointer: last)
        // VoiceOver hears the size the corner made.
        let layout = currentLayout
        if let rect = selection.rect, let display = layout.display(at: CGPoint(x: rect.midX, y: rect.minY)) ?? layout.display(at: last) {
            entries[display.id]?.view.announceValue()
        }
    }

    func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool) {
        onCopyMeasurement?(text, pointer ?? NSEvent.mouseLocation, ending)
        if ending { end(.cancelled) }
    }

    func overlayView(_ view: OverlayView, didChangeColorFormat format: ColorFormat) {
        guard isActive, purpose == .color else { return }
        colorFormat = format
        for entry in entries.values {
            entry.view.setColorFormat(format)
        }
        onColorFormatChange?(format)
    }

    func overlayView(_ view: OverlayView, didChangeSelfTimerDelay seconds: Int) {
        guard isActive, currentSelfTimerDelay != nil else { return }
        let clamped = max(seconds, 1)
        currentSelfTimerDelay = clamped
        options.selfTimerDelay = clamped
        for entry in entries.values {
            entry.view.setSelfTimerDelay(clamped)
        }
        onSelfTimerDelayChange?(clamped)
    }

    func overlayView(_ view: OverlayView, didChangeSelectedWindows targets: [WindowTarget]) {
        selectedWindows = targets
        for entry in entries.values where entry.view !== view {
            entry.view.setSelectedWindows(targets)
        }
    }

    func overlayView(_ view: OverlayView, didCaptureMeasurement measurement: RulerMeasurement, of frame: CapturedFrame) {
        // The overlay goes first, so the screen comes back at once; the capture is kept after. Ending the session lets
        // its handlers go, so this one is held first.
        let capture = onCaptureMeasurement
        end(.cancelled)
        capture?(frame, measurement)
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
        guard isActive, hasInput, purpose.opensSizeControl(allInOne: isAllInOne), !isAnnotating else { return }
        let at = pointer ?? NSEvent.mouseLocation
        let display: DisplayInfo
        var dragged: CGRect?
        if drag != nil, let began = dragDisplay, let rect = selection.rect.flatMap({ AreaFrame.fitted($0, in: began.frame) }) {
            // The drag in hand becomes the frame, on the display it began on.
            display = began
            dragged = rect
        } else {
            // Nothing dragged yet (or too little): a start around the crosshair, for the size to be typed.
            display = currentLayout.display(at: at) ?? view.display
        }
        let start = Self.sizingStart(dragged: dragged, on: display, around: at, shapeLocked: drag?.modifiers.contains(.shift) ?? false, kept: keptShape)
        // The press that began the drag may still be down: its moves and its end are no longer the selection's.
        drag = nil
        selection.reset()
        showSelection()
        Log.capture.notice("Area framed to size: \(NSStringFromRect(start.area), privacy: .public) on display \(display.id, privacy: .public)")
        startAllInOneSetup(on: display, area: start.area, sizing: true, ratio: start.ratio)
    }

    func overlayViewDidRequestLastArea(_ view: OverlayView) {
        guard isActive, hasInput, drag == nil, purpose.recallsLastArea, !isAnnotating,
              let rect = lastArea, let display = startDisplay(of: rect) else {
            NSSound.beep()
            return
        }
        switch purpose {
        case .screenshot, .annotate:
            if !startAllInOneSetup(on: display, area: rect, sizing: !isAllInOne, ratio: nil) {
                NSSound.beep()
            }
        case .record:
            guard let fitted = AreaFrame.fitted(rect, in: display.frame) else {
                NSSound.beep()
                return
            }
            startRecordingSetup(on: display, target: fitted == display.frame ? .display : .area(fitted))
        case .scroll:
            if !startScrollingSetup(on: display, area: rect) {
                NSSound.beep()
            }
        case .text, .color, .measure:
            NSSound.beep()
        }
    }

    func overlayViewDidResetDrag(_ view: OverlayView) {
        guard drag != nil else { return }
        drag = nil
        pressedWindow = nil
        selection.reset()
        showSelection()
        if let pointer {
            updateCursorVisibility(at: pointer)
            updateHover(at: pointer)
        }
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
        if drag != nil {
            drag?.spaceHeld = true
        } else if !isRepeat {
            overlayView(view, didSwitchTo: view.mode == .area ? .window : .area)
        }
    }

    func overlayViewDidReleaseSpace(_ view: OverlayView) {
        drag?.spaceHeld = false
    }

    func overlayViewDidRequestDisplayCapture(_ view: OverlayView) {
        framed = nil
        allInOneSelectedWindows = []
        allInOneCaptureWindows = []
        for entry in entries.values { entry.view.setSelectedWindows([]) }
        if isAllInOne, allInOneMode == nil {
            endAllInOne(.screenshot(nil), view.display.frame, on: view.display)
        } else {
            overlayView(view, didSelect: view.display.frame, modifiers: [])
        }
    }

    func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags) {
        // All-In-One's Screen (or F) takes the whole display at once; a mode chosen before takes it too.
        if isAllInOne, allInOneMode == nil {
            return endAllInOne(.screenshot(nil), rect, on: view.display)
        }
        select(rect, startingOn: view.display, modifiers: modifiers)
    }

    func overlayView(_ view: OverlayView, didSelectElement rect: CGRect, modifiers: NSEvent.ModifierFlags) {
        let targetDisplay = !rect.intersection(view.display.frame).isEmpty ? view.display : (startDisplay(of: rect) ?? view.display)
        select(rect, startingOn: targetDisplay, modifiers: modifiers)
    }

    func overlayView(_ view: OverlayView, didChooseMode choice: AllInOneChoice) {
        guard isAllInOne, drag == nil else { return }
        // Choosing the purpose in hand again, or a plain capture (Area, A), lets it go.
        let next: AllInOneChoice? = if case .screenshot = choice { nil } else if choice == allInOneMode { nil } else { choice }
        guard next != allInOneMode else { return }
        allInOneSelectedWindows = []
        allInOneCaptureWindows = []
        for entry in entries.values { entry.view.setSelectedWindows([]) }
        allInOneMode = next
        let mark = next.flatMap(AllInOneBar.Choice.init(purpose:))
        for entry in entries.values { entry.view.markPurpose(mark) }
        let announcement = switch next {
        case .text?: String(localized: "Text. Drag over text to copy it.", bundle: .module)
        case .scroll?: String(localized: "Scrolling capture. Drag over the part that scrolls.", bundle: .module)
        case .record?: String(localized: "Record. Drag over an area to record it.", bundle: .module)
        case .screenshot?, nil: String(localized: "Capture. Click a window or drag over an area, then choose what to do with it.", bundle: .module)
        }
        VoiceOver.announce(announcement, from: view)
    }

    func overlayViewDidRequestMeasure(_ view: OverlayView) {
        guard isAllInOne, drag == nil else { return }
        turnToMeasure()
    }

    /// All-In-One's Measure: the session measures from here on, in place, so no second session takes the keyboard back
    /// and the screen stays as it was frozen (a live one holds still as the magnifier showed it, since the ruler reads
    /// that frame). Whatever the next area was for is let go, with the bar, the highlighted window, and any text found
    /// to snap to; Escape, Return, and C end the session as they end Measure's.
    private func turnToMeasure() {
        onWillMeasure?()
        purpose = .measure
        options.allInOne = nil
        allInOneMode = nil
        selection = SelectionModel(bounds: .zero, pixelsPerPoint: 1)
        dragDisplay = nil
        hoverWindows = []
        hovered = nil
        pressedWindow = nil
        allInOneSelectedWindows = []
        allInOneCaptureWindows = []
        selectedWindows = []
        framed = nil
        cancelTextDetections()
        snapsToText = false
        let point = pointer ?? NSEvent.mouseLocation
        for entry in entries.values {
            entry.view.turnToMeasure(
                pointer: point, colorFormat: colorFormat, unit: measureUnit, tolerance: measureTolerance, snapsToContent: measureSnapsToContent
            )
        }
        giveKeyboard(to: currentLayout.display(at: point))
        updateCursorVisibility(at: point)
        Log.capture.notice("All-In-One turned to Measure")
        if let display = currentLayout.display(at: point), let view = entries[display.id]?.view {
            VoiceOver.announce(announcement, from: view)
        }
    }

    func overlayViewDidRequestWindowPicker(_ view: OverlayView) {
        guard isActive, windowPicker == nil, drag == nil, !isAnnotating,
              purpose == .screenshot || purpose == .record else { return }
        if let mode = allInOneMode, mode != .record {
            overlayView(view, didSwitchTo: .window)
            return
        }
        showWindowPicker(on: view.display, returningTo: view.mode == .area ? .area : .window)
    }

    private func showWindowPicker(on display: DisplayInfo, returningTo mode: Mode? = nil) {
        let records = purpose == .record || allInOneMode == .record
        if records {
            if isAllInOne { onWillSetUpRecording?() }
            didSetUpRecording = true
        }
        let layout = currentLayout
        let picker = WindowPickerController(
            layout: layout, recording: records ? recordingChoices : nil,
            preferredProcessID: previousApp?.processIdentifier, offersBack: mode != nil,
            load: { [capturer] in try await capturer.availableWindows(in: layout) },
            preview: { [capturer] target in try await capturer.windowPreview(target) }
        )
        picker.onCancel = { [weak self] in self?.cancel() }
        if let completion {
            let purpose = purpose, options = options, chosenMode = allInOneMode
            picker.onSelectOnScreen = { [weak self] in
                guard let self else { return }
                self.completion = nil
                end(.cancelled)
                begin(mode: .window, purpose: purpose, options: options, completion: completion)
                allInOneMode = chosenMode
                for entry in entries.values { entry.view.markPurpose(chosenMode.flatMap(AllInOneBar.Choice.init(purpose:))) }
            }
        }
        if let mode, let completion {
            let purpose = purpose, options = options, chosenMode = allInOneMode
            picker.onBack = { [weak self] in
                guard let self else { return }
                self.completion = nil
                end(.cancelled)
                begin(mode: mode, purpose: purpose, options: options, completion: completion)
                allInOneMode = chosenMode
                for entry in entries.values { entry.view.markPurpose(chosenMode.flatMap(AllInOneBar.Choice.init(purpose:))) }
            }
        }
        picker.onRecordingChange = { [weak self] target, choices in
            guard let self, let display = target.display(in: currentLayout) else { return }
            recordingChoices = choices
            onRecordingSetupChange?(.window(target), display, choices)
        }
        picker.onChoose = { [weak self] target, choices, modifiers in
            guard let self, isActive else { return }
            if let choices, let display = target.display(in: currentLayout) {
                end(.record(.window(target), display: display, choices: choices))
            } else if choices == nil {
                end(.window(target, modifiers: modifiers))
            } else {
                end(.cancelled)
            }
        }
        windowPicker = picker
        // Choosing an off-Space window needs no screen-sized overlay and no frame over the wrong app.
        cursorVisibility.end()
        if presentsPanels { NSCursor.arrow.set() }
        for entry in entries.values {
            entry.panel.orderOut(nil)
            entry.view.clear()
        }
        frameLeases.removeAll()
        cancelTextDetections()
        if presentsPanels { picker.show(on: display) }
    }

    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) {
        let targetDisplay = target.display(in: currentLayout) ?? view.display
        if isAllInOne, let mode = allInOneMode {
            switch mode {
            case .record: setUpRecording(on: targetDisplay, target: .window(target))
            case .scroll, .text, .screenshot: endAllInOne(mode, target.frame.intersection(view.display.frame), on: view.display)
            }
            return
        }
        switch purpose {
        case .record:
            startRecordingSetup(on: targetDisplay, target: .window(target))
        case .scroll:
            // A window's frame where it is on screen: its title bar and toolbar stay put, as a header does.
            startScrollingSetup(on: view.display, area: target.frame)
        case .annotate:
            // A window is annotated where it is on the frozen screen.
            let area = target.frame.intersection(view.display.frame)
            if !area.isNull, area.width >= 1, area.height >= 1 { startAnnotating(on: view.display.id, area: area) }
        case .screenshot, .text, .color, .measure:
            end(.window(target, modifiers: modifiers))
        }
    }

    func overlayView(_ view: OverlayView, didSelectWindows targets: [WindowTarget], modifiers: NSEvent.ModifierFlags) {
        guard let first = targets.first else { return }
        let unionFrame = targets.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        if isAllInOne, allInOneMode == nil, purpose == .screenshot {
            guard let setupDisplay = Self.displayForSetup(targets: targets, in: currentLayout) else { return }
            allInOneCaptureWindows = targets
            guard startAllInOneSetup(
                on: setupDisplay, area: unionFrame.intersection(setupDisplay.frame), windowFrames: targets.map(\.frame)
            ) else {
                allInOneCaptureWindows = []
                return
            }
            return
        }
        if targets.count == 1 {
            overlayView(view, didSelectWindow: first, modifiers: modifiers)
            return
        }
        if isAllInOne, let mode = allInOneMode {
            switch mode {
            case .record:
                let targetDisplay = AreaFrame.fitted(unionFrame, in: view.display.frame) != nil
                    ? view.display
                    : (startDisplay(of: unionFrame) ?? view.display)
                if let fitted = AreaFrame.fitted(unionFrame, in: targetDisplay.frame) {
                    setUpRecording(on: targetDisplay, target: fitted == targetDisplay.frame ? .display : .area(fitted))
                } else {
                    setUpRecording(on: targetDisplay, target: .display)
                }
            case .scroll, .text, .screenshot:
                let area = unionFrame.intersection(view.display.frame)
                if !area.isNull, area.width >= 1, area.height >= 1 {
                    endAllInOne(mode, area, on: view.display)
                }
            }
            return
        }
        if purpose == .annotate {
            let area = unionFrame.intersection(view.display.frame)
            if !area.isNull, area.width >= 1, area.height >= 1 { startAnnotating(on: view.display.id, area: area) }
            return
        }
        end(.windows(targets, modifiers: modifiers))
    }

    func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode) {
        // Once an area is chosen for annotation, even while its frame is still on the way, it stays chosen.
        guard pendingAnnotation == nil, !isAnnotating else { return }
        selection.reset()
        selectedWindows = []
        drag = nil
        allInOneSelectedWindows = []
        showHover()
        if mode == .window, windows.isEmpty {
            windows = WindowCatalog.snapshot(layout: currentLayout, excludingPID: windowsExcluded)
        }
        for entry in entries.values {
            entry.view.switchMode(to: mode, windows: windows)
        }
        updateHover(at: pointer ?? NSEvent.mouseLocation)
    }

    func overlayViewDidToggleKeys(_ view: OverlayView) {
        guard !overlayViewDidPutKeysAway(view) else { return }
        let mouse = NSEvent.mouseLocation
        let target = entries.values.first { $0.view.display.frame.contains(mouse) }?.view ?? view
        target.showKeys(view.keyHelp)
    }

    func overlayViewDidPutKeysAway(_ view: OverlayView) -> Bool {
        entries.values.map { $0.view.putKeysAway() }.contains(true)
    }

    func overlayViewDidCancel(_ view: OverlayView) {
        Log.capture.notice("Overlay cancelled with Escape\(self.drag == nil ? "" : " during a drag", privacy: .public)")
        end(.cancelled)
    }

}
