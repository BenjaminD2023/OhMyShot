import AppKit
import OMSCore

/// Capture Text's only feedback by default: the selection, drawn like selected text, stays where it was
/// while the text is read, then fades. A click-through panel that never takes focus, drawn exactly like
/// the overlay's text selection and at the overlay's level, so letting go of the mouse looks like one
/// continuous gesture.
public final class TextSelectionHighlight {
    private var panel: NSPanel?
    private var shape: CAShapeLayer?
    private var breathing: Task<Void, Never>?
    private var windowLease: ActiveResources.Lease?

    public init() {}

    /// Shows the highlight over `selection`, in AppKit's global coordinates, until `finish`. When the
    /// text takes more than a second to read (a model's first use), the highlight breathes slowly so it
    /// does not look stuck.
    public func show(_ selection: CGRect) {
        let panel = self.panel ?? makePanel()
        panel.setFrame(selection.integral, display: false)
        if let shape {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = CGRect(origin: .zero, size: panel.frame.size)
            applyStyle()
            CATransaction.commit()
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }

        breathing?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        breathing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let shape = self?.shape else { return }
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.5
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(breathe, forKey: "breathe")
        }
    }

    /// Fades the highlight: slowly once `copied` text is on the clipboard, quickly with a beep when
    /// there was none (`nil`). Instant with Reduce Motion. `announces` tells VoiceOver the count or the
    /// empty result, for when no card does; `formula` says what Capture Formula copied, or didn't.
    public func finish(copied text: String?, announces: Bool, formula: Bool = false) {
        breathing?.cancel()
        breathing = nil
        if text == nil { NSSound.beep() }
        if announces {
            let message = if formula {
                text == nil ? String(localized: "No formula found", bundle: .module) : String(localized: "Copied the formula as LaTeX", bundle: .module)
            } else {
                text.map(TextResultCard.copiedCount) ?? String(localized: "No text found", bundle: .module)
            }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        guard let panel else { return }
        self.panel = nil
        shape?.removeAnimation(forKey: "breathe")
        shape = nil
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (text == nil ? 0.15 : 0.35)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            panel.orderOut(nil)
            if self?.panel == nil {
                self?.windowLease = nil
                // The reading is done by now, and what it used freed (the selection's pixels, a TIFF's buffers): its
                // pages go back, as the card's do when it goes.
                MemoryRelief.returnFreedPages()
            }
        }
    }

    /// Takes the highlight away at once, without a sound: something else now shows the result, over it.
    public func hide() {
        breathing?.cancel()
        breathing = nil
        guard let panel else { return }
        self.panel = nil
        shape?.removeAnimation(forKey: "breathe")
        shape = nil
        panel.orderOut(nil)
        windowLease = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // The overlay's level: a selection over the menu bar, the Dock, or a frozen menu stays visible.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        let shape = CAShapeLayer()
        view.layer?.addSublayer(shape)
        panel.contentView = view
        self.panel = panel
        self.shape = shape
        return panel
    }

    /// The overlay's text selection: the system's selection color, lightly filled, edged in the accent;
    /// a 2 pt edge with Increase Contrast. The color is resolved for the appearance before its alpha is
    /// applied, which would otherwise fix it to the light value.
    private func applyStyle() {
        guard let shape, let appearance = panel?.effectiveAppearance else { return }
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let edge: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        shape.lineWidth = edge
        shape.path = CGPath(rect: shape.bounds.insetBy(dx: edge / 2, dy: edge / 2), transform: nil)
        shape.fillColor = Theme.cgColor(.selectedTextBackgroundColor, for: appearance).copy(alpha: dark ? 0.45 : 0.35)
        shape.strokeColor = Theme.cgColor(.controlAccentColor, for: appearance)
    }
}
