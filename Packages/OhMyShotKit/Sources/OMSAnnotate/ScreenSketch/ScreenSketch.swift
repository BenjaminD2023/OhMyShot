import AppKit
import OMSCore
import OMSDesign
import QuartzCore

/// Draw on Screen: marks drawn over the live screen, not a frozen picture of it, for showing something while sharing
/// the screen, presenting, or recording. A fading laser pointer, the pen, arrows, boxes, ovals, and counters; Undo and
/// Clear; and Click Through, which hands the pointer and keyboard to the apps underneath while the marks stay.
///
/// Each display has a clear canvas panel of its own, floating over apps but under the recording bar, and a small
/// toolbar stands at the top of the display the pointer was on. Nothing runs while nothing is drawn: the laser's
/// frames are drawn only while a trail is fading. The canvases are taken into captures and recordings as pins are
/// (`canvasWindowIDs`); the toolbar never is.
@MainActor
public final class ScreenSketchController {
    public enum Tool: String, CaseIterable, Sendable {
        case laser, pen, arrow, rectangle, ellipse, counter
    }

    /// Whether the canvases are up.
    public private(set) var isActive = false
    /// Called when the canvases come up or go, for the menu's title.
    public var onChange: (() -> Void)?
    /// Called once the canvases are on screen: a recording under way takes them in.
    public var onCanvasesShown: (() -> Void)?

    public private(set) var tool: Tool = .laser
    public private(set) var color: RGBA = .red
    /// Whether the pointer and keyboard go to the apps underneath, the marks staying on screen.
    public private(set) var clicksThrough = false
    public static let colors: [RGBA] = [.red, .yellow, .green, .blue, .white]
    static let lineWidth: CGFloat = 4

    private var boards: [SketchBoard] = []
    private var toolbar: SketchToolbar?
    /// Every board's marks before each change, newest last, for Undo.
    private var history: [[[Annotation]]] = []
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
        boards = NSScreen.screens.map { screen in
            let board = SketchBoard(screen: screen, controller: self)
            board.panel.orderFrontRegardless()
            return board
        }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let toolbar = SketchToolbar(controller: self)
            toolbar.place(on: screen)
            toolbar.orderFrontRegardless()
            self.toolbar = toolbar
        }
        board(at: pointer)?.panel.makeKey()
        VoiceOver.announce(String(localized: "Draw on Screen. Press Escape to stop.", bundle: .module))
        onChange?()
        onCanvasesShown?()
    }

    /// Takes the canvases, their marks, and the toolbar away.
    public func stop() {
        guard isActive else { return }
        isActive = false
        for board in boards { board.close() }
        boards = []
        toolbar?.close()
        toolbar = nil
        history = []
        onChange?()
    }

    // MARK: Choices

    func choose(_ tool: Tool) {
        self.tool = tool
        defaults.set(tool.rawValue, forKey: Self.toolKey)
        if clicksThrough { setClicksThrough(false) }
        toolbar?.refresh()
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
        if !on { board(at: NSEvent.mouseLocation)?.panel.makeKey() }
        toolbar?.refresh()
        VoiceOver.announce(on ? String(localized: "Clicks go through to the apps", bundle: .module) : String(localized: "Drawing", bundle: .module))
    }

    // MARK: Marks

    /// Notes every board's marks before a change, for Undo.
    func willChange() {
        history.append(boards.map(\.view.marks))
        if history.count > 200 { history.removeFirst() }
        toolbar?.refresh()
    }

    var canUndo: Bool { !history.isEmpty }
    var hasMarks: Bool { boards.contains { !$0.view.marks.isEmpty } }

    func undo() {
        guard let last = history.popLast() else { return NSSound.beep() }
        for (board, marks) in zip(boards, last) { board.view.marks = marks }
        toolbar?.refresh()
    }

    func clear() {
        guard hasMarks else { return }
        willChange()
        for board in boards { board.view.marks = [] }
        toolbar?.refresh()
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

    /// The keys a canvas answers while it has the keyboard: Escape stops, ⌘Z undoes, Delete clears, 1 to 6 choose a
    /// tool, T clicks through.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (event.keyCode, flags) {
        case (53, []):
            stop()
        case (51, []), (117, []):
            clear()
        case (_, .command) where key == "z":
            undo()
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
    #endif
}

/// One display's canvas: a clear panel over it and the view the marks are drawn in.
@MainActor
final class SketchBoard {
    let panel: SketchPanel
    let view: SketchView

    init(screen: NSScreen, controller: ScreenSketchController) {
        panel = SketchPanel(frame: screen.frame)
        view = SketchView(frame: CGRect(origin: .zero, size: screen.frame.size), controller: controller)
        panel.contentView = view
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
        setAccessibilityLabel(String(localized: "Drawing Canvas", bundle: .module))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws a display's marks, the mark being drawn, and the laser's trails, in points from the display's top-left
/// corner.
@MainActor
final class SketchView: NSView {
    var marks: [Annotation] = [] {
        didSet { needsDisplay = true }
    }

    private weak var controller: ScreenSketchController?
    private var drawing: Annotation?
    private var start: CGPoint?
    private var penPoints: [CGPoint] = []
    private var trails: [(trail: LaserTrail, color: RGBA)] = []
    private var frames: CADisplayLink?

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
        let now = CACurrentMediaTime()
        for (trail, color) in trails {
            guard let outline = trail.outline(at: now) else { continue }
            // A soft glow under a bright core, as a laser pointer's dot looks.
            context.setFillColor(color.cgColor.copy(alpha: 0.35) ?? color.cgColor)
            context.addPath(outline.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 4))
            context.fillPath()
            context.setFillColor(color.cgColor)
            context.addPath(outline)
            context.fillPath()
        }
    }

