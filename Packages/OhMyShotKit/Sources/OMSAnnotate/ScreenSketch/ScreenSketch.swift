import AppKit
import OMSCore
import OMSDesign
import QuartzCore

/// Draw on Screen: marks drawn over the live screen, not a frozen picture of it, for showing something while sharing
/// the screen, presenting, or recording. A fading laser pointer, the pen, arrows, boxes, ovals, and counters; Undo,
/// Redo, and Clear; and Click Through, which hands the pointer and keyboard to the apps underneath while the marks stay.
///
/// Each display has a clear canvas panel of its own, floating over apps but under the recording bar, and a small
/// toolbar stands at the top of the display the pointer was on. Displays added, taken away, or rearranged while drawing
/// get, lose, or move their canvases. Nothing runs while nothing is drawn: the laser's frames are drawn only while a
/// trail is fading, and only where it is. The canvases are taken into captures and recordings as pins are
/// (`canvasWindowIDs`); the toolbar never is.
@MainActor
public final class ScreenSketchController {
    public enum Tool: String, CaseIterable, Sendable {
        case laser, pen, arrow, rectangle, ellipse, counter

        /// The editor's tool that draws the same mark, whose symbol and name the toolbar shows; the laser draws none.
        var mark: AnnotationTool? {
            switch self {
            case .laser: nil
            case .pen: .pen
            case .arrow: .arrow
            case .rectangle: .rectangle
            case .ellipse: .ellipse
            case .counter: .counter
            }
        }

        var symbol: String { mark?.symbol ?? "cursorarrow.rays" }
        var name: String { mark?.name ?? String(localized: "Laser Pointer", bundle: .module) }
    }

    /// Whether the canvases are up.
    public private(set) var isActive = false
    /// Called when the canvases come up or go, for the menu's title.
    public var onChange: (() -> Void)?
    /// Called once the canvases are on screen, and again when a display added later gets one: a recording under way
    /// takes them in.
    public var onCanvasesShown: (() -> Void)?

    public private(set) var tool: Tool = .laser
    public private(set) var color: RGBA = .red
    /// Whether the pointer and keyboard go to the apps underneath, the marks staying on screen.
    public private(set) var clicksThrough = false
    public static let colors: [RGBA] = [.red, .yellow, .green, .blue, .white]
    static let lineWidth: CGFloat = 4

    /// Every display's marks, by display, at one moment.
    private typealias Snapshot = [CGDirectDisplayID: [Annotation]]

