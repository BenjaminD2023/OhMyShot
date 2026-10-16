import AppKit
import Carbon.HIToolbox
import OMSCore
import QuartzCore

/// Writes down what the pointer and the keyboard do while a Studio recording runs: where the pointer is,
/// sixty times a second, the cursor's look whenever it changes, every click, and, when asked, every key.
///
/// Studio records the screen without the cursor so the Studio window can draw it again, smooth and larger;
/// this is what it is drawn from. The system's cursor is read as other apps set it (no permission needed);
/// clicks come from a global monitor (none either); keys need Input Monitoring, as the keystroke display's do.
/// Times are host-clock seconds, the clock the stream stamps frames with.
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
    private var clickMonitor: Any?
    private var keyMonitor: KeyMonitor?
    var keyMode: KeystrokeMode?
    /// Whether the system is keeping keystrokes private right now.
    var isSecureInputOn: () -> Bool = { IsSecureEventInputEnabled() }
    /// Cursors seen so far by what tells them apart, and the newest.
    private var cursorIndices: [String: Int] = [:]
    private var lastCursorShape: String?
    private var lastCursor = 0
    private var lastSample: StudioTelemetry.Sample?

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
        self.area = area
        telemetry = StudioTelemetry(width: area.width, height: area.height, pixelsPerPoint: pixelsPerPoint)
        keyMode = keys
        cursorIndices = [:]
        lastCursorShape = nil
        lastSample = nil
        sample()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop.
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let button: StudioTelemetry.Click.Button = switch event.type {
            case .leftMouseDown: .primary
            case .rightMouseDown: .secondary
            default: .other
            }
            MainActor.assumeIsolated { self?.click(button) }
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

    /// Stops and hands over what was written down, in host-clock seconds.
    @discardableResult
    public func stop() -> StudioTelemetry {
        timer?.invalidate()
        timer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        keyMonitor?.stop()
        keyMonitor = nil
        return telemetry
    }

    // MARK: Private

    /// The pointer in the recording's points from its top-left corner.
    private func local(_ point: CGPoint) -> (x: Double, y: Double) {
        (point.x - area.minX, area.maxY - point.y)
    }

    private func sample() {
        let place = local(NSEvent.mouseLocation)
        let sample = StudioTelemetry.Sample(time: CACurrentMediaTime(), x: place.x, y: place.y, cursor: cursorIndex())
        // A pointer at rest writes nothing until it moves or changes look: the last reading holds.
        if let last = lastSample, last.x == sample.x, last.y == sample.y, last.cursor == sample.cursor { return }
        telemetry.samples.append(sample)
        lastSample = sample
    }

    private func click(_ button: StudioTelemetry.Click.Button) {
        let place = local(NSEvent.mouseLocation)
        telemetry.clicks.append(.init(time: CACurrentMediaTime(), x: place.x, y: place.y, button: button))
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
        let place = local(point)
        telemetry.clicks.append(.init(time: CACurrentMediaTime(), x: place.x, y: place.y, button: .primary))
    }
    #endif
}
