import AppKit
import AVFoundation
import OMSCore
import QuartzCore

/// The camera's picture in a bubble over the screen, recorded with it: a circle or a rounded square in a
/// corner of what is recorded, ringed in white, which can be dragged anywhere on its display. Double-click
/// fills what is recorded with the camera; again brings the bubble back.
///
/// The camera runs only while the bubble shows, and the bubble shows from the moment the camera is chosen on
/// the recording bar, so it can be placed before recording. Its window floats above the overlay that chooses
/// what to record, the Dock, and other apps' menus, and the recording's filter takes it in.
public final class CameraBubble {
    private var panel: BubblePanel?
    private let view = BubbleView()
    private let camera = CameraSession()
    private var lease: ActiveResources.Lease?
    private var style = CameraStyle()
    private var deviceID: String?
    /// What is recorded, in global points: where the bubble starts, and what it fills.
    private var area: CGRect = .zero
    /// Where the bubble is, in global points; its panel reaches past it by `room`.
    private var bubble: CGRect?
    /// Moved by hand: the bubble stays where it was put when what is recorded changes.
    private var wasMoved = false
    private var fills = false
    private var isRecording = false

    /// Room around the bubble in its panel for the shadow: twice its blur and its drop.
    private static let room: CGFloat = 28

    public init() {
        view.onDrag = { [weak self] delta in self?.drag(by: delta) }
        view.onDoubleClick = { [weak self] in self?.toggleFill() }
    }

    /// The window, for the recording's filter to take in; nil while hidden.
    public var windowID: CGWindowID? {
        panel.map { CGWindowID($0.windowNumber) }
    }

    public var isShowing: Bool {
        panel != nil
    }

    /// Shows camera `id` (empty for the system's default) in a bubble at the bottom-left of `area`, or moves
    /// it there and changes its camera and look. Access to the camera must be granted already.
    public func show(camera id: String, style: CameraStyle, in area: CGRect) {
        let changedCamera = id != deviceID
        self.style = style
        deviceID = id
        if self.area != area {
            self.area = area
            if !wasMoved { fills = false }
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if changedCamera { startCamera(id) }
        if let current = bubble, wasMoved, current.intersects(area) {
            bubble = CGRect(origin: current.origin, size: CGSize(width: side, height: side))
        } else {
            bubble = Self.corner(of: area, side: side)
            wasMoved = false
        }
        layout()
        panel.orderFrontRegardless()
    }

    /// Recording or not: filling what is recorded, the camera sits under the menu bar and the control bar,
    /// which stay within reach; while what to record is chosen it stays above the overlay.
    public func setRecording(_ recording: Bool) {
        isRecording = recording
        updateLevel()
    }

    public func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        deviceID = nil
        bubble = nil
        wasMoved = false
        fills = false
        isRecording = false
        view.preview.session = nil
        camera.stop()
        lease = nil
    }

    // MARK: Private

    /// The bubble's side, never more than half of what is recorded.
    private var side: CGFloat {
        min(style.size.points, max(min(area.width, area.height) / 2, 60))
    }

    /// 24 points in from the bottom-left corner of `area`.
    private static func corner(of area: CGRect, side: CGFloat) -> CGRect {
        let inset = min(24, max(min(area.width, area.height) - side, 0) / 2)
        return CGRect(x: area.minX + inset, y: area.minY + inset, width: side, height: side)
    }

    private func makePanel() -> BubblePanel {
        let panel = BubblePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let container = NSView()
        container.addSubview(view)
        panel.contentView = container
        lease = ActiveResources.shared.acquire(.window)
        return panel
    }

    /// The panel around the bubble with room for its shadow, or over all of what is recorded when it fills.
    private func layout() {
        guard let panel, let bubble else { return }
        view.apply(style, fills: fills)
        updateLevel()
        if fills {
            panel.setFrame(area, display: false)
            view.frame = CGRect(origin: .zero, size: area.size)
        } else {
            panel.setFrame(bubble.insetBy(dx: -Self.room, dy: -Self.room), display: false)
            view.frame = CGRect(x: Self.room, y: Self.room, width: bubble.width, height: bubble.height)
        }
        panel.display()
    }

    private func updateLevel() {
        panel?.level = fills && isRecording
            ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
            : NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
    }

    private func startCamera(_ id: String) {
        view.preview.session = camera.session
        camera.run(id)
    }