    private var boards: [SketchBoard] = []
    private var toolbar: SketchToolbar?
    /// The marks before each change, newest last, for Undo; and the marks each Undo took back, for Redo.
    private var history: [Snapshot] = []
    private var future: [Snapshot] = []
    private var screensObserver: (any NSObjectProtocol)?
    private let defaults: UserDefaults
    private static let toolKey = "sketch.tool"
    private static let colorKey = "sketch.color"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tool = defaults.string(forKey: Self.toolKey).flatMap(Tool.init(rawValue:)) ?? .laser
        let colorIndex = defaults.integer(forKey: Self.colorKey)
        color = Self.colors.indices.contains(colorIndex) ? Self.colors[colorIndex] : .red
    }

    /// The canvases' windows, which captures and recordings take in.
    public var canvasWindowIDs: Set<CGWindowID> {
        Set(boards.compactMap { $0.panel.windowNumber > 0 ? CGWindowID($0.panel.windowNumber) : nil })
    }

    public func toggle() {
        isActive ? stop() : start()
    }

    /// Puts a canvas over every display and the toolbar on the one with the pointer.
    public func start() {
        guard !isActive else { return }
        isActive = true
        clicksThrough = false
        history = []
        future = []
        boards = NSScreen.screens.map { SketchBoard(screen: $0, controller: self) }
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first {
            let toolbar = SketchToolbar(controller: self)
            toolbar.show(on: screen)
            self.toolbar = toolbar
        }
        board(at: pointer)?.takeKeyboard()
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        VoiceOver.announce(String(localized: "Draw on Screen. Press Escape to stop.", bundle: .module))
        onChange?()
        onCanvasesShown?()
    }

    /// Takes the canvases, their marks, and the toolbar away.
    public func stop() {
        guard isActive else { return }
        isActive = false
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
        HoverTag.shared.dismiss()
        for board in boards { board.close() }
        boards = []
        toolbar?.orderOut(nil)
        toolbar?.close()
        toolbar = nil
        history = []
        future = []
        onChange?()
    }

    /// A display added, taken away, or rearranged while drawing: each display that stays keeps its canvas and marks,
    /// one added gets a canvas, and the toolbar comes back onto a display if its own went.
    private func screensChanged() {
        guard isActive else { return }
        let screens = NSScreen.screens
        let kept = screens.map { screen in
            guard let board = boards.first(where: { $0.display == screen.displayID }) else {
                return SketchBoard(screen: screen, controller: self)
            }
            board.fit(to: screen)
            return board
        }
        for board in boards where !kept.contains(where: { $0 === board }) { board.close() }
        let added = kept.contains { board in !boards.contains { $0 === board } }
        boards = kept
        if let toolbar, !screens.contains(where: { $0.frame.intersects(toolbar.capsuleFrame) }), let screen = NSScreen.main ?? screens.first {
            toolbar.place(on: screen)
        }
        toolbar?.refresh()
        if added { onCanvasesShown?() }
    }

    // MARK: Choices

    func choose(_ tool: Tool) {
        self.tool = tool
        defaults.set(tool.rawValue, forKey: Self.toolKey)
        if clicksThrough { setClicksThrough(false) }
        toolbar?.refresh()
        // Chosen by its key with the pointer on a canvas, the pointer takes the new tool's look at once.
        let pointer = NSEvent.mouseLocation
        if board(at: pointer) != nil, toolbar?.capsuleFrame.contains(pointer) != true { SketchView.cursor(for: tool).set() }
    }

    func choose(_ color: RGBA) {
        self.color = color
        if let index = Self.colors.firstIndex(of: color) { defaults.set(index, forKey: Self.colorKey) }
        toolbar?.refresh()
    }

    func setClicksThrough(_ on: Bool) {
        clicksThrough = on
        for board in boards { board.panel.ignoresMouseEvents = on }
        // Drawing again, the canvas under the pointer takes the keys back; clicking through, the app clicked takes them.
        if !on { board(at: NSEvent.mouseLocation)?.takeKeyboard() }
        toolbar?.refresh()
        VoiceOver.announce(on ? String(localized: "Clicks go through to the apps", bundle: .module) : String(localized: "Drawing", bundle: .module))
    }

    // MARK: Marks

    private var snapshot: Snapshot {
        Dictionary(boards.map { ($0.display, $0.view.marks) }, uniquingKeysWith: { first, _ in first })
    }

    private func restore(_ snapshot: Snapshot) {
        for board in boards { board.view.marks = snapshot[board.display] ?? [] }
    }

    /// Notes every board's marks before a change, for Undo; a new change leaves nothing to redo.
    func willChange() {
        history.append(snapshot)
        if history.count > 200 { history.removeFirst() }
        future = []
    }

    /// A board's marks changed: Undo, Redo, and Clear say whether they can act now.
    func marksDidChange() {
        toolbar?.refresh()
    }

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var hasMarks: Bool { boards.contains { !$0.view.marks.isEmpty } }

    func undo() {
        guard let last = history.popLast() else { return NSSound.beep() }
        future.append(snapshot)
        restore(last)
    }

    func redo() {
        guard let next = future.popLast() else { return NSSound.beep() }
        history.append(snapshot)
        restore(next)
    }

    func clear() {
        guard hasMarks else { return }
        willChange()
        for board in boards { board.view.marks = [] }
    }

    /// The next counter's number, counted across every display.
    func nextCounterValue() -> Int {
        let values = boards.flatMap(\.view.marks).compactMap { item -> Int? in
            if case .counter(let counter) = item.shape { return counter.value }
            return nil
        }
        return (values.max() ?? 0) + 1
    }

    private func board(at point: CGPoint) -> SketchBoard? {
        boards.first { NSMouseInRect(point, $0.panel.frame, false) }
    }

    /// The keys a canvas answers while it has the keyboard: Escape stops, ⌘Z undoes, ⇧⌘Z redoes, Delete clears, 1 to 6
    /// choose a tool (on the keypad too), T clicks through.
    func handle(_ event: NSEvent) -> Bool {
        // Forward Delete and the keypad's digits carry these flags of their own; they are not modifiers held down.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (event.keyCode, flags) {
        case (53, []):
            stop()
        case (51, []), (117, []):
            clear()
        case (_, .command) where key == "z":
            undo()
        case (_, [.command, .shift]) where key == "z":
            redo()
        case (_, []) where key == "t":
            setClicksThrough(!clicksThrough)
        case (_, []) where key.flatMap(Int.init).map { (1...Tool.allCases.count).contains($0) } == true:
            choose(Tool.allCases[Int(key!)! - 1])
        default:
            return false
        }
        return true
    }

    #if DEBUG
    /// Every board's marks, for tests.
    var debugMarks: [[Annotation]] { boards.map(\.view.marks) }
    func debugDraw(on board: Int, from start: CGPoint, to end: CGPoint) { boards[board].view.debugDraw(from: start, to: end) }

    /// The toolbar alone in a window behind the desktop picture, for scripted renders that show nothing: `tool` in hand,
    /// or none while clicking through, the ink at `colorIndex` chosen, and Undo lit when `canUndo`.
    public static func debugToolbarWindow(dark: Bool, tool: Tool, colorIndex: Int, clicksThrough: Bool, canUndo: Bool) -> NSWindow {
        let controller = ScreenSketchController(defaults: UserDefaults(suiteName: "ohmyshot.sketch-render") ?? .standard)
        controller.tool = tool
        controller.color = colors[min(max(colorIndex, 0), colors.count - 1)]
        controller.clicksThrough = clicksThrough
        if canUndo { controller.history = [[:]] }
        let bar = SketchToolbarView(controller: controller)
        let room = SketchToolbarView.shadowRoom
        let size = bar.fittingSize
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size.width + room * 2, height: size.height + room * 2),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
        }
        bar.frame = CGRect(origin: .zero, size: window.frame.size)
        window.contentView = bar
        // Kept for as long as the app runs: the bar holds its controller weakly.
        debugControllers.append(controller)
        window.orderFront(nil)
        return window
    }

    private static var debugControllers: [ScreenSketchController] = []
    #endif
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// One display's canvas: a clear panel over it and the view the marks are drawn in.
@MainActor
final class SketchBoard {
    let display: CGDirectDisplayID
    let panel: SketchPanel
    let view: SketchView

