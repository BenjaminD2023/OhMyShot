import AppKit
import ApplicationServices
import Darwin
import OMSCore
import OSLog

/// Starts scrolling immediately at a moderate speed. The panel changes speed or pauses; the pointer
/// remains free. Posting targets the captured window and never posts mouse movement or warps the cursor.
/// Posting events needs Accessibility.
public final class AutoScroller {
    public enum Direction: Sendable, Equatable {
        case down
        case up
        case right
        case left

        /// The way a capture that last moved `offset` pixels along `axis` goes on.
        public init(axis: ScrollStitcher.Axis?, offset: Int) {
            switch axis {
            case .horizontal: self = offset < 0 ? .left : .right
            case .vertical, nil: self = offset < 0 ? .up : .down
            }
        }

        public var isVertical: Bool { self == .down || self == .up }
    }

    /// Why Auto-scroll stopped by itself: what the user did to take over, or what became of the page.
    public enum TakeOver: Sendable, Equatable {
        case click
        case key
        case scroll
        case targetClosed
        /// It pushed on and the content came no further: its end, or what scrolls stopped moving.
        case reachedEnd
    }

    /// The user clicked, typed, or scrolled themselves.
    public var onUserTookOver: ((TakeOver) -> Void)?
    public private(set) var isRunning = false
    public let direction: Direction
    public var speedMultiplier: Double = 1
    /// Signed points per second, positive toward the bottom/right.
    public private(set) var velocity: Double = 0
    /// How far it has asked the app to scroll since it started, in points.
    public private(set) var posted: Double = 0

    private let area: CGRect
    private let axis: ScrollStitcher.Axis
    private var motion = AutoScrollMotion()
    private var isSendingScroll = false
    private var destination: AutoScrollDestination?
    #if DEBUG
    private var debugDestination: AutoScrollDestination?
    #endif
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private var keyMonitor: Any?
    private var wheelMonitor: AutoScrollWheelMonitor?
    private var leases: [ActiveResources.Lease] = []
    /// The source for window-directed wheel events. It never posts pointer movement.
    private let source = CGEventSource(stateID: .hidSystemState)
    /// Marks the events this posts, should the mark come back with them.
    static let mark: Int64 = 0x4F4D_5353

    /// Whether this app may post events: Accessibility.
    public static var isAllowed: Bool { AXIsProcessTrusted() }

