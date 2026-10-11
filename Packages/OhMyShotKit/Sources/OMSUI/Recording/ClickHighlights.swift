import AppKit
import OMSCore
import QuartzCore

/// Clicks drawn as rings where they land, recorded with what is recorded: an accent ring that widens and
/// fades at each press, the other way to show clicks than the system's own circles.
///
/// A clear, click-through window lies over what is recorded for as long as it records, so the recording's
/// filter takes it in from the start; only the rings come and go. Presses are seen by a global monitor,
/// which needs no permission for the mouse, and which never sees presses on this app's own windows, so the
/// control bar's buttons draw no rings.
public final class ClickHighlights {
    private var panel: NSPanel?
    private var monitor: Any?
    private var area: CGRect = .zero

    /// The ring's diameter as it starts and as it ends, and how long it takes.
    private static let startSize: CGFloat = 18
    private static let endSize: CGFloat = 54
    private static let duration: CFTimeInterval = 0.4

    public init() {}

    /// The window, for the recording's filter to take in; nil until shown.
    public var windowID: CGWindowID? {
        panel.map { CGWindowID($0.windowNumber) }
    }

    /// Lies over `area` (global points) and starts drawing rings at presses inside it.
    public func show(over area: CGRect) {
        self.area = area
        let panel = self.panel ?? makePanel()
        panel.setFrame(area, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                // Global monitors are called on the main thread.
                MainActor.assumeIsolated { self?.ring(at: NSEvent.mouseLocation, secondary: event.type != .leftMouseDown) }
            }
        }
    }

    public func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // With the keystrokes: above what is recorded and the Dock, under menus.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    /// A ring at `point` (global points) when it is inside what is recorded: the accent, a dimmer one for
    /// other buttons than the main one.
    private func ring(at point: CGPoint, secondary: Bool) {
        guard let ring = addRing(at: point, secondary: secondary) else { return }

        let start = Self.startSize / Self.endSize
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak ring] in ring?.removeFromSuperlayer() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // No motion: the ring shows at its size and goes.
            let hold = CABasicAnimation(keyPath: "opacity")
            hold.fromValue = 1
            hold.toValue = 1
            hold.duration = Self.duration
            ring.opacity = 0
            ring.add(hold, forKey: "hold")
        } else {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = start
            grow.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = Self.duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.opacity = 0
            ring.add(group, forKey: "ring")
        }
        CATransaction.commit()
    }

    /// The ring for a press at `point` (global points), added over what is recorded at its full size; nil
    /// outside it.
    private func addRing(at point: CGPoint, secondary: Bool) -> CAShapeLayer? {
        guard let panel, let host = panel.contentView?.layer, area.contains(point) else { return nil }
        let ring = CAShapeLayer()
        let bounds = CGRect(x: 0, y: 0, width: Self.endSize, height: Self.endSize)
        ring.bounds = bounds
        ring.position = CGPoint(x: point.x - area.minX, y: point.y - area.minY)
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ring.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        ring.strokeColor = NSColor.controlAccentColor.withAlphaComponent(secondary ? 0.55 : 0.9).cgColor
        ring.lineWidth = 3
        ring.contentsScale = panel.backingScaleFactor
        host.addSublayer(ring)
        return ring
    }

    #if DEBUG
    /// Draws a ring as a press would, for scripted checks; `hold` leaves it still at its middle size for a
    /// render instead of animating it away.
    public func debugRing(at point: CGPoint, hold: Bool) {
        guard hold else { return ring(at: point, secondary: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addRing(at: point, secondary: false)?.transform = CATransform3DMakeScale(0.7, 0.7, 1)
        CATransaction.commit()
    }

    /// Lies over `area` behind the desktop picture, for rendering checks; returns the window.
    public func debugShowBehindWallpaper(over area: CGRect) -> NSWindow? {
        show(over: area)
        panel?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        return panel
    }
    #endif
}