    init(screen: NSScreen, controller: ScreenSketchController) {
        display = screen.displayID
        panel = SketchPanel(frame: screen.frame)
        view = SketchView(frame: CGRect(origin: .zero, size: screen.frame.size), controller: controller)
        panel.contentView = view
        panel.initialFirstResponder = view
        panel.orderFrontRegardless()
    }

    /// Over its display again, after the display moved or changed size.
    func fit(to screen: NSScreen) {
        guard panel.frame != screen.frame else { return }
        panel.setFrame(screen.frame, display: true)
    }

    /// Takes the keyboard without bringing the app forward, the canvas itself answering the keys: a panel made key
    /// keeps the window as its first responder until something in it is clicked.
    func takeKeyboard() {
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    func close() {
        view.stopFrames()
        panel.orderOut(nil)
        panel.close()
    }
}

/// A clear, borderless panel over a whole display, on every Space and over full-screen apps, that takes the keyboard
/// without bringing the app forward.
final class SketchPanel: NSPanel {
    /// Over apps and the menu bar, under the recording bar and its camera, which stay usable.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        setAccessibilityLabel(String(localized: "Drawing Canvas", bundle: .module))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws a display's marks, the mark being drawn, and the laser's trails, in points from the display's top-left
/// corner. What changes as the pointer moves is redrawn where it was and where it is, not over the whole display.
@MainActor
final class SketchView: NSView {
    var marks: [Annotation] = [] {
        didSet {
            needsDisplay = true
            controller?.marksDidChange()
        }
    }

    private weak var controller: ScreenSketchController?
    private var drawing: Annotation? {
        didSet {
            invalidate(oldValue)
            invalidate(drawing)
        }
    }
    private var start: CGPoint?
    private var penPoints: [CGPoint] = []
    private var trails: [(trail: LaserTrail, color: RGBA)] = []
    /// The trails' outlines as the last frame found them, and the room they take with their glow: the next frame
    /// redraws only there and where they have gone.
    private var laser: [(outline: CGPath, color: RGBA)] = []
    private var laserRoom = CGRect.null
    private var frames: CADisplayLink?
    /// The width of the soft glow around a laser trail's core.
    private static let glow: CGFloat = 4

