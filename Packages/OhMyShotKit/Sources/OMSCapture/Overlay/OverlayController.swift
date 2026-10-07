import AppKit
import CoreGraphics
import OMSCore
import OSLog
import QuartzCore

/// Runs one selection session across every display.
///
/// The overlay appears first and the captures follow: the panels order front synchronously on the
/// hotkey, then each display's frame loads in the background (the pointer's display first) for the
/// loupe, or as the backdrop when the screen is frozen.
public final class OverlayController {
    public enum Outcome: Sendable {
        /// `modifiers` are the keys held when the mouse was released (Capture Text opens the OCR panel
        /// with Option), read from that event: a later global read would race the keys' release.
        case region(CGRect, display: DisplayInfo, modifiers: NSEvent.ModifierFlags)
        case window(WindowTarget, modifiers: NSEvent.ModifierFlags)
        case cancelled
    }

    /// What the capture is for: a screenshot, or text to copy. Text gets a lighter overlay: no All-In-One
    /// bar (its modes are screenshot modes), no dimming, no magnifier or readings, the system crosshair.
    public enum Purpose: Sendable {
        case screenshot
        case text
    }

    public enum Mode: Sendable {
        case area
        case window
    }

    /// Hold the screen still while selecting, so hover states and menus can be captured.
    public var freezesScreen = false
    private var hidesCursor = false

    public private(set) var isActive = false

    private struct Entry {
        let panel: OverlayPanel
        let view: OverlayView
    }

    private let topology: DisplayTopology
    private let capturer: ScreenCapturer
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var completion: ((Outcome) -> Void)?
    private var previousApp: NSRunningApplication?
    private var session = 0
    private var firstFrameArrived = false
    private var frameLeases: [ActiveResources.Lease] = []
    private var windowLease: ActiveResources.Lease?
    private var windows: [WindowTarget] = []

    public init(topology: DisplayTopology, capturer: ScreenCapturer) {
        self.topology = topology
        self.capturer = capturer
    }

    /// Creates the panels for the current displays ahead of time, so the hotkey only has to show them.
    public func prepare() {
        let layout = topology.layout
        for (id, entry) in entries where layout.display(id: id) != entry.view.display {
            entry.panel.orderOut(nil)
            entries[id] = nil
        }
        for display in layout.displays where entries[display.id] == nil {
            let panel = OverlayPanel(frame: display.frame)
            let view = OverlayView(display: display)
            view.delegate = self
            panel.contentView = view
            entries[display.id] = Entry(panel: panel, view: view)
        }
    }

    public func begin(mode: Mode = .area, purpose: Purpose = .screenshot, completion: @escaping (Outcome) -> Void) {
        guard !isActive else { return }
        let visible = LatencyProbe("overlay.visible")
        let frozen = LatencyProbe("overlay.frozen")
        isActive = true
        session += 1
        firstFrameArrived = false
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }

        prepare()
        let pointer = NSEvent.mouseLocation
        let layout = topology.layout
        let pointerDisplay = layout.display(at: pointer) ?? layout.primary