    private func drag(by delta: CGVector) {
        guard let panel, var moved = bubble, !fills else { return }
        moved = moved.offsetBy(dx: delta.dx, dy: delta.dy)
        // Kept on the display it is on.
        if let screen = panel.screen ?? NSScreen.main {
            let bounds = screen.frame
            moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        }
        bubble = moved
        wasMoved = true
        panel.setFrameOrigin(CGPoint(x: moved.minX - Self.room, y: moved.minY - Self.room))
    }

    /// Fills what is recorded, or goes back to a bubble in its corner, through a quick fade.
    private func toggleFill() {
        guard let panel else { return }
        fills.toggle()
        if !fills {
            bubble = Self.corner(of: area, side: side)
            wasMoved = false
        }
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: fills ? String(localized: "Camera fills the recording", bundle: .module) : String(localized: "Camera in a bubble", bundle: .module),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return layout() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.fade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // Animation groups end on the main thread.
            MainActor.assumeIsolated {
                self?.layout()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Theme.Motion.fade
                    panel?.animator().alphaValue = 1
                }
            }
        }
    }
}

#if DEBUG
extension CameraBubble {
    /// The bubble without its camera (the capsule surface) behind the desktop picture, for rendering checks;
    /// returns its window.
    public static func debugHiddenWindow(style: CameraStyle) -> NSWindow {
        let view = BubbleView()
        view.apply(style, fills: false)
        let side = style.size.points
        let room: CGFloat = 24
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: side + room * 2, height: side + room * 2), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
        }
        let content = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        view.frame = CGRect(x: room, y: room, width: side, height: side)
        content.addSubview(view)
        window.contentView = content
        window.orderFront(nil)
        return window
    }
}
#endif

/// The capture session, configured, started, and stopped on a queue of its own, since those block; the
/// preview layer holds it too, as AVFoundation allows.
nonisolated private final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "OhMyShot.camera")

    /// Runs camera `id`, or the system's default when it is empty or gone.
    func run(_ id: String) {
        queue.async { [self] in
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.sessionPreset = .high
            let device = (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
        }
    }
}

/// The bubble's window: above the recording overlay (pop-up menus + 1), so it can be seen and moved while
/// what to record is chosen, and above the Dock and menus while recording; never key.
private final class BubblePanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The camera's picture clipped to the bubble's shape, with a white ring and a soft shadow.
private final class BubbleView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    private let clip = CALayer()
    private let ring = CAShapeLayer()
    /// Under Increase Contrast, a dark hairline outside the white ring, so the bubble holds on white pages.
    private let edge = CAShapeLayer()
    var onDrag: ((CGVector) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var lastDrag: CGPoint?
    private var style = CameraStyle()
    private var fills = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        clip.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        clip.addSublayer(preview)
        layer?.addSublayer(clip)
        ring.fillColor = nil
        ring.strokeColor = CGColor(gray: 1, alpha: 0.95)
        ring.lineWidth = 3
        layer?.addSublayer(ring)
        edge.fillColor = nil
        edge.lineWidth = 1
        layer?.addSublayer(edge)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Camera", bundle: .module))
        setAccessibilityHelp(String(localized: "Drag to move. Double-click to fill the recording.", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ style: CameraStyle, fills: Bool) {
        self.style = style
        self.fills = fills
        // Before the camera's first frame, the capsule surface: never a dark disc in a recording.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        clip.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.96) : CGColor(gray: 1, alpha: 0.97)
        edge.strokeColor = dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35)
        edge.isHidden = !contrast
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = style.mirrored
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius: CGFloat = fills ? 0 : style.shape == .circle ? bounds.width / 2 : bounds.width * 0.2
        clip.frame = bounds
        clip.cornerRadius = radius
        clip.cornerCurve = .continuous
        preview.frame = clip.bounds
        // The connection exists once the session has its camera: mirror it as chosen then.
        if let connection = preview.connection, connection.isVideoMirroringSupported, connection.isVideoMirrored != style.mirrored {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = style.mirrored
        }
        let path = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: max(radius - 1.5, 0), cornerHeight: max(radius - 1.5, 0), transform: nil)
        ring.path = path
        ring.isHidden = fills
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: -0.5, dy: -0.5), cornerWidth: radius + 0.5, cornerHeight: radius + 0.5, transform: nil)
        edge.isHidden = fills || !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.shadowPath = fills ? nil : CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            lastDrag = nil
            onDoubleClick?()
            return
        }
        lastDrag = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDrag else { return }
        let now = NSEvent.mouseLocation
        onDrag?(CGVector(dx: now.x - last.x, dy: now.y - last.y))
        lastDrag = now
    }

    override func mouseUp(with event: NSEvent) {
        lastDrag = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