    init(frame: CGRect, controller: ScreenSketchController) {
        self.controller = controller
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Drawing Canvas", bundle: .module))
        setAccessibilityHelp(String(localized: "Draw with the pointer. Press 1 to 6 to choose a tool, T to click through, Delete to clear, Command-Z to undo, or Escape to stop.", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for mark in marks + [drawing].compactMap(\.self) {
            AnnotationRenderer.draw(mark, in: context, scale: 1, flippedBacking: true)
        }
        for (outline, color) in laser {
            // A soft glow under a bright core, as a laser pointer's dot looks.
            context.setFillColor(color.cgColor.copy(alpha: 0.35) ?? color.cgColor)
            context.addPath(outline.copy(strokingWithWidth: Self.glow, lineCap: .round, lineJoin: .round, miterLimit: 4))
            context.fillPath()
            context.setFillColor(color.cgColor)
            context.addPath(outline)
            context.fillPath()
        }
    }

    /// Asks for the room a mark takes, its shadow included, to be drawn again.
    private func invalidate(_ mark: Annotation?) {
        guard let room = mark?.drawingBounds(scale: 1), !room.isNull else { return }
        setNeedsDisplay(room.insetBy(dx: -2, dy: -2))
    }

    // MARK: Pointer

    /// The arrow for the laser, which points at things; a crosshair for every tool that draws a mark.
    static func cursor(for tool: ScreenSketchController.Tool) -> NSCursor {
        tool == .laser ? .arrow : .crosshair
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Always: the canvas takes the keyboard without the app coming forward, so the app is seldom active.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let controller else { return super.cursorUpdate(with: event) }
        Self.cursor(for: controller.tool).set()
    }

    // MARK: Drawing

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        window?.makeKey()
        Self.cursor(for: controller.tool).set()
        let point = convert(event.locationInWindow, from: nil)
        let style = Style(color: controller.color, lineWidth: ScreenSketchController.lineWidth, shadow: true)
        switch controller.tool {
        case .laser:
            var trail = LaserTrail(width: ScreenSketchController.lineWidth * 2.5)
            trail.add(point, at: CACurrentMediaTime())
            trails.append((trail, controller.color))
            startFrames()
        case .pen:
            penPoints = [point]
            drawing = Annotation(shape: .pen(Stroke(points: penPoints)), style: style)
        case .arrow, .rectangle, .ellipse:
            start = point
        case .counter:
            controller.willChange()
            marks.append(Annotation(shape: .counter(Counter(center: point, value: controller.nextCounterValue())), style: style))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        let constrained = event.modifierFlags.contains(.shift)
        switch controller.tool {
        case .laser:
            guard !trails.isEmpty else { return }
            trails[trails.count - 1].trail.add(point, at: CACurrentMediaTime())
        case .pen:
            guard !penPoints.isEmpty else { return }
            penPoints.append(point)
            drawing = Annotation(shape: .pen(Stroke(points: penPoints)), style: Style(color: controller.color, lineWidth: ScreenSketchController.lineWidth, shadow: true))
        case .arrow, .rectangle, .ellipse:
            guard let start else { return }
            drawing = Self.shape(controller.tool, from: start, to: point, constrained: constrained, color: controller.color)
        case .counter:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        defer {
            drawing = nil
            start = nil
            penPoints = []
        }
        // A laser's trail fades by itself; anything else drawn is kept, unless it was only a click.
        guard controller.tool != .laser, controller.tool != .counter, let drawing else { return }
        if case .pen = drawing.shape, penPoints.count < 2 { return }
        controller.willChange()
        marks.append(drawing)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handle(event) != true { super.keyDown(with: event) }
    }

    static func shape(_ tool: ScreenSketchController.Tool, from start: CGPoint, to end: CGPoint, constrained: Bool, color: RGBA) -> Annotation? {
        let annotationTool: AnnotationTool = switch tool {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .laser, .pen, .counter: .select
        }
        guard hypot(end.x - start.x, end.y - start.y) >= 3 else { return nil }
        let settings = ToolSettings(color: color, lineWidth: ScreenSketchController.lineWidth, shadow: true, cornerRadius: 6)
        return annotationTool.mark(from: start, to: end, constrained: constrained, settings: settings)
    }

    // MARK: Frames

    /// The laser's frames, drawn only while a trail is fading.
    private func startFrames() {
        guard frames == nil else { return }
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        frames = link
    }

    func stopFrames() {
        frames?.invalidate()
        frames = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // A trail still being drawn stays, however still the pointer; one let go goes once it has faded.
        let drawingTrail = NSEvent.pressedMouseButtons & 1 == 1 && controller?.tool == .laser ? trails.indices.last : nil
        trails = trails.enumerated().filter { index, item in index == drawingTrail || !item.trail.isDone(at: now) }.map(\.element)
        laser = trails.compactMap { item in item.trail.outline(at: now).map { (outline: $0, color: item.color) } }
        let room = laser.reduce(CGRect.null) { $0.union($1.outline.boundingBoxOfPath) }
        let padded = room.isNull ? room : room.insetBy(dx: -(Self.glow / 2 + 2), dy: -(Self.glow / 2 + 2))
        let dirty = laserRoom.union(padded)
        if !dirty.isNull { setNeedsDisplay(dirty) }
        laserRoom = padded
        if trails.isEmpty { stopFrames() }
    }

    #if DEBUG
    func debugDraw(from start: CGPoint, to end: CGPoint) {
        guard let controller, let mark = Self.shape(controller.tool, from: start, to: end, constrained: false, color: controller.color) else { return }
        controller.willChange()
        marks.append(mark)
    }
    #endif
}

/// The toolbar's panel: borderless and clear, over the canvases, on every Space and over full-screen apps, and never
/// key, so the canvas under the pointer keeps the keyboard. It can be dragged aside by its background.
@MainActor
final class SketchToolbar: NSPanel {
    private let bar: SketchToolbarView

    init(controller: ScreenSketchController) {
        bar = SketchToolbarView(controller: controller)
        let size = bar.fittingSize
        let room = SketchToolbarView.shadowRoom
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: size.width + room * 2, height: size.height + room * 2),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The capsule casts its own shadow, in the room around it: a window's shadow would be drawn around the room.
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .none
        bar.frame = CGRect(origin: .zero, size: frame.size)
        contentView = bar
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The capsule on screen, without the room around it for its shadow.
    var capsuleFrame: CGRect {
        frame.insetBy(dx: SketchToolbarView.shadowRoom, dy: SketchToolbarView.shadowRoom)
    }

    /// At the top of `screen`, centered, the capsule 12 pt under the menu bar.
    func place(on screen: NSScreen) {
        let area = screen.visibleFrame
        let room = SketchToolbarView.shadowRoom
        setFrameOrigin(CGPoint(x: (area.midX - frame.width / 2).rounded(), y: (area.maxY - 12 + room - frame.height).rounded()))
    }

    /// Placed on `screen` and faded in; at once under Reduce Motion.
    func show(on screen: NSScreen) {
        place(on: screen)
        let fades = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = fades ? 0 : 1
        orderFrontRegardless()
        guard fades else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func refresh() {
        bar.refresh()
    }
}

/// The toolbar's capsule, the in-place toolbar's sibling: the tools, the inks, Undo, Redo, and Clear, then Click
/// Through and Done, in 30 pt round chips 6 pt inside a 42 pt capsule, groups parted by hairlines. Glass over an
/// opaque window-colored backing, a solid capsule with Reduce Transparency. The tool in hand is marked as the editor
/// marks it, its symbol in the accent on the selected fill, and Click Through the same while it is on; the chosen ink is
/// ringed in the label ink, as the style capsule rings it. Every chip names itself and its key in a hover tag.
@MainActor
final class SketchToolbarView: NSView {
    enum Action {
        case undo, redo, clear, clickThrough, done
    }

    /// Room around the capsule for its shadow.
    static let shadowRoom: CGFloat = 24
    private static let height: CGFloat = 42
    private static let inset: CGFloat = 6
    private static let chip: CGFloat = 30
    private static let inkChip: CGFloat = 24

    private weak var controller: ScreenSketchController?
    private var container = NSView()
    private let backing = NSView()
    /// The capsule's hairline, drawn inside the backing as the recording bar's is.
    private let rim = CAShapeLayer()
    private let stack = NSStackView()
    private var displayOptions: (any NSObjectProtocol)?
    private var toolChips: [ScreenSketchController.Tool: RailChip] = [:]
    private var inkChips: [RailChip] = []
    private var actionChips: [Action: RailChip] = [:]

    init(controller: ScreenSketchController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        for (index, tool) in ScreenSketchController.Tool.allCases.enumerated() {
            let chip = makeChip(symbol: tool.symbol, name: tool.name, key: "\(index + 1)")
            chip.setButtonType(.onOff)
            toolChips[tool] = chip
            stack.addArrangedSubview(chip)
        }
        addDivider()
        for color in ScreenSketchController.colors {
            let chip = makeInkChip(color)
            inkChips.append(chip)
            stack.addArrangedSubview(chip)
        }
        addDivider()
        add(.undo, symbol: "arrow.uturn.backward", name: String(localized: "Undo", bundle: .module), help: String(localized: "Undo (⌘Z)", bundle: .module))
        add(.redo, symbol: "arrow.uturn.forward", name: String(localized: "Redo", bundle: .module), help: String(localized: "Redo (⇧⌘Z)", bundle: .module))
        let clear = String(localized: "Clear", bundle: .module)
        add(.clear, symbol: "trash", name: clear, help: "\(clear) (⌫)")
        addDivider()
        let through = String(localized: "Click Through", bundle: .module)
        add(.clickThrough, symbol: "cursorarrow.click.2", name: through, help: "\(through) (T)")
        actionChips[.clickThrough]?.setButtonType(.onOff)
        let done = String(localized: "Done", bundle: .module)
        add(.done, symbol: "xmark", name: done, help: "\(done) (Esc)")
        // The stack's own size from the start: laid out at 0 × 0 before its first layout, it could not hold its
        // chips, and AppKit would log a broken constraint for each.
        stack.frame.size = CGSize(width: stack.fittingSize.width, height: Self.height)

        backing.wantsLayer = true
        backing.addSubview(stack)
        rim.fillColor = nil
        backing.layer?.addSublayer(rim)
        installContainer()
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Draw on Screen", bundle: .module))
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
    }

    override var fittingSize: NSSize {
        NSSize(width: stack.fittingSize.width, height: Self.height)
    }

    /// The capsule's own rectangle, centered in the room left for its shadow.
    private var capsuleRect: CGRect {
        let size = fittingSize
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let capsule = capsuleRect
        let radius = capsule.height / 2
        container.frame = capsule
        if let glass = container as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            container.layer?.cornerRadius = radius
        }
        backing.frame = container.bounds
        backing.layer?.cornerRadius = radius
        stack.frame = backing.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = backing.bounds
        let inset = rim.lineWidth / 2
        rim.path = CGPath(roundedRect: backing.bounds.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
        CATransaction.commit()
        layer?.shadowPath = CGPath(roundedRect: capsule, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rim.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Glass, or a solid capsule with Reduce Transparency; swapped when the setting changes while drawing.
    private func installContainer() {
        let wantsSolid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let isSolid = !(container is NSGlassEffectView) && container.superview != nil
        guard container.superview == nil || wantsSolid != isSolid else { return }
        container.removeFromSuperview()
        backing.removeFromSuperview()
        if wantsSolid {
            let solid = NSView()
            solid.wantsLayer = true
            solid.addSubview(backing)
            container = solid
        } else {
            let glass = NSGlassEffectView()
            glass.contentView = backing
            container = glass
        }
        addSubview(container, positioned: .below, relativeTo: nil)
        needsLayout = true
    }

    /// Reduce Transparency and Increase Contrast switched while drawing take effect at once.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        guard window != nil else { return }
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installContainer()
                self?.refresh()
            }
        }
    }

    /// Shows what is chosen and what can act now, resolved for this view's appearance and Increase Contrast.
    func refresh() {
        guard let controller else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let dark = effectiveAppearance.isDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            rim.lineWidth = contrast ? 1 : 0.5
            rim.strokeColor = contrast
                ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35))
                : NSColor.separatorColor.cgColor
        }
        let fills = (on: Theme.ChipFill.selectedColor(dark: dark, contrast: contrast), hover: Theme.ChipFill.hoverColor(dark: dark, contrast: contrast))
        for (tool, chip) in toolChips { paint(chip, fills: fills, on: tool == controller.tool && !controller.clicksThrough) }
        for (index, chip) in inkChips.enumerated() {
            let ink = ScreenSketchController.colors[index]
            let chosen = ink == controller.color
            chip.image = StyleCapsule.dot(ink, selected: chosen)
            chip.setAccessibilityValue(chosen ? String(localized: "Selected", bundle: .module) : nil)
        }
        paint(actionChips[.undo], fills: fills, enabled: controller.canUndo)
        paint(actionChips[.redo], fills: fills, enabled: controller.canRedo)
        paint(actionChips[.clear], fills: fills, enabled: controller.hasMarks)
        paint(actionChips[.clickThrough], fills: fills, on: controller.clicksThrough)
        paint(actionChips[.done], fills: fills)
    }

