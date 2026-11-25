import AppKit
import Carbon.HIToolbox
import OMSCore
import OMSDesign
import OSLog
import QuartzCore

/// Self-Timer's countdown: the area about to be captured outlined where it lies, and a small disc
/// counting the seconds down under it, while the screen is set up: a menu opened, a card hovered.
///
/// The outline lets every click through and never activates the app; the small countdown disc shows a
/// subtle cancel affordance that can be clicked without activating the app, and pressing Escape cancels
/// the countdown through an ephemeral monitor that is active only while the countdown runs. Like every
/// window of this app, its panels are left out of the capture.
public final class SelfTimerCountdown {
    public private(set) var isRunning = false

    private var outlinePanels: [CountdownPanel] = []
    private var discPanel: CountdownPanel?
    private var disc: CountdownDisc?
    private var task: Task<Void, Never>?
    private var leases: [ActiveResources.Lease] = []
    private var onCancel: (() -> Void)?
    private var escapeMonitor: CountdownEscapeMonitor?

    static let discDiameter: CGFloat = 64
    /// Room around the disc for its shadow: twice its blur and its drop, so it fades out before the
    /// panel's edge.
    private static let shadowRoom: CGFloat = 24

    public init() {}

    isolated deinit {
        close()
    }

    /// Outlines `area` (global points) and counts `seconds` down under it; `finish` runs at zero, once
    /// the countdown has left the screen. Without `outlinesArea`, only the disc shows: whoever started it
    /// keeps an outline of their own up (a recording, from its countdown to its end). `onCancel` runs when
    /// the user cancels via Escape or by clicking the countdown disc.
    public func start(
        seconds: Int,
        area: CGRect,
        layout: DisplayLayout,
        outlinesArea: Bool = true,
        onCancel: (() -> Void)? = nil,
        finish: @escaping () -> Void
    ) {
        close()
        let seconds = max(seconds, 1)
        isRunning = true
        self.onCancel = onCancel
        leases = [ActiveResources.shared.acquire(.timer), ActiveResources.shared.acquire(.window)]
        if outlinesArea { outlinePanels = AreaOutline.panels(around: area, layout: layout) }
        let discFrame = Self.discFrame(for: area, diameter: Self.discDiameter, displays: layout.displays.map(\.frame))
        let panel = CountdownPanel(frame: discFrame.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom), ignoresMouseEvents: false)
        panel.allowsToolTipsWhenApplicationIsInactive = true
        let disc = CountdownDisc(seconds: seconds)
        disc.onCancel = { [weak self] in self?.cancelFromUser() }
        disc.frame = CGRect(origin: .zero, size: panel.frame.size)
        panel.contentView = disc
        discPanel = panel
        self.disc = disc
        // The first second is on the disc before it shows, so it never appears blank.
        disc.show(remaining: seconds)

        let monitor = CountdownEscapeMonitor { [weak self] in self?.cancelFromUser() }
        monitor.arm()
        escapeMonitor = monitor

        // Faded in once; the ring then runs out with the time, and the digit steps down each second.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panels = outlinePanels + [panel]
        for panel in panels {
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
        }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.fade
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for panel in panels { panel.animator().alphaValue = 1 }
            }
        }
        disc.start(sweeping: !reduceMotion)

        task = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            for second in 0..<seconds {
                self?.disc?.show(remaining: seconds - second)
                // Absolute deadlines, so the seconds never drift.
                do {
                    try await clock.sleep(until: start.advanced(by: .seconds(second + 1)), tolerance: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard let self, isRunning else { return }
            close()
            finish()
        }
    }

    /// Stops the countdown; nothing is captured.
    public func cancel() {
        close()
    }

    private func cancelFromUser() {
        guard isRunning else { return }
        let handler = onCancel
        close()
        if let handler {
            handler()
        } else {
            VoiceOver.announce(String(localized: "Countdown cancelled", bundle: .module))
        }
    }

    private func close() {
        escapeMonitor?.disarm()
        escapeMonitor = nil
        onCancel = nil
        task?.cancel()
        task = nil
        for panel in outlinePanels { panel.orderOut(nil) }
        outlinePanels = []
        discPanel?.orderOut(nil)
        discPanel = nil
        disc = nil
        leases = []
        isRunning = false
    }

    /// Where the disc goes: centered `gap` under the area, or above it, when a display has room for it
    /// there; inside the area's bottom edge only when neither has, since inside it would cover what is
    /// being set up. Always on a display, `margin` from its edges.
    static func discFrame(for area: CGRect, diameter: CGFloat, gap: CGFloat = 12, margin: CGFloat = 8, displays: [CGRect]) -> CGRect {
        let below = CGRect(x: area.midX - diameter / 2, y: area.minY - gap - diameter, width: diameter, height: diameter)
        let above = CGRect(x: area.midX - diameter / 2, y: area.maxY + gap, width: diameter, height: diameter)
        for candidate in [below, above] where displays.contains(where: { $0.insetBy(dx: margin, dy: margin).contains(candidate) }) {
            return candidate
        }
        var inside = CGRect(x: area.midX - diameter / 2, y: area.minY + gap, width: diameter, height: diameter)
        let center = CGPoint(x: inside.midX, y: inside.midY)
        guard let display = displays.first(where: { $0.contains(center) }) ?? displays.first(where: { $0.intersects(area) }) ?? displays.first else {
            return inside
        }
        let room = display.insetBy(dx: margin, dy: margin)
        inside.origin.x = min(max(inside.minX, room.minX), room.maxX - diameter)
        inside.origin.y = min(max(inside.minY, room.minY), room.maxY - diameter)
        return inside
    }
}