        // Active, so the overlay owns the keyboard and the pointer. The app stays an accessory, so no
        // Dock icon appears, and the overlay covers the menu bar while it is ours.
        NSApp.activate()
        // The window list is read only when windows are the target; area capture never pays for it.
        windows = mode == .window ? WindowCatalog.snapshot(layout: layout) : []
        let viewMode: OverlayView.Mode = mode == .window ? .window : .area
        for (id, entry) in entries {
            entry.view.reset(
                pointer: pointer, mode: viewMode, windows: windows,
                showsToolbar: id == pointerDisplay?.id && purpose == .screenshot,
                purpose: purpose
            )
        }
        // The panels are reused: the reset layers are committed before any panel is ordered in, so none
        // shows a frame of its previous session.
        CATransaction.flush()
        for entry in entries.values {
            entry.panel.orderFrontRegardless()
        }
        if let id = pointerDisplay?.id, let view = entries[id]?.view {
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                .announcement: purpose == .text
                    ? String(localized: "Drag over text to copy it, or press Space to choose a window.")
                    : String(localized: "Drag to capture an area, or press Space to capture a window."),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        if let id = pointerDisplay?.id, let entry = entries[id] {
            entry.panel.makeKey()
            entry.panel.makeFirstResponder(entry.view)
        }
        // A screenshot draws its own crosshair and magnifier; copying text keeps the system crosshair.
        hidesCursor = purpose == .screenshot
        if hidesCursor { NSCursor.hide() }
        CATransaction.flush()
        visible.end()
        windowLease = ActiveResources.shared.acquire(.window)

        let session = self.session
        // Text without freezing shows no frame, but the pointer display's still arrives first: it tells
        // the watchdog that capturing works.
        let others = purpose == .text && !freezesScreen ? [] : layout.displays.filter { $0.id != pointerDisplay?.id }
        let ordered = [pointerDisplay].compactMap(\.self) + others
        Task { [weak self] in
            await self?.loadFrames(for: ordered, session: session, probe: frozen)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.watchdog(session: session)
        }
    }

    public func cancel() {
        end(.cancelled)
    }

    /// Draws a selection and pointer without mouse input, for scripted checks of the rendering.
    public func simulate(selection rect: CGRect, pointer: CGPoint) {
        guard isActive, let display = topology.layout.display(at: rect.origin) else { return }
        entries[display.id]?.view.simulate(selection: rect, pointer: pointer)
    }

    /// Whether every display's frame has arrived, for scripted checks.
    public var hasFrames: Bool { frameLeases.count == entries.count }

    /// Panel visibility per display, for scripted checks.
    public var panelStates: String {
        entries.map { id, entry in
            "\(id): visible=\(entry.panel.isVisible) onActiveSpace=\(entry.panel.isOnActiveSpace) occluded=\(!entry.panel.occlusionState.contains(.visible)) key=\(entry.panel.isKeyWindow)"
        }.sorted().joined(separator: "; ")
    }

    private func loadFrames(for displays: [DisplayInfo], session: Int, probe: LatencyProbe) async {
        for (index, display) in displays.enumerated() {
            do {
                let frame = try await capturer.captureDisplay(display)
                guard isActive, session == self.session else { return }
                entries[display.id]?.view.show(frame, frozen: freezesScreen)
                frameLeases.append(ActiveResources.shared.acquire(.frameBuffer))
                if index == 0 {
                    firstFrameArrived = true
                    probe.end()
                }
            } catch {
                Log.capture.error("Overlay frame for display \(display.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if index == 0, isActive, session == self.session { end(.cancelled) }
                return
            }
        }
    }

    /// The first frame normally lands within about 50 ms. If it has not after half a second, macOS is
    /// most likely asking the user to confirm Screen Recording, and the overlay would hide that prompt.
    private func watchdog(session: Int) {
        guard isActive, session == self.session, !firstFrameArrived else { return }
        Log.capture.notice("Overlay dismissed: no frame after 500 ms")
        end(.cancelled)
    }

    private func end(_ outcome: Outcome) {
        guard isActive else { return }
        isActive = false
        for entry in entries.values {
            entry.panel.orderOut(nil)
            entry.view.clear()
        }
        if hidesCursor { NSCursor.unhide() }
        hidesCursor = false
        frameLeases.removeAll()
        windowLease = nil
        windows = []
        if let previousApp {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        previousApp = nil
        MemoryRelief.returnFreedPages()
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }
}

extension OverlayController: OverlayViewDelegate {
    func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags) {
        end(.region(rect, display: view.display, modifiers: modifiers))
    }

    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) {
        end(.window(target, modifiers: modifiers))
    }

    func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode) {
        if mode == .window, windows.isEmpty {
            windows = WindowCatalog.snapshot(layout: topology.layout)
        }
        for entry in entries.values {
            entry.view.switchMode(to: mode, windows: windows)
        }
    }

    func overlayViewDidCancel(_ view: OverlayView) {
        end(.cancelled)
    }
}
