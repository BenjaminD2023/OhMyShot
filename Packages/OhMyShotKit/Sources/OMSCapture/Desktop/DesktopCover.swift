import AppKit
import OMSCore
import OSLog
import QuartzCore

/// Hide Desktop Icons: a picture of the wallpaper laid over the icons on every display, one level above them, so
/// every window stays above it and Finder is never restarted. The picture is the wallpaper's own windows as they
/// show, a dynamic or a photo wallpaper alike; without Screen Recording it is drawn from the wallpaper's file.
///
/// Clicks land on the picture, so icons that cannot be seen are never selected or opened; the desktop's own menu
/// goes with them while the icons are hidden. Captures take the covers in (`windowIDs`): a screenshot shows the
/// desktop as it looks.
public final class DesktopCover {
    public private(set) var isShown = false
    /// Covers came or went: what can be captured is out of date.
    public var onChange: (() -> Void)?
    /// Whether the wallpaper's windows may be read (Screen Recording is on). When not, the picture is drawn from the
    /// wallpaper's file: asking ScreenCaptureKit would bring up macOS's permission prompt.
    public var canReadScreen: () -> Bool = { false }

    /// The covers' windows, for the captures to take in.
    public var windowIDs: Set<CGWindowID> {
        Set(panels.values.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
    }

    /// Each cover's window, level, frame, and state, for scripted checks.
    public var debugSummary: String {
        guard !panels.isEmpty else { return "no covers" }
        return panels.values.map { panel in
            let contents = panel.contentView?.layer?.contents.map { $0 as CFTypeRef }
            let size = if let contents, CFGetTypeID(contents) == CGImage.typeID {
                "\((contents as! CGImage).width)x\((contents as! CGImage).height)"
            } else {
                contents == nil ? "no picture" : "a file's picture"
            }
            return "window \(panel.windowNumber) level \(panel.level.rawValue) frame \(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) canBecomeKey=\(panel.canBecomeKey) nonactivating=\(panel.styleMask.contains(.nonactivatingPanel)) ignoresMouse=\(panel.ignoresMouseEvents) picture=\(size)"
        }.joined(separator: "; ")
    }

    private enum Picture {
        case captured(CGImage)
        case file(NSImage, gravity: CALayerContentsGravity, fill: NSColor)
        case color(NSColor)
    }

    private let topology: DisplayTopology
    private let capturer: ScreenCapturer
    private var panels: [CGDirectDisplayID: CoverPanel] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Whether the user's persistent Hide Desktop Icons toggle is on.
    private var persistentShown = false
    /// Reference count for ephemeral captures/recordings ("Hide desktop icons while capturing").
    private var temporaryHideCount = 0
    /// Counts the refreshes, so a slow capture never replaces a later one's picture.
    private var generation = 0
    private var lease: ActiveResources.Lease?
    /// A refresh asked for by a Space switch, a wake, or Dark Mode: one for a burst of them, once the switch is over.
    private var pendingRefresh: Task<Void, Never>?
    /// The in-flight refresh capturing/drawing wallpaper panels.
    private var refreshTask: Task<Void, Never>?

    public init(topology: DisplayTopology, capturer: ScreenCapturer) {
        self.topology = topology
        self.capturer = capturer
    }

    /// Whether an ephemeral capture/recording currently holds a temporary hide lease.
    public var isTemporarilyHidden: Bool { temporaryHideCount > 0 }

    public func setShown(_ shown: Bool) {
        guard shown != persistentShown else { return }
        persistentShown = shown
        updateVisibility()
    }

    /// Reference-counted ephemeral hide for "Hide desktop icons while capturing": shows the cover without
    /// altering the persistent toggle, and tears it down automatically when the matching `endTemporaryHide()` ends.
    public func beginTemporaryHide() {
        temporaryHideCount += 1
        updateVisibility()
    }

    /// Releases one temporary hide lease acquired via `beginTemporaryHide()`.
    public func endTemporaryHide() {
        guard temporaryHideCount > 0 else { return }
        temporaryHideCount -= 1
        updateVisibility()
    }

    /// Awaits any wallpaper refresh currently in flight (for example, after `beginTemporaryHide()` before capturing).
    public func waitForRefresh() async {
        await refreshTask?.value
    }

    private func updateVisibility() {
        let shouldShow = persistentShown || temporaryHideCount > 0
        guard shouldShow != isShown else { return }
        isShown = shouldShow
        Log.capture.notice("Desktop icons \(shouldShow ? "hidden" : "shown", privacy: .public)")
        if shouldShow {
            observe()
            lease = ActiveResources.shared.acquire(.window)
            refresh()
        } else {
            generation += 1
            pendingRefresh?.cancel()
            pendingRefresh = nil
            refreshTask?.cancel()
            refreshTask = nil
            for (center, observer) in observers { center.removeObserver(observer) }
            observers = []
            for panel in panels.values { panel.orderOut(nil) }
            panels = [:]
            lease = nil
            onChange?()
            MemoryRelief.returnFreedPages()
        }
    }

    /// Takes the wallpaper's picture again on the displays there are now: the arrangement, the Space, or the
    /// appearance changed (a dynamic wallpaper follows Dark Mode).
    public func refresh() {
        guard isShown else { return }
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshTask?.cancel()
        generation += 1
        let generation = generation
        let layout = topology.layout
        let gone = panels.keys.filter { layout.display(id: $0) == nil }
        for id in gone {
            panels[id]?.orderOut(nil)
            panels[id] = nil
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var captured: [CGDirectDisplayID: CGImage] = [:]
            if canReadScreen() {
                do {
                    captured = try await capturer.captureWallpapers(of: layout.displays)
                } catch {
                    Log.capture.notice("Wallpaper not captured (\(String(describing: error), privacy: .public)): drawn from its file")
                }
            }
            guard isShown, generation == self.generation, !Task.isCancelled else { return }
            let new = layout.displays.filter { panels[$0.id] == nil }
            for display in layout.displays {
                show(captured[display.id].map(Picture.captured) ?? Self.drawnPicture(of: display), on: display)
            }
            // Only new or gone covers matter to the captures; one already known keeps its window.
            if !new.isEmpty || !gone.isEmpty { onChange?() }
        }
    }

    /// A refresh once a burst of Space switches, wakes, or appearance changes is over, the switch's animation done.
    private func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// The wallpaper drawn from its file as the desktop draws it (scaled, cropped, or centered on its fill color),
    /// for when its windows cannot be read.
    private static func drawnPicture(of display: DisplayInfo) -> Picture {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.id }) else { return .color(.windowBackgroundColor) }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let fill = options[.fillColor] as? NSColor ?? .black
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) else { return .color(fill) }
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clips = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let gravity: CALayerContentsGravity = switch scaling {
        case .scaleAxesIndependently: .resize
        case .scaleNone: .center
        default: clips ? .resizeAspectFill : .resizeAspect
        }
        return .file(image, gravity: gravity, fill: fill)
    }

    private func show(_ picture: Picture, on display: DisplayInfo) {
        let panel = panels[display.id] ?? CoverPanel(display: display)
        panels[display.id] = panel
        panel.setFrame(display.frame, display: false)
        guard let layer = panel.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch picture {
        case .captured(let image):
            layer.contents = image
            layer.contentsGravity = .resize
            layer.backgroundColor = NSColor.black.cgColor
        case .file(let image, let gravity, let fill):
            layer.contents = image
            layer.contentsGravity = gravity
            layer.backgroundColor = fill.cgColor
        case .color(let color):
            layer.contents = nil
            layer.backgroundColor = color.cgColor
        }
        layer.contentsScale = display.pixelsPerPoint
        CATransaction.commit()
        panel.orderFrontRegardless()
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            }))
        }
        let distributed = DistributedNotificationCenter.default()
        for name in [
            Notification.Name("AppleInterfaceThemeChangedNotification"),
            Notification.Name("com.apple.desktop"),
            Notification.Name("AppleDesktopPictureChanged"),
        ] {
            observers.append((distributed, distributed.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            }))
        }
    }
}

/// One display's cover: borderless, opaque, on every Space and still through Mission Control, as the desktop is;
/// it never takes the keyboard or makes this app active.
private final class CoverPanel: NSPanel {
    init(display: DisplayInfo) {
        super.init(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        let view = NSView(frame: CGRect(origin: .zero, size: display.frame.size))
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        view.autoresizingMask = [.width, .height]
        contentView = view
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
