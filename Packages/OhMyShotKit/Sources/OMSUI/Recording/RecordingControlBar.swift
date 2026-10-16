import AppKit
import OMSCore
import QuartzCore

/// The small bar beside what is being recorded: the time so far, Pause or Resume, Restart, Delete, and
/// Stop. It never takes the app forward or the keyboard from the app being recorded, and like every
/// window of this app it is left out of the recording. It can be dragged aside by its background.
public final class RecordingControlBar {
    public struct Actions {
        public var pause: () -> Void
        public var resume: () -> Void
        public var restart: () -> Void
        public var delete: () -> Void
        public var stop: () -> Void

        public init(pause: @escaping () -> Void, resume: @escaping () -> Void, restart: @escaping () -> Void, delete: @escaping () -> Void, stop: @escaping () -> Void) {
            self.pause = pause
            self.resume = resume
            self.restart = restart
            self.delete = delete
            self.stop = stop
        }
    }

    private let actions: Actions
    private var panel: ControlBarPanel?
    private var bar: ControlBarView?
    private var lease: ActiveResources.Lease?

    /// Room around the capsule for its shadow.
    static let shadowRoom: CGFloat = 24

    public init(actions: Actions) {
        self.actions = actions
    }

    public var isShowing: Bool { panel != nil }