    /// A chip that is on takes the selected fill under an accent symbol; one that is off, the hover fill under the
    /// pointer; one that cannot act now, the tertiary ink and no fill.
    private func paint(_ chip: RailChip?, fills: (on: CGColor, hover: CGColor), on: Bool = false, enabled: Bool = true) {
        guard let chip else { return }
        chip.isEnabled = enabled
        chip.state = on ? .on : .off
        chip.contentTintColor = !enabled ? .tertiaryLabelColor : on ? .controlAccentColor : .labelColor
        chip.layer?.backgroundColor = on ? fills.on : enabled && chip.isHovered ? fills.hover : .clear
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(6, after: last) }
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(6, after: divider)
    }

    private func add(_ action: Action, symbol: String, name: String, help: String) {
        let chip = makeChip(symbol: symbol, name: name, help: help)
        chip.setButtonType(.momentaryChange)
        actionChips[action] = chip
        stack.addArrangedSubview(chip)
    }

    private func makeChip(symbol: String, name: String, key: String) -> RailChip {
        makeChip(symbol: symbol, name: name, help: "\(name) (\(key))")
    }

    private func makeChip(symbol: String, name: String, help: String) -> RailChip {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        let chip = RailChip(image: image ?? NSImage(), target: self, action: #selector(clicked(_:)))
        configure(chip, side: Self.chip, name: name, help: help)
        return chip
    }

    /// An ink's chip: its dot, 16 pt in a 24 pt chip, with no fill of its own.
    private func makeInkChip(_ color: RGBA) -> RailChip {
        let chip = RailChip(image: StyleCapsule.dot(color, selected: false), target: self, action: #selector(clicked(_:)))
        let name = StyleCapsule.colorName(color)
        configure(chip, side: Self.inkChip, name: name, help: name)
        return chip
    }

    private func configure(_ chip: RailChip, side: CGFloat, name: String, help: String) {
        chip.answersInInactiveWindow = true
        chip.onHover = { [weak self] _ in self?.refresh() }
        chip.isBordered = false
        chip.imagePosition = .imageOnly
        chip.contentTintColor = .labelColor
        chip.wantsLayer = true
        chip.layer?.cornerRadius = side / 2
        chip.toolTip = help
        chip.setAccessibilityLabel(name)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: side).isActive = true
        chip.heightAnchor.constraint(equalToConstant: side).isActive = true
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let controller else { return }
        if let tool = toolChips.first(where: { $0.value === sender })?.key {
            controller.choose(tool)
        } else if let index = inkChips.firstIndex(where: { $0 === sender }) {
            controller.choose(ScreenSketchController.colors[index])
        } else if let action = actionChips.first(where: { $0.value === sender })?.key {
            switch action {
            case .undo: controller.undo()
            case .redo: controller.redo()
            case .clear: controller.clear()
            case .clickThrough: controller.setClicksThrough(!controller.clicksThrough)
            case .done: controller.stop()
            }
        }
        // A chip that is on or off toggles itself as it is clicked; the controller decides what shows.
        refresh()
    }

    #if DEBUG
    /// What the chips show, for tests: the tools that are on, and whether Undo, Redo, and Clear can act and Click Through
    /// is on.
    var debugLook: (toolsOn: [ScreenSketchController.Tool], undo: Bool, redo: Bool, clear: Bool, clicksThrough: Bool) {
        (
            ScreenSketchController.Tool.allCases.filter { toolChips[$0]?.state == .on },
            actionChips[.undo]?.isEnabled == true, actionChips[.redo]?.isEnabled == true, actionChips[.clear]?.isEnabled == true,
            actionChips[.clickThrough]?.state == .on
        )
    }
    #endif
}