    /// - Parameter area: The area in global points.
    public init(area: CGRect, direction: Direction = .down) {
        self.area = area
        self.direction = direction
        axis = direction.isVertical ? .vertical : .horizontal
    }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning, Self.isAllowed else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let middle = CGPoint(x: area.midX, y: primaryHeight - area.midY)
        #if DEBUG
        let resolved = debugDestination ?? AutoScrollDestination.at(middle)
        #else
        let resolved = AutoScrollDestination.at(middle)
        #endif
        guard let destination = resolved, destination.canPost else { return false }
        let wheelMonitor = AutoScrollWheelMonitor { [weak self] event in self?.heard(event) }
        guard wheelMonitor.start() else { return false }
        self.wheelMonitor = wheelMonitor
        self.destination = destination
        isRunning = true
        motion = AutoScrollMotion()
        isSendingScroll = false
        posted = 0
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            self?.heard(event)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.heard(event)
            return event
        }
        leases = (0..<3).map { _ in ActiveResources.shared.acquire(.eventMonitor) } + [ActiveResources.shared.acquire(.timer)]
        task = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self, isRunning else { break }
                let now = ContinuousClock.now
                tick(elapsed: (now - last) / .seconds(1))
                last = now
            }
        }
        Log.capture.notice("Auto-scroll started: panel controls speed")
        return true
    }

    private func tick(elapsed: Double) {
        guard let destination, !destination.application.isTerminated else {
            stop()
            onUserTookOver?(.targetClosed)
            return
        }
        let extent = axis == .vertical ? area.height : area.width
        let speed = AutoScrollMotion.velocity(multiplier: speedMultiplier, extent: extent)
        velocity = direction == .up || direction == .left ? -speed : speed
        let distance = motion.step(velocity: velocity, elapsed: elapsed)
        if distance != 0 {
            destination.post(distance: distance, axis: axis, source: source, phase: isSendingScroll ? .changed : .began)
            isSendingScroll = true
            posted += Double(abs(distance))
        }
    }

    /// Scrolls at `point` (global points) from now on, in the same window: the gesture so far ends and the next
    /// begins there, so the app looks again at what is under it. For a scroller inside the page that took the
    /// gesture and stopped, or scrolls alone.
    public func retarget(to point: CGPoint) {
        guard isRunning, var destination else { return }
        if isSendingScroll { destination.post(distance: 0, axis: axis, source: source, phase: .ended) }
        isSendingScroll = false
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        destination.location = CGPoint(x: point.x, y: primaryHeight - point.y)
        self.destination = destination
        Log.capture.notice("Auto-scroll moved to \(Int(point.x), privacy: .public), \(Int(point.y), privacy: .public)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        task?.cancel()
        task = nil
        velocity = 0
        if isSendingScroll, let destination, !destination.application.isTerminated {
            destination.post(distance: 0, axis: axis, source: source, phase: .ended)
        }
        isSendingScroll = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        wheelMonitor?.stop()
        wheelMonitor = nil
        leases.removeAll()
        destination = nil
        Log.capture.notice("Auto-scroll stopped")
    }

    private func heard(_ event: NSEvent) {
        guard isRunning, let destination else { return }
        if event.type == .keyDown {
            // The panel's explicit Pause button owns normal control. Typing in another app must not
            // interrupt a capture; Escape and typing in the target app still hand control back.
            guard event.keyCode == 53 || NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.application.processIdentifier else { return }
        } else {
            let point = NSEvent.mouseLocation
            guard !NSApp.windows.contains(where: { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point) }) else { return }
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            let screenPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
            guard AutoScrollDestination.at(screenPoint)?.windowID == destination.windowID else { return }
        }
        let takeOver: TakeOver
        switch event.type {
        case .scrollWheel:
            takeOver = .scroll
        case .keyDown:
            takeOver = .key
        default:
            takeOver = .click
        }
        let fields = event.cgEvent.map { event in
            "process \(event.getIntegerValueField(.eventSourceUnixProcessID)) (this \(getpid())), source state \(event.getIntegerValueField(.eventSourceStateID)), mark \(event.getIntegerValueField(.eventSourceUserData) == Self.mark)"
        } ?? "no event fields"
        let scroll = event.type == .scrollWheel
            ? "deltas \(event.scrollingDeltaX), \(event.scrollingDeltaY), phase \(event.phase.rawValue), momentum \(event.momentumPhase.rawValue)"
            : ""
        Log.capture.notice("Auto-scroll handed back by \(String(describing: takeOver), privacy: .public): \(fields, privacy: .public) \(scroll, privacy: .public)")
        stop()
        onUserTookOver?(takeOver)
    }

    #if DEBUG
    /// The same driver addressed to a known test window, including an occluded window captured by SCK.
    public static func debugWindow(
        area: CGRect, processID: pid_t, windowID: CGWindowID, windowFrame: CGRect, direction: Direction = .down
    ) -> AutoScroller? {
        guard let app = NSRunningApplication(processIdentifier: processID) else { return nil }
        let result = AutoScroller(area: area, direction: direction)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        result.debugDestination = AutoScrollDestination(application: app, windowID: windowID,
            location: CGPoint(x: area.midX, y: primaryHeight - area.midY), frame: windowFrame)
        return result
    }
    #endif

}

/// Observe hardware wheel input before smoothing apps consume it and emit their own gestures. Those
/// replacement gestures have a source process even when they have lost the original user-data marker.
final class AutoScrollWheelMonitor {
    private let onWheel: (NSEvent) -> Void
    private let observesPointer: Bool
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var observedEvents = 0
    private(set) var pointerEvents = 0

    init(observesPointer: Bool = false, onWheel: @escaping (NSEvent) -> Void) {
        self.observesPointer = observesPointer
        self.onWheel = onWheel
    }

    func start() -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue) | (observesPointer ? CGEventMask(1 << CGEventType.mouseMoved.rawValue) : 0),
            callback: { _, type, event, info in
                if let info {
                    let observer = Unmanaged<AutoScrollWheelMonitor>.fromOpaque(info).takeUnretainedValue()
                    MainActor.assumeIsolated { observer.heard(type, event) }
                }
                // Observation only: physical input always continues unchanged.
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    /// Whether a hardware wheel event is the user scrolling: it moves, and it is a wheel's click or a gesture's
    /// start or change. Fingers resting on a trackpad (may begin, cancelled), a gesture's end, and the momentum
    /// of a flick made before are not.
    static func isScrolling(_ event: CGEvent) -> Bool {
        let moves = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) != 0 || event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) != 0
            || event.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0 || event.getIntegerValueField(.scrollWheelEventDeltaAxis2) != 0
        guard moves, event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return false }
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        // No phase: a mouse's wheel. Began and changed: a trackpad gesture.
        return phase == 0 || phase == Int64(CGScrollPhase.began.rawValue) || phase == Int64(CGScrollPhase.changed.rawValue)
    }

    private func heard(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if type == .mouseMoved {
            if event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
               event.getIntegerValueField(.mouseEventDeltaX) != 0 || event.getIntegerValueField(.mouseEventDeltaY) != 0 { pointerEvents += 1 }
        } else if type == .scrollWheel {
            observedEvents += 1
            guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
                  event.getIntegerValueField(.eventSourceUserData) != AutoScroller.mark,
                  Self.isScrolling(event),
                  let event = NSEvent(cgEvent: event) else { return }
            onWheel(event)
        }
    }
}