    /// Shows the bar by `area` (global points): centered under it, above it without room there, inside its
    /// bottom edge when neither has room (a whole display), above `clearing` points at its foot. Always on a
    /// display. With `microphone`, a meter after the time shows how loud the microphone is.
    public func show(by area: CGRect, displays: [CGRect], clearing: CGFloat = 0, microphone: Bool = false) {
        hide()
        let view = ControlBarView(actions: actions, showsMicrophone: microphone)
        let size = view.fittingSize
        let frame = Self.frame(for: size, by: area, inset: max(32, clearing + 12), displays: displays)
        let panel = ControlBarPanel(frame: frame.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom))
        view.frame = CGRect(origin: .zero, size: panel.frame.size)
        panel.contentView = view
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.fade
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        self.panel = panel
        bar = view
        lease = ActiveResources.shared.acquire(.window)
    }

    public func hide() {
        panel?.orderOut(nil)
        panel = nil
        bar = nil
        lease = nil
    }

    /// How loud the microphone has been lately, from 0 to 1 on a meter's scale; call about ten times a second.
    public func update(microphoneLevel: Double) {
        bar?.updateMicrophone(level: microphoneLevel)
    }

    /// Whether the microphone has stopped sending sound: the meter gives way to a warning until it sends again.
    public func update(microphoneStalled: Bool) {
        bar?.updateMicrophone(stalled: microphoneStalled)
    }

    /// The time so far and whether recording is paused. The bar grows when the time does (an hour in),
    /// keeping its middle where it is.
    public func update(elapsed: Duration, paused: Bool) {
        guard let bar, let panel else { return }
        bar.update(elapsed: elapsed, paused: paused)
        let width = bar.fittingSize.width + Self.shadowRoom * 2
        guard width > panel.frame.width + 0.5 else { return }
        var frame = panel.frame
        frame.origin.x -= (width - frame.width) / 2
        frame.size.width = width
        panel.setFrame(frame.integral, display: true)
        bar.frame = CGRect(origin: .zero, size: panel.frame.size)
    }

    /// Where the capsule goes: `gap` under the area, or above it, when a display has room for it there;
    /// inside the area's bottom edge only when neither has. Always on a display, `margin` from its edges.
    static func frame(for size: CGSize, by area: CGRect, gap: CGFloat = 12, inset: CGFloat = 32, margin: CGFloat = 8, displays: [CGRect]) -> CGRect {
        let below = CGRect(x: area.midX - size.width / 2, y: area.minY - gap - size.height, width: size.width, height: size.height)
        let above = CGRect(x: below.minX, y: area.maxY + gap, width: size.width, height: size.height)
        for candidate in [below, above] where displays.contains(where: { $0.insetBy(dx: margin, dy: margin).contains(candidate) }) {
            return candidate.integral
        }
        var inside = CGRect(x: below.minX, y: area.minY + inset, width: size.width, height: size.height)
        let center = CGPoint(x: area.midX, y: area.minY + inset)
        guard let display = displays.first(where: { $0.contains(center) }) ?? displays.first(where: { $0.intersects(area) }) ?? displays.first else {
            return inside.integral
        }
        let room = display.insetBy(dx: margin, dy: margin)
        inside.origin.x = min(max(inside.minX, room.minX), room.maxX - size.width)
        inside.origin.y = min(max(inside.minY, room.minY), room.maxY - size.height)
        return inside.integral
    }

    #if DEBUG
    /// The bar alone in a window behind the desktop picture, for scripted renders that show nothing.
    public static func debugHiddenWindow(elapsed: Duration, paused: Bool, dark: Bool, microphoneLevel: Double? = nil, microphoneStalled: Bool = false) -> NSWindow {
        let view = ControlBarView(actions: Actions(pause: {}, resume: {}, restart: {}, delete: {}, stop: {}), showsMicrophone: microphoneLevel != nil || microphoneStalled)
        view.update(elapsed: elapsed, paused: paused)
        if let microphoneLevel { view.updateMicrophone(level: microphoneLevel) }
        if microphoneStalled { view.updateMicrophone(stalled: true) }
        let size = view.fittingSize
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size.width + shadowRoom * 2, height: size.height + shadowRoom * 2),
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
        view.frame = CGRect(origin: .zero, size: window.frame.size)
        window.contentView = view
        window.orderFront(nil)
        return window
    }
    #endif

    /// Formats a recording's time as the bar and the menu bar show it: 0:42, 12:05, 1:02:09.
    public static func format(_ elapsed: Duration) -> String {
        let total = max(0, Int(elapsed.components.seconds))
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// The control bar's panel: borderless and clear, above Quick Access, pins, and the Dock, on every Space and
/// over full-screen apps, never key, so a click on it never takes the keyboard from the app being recorded.
final class ControlBarPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the Dock: on a whole display the bar sits inside its bottom edge, where the Dock is.
        level = RecordingWindowLevel.chrome
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
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

/// The capsule: a red dot and the time in the reading face, the microphone's meter when it is recorded (a
/// slashed microphone in orange when it stops sending sound), then the four buttons. Glass over an opaque
/// window-colored backing, as the All-In-One bar is; a solid capsule with Reduce Transparency.
private final class ControlBarView: NSView {
    private let actions: RecordingControlBar.Actions
    private let container: NSView
    private let backing = NSView()
    /// The capsule's hairline, drawn inside the backing as the countdown disc's rim is.
    private let rim = CAShapeLayer()
    private let stack = NSStackView()
    private let dot = NSView()
    private let time = NSTextField(labelWithString: "0:00")
    /// The system's microphone-with-meter symbol, its dots lit by how loud the microphone is.
    private let meter = NSImageView()
    private let showsMicrophone: Bool
    /// What the meter shows: it rises at once and falls back gently, as meters do.
    private var shownLevel = 0.0
    /// The meter's lit dots, in fifths, so the symbol is drawn again only when they change.
    private var litSteps = -1
    /// The microphone stopped sending sound: the meter shows a warning instead of the level.
    private var stalled = false
    private let pauseButton = CardButton(style: .barIcon, title: String(localized: "Pause", bundle: .module), symbolName: "pause.fill")
    private let restartButton = CardButton(style: .barIcon, title: String(localized: "Restart", bundle: .module), symbolName: "arrow.counterclockwise")
    private let deleteButton = CardButton(style: .barIcon, title: String(localized: "Delete", bundle: .module), symbolName: "trash")
    private let stopButton = CardButton(style: .barIcon, title: String(localized: "Stop", bundle: .module), symbolName: "stop.fill")
    private var paused = false
    private static let height: CGFloat = 42

    init(actions: RecordingControlBar.Actions, showsMicrophone: Bool = false) {
        self.actions = actions
        self.showsMicrophone = showsMicrophone
        container = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? NSView() : NSGlassEffectView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        time.font = Theme.Typeface.reading(size: 13, weight: .semibold)
        time.textColor = .labelColor
        time.setAccessibilityElement(false)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 6)
        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(time)
        stack.setCustomSpacing(6, after: dot)
        stack.setCustomSpacing(10, after: time)
        if showsMicrophone {
            meter.contentTintColor = .labelColor
            meter.setAccessibilityElement(false)
            meter.toolTip = String(localized: "Microphone level", bundle: .module)
            meter.translatesAutoresizingMaskIntoConstraints = false
            meter.widthAnchor.constraint(equalToConstant: 18).isActive = true
            meter.heightAnchor.constraint(equalToConstant: 18).isActive = true
            stack.addArrangedSubview(meter)
            stack.setCustomSpacing(8, after: meter)
            updateMicrophone(level: 0)
        }
        for (button, action) in [(pauseButton, #selector(pauseClicked)), (restartButton, #selector(restartClicked)), (deleteButton, #selector(deleteClicked)), (stopButton, #selector(stopClicked))] {
            button.target = self
            button.action = action
            stack.addArrangedSubview(button)
        }
        stopButton.symbolTint = .systemRed
        stopButton.title = String(localized: "Stop Recording", bundle: .module)
        restartButton.title = String(localized: "Restart Recording", bundle: .module)
        deleteButton.title = String(localized: "Delete Recording", bundle: .module)

        backing.wantsLayer = true
        backing.addSubview(stack)
        rim.fillColor = nil
        backing.layer?.addSublayer(rim)
        if let glass = container as? NSGlassEffectView {
            glass.contentView = backing
        } else {
            container.wantsLayer = true
            container.addSubview(backing)
        }
        addSubview(container)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Recording controls", bundle: .module))
        update(elapsed: .zero, paused: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var fittingSize: NSSize {
        // Room for the longest time a short recording shows, so the bar does not grow every ten minutes.
        let width = stack.fittingSize.width + max(0, ceil(("00:00" as NSString).size(withAttributes: [.font: time.font!]).width) - time.fittingSize.width)
        return NSSize(width: width, height: Self.height)
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
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rim.contentsScale = window?.backingScaleFactor ?? 2
    }

    func updateMicrophone(level: Double) {
        guard showsMicrophone, !stalled else { return }
        // Up at once, down by a fifth of the scale in about 0.3 s.
        shownLevel = max(min(level, 1), shownLevel - 0.07)
        let steps = Int((shownLevel * 5).rounded())
        guard steps != litSteps else { return }
        litSteps = steps
        meter.image = NSImage(systemSymbolName: "mic.and.signal.meter.fill", variableValue: Double(steps) / 5, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    /// A microphone that stopped sending sound shows `mic.slash` in system orange in the meter's place, and says
    /// why in its tooltip and to VoiceOver; the meter comes back when sound does.
    func updateMicrophone(stalled: Bool) {
        guard showsMicrophone, stalled != self.stalled else { return }
        self.stalled = stalled
        let warning = String(localized: "The microphone stopped sending sound. It may have been disconnected.", bundle: .module)
        meter.contentTintColor = stalled ? .systemOrange : .labelColor
        meter.toolTip = stalled ? warning : String(localized: "Microphone level", bundle: .module)
        meter.setAccessibilityElement(stalled)
        meter.setAccessibilityLabel(stalled ? warning : nil)
        if stalled {
            meter.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        } else {
            litSteps = -1
            updateMicrophone(level: shownLevel)
        }
    }

    func update(elapsed: Duration, paused: Bool) {
        let text = RecordingControlBar.format(elapsed)
        if time.stringValue != text { time.stringValue = text }
        if paused != self.paused {
            self.paused = paused
            pauseButton.symbolName = paused ? "play.fill" : "pause.fill"
            pauseButton.title = paused ? String(localized: "Resume", bundle: .module) : String(localized: "Pause", bundle: .module)
            applyAppearance()
        }
        setAccessibilityValue(paused
            ? String(localized: "Paused at \(text)", bundle: .module)
            : String(localized: "Recording, \(text)", bundle: .module))
    }

    /// The dot is red while recording and gray while paused; the time steps back to secondary ink then.
    private func applyAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            rim.lineWidth = contrast ? 1 : 0.5
            rim.strokeColor = contrast
                ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35))
                : NSColor.separatorColor.cgColor
            dot.layer?.backgroundColor = paused ? NSColor.tertiaryLabelColor.cgColor : NSColor.systemRed.cgColor
        }
        time.textColor = paused ? .secondaryLabelColor : .labelColor
    }

    @objc private func pauseClicked() {
        paused ? actions.resume() : actions.pause()
    }

    @objc private func restartClicked() { actions.restart() }
    @objc private func deleteClicked() { actions.delete() }
    @objc private func stopClicked() { actions.stop() }
}
