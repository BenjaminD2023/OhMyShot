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
        /// In-place annotation finished (`finishAnnotation`); its own handler has the result.
        case annotated
        case cancelled
    }

    /// What the capture is for: a screenshot, or text to copy. Text gets a lighter overlay: no All-In-One
    /// bar (its modes are screenshot modes), no dimming, no magnifier or readings, the system crosshair.
    public enum Purpose: Sendable {
        case screenshot
        case text
        /// Mark up the selection in place: the screen freezes, and once an area (or a window) is chosen
        /// the overlay stays, handing its display's frozen frame to `onAnnotate`.
        case annotate
    }

    /// What in-place annotation is given once its area is chosen: the view to host its interface (the
    /// overlay of that display, y up, covering the display), the display, the chosen area in global
    /// points, and the display's frozen frame. End it with `finishAnnotation()` or `cancel()`.
    public struct AnnotationRequest {
        public let host: NSView
        public let display: DisplayInfo
        public let area: CGRect
        public let frame: CapturedFrame
    }

    /// Starts in-place annotation over the overlay; set by whoever owns the annotation interface.
    public var onAnnotate: ((AnnotationRequest) -> Void)?

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
    private var purpose: Purpose = .screenshot
    /// An area chosen for annotation before its display's frame arrived.
    private var pendingAnnotation: (display: CGDirectDisplayID, area: CGRect)?
    #if DEBUG
    /// Frames to show instead of capturing the screen, for scripted checks of the overlay that must never
    /// record what is on screen.
    public var injectedFrames: [CGDirectDisplayID: CapturedFrame]?
    #endif

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
        self.purpose = purpose
        pendingAnnotation = nil
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
                showsToolbar: id == pointerDisplay?.id && purpose != .text,
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
            let announcement = switch purpose {
            case .text: String(localized: "Drag over text to copy it, or press Space to choose a window.")
            case .annotate: String(localized: "Drag over an area to mark it up, or press Space to choose a window.")
            case .screenshot: String(localized: "Drag to capture an area, or press Space to capture a window.")
            }
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        if let id = pointerDisplay?.id, let entry = entries[id] {
            entry.panel.makeKey()
            entry.panel.makeFirstResponder(entry.view)
        }
        // A screenshot draws its own crosshair and magnifier; copying text keeps the system crosshair.
        hidesCursor = purpose != .text
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

    /// Ends in-place annotation: the overlay goes away and the previous app gets the keyboard back.
    public func finishAnnotation() {
        end(.annotated)
    }

    /// Whether in-place annotation is showing, for scripted checks.
    public var isAnnotating: Bool {
        isActive && entries.values.contains { $0.view.isAnnotating }
    }

    /// Draws a selection and pointer without mouse input, for scripted checks of the rendering.
    public func simulate(selection rect: CGRect, pointer: CGPoint) {
        guard isActive, let display = topology.layout.display(at: rect.origin) else { return }
        entries[display.id]?.view.simulate(selection: rect, pointer: pointer)
    }

    #if DEBUG
    /// Chooses an area for in-place annotation without mouse input, for scripted checks.
    public func simulateAnnotation(selection rect: CGRect) {
        guard isActive, purpose == .annotate, let display = topology.layout.display(at: CGPoint(x: rect.midX, y: rect.midY)) else { return }
        entries[display.id]?.view.simulate(selection: rect, pointer: CGPoint(x: rect.maxX, y: rect.minY))
        startAnnotating(on: display.id, area: rect)
    }
    #endif

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
                let frame: CapturedFrame
                #if DEBUG
                if let injected = injectedFrames?[display.id] {
                    frame = injected
                } else {
                    frame = try await capturer.captureDisplay(display)
                }
                #else
                frame = try await capturer.captureDisplay(display)
                #endif
                guard isActive, session == self.session else { return }
                // Annotating in place draws on the frozen screen, so it always holds still.
                entries[display.id]?.view.show(frame, frozen: freezesScreen || purpose == .annotate)
                frameLeases.append(ActiveResources.shared.acquire(.frameBuffer))
                if index == 0 {
                    firstFrameArrived = true
                    probe.end()
                }
                if let pending = pendingAnnotation, pending.display == display.id {
                    pendingAnnotation = nil
                    startAnnotating(on: display.id, area: pending.area)
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

    /// Hands the chosen area to in-place annotation, once its display's frozen frame is there.
    private func startAnnotating(on displayID: CGDirectDisplayID, area: CGRect) {
        guard let entry = entries[displayID] else { return }
        guard let frame = entry.view.frame(), let onAnnotate else {
            pendingAnnotation = (displayID, area)
            return
        }
        // The pointer is the system's again: marks need the arrow, the I-beam, and the resize cursors.
        if hidesCursor { NSCursor.unhide() }
        hidesCursor = false
        // Only this display stays: the others would start selections of their own.
        for (id, other) in entries where id != displayID {
            other.panel.orderOut(nil)
            other.view.clear()
        }
        entry.view.enterAnnotation()
        entry.panel.makeKey()
        onAnnotate(AnnotationRequest(host: entry.view, display: entry.view.display, area: area, frame: frame))
    }

    private func end(_ outcome: Outcome) {
        guard isActive else { return }
        isActive = false
        pendingAnnotation = nil
        #if DEBUG
        injectedFrames = nil
        #endif
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
        if purpose == .annotate {
            startAnnotating(on: view.display.id, area: rect)
            return
        }
        end(.region(rect, display: view.display, modifiers: modifiers))
    }

    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) {
        if purpose == .annotate {
            // A window is annotated where it is on the frozen screen.
            let area = target.frame.intersection(view.display.frame)
            if !area.isNull, area.width >= 1, area.height >= 1 { startAnnotating(on: view.display.id, area: area) }
            return
        }
        end(.window(target, modifiers: modifiers))
    }

    func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode) {
        // Once an area is chosen for annotation, even while its frame is still on the way, it stays chosen.
        guard pendingAnnotation == nil, !isAnnotating else { return }
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