/// Resolves once when starting, so moving the pointer cannot retarget scrolling to another app.
struct AutoScrollDestination {
    let application: NSRunningApplication
    let windowID: CGWindowID
    var location: CGPoint
    var frame: CGRect = .zero
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias SetField = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias GetField = @convention(c) (CGEvent, UInt32) -> Int64
    private typealias PostToProcess = @convention(c) (pid_t, CGEvent) -> Void
    private struct Transport {
        let setWindowLocation: SetWindowLocation
        let setField: SetField
        let post: PostToProcess
        let windowField: UInt32
    }
    private static let transport: Transport? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let location = dlsym(library, "SLEventSetWindowLocation"),
              let field = dlsym(library, "SLEventSetIntegerValueField"),
              let getter = dlsym(library, "SLEventGetIntegerValueField"),
              let post = dlsym(library, "SLEventPostToPid") else { return nil }
        let getField = unsafeBitCast(getter, to: GetField.self)
        func template(_ window: Int) -> CGEvent? {
            NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)?.cgEvent?.copy()
        }
        // Derive the private window slot from AppKit's own event representation instead of assuming a
        // numeric CGEventField. These templates are inspected only and are never posted.
        guard let first = template(1234), let second = template(5678) else { return nil }
        let fields = (UInt32(0)..<128).filter { getField(first, $0) == 1234 && getField(second, $0) == 5678 }
        guard fields.count == 1, let windowField = fields.first else { return nil }
        return Transport(
            setWindowLocation: unsafeBitCast(location, to: SetWindowLocation.self),
            setField: unsafeBitCast(field, to: SetField.self),
            post: unsafeBitCast(post, to: PostToProcess.self), windowField: windowField
        )
    }()

    var canPost: Bool { Self.transport != nil }

    static func at(_ location: CGPoint) -> Self? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != getpid(),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(location),
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            return Self(application: app, windowID: id, location: location, frame: frame)
        }
        return nil
    }

    func event(distance: Int32, axis: ScrollStitcher.Axis, source: CGEventSource?, phase: CGScrollPhase? = nil) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
            wheel1: axis == .vertical ? -distance : 0, wheel2: axis == .horizontal ? -distance : 0, wheel3: 0
        ) else { return nil }
        // AppKit's window association accompanies the wheel payload. Never send a mouse-move event to
        // prime the target application's state; the real cursor belongs to the user.
        event.flags = []
        let vertical = axis == .vertical ? -distance : 0
        let horizontal = axis == .horizontal ? -distance : 0
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(vertical))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(horizontal))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(vertical))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(horizontal))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: AutoScroller.mark)
        return event
    }

    func post(distance: Int32, axis: ScrollStitcher.Axis, source: CGEventSource?, phase: CGScrollPhase? = nil) {
        guard let transport = Self.transport, let wheel = event(distance: distance, axis: axis, source: source, phase: phase) else { return }
        // Private SkyLight fields are not CGEventField values. Keep their mapping inside this shim.
        transport.setField(wheel, transport.windowField, Int64(windowID))
        wheel.location = location
        wheel.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(application.processIdentifier))
        transport.setWindowLocation(wheel, CGPoint(x: location.x - frame.minX, y: location.y - frame.minY))
        transport.post(application.processIdentifier, wheel)
    }

}

/// The speed curve and fractional pixel accumulator, independent of event delivery and permissions.
nonisolated struct AutoScrollMotion {
    private var remainder = 0.0

    static func velocity(multiplier: Double, extent: Double) -> Double {
        guard multiplier.isFinite, extent.isFinite, extent > 0 else { return 0 }
        let base = min(320, max(60, extent * 0.35))
        return min(extent * 0.8, base * min(2, max(0.25, multiplier)))
    }

    mutating func step(velocity: Double, elapsed: Double) -> Int32 {
        guard velocity.isFinite, elapsed.isFinite, elapsed > 0, velocity != 0 else {
            remainder = 0
            return 0
        }
        if remainder * velocity < 0 { remainder = 0 }
        // A busy main thread must never catch up with a large jump that loses the overlap.
        remainder += max(-900, min(900, velocity)) * min(elapsed, 0.05)
        let whole = Int32(remainder.rounded(.towardZero))
        remainder -= Double(whole)
        return whole
    }
}