/// A countdown panel: borderless and clear, above menus so an opened one cannot cover it, on every
/// Space, never key, and letting clicks through unless configured otherwise (the disc's cancel target).
/// An area's outline (`AreaOutline`) shows in these too.
final class CountdownPanel: NSPanel {
    init(
        frame: CGRect,
        level: NSWindow.Level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1),
        ignoresMouseEvents: Bool = true
    ) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = ignoresMouseEvents
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The disc counting down: the seconds left in the reading face, a ring that runs out with the
/// time, and a small cancel affordance so clicking the disc cancels the countdown without activating the app.
/// Glass over an opaque window-colored backing, as the All-In-One bar is; a solid disc with Reduce Transparency.
final class CountdownDisc: NSView {
    var onCancel: (() -> Void)?

    private let seconds: Int
    private let diameter = SelfTimerCountdown.discDiameter
    private let container: NSView
    private let backing = NSView()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private let cancelBadge = CALayer()
    private let cancelEdge = CAShapeLayer()
    private let cancelSymbol = NSImageView()
    private var sweeps = true
    private var hovering = false
    private var pressed = false

    private static let cancelSize: CGFloat = 20

    init(seconds: Int) {
        self.seconds = seconds
        container = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? NSView() : NSGlassEffectView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        backing.wantsLayer = true
        if let glass = container as? NSGlassEffectView {
            glass.cornerRadius = diameter / 2
            glass.contentView = backing
        } else {
            container.wantsLayer = true
            container.addSubview(backing)
        }
        addSubview(container)
        for line in [track, ring] {
            line.fillColor = nil
            line.lineWidth = 2.5
            line.lineCap = .round
            backing.layer?.addSublayer(line)
        }
        rim.fillColor = nil
        backing.layer?.addSublayer(rim)
        label.font = Theme.Typeface.reading(size: 26, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        backing.addSubview(label)

        cancelBadge.cornerRadius = Self.cancelSize / 2
        cancelBadge.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
        cancelEdge.fillColor = nil
        cancelEdge.lineWidth = 1
        cancelBadge.addSublayer(cancelEdge)
        layer?.addSublayer(cancelBadge)

        cancelSymbol.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        cancelSymbol.contentTintColor = .white
        cancelSymbol.setAccessibilityElement(false)
        addSubview(cancelSymbol)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Cancel countdown", bundle: .module))
        toolTip = String(localized: "Click or press Escape to cancel", bundle: .module)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The disc's own square, centered in the room left around it for the shadow.
    private var discRect: CGRect {
        CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    }

    /// Small circular cancel affordance tucked onto the top-right edge of the disc inside the shadow room.
    private var cancelBadgeRect: CGRect {
        let disc = discRect
        return CGRect(x: disc.maxX - Self.cancelSize + 6, y: disc.maxY - Self.cancelSize + 6, width: Self.cancelSize, height: Self.cancelSize)
    }

    private func containsCancelTarget(_ point: CGPoint) -> Bool {
        let disc = discRect
        if hypot(point.x - disc.midX, point.y - disc.midY) <= disc.width / 2 { return true }
        let badge = cancelBadgeRect
        return hypot(point.x - badge.midX, point.y - badge.midY) <= badge.width / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return containsCancelTarget(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let nowHovering = containsCancelTarget(convert(event.locationInWindow, from: nil))
        if nowHovering != hovering {
            hovering = nowHovering
            applyCancelBadgeAppearance()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hovering {
            hovering = false
            applyCancelBadgeAppearance()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard containsCancelTarget(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.preventWindowOrdering()
        pressed = true
        applyCancelBadgeAppearance()
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = containsCancelTarget(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                applyCancelBadgeAppearance()
                if inside { onCancel?() }
                return
            }
            if pressed != inside {
                pressed = inside
                applyCancelBadgeAppearance()
            }
        }
        pressed = false
        applyCancelBadgeAppearance()
    }

    override func accessibilityPerformPress() -> Bool {
        onCancel?()
        return true
    }

    override func layout() {
        super.layout()
        let disc = discRect
        container.frame = disc
        backing.frame = container.bounds
        backing.layer?.cornerRadius = diameter / 2
        container.layer?.cornerRadius = diameter / 2
        layer?.shadowPath = CGPath(ellipseIn: disc, transform: nil)
        let local = backing.bounds
        // The ring starts at twelve o'clock and runs clockwise; as the time runs out it shrinks back to twelve.
        let center = CGPoint(x: local.midX, y: local.midY)
        let path = CGMutablePath()
        path.addArc(center: center, radius: diameter / 2 - 6, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for line in [track, ring] {
            line.frame = local
            line.path = path
        }
        rim.frame = local
        rim.path = CGPath(ellipseIn: local.insetBy(dx: rim.lineWidth / 2, dy: rim.lineWidth / 2), transform: nil)
        label.sizeToFit()
        label.frame = CGRect(x: 0, y: ((local.height - label.frame.height) / 2).rounded(), width: local.width, height: label.frame.height)

        let badge = cancelBadgeRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cancelBadge.frame = badge
        cancelEdge.frame = cancelBadge.bounds
        cancelEdge.path = CGPath(ellipseIn: cancelBadge.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        CATransaction.commit()
        cancelSymbol.frame = badge
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for line in [track, ring, rim, cancelEdge] { line.contentsScale = scale }
        cancelBadge.contentsScale = scale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Starts the ring: a sweep over the whole countdown, or, with Reduce Motion, a step each second.
    func start(sweeping: Bool) {
        sweeps = sweeping
        guard sweeping else { return }
        let sweep = CABasicAnimation(keyPath: "strokeEnd")
        sweep.fromValue = 1
        sweep.toValue = 0
        sweep.duration = CFTimeInterval(seconds)
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.strokeEnd = 0
        ring.add(sweep, forKey: "sweep")
    }

    func show(remaining: Int) {
        label.stringValue = "\(remaining)"
        setAccessibilityValue(String(localized: "\(remaining) seconds remaining", bundle: .module))
        needsLayout = true
        guard !sweeps else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = CGFloat(remaining) / CGFloat(seconds)
        CATransaction.commit()
    }

    /// Layer colors are fixed values, resolved for this view's appearance and again when it changes.
    /// Increase Contrast gives the disc a firm edge.
    private func applyAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.isDark
            backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            track.strokeColor = NSColor.labelColor.withAlphaComponent(contrast ? 0.3 : 0.12).cgColor
            ring.strokeColor = NSColor.controlAccentColor.cgColor
            rim.lineWidth = contrast ? 1 : 0.5
            rim.strokeColor = contrast ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35)) : NSColor.separatorColor.cgColor
        }
        applyCancelBadgeAppearance()
    }

    private func applyCancelBadgeAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha: CGFloat = pressed ? 0.72 : hovering ? 0.62 : 0.5
        cancelBadge.backgroundColor = CGColor(gray: 0, alpha: alpha)
        cancelEdge.strokeColor = contrast ? CGColor(gray: 1, alpha: 0.7) : nil
    }
}

/// Ephemeral Escape key monitor active only while a countdown runs (zero idle wakeups).
/// Uses a Carbon hot key so Escape cancels even when another app is frontmost, with a local NSEvent fallback.
private final class CountdownEscapeMonitor {
    private nonisolated static let signature: OSType = 0x4F_4D_53_43 // OMSC
    private static var handler: EventHandlerRef?
    private static var armed: [UInt32: Weak] = [:]
    private static var lastID: UInt32 = 0

    private struct Weak {
        weak var monitor: CountdownEscapeMonitor?
    }

    private let id: UInt32
    private let onEscape: () -> Void
    private var hotKey: EventHotKeyRef?
    private var localMonitor: Any?

    init(onEscape: @escaping () -> Void) {
        Self.lastID += 1
        id = Self.lastID
        self.onEscape = onEscape
    }

    isolated deinit {
        disarm()
    }

    func arm() {
        guard hotKey == nil, localMonitor == nil else { return }
        if Self.installHandler() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &ref
            )
            if status == noErr, let ref {
                hotKey = ref
                Self.armed[id] = Weak(monitor: self)
                return
            }
        }
        // Fallback when another global Escape hot key is already registered: catch Escape while OhMyShot is active.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            self?.onEscape()
            return nil
        }
    }

    func disarm() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
            Self.armed[id] = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private static func installHandler() -> Bool {
        guard handler == nil else { return true }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let status = InstallEventHandler(GetEventDispatcherTarget(), countdownEscapeHandler, types.count, &types, nil, &handler)
        if status != noErr {
            Log.capture.error("Countdown Escape handler couldn't be installed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    fileprivate nonisolated static func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else { return OSStatus(eventNotHandledErr) }
        let id = hotKeyID.id
        MainActor.assumeIsolated {
            armed[id]?.monitor?.onEscape()
        }
        return noErr
    }
}

private let countdownEscapeHandler: EventHandlerUPP = { _, event, _ in
    CountdownEscapeMonitor.handle(event)
}
