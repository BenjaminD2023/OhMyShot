import AppKit
import OMSCore
import QuartzCore

/// Self-Timer's countdown: the area about to be captured outlined where it lies, and a small disc
/// counting the seconds down under it, while the screen is set up: a menu opened, a card hovered.
///
/// It takes neither the keyboard nor the pointer, which would close the very menu being set up: its
/// panels never activate the app and let every click through. Like every window of this app, they are
/// left out of the capture.
public final class SelfTimerCountdown {
    public private(set) var isRunning = false

    private var outlinePanels: [CountdownPanel] = []
    private var discPanel: CountdownPanel?
    private var disc: CountdownDisc?
    private var task: Task<Void, Never>?
    private var leases: [ActiveResources.Lease] = []

    static let discDiameter: CGFloat = 64
    /// Room around the disc for its shadow: twice its blur and its drop, so it fades out before the
    /// panel's edge.
    private static let shadowRoom: CGFloat = 24

    public init() {}

    /// Outlines `area` (global points) and counts `seconds` down under it; `finish` runs at zero, once
    /// the countdown has left the screen.
    public func start(seconds: Int, area: CGRect, layout: DisplayLayout, finish: @escaping () -> Void) {
        close()
        let seconds = max(seconds, 1)
        isRunning = true
        leases = [ActiveResources.shared.acquire(.timer), ActiveResources.shared.acquire(.window)]
        // A panel per display: with a Space per display, a window across two shows on only one.
        for display in layout.displays where !display.frame.intersection(area).isEmpty {
            let frame = area.insetBy(dx: -4, dy: -4).intersection(display.frame)
            let panel = CountdownPanel(frame: frame)
            let view = SelectionOutlineView(frame: CGRect(origin: .zero, size: frame.size))
            view.outline = area.offsetBy(dx: -frame.minX, dy: -frame.minY)
            panel.contentView = view
            outlinePanels.append(panel)
        }
        let discFrame = Self.discFrame(for: area, diameter: Self.discDiameter, displays: layout.displays.map(\.frame))
        let panel = CountdownPanel(frame: discFrame.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom))
        let disc = CountdownDisc(seconds: seconds)
        disc.frame = CGRect(origin: .zero, size: panel.frame.size)
        panel.contentView = disc
        discPanel = panel
        self.disc = disc
        // The first second is on the disc before it shows, so it never appears blank.
        disc.show(remaining: seconds)

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

    private func close() {
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
/// Space, never key, and letting every click through to what is under it.
final class CountdownPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
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

/// The area's edge, drawn as the capture overlay draws a selection: white over a soft dark outline.
/// Nothing is dimmed: the screen is in use.
final class SelectionOutlineView: NSView {
    var outline: CGRect = .zero {
        didSet { updatePaths() }
    }

    private let shade = CAShapeLayer()
    private let edge = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        for line in [shade, edge] {
            line.fillColor = nil
            line.lineJoin = .round
            layer?.addSublayer(line)
        }
        shade.lineWidth = Theme.Overlay.borderWidth + 2
        edge.lineWidth = Theme.Overlay.borderWidth
        edge.strokeColor = .white
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        shade.strokeColor = CGColor(gray: 0, alpha: contrast ? Theme.Overlay.outlineOpacityIncreasedContrast : Theme.Overlay.outlineOpacity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        for line in [shade, edge] { line.frame = bounds }
        updatePaths()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for line in [shade, edge] { line.contentsScale = scale }
    }

    private func updatePaths() {
        let path = CGPath(rect: outline, transform: nil)
        shade.path = path
        edge.path = path
    }
}

/// The disc counting down: the seconds left in the reading face, and a ring that runs out with the
/// time. Glass over an opaque window-colored backing, as the All-In-One bar is; a solid disc with
/// Reduce Transparency.
final class CountdownDisc: NSView {
    private let seconds: Int
    private let diameter = SelfTimerCountdown.discDiameter
    private let container: NSView
    private let backing = NSView()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var sweeps = true

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
        setAccessibilityElement(false)
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
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for line in [track, ring, rim] { line.contentsScale = scale }
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
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            track.strokeColor = NSColor.labelColor.withAlphaComponent(contrast ? 0.3 : 0.12).cgColor
            ring.strokeColor = NSColor.controlAccentColor.cgColor
            rim.lineWidth = contrast ? 1 : 0.5
            rim.strokeColor = contrast ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35)) : NSColor.separatorColor.cgColor
        }
    }
}
