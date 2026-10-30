import AppKit
import Carbon.HIToolbox
import OMSCore
import OSLog
import QuartzCore

/// Writes down what the pointer and the keyboard do while a Studio recording runs: where the pointer goes,
/// the cursor's look whenever it changes, every click and where it was released, and, when asked, every key.
///
/// Studio records the screen without the cursor so the Studio window can draw it again, smooth and larger;
/// this is what it is drawn from. The pointer's moves, drags, presses, and releases are written down at the time
/// and place each event carries rather than when it arrives. When Input Monitoring allows it, they come from a
/// listen-only event tap on a thread of its own (`PointerTap`), so what the pointer does while the main thread is
/// busy keeps every reading; otherwise from event monitors, global for other apps and local for OhMyShot's own
/// windows (no permission needed), which hand moves made during a stall over afterwards as one. A timer, sixty
/// times a second, takes the tap's events in, reads the system's cursor as other apps set it (no permission
/// either), and reads the pointer's place when no event has placed it since its last reading. Keys need Input
/// Monitoring, as the keystroke display's do; the system is never asked for it here, where its prompt would be
/// recorded. Times are host-clock seconds, the clock the stream stamps frames with and events' own.
///
/// Keys are written down so Studio can show them afterwards, whether or not the recording bar showed them
/// while recording. Keys typed while the system keeps keystrokes private (a password field has focus, an app
/// has turned on secure input) are never written down: the system keeps them from the monitor, and this
/// drops any that arrive all the same.
public final class TelemetryRecorder {
    private var telemetry = StudioTelemetry(width: 0, height: 0, pixelsPerPoint: 1)
    /// What is recorded, in global points.
    private var area: CGRect = .zero
    private var timer: Timer?
    /// Where the pointer's events come from: the tap, or else the event monitors, global and local.
    private var pointerTap: PointerTap?
    private var monitors: [Any] = []
    private var keyMonitor: KeyMonitor?
    var keyMode: KeystrokeMode?
    /// Whether the system is keeping keystrokes private right now.
    var isSecureInputOn: () -> Bool = { IsSecureEventInputEnabled() }
    /// Cursors seen so far by what tells them apart, and the newest.
    private var cursorIndices: [String: Int] = [:]
    private var lastCursorShape: String?
    private var lastCursor = 0
    /// The latest reading in time.
    private var lastSample: StudioTelemetry.Sample?
    /// Whether a pointer event has come since the timer's last reading: the timer then leaves the pointer's
    /// place to the events, whose times are their own.
    private var movedSinceTick = false
    /// Presses not yet released, by button number: where each is in `telemetry.clicks`.
    private var held: [Int: Int] = [:]
    /// Whether this recording's first pointer event has been logged, with how late it arrived.
    private var loggedDelivery = false

    /// The cursor's pictures are kept at four pixels a point: Studio draws the cursor larger and zooms in.
    private static let cursorScale = 4.0

    public init() {}

    public var isRecording: Bool {
        timer != nil
    }

    /// The mode a Studio recording writes keys down in, or nil for none: `mode` (Settings' Keystrokes
    /// choice, under which Shortcuts only never writes typing down) when Input Monitoring allows keys at all and
    /// either the bar showed them or Settings keeps them for Studio to show later. A window recorded on its own
    /// keeps them only when the bar showed them: what is typed in other apps is no part of it. The system is
    /// never asked for Input Monitoring from here, where its prompt would be recorded.
    public static func keystrokeMode(
        showsKeystrokes: Bool, keepsForStudio: Bool, recordsWindow: Bool, inputMonitoringAllowed: Bool, mode: KeystrokeMode
    ) -> KeystrokeMode? {
        guard inputMonitoringAllowed, showsKeystrokes || (keepsForStudio && !recordsWindow) else { return nil }
        return mode
    }