    // MARK: Drawing

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        window?.makeKey()
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
            penPoints.append(point)
            drawing = Annotation(shape: .pen(Stroke(points: penPoints)), style: Style(color: controller.color, lineWidth: ScreenSketchController.lineWidth, shadow: true))
            needsDisplay = true
        case .arrow, .rectangle, .ellipse:
            guard let start else { return }
            drawing = Self.shape(controller.tool, from: start, to: point, constrained: constrained, color: controller.color)
            needsDisplay = true
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
            needsDisplay = true
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
        needsDisplay = true
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

/// The toolbar: the tools, the colors, Undo, Clear, Click Through, and Done, in a small capsule at the top of a display.
@MainActor
final class SketchToolbar: NSPanel {
    private weak var controller: ScreenSketchController?
    private let stack = NSStackView()
    private var toolButtons: [ScreenSketchController.Tool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private let undoButton = NSButton()
    private let clearButton = NSButton()
    private let throughButton = NSButton()

    init(controller: ScreenSketchController) {
        self.controller = controller
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 22
        glass.layer?.masksToBounds = true
        contentView = glass

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        for (index, tool) in ScreenSketchController.Tool.allCases.enumerated() {
            let button = symbolButton(Self.symbol(of: tool), name: Self.name(of: tool), key: "\(index + 1)") { [weak self] in self?.controller?.choose(tool) }
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(Self.divider())
        for color in ScreenSketchController.colors {
            let button = NSButton(title: "", target: nil, action: nil)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = 9
            button.layer?.borderWidth = 1
            button.layer?.borderColor = CGColor(gray: 0.5, alpha: 0.5)
            button.setAccessibilityLabel(StyleCapsule.colorName(color))
            button.toolTip = StyleCapsule.colorName(color)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 18), button.heightAnchor.constraint(equalToConstant: 18)])
            button.target = self
            button.action = #selector(colorClicked(_:))
            button.tag = colorButtons.count
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(Self.divider())
        configure(undoButton, "arrow.uturn.backward", name: String(localized: "Undo", bundle: .module), key: "⌘Z") { [weak self] in self?.controller?.undo() }
        configure(clearButton, "trash", name: String(localized: "Clear", bundle: .module), key: "⌫") { [weak self] in self?.controller?.clear() }
        configure(throughButton, "cursorarrow.click.2", name: String(localized: "Click Through", bundle: .module), key: "T") { [weak self] in
            guard let controller = self?.controller else { return }
            controller.setClicksThrough(!controller.clicksThrough)
        }
        for button in [undoButton, clearButton, throughButton] { stack.addArrangedSubview(button) }
        let done = symbolButton("xmark.circle.fill", name: String(localized: "Done", bundle: .module), key: "esc") { [weak self] in self?.controller?.stop() }
        stack.addArrangedSubview(done)
        setContentSize(stack.fittingSize)
        refresh()
        setAccessibilityLabel(String(localized: "Draw on Screen", bundle: .module))
    }

    override var canBecomeKey: Bool { false }

    /// At the top of `screen`, centered, under the menu bar.
    func place(on screen: NSScreen) {
        let size = frame.size
        let area = screen.visibleFrame
        setFrameOrigin(CGPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12))
    }

    func refresh() {
        guard let controller else { return }
        for (tool, button) in toolButtons { button.state = tool == controller.tool && !controller.clicksThrough ? .on : .off }
        for (index, button) in colorButtons.enumerated() {
            let chosen = ScreenSketchController.colors[index] == controller.color
            button.layer?.borderWidth = chosen ? 2.5 : 1
            button.layer?.borderColor = chosen ? NSColor.controlAccentColor.cgColor : CGColor(gray: 0.5, alpha: 0.5)
            button.setAccessibilityValue(chosen ? String(localized: "Selected", bundle: .module) : nil)
        }
        undoButton.isEnabled = controller.canUndo
        clearButton.isEnabled = controller.hasMarks
        throughButton.state = controller.clicksThrough ? .on : .off
    }

    @objc private func colorClicked(_ sender: NSButton) {
        controller?.choose(ScreenSketchController.colors[sender.tag])
    }

    private var actions: [ObjectIdentifier: () -> Void] = [:]

    private func symbolButton(_ symbol: String, name: String, key: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton()
        configure(button, symbol, name: name, key: key, action: action)
        return button
    }

    private func configure(_ button: NSButton, _ symbol: String, name: String, key: String, action: @escaping () -> Void) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        button.bezelStyle = .toolbar
        button.setButtonType(.pushOnPushOff)
        button.isBordered = true
        button.toolTip = "\(name)  \(key)"
        button.setAccessibilityLabel(name)
        button.target = self
        button.action = #selector(buttonClicked(_:))
        actions[ObjectIdentifier(button)] = action
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        actions[ObjectIdentifier(sender)]?()
        refresh()
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    static func symbol(of tool: ScreenSketchController.Tool) -> String {
        switch tool {
        case .laser: "cursorarrow.rays"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .counter: "1.circle"
        }
    }

    static func name(of tool: ScreenSketchController.Tool) -> String {
        switch tool {
        case .laser: String(localized: "Laser Pointer", bundle: .module)
        case .pen: String(localized: "Pen", bundle: .module)
        case .arrow: String(localized: "Arrow", bundle: .module)
        case .rectangle: String(localized: "Rectangle", bundle: .module)
        case .ellipse: String(localized: "Ellipse", bundle: .module)
        case .counter: String(localized: "Counter", bundle: .module)
        }
    }
}
