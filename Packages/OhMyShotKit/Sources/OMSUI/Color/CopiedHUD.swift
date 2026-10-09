import AppKit
import OMSCore

/// What was just copied, in a reading capsule by the point it came from, for a moment: a picked color with
/// its swatch, or a measurement. It takes no clicks and no focus and goes by itself, as a pin's reading
/// does: it shows at once, stays 0.9 s, and fades over 0.12 s.
public final class CopiedHUD {
    private var panel: NSPanel?
    private let reading = ReadingCapsule(showsSwatch: true)
    private var fade: Task<Void, Never>?
    private var windowLease: ActiveResources.Lease?
    /// Room around the capsule for its shadow.
    private static let margin: CGFloat = 16

    public init() {}

    /// Shows `text`, led by `swatch` for a color, by `point` in AppKit's global coordinates.
    public func show(_ text: String, swatch: CGColor? = nil, near point: CGPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reading.setScale(screen?.backingScaleFactor ?? 2)
        reading.applyAppearance(dark: dark, contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        reading.swatch = swatch
        reading.text = text
        reading.layer.isHidden = false
        reading.layer.frame.origin = CGPoint(x: Self.margin, y: Self.margin)
        CATransaction.commit()
        // Below and right of the point, where the magnifier's reading was, turned away from the screen's edges.
        let size = reading.layer.bounds.size
        let visible = screen?.visibleFrame ?? CGRect(origin: point, size: .zero).insetBy(dx: -500, dy: -500)
        var origin = CGPoint(x: point.x + 14, y: point.y - 14 - size.height)
        if origin.x + size.width > visible.maxX - 6 { origin.x = point.x - 14 - size.width }
        if origin.y < visible.minY + 6 { origin.y = point.y + 14 }
        let frame = CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height).insetBy(dx: -Self.margin, dy: -Self.margin)
        panel.setFrame(frame.integral, display: false)
        fade?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        windowLease = windowLease ?? ActiveResources.shared.acquire(.window)
        if let view = panel.contentView {
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        fade = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        fade = Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            self?.windowLease = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Over everything, the measuring overlay included (⌘C copies while it stays), and click-through.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(reading.layer)
        panel.contentView = view
        return panel
    }
}