    /// Starts writing down what happens over `area` (global points); with `keys`, the keys pressed too, as
    /// that mode shows them (Input Monitoring must be on): under Shortcuts only, a key typed alone is kept
    /// only as a press, so typing still places zooms but is never written down.
    public func start(area: CGRect, pixelsPerPoint: Double, keys: KeystrokeMode?) {
        stop()
        begin(area: area, pixelsPerPoint: pixelsPerPoint)
        keyMode = keys
        sample()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop.
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A tap only where Input Monitoring is on already: one made without it might have the system ask.
        if KeyMonitor.isAllowed, let tap = PointerTap(mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height) {
            pointerTap = tap
        } else {
            listenOnMainThread()
        }
        if keys != nil {
            let monitor = KeyMonitor()
            monitor.onPress = { [weak self] key in self?.press(key) }
            if monitor.start() {
                keyMonitor = monitor
                telemetry.keystrokeMode = keys
            }
        }
    }

    /// Stops and hands over what was written down, in host-clock seconds and in time order.
    @discardableResult
    public func stop() -> StudioTelemetry {
        timer?.invalidate()
        timer = nil
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        if let pointerTap {
            pointerTap.stop()
            take(pointerTap.drain())
        }
        pointerTap = nil
        keyMonitor?.stop()
        keyMonitor = nil
        // Events can arrive after a reading the timer took later, and the two monitors' out of turn.
        telemetry.samples = Self.inOrder(telemetry.samples)
        telemetry.clicks = telemetry.clicks.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
        held = [:]
        return telemetry
    }

    /// Begins afresh over `area` (global points), with nothing written down.
    func begin(area: CGRect, pixelsPerPoint: Double) {
        self.area = area
        telemetry = StudioTelemetry(width: area.width, height: area.height, pixelsPerPoint: pixelsPerPoint)
        cursorIndices = [:]
        lastCursorShape = nil
        lastCursor = 0
        lastSample = nil
        movedSinceTick = false
        held = [:]
        loggedDelivery = false
    }

    /// The timer's reading of the pointer at `location` (global points) and of the cursor's look: the place is
    /// left to the events when one has come since the last reading, unless the look changed.
    func sample(at time: Double = CACurrentMediaTime(), location: CGPoint = NSEvent.mouseLocation, cursor: Int? = nil) {
        let cursor = cursor ?? cursorIndex()
        lastCursor = cursor
        defer { movedSinceTick = false }
        if movedSinceTick, cursor == lastSample?.cursor { return }
        let place = local(location)
        write(.init(time: time, x: place.x, y: place.y, cursor: cursor))
    }

    /// The pointer at `location` (global points) at `time`, as a move, a drag, a press, or a release places it.
    func move(at time: Double, location: CGPoint) {
        movedSinceTick = true
        let place = local(location)
        write(.init(time: time, x: place.x, y: place.y, cursor: lastCursor))
    }

    /// A press of button `number`: a click, which its release ends.
    func click(_ button: StudioTelemetry.Click.Button, number: Int, at time: Double, location: CGPoint) {
        let place = local(location)
        held[number] = telemetry.clicks.count
        telemetry.clicks.append(.init(time: time, x: place.x, y: place.y, button: button))
        move(at: time, location: location)
    }

    /// The release of button `number`, which ends its click; one pressed before recording began has none.
    func release(number: Int, at time: Double, location: CGPoint) {
        move(at: time, location: location)
        guard let index = held.removeValue(forKey: number), telemetry.clicks.indices.contains(index) else { return }
        let place = local(location)
        telemetry.clicks[index].releaseTime = time
        telemetry.clicks[index].releaseX = place.x
        telemetry.clicks[index].releaseY = place.y
    }

    /// The tap's events since it was last asked, in the order they happened.
    func take(_ events: [PointerTap.Event]) {
        for event in events {
            guard let type = NSEvent.EventType(rawValue: UInt(event.type.rawValue)) else { continue }
            handle(
                type, number: event.button, at: event.time, location: event.location, arrived: event.arrived, from: "the event tap",
                onOwnWindow: event.isOnOwnWindow
            )
        }
    }

    func press(_ key: Keystroke, at time: Double = CACurrentMediaTime()) {
        guard !isSecureInputOn() else { return }
        guard keyMode == .all || KeystrokeCaption.isShortcut(key) else {
            return telemetry.keys.append(.unrecorded(time: time, isRepeat: key.isRepeat))
        }
        telemetry.keys.append(.init(
            time: time, keyCode: key.keyCode, modifiers: key.modifiers.rawValue, characters: key.characters,
            keyCharacters: key.keyCharacters, isRepeat: key.isRepeat
        ))
    }

    /// `samples` in time order, each the same as the one before it left out, as at rest; of two at the same
    /// time, the one written down last stands.
    static func inOrder(_ samples: [StudioTelemetry.Sample]) -> [StudioTelemetry.Sample] {
        var result: [StudioTelemetry.Sample] = []
        result.reserveCapacity(samples.count)
        for (_, sample) in samples.enumerated().sorted(by: { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }) {
            if result.last?.time == sample.time { result.removeLast() }
            if let last = result.last, last.x == sample.x, last.y == sample.y, last.cursor == sample.cursor { continue }
            result.append(sample)
        }
        return result
    }

    // MARK: Private

    /// The pointer in the recording's points from its top-left corner.
    private func local(_ point: CGPoint) -> (x: Double, y: Double) {
        (point.x - area.minX, area.maxY - point.y)
    }

    /// The timer's tick: the tap's events first, then the timer's own reading, which they may make unneeded.
    private func tick() {
        if let pointerTap { take(pointerTap.drain()) }
        sample()
    }

    /// The pointer's events from monitors on the main thread, for when there is no tap.
    private func listenOnMainThread() {
        let pointer: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        // Both monitors are called on the main thread. An event in another app has no window, so its place in
        // the window is its place on screen, in the space of `NSEvent.mouseLocation`.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: pointer, handler: { [weak self] event in
            let (type, time, number, location) = (event.type, event.timestamp, event.buttonNumber, event.locationInWindow)
            MainActor.assumeIsolated {
                self?.handle(type, number: number, at: time, location: location, arrived: CACurrentMediaTime(), from: "the event monitors")
            }
        }) {
            monitors.append(global)
        }
        // OhMyShot's own windows, the recording bar's among them: where the pointer is, but no clicks.
        if let local = NSEvent.addLocalMonitorForEvents(matching: pointer, handler: { [weak self] event in
            MainActor.assumeIsolated {
                let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
                self?.handle(
                    event.type, number: event.buttonNumber, at: event.timestamp, location: location, arrived: CACurrentMediaTime(),
                    from: "the event monitors", onOwnWindow: true
                )
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// One pointer event. A press or release on OhMyShot's own windows (`onOwnWindow`) only places the pointer:
    /// recordings leave those windows out, so a click there (the recording bar's Pause or Stop) would ring over
    /// whatever the movie shows behind them, and two would place a zoom.
    private func handle(
        _ type: NSEvent.EventType, number: Int, at time: Double, location: CGPoint, arrived: Double, from source: String, onOwnWindow: Bool = false
    ) {
        let kind: String
        switch type {
        // (A `where` after several patterns would guard only the last.)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = "press"
            if onOwnWindow {
                move(at: time, location: location)
            } else {
                click(type == .leftMouseDown ? .primary : type == .rightMouseDown ? .secondary : .other, number: number, at: time, location: location)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            kind = "release"
            if onOwnWindow {
                move(at: time, location: location)
            } else {
                release(number: number, at: time, location: location)
            }
        default:
            kind = "move"
            move(at: time, location: location)
        }
        // Events' times and the timer's are both the host clock: the first event says how far apart they are.
        guard !loggedDelivery else { return }
        loggedDelivery = true
        Log.studio.notice("Studio telemetry: the first pointer event, a \(kind, privacy: .public) from \(source, privacy: .public), arrived \((arrived - time) * 1000, format: .fixed(precision: 2), privacy: .public) ms after its own time")
    }

    /// Writes `sample` down unless the latest reading, no later than it, says as much already: a pointer at rest
    /// writes nothing until it moves or changes look. One earlier than the latest is kept for `stop()` to order.
    private func write(_ sample: StudioTelemetry.Sample) {
        if let last = lastSample, last.time <= sample.time, last.x == sample.x, last.y == sample.y, last.cursor == sample.cursor { return }
        telemetry.samples.append(sample)
        if sample.time >= lastSample?.time ?? -.infinity { lastSample = sample }
    }

    /// The cursor showing now, written down the first time it is seen. Its size and hot spot tell most cursors
    /// apart cheaply; when they change, its picture is compared too, which tells the rest apart.
    private func cursorIndex() -> Int {
        guard let cursor = NSCursor.currentSystem else { return lastCursor }
        let size = cursor.image.size
        let shape = "\(size.width)x\(size.height)@\(cursor.hotSpot.x),\(cursor.hotSpot.y)"
        guard shape != lastCursorShape else { return lastCursor }
        lastCursorShape = shape
        guard let png = Self.png(of: cursor.image, scale: Self.cursorScale) else { return lastCursor }
        let identity = "\(shape)#\(png.hashValue)"
        if let index = cursorIndices[identity] {
            lastCursor = index
        } else {
            telemetry.cursors.append(.init(
                png: png, scale: Self.cursorScale, width: size.width, height: size.height,
                hotSpotX: cursor.hotSpot.x, hotSpotY: cursor.hotSpot.y
            ))
            lastCursor = telemetry.cursors.count - 1
            cursorIndices[identity] = lastCursor
        }
        return lastCursor
    }

    /// `image` drawn at `scale` pixels per point, as a PNG.
    public static func png(of image: NSImage, scale: Double) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    #if DEBUG
    /// Writes down a click as a press would, for scripted checks.
    public func debugClick(at point: CGPoint) {
        click(.primary, number: 0, at: CACurrentMediaTime(), location: point)
    }
    #endif
}

/// The pointer's moves, drags, presses, and releases, heard through a listen-only event tap on a thread of its
/// own and kept until `drain()`, so a busy main thread holds them up but loses none. It hears OhMyShot's own
/// windows too, releases inside a button's tracking among them.
nonisolated final class PointerTap: @unchecked Sendable {
    struct Event {
        var type: CGEventType
        var button: Int
        /// The event's own time, host-clock seconds.
        var time: Double
        /// In global points from the main display's bottom-left corner, as `NSEvent.mouseLocation`.
        var location: CGPoint
        /// When the tap heard it, host-clock seconds.
        var arrived: Double
        /// It goes to one of OhMyShot's own windows.
        var isOnOwnWindow = false
    }

    static let types: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
    ]

    private let lock = NSLock()
    private var events: [Event] = []
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false
    /// The main display's height, which turns the tap's places (from its top-left corner) into AppKit's.
    private let mainDisplayHeight: Double
    private let ownProcess = getpid()

    /// A tap listening from now on, or nil when the system makes none.
    init?(mainDisplayHeight: Double) {
        self.mainDisplayHeight = mainDisplayHeight
        let mask = Self.types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context { Unmanaged<PointerTap>.fromOpaque(context).takeUnretainedValue().hear(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port
        // The thread keeps the tap alive until its run loop ends, when the port is invalidated.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            let port = lock.withLock {
                runLoop = loop
                return self.port
            }
            if let port { CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes) }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Studio pointer"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// What was heard since the last time, in the order it happened.
    func drain() -> [Event] {
        lock.withLock {
            let taken = events
            events.removeAll(keepingCapacity: true)
            return taken
        }
    }

    /// Stops listening; what was heard stays for `drain()`.
    func stop() {
        let (port, loop) = lock.withLock {
            stopped = true
            return (self.port, runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    private func hear(_ type: CGEventType, _ event: CGEvent) {
        // The system turns a tap off when it answers slowly or at the user's say; it is turned back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let port = lock.withLock { stopped ? nil : self.port }
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        let arrived = CACurrentMediaTime()
        let time = NSEvent(cgEvent: event)?.timestamp ?? Double(event.timestamp) / 1e9
        let place = event.location
        let heard = Event(
            type: type, button: Int(event.getIntegerValueField(.mouseEventButtonNumber)), time: time,
            location: CGPoint(x: place.x, y: mainDisplayHeight - place.y), arrived: arrived,
            isOnOwnWindow: event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(ownProcess)
        )
        lock.withLock { events.append(heard) }
    }
}
