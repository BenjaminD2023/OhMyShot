import AppKit
import OMSCore

/// Pins: pictures kept above every app's windows, for reference while working — a capture, or a picture
/// from the clipboard or a file. Each is its own small window: dragged to move, scrolled or pinched to
/// zoom, Option-scrolled to fade, moved with the arrows, closed with Escape, its close button, or a
/// middle click; its menu holds the rest. A locked pin lets every click through and is unlocked from the
/// menu bar. A pin keeps its own copy of the picture, so it outlives the capture's place in the history.
public final class PinController {
    /// A pinned picture and where it came from.
    public struct Pin {
        public let id: UUID
        public let image: CGImage
        /// Pixels per point.
        public let scale: CGFloat
        public let origin: Origin
    }

    public enum Origin: Equatable {
        /// A capture in the history.
        case capture(UUID)
        case file(URL)
        case clipboard
    }

    /// What a pin's menu does beyond the window itself; the composition root has the history, the
    /// editor, and the OCR panel.
    public struct Actions {
        public var copy: (Pin) -> Void
        public var save: (Pin) -> Void
        public var saveAs: (Pin) -> Void
        public var annotate: (Pin) -> Void
        public var recognizeText: (Pin) -> Void

        public init(
            copy: @escaping (Pin) -> Void,
            save: @escaping (Pin) -> Void,
            saveAs: @escaping (Pin) -> Void,
            annotate: @escaping (Pin) -> Void,
            recognizeText: @escaping (Pin) -> Void
        ) {
            self.copy = copy
            self.save = save
            self.saveAs = saveAs
            self.annotate = annotate
            self.recognizeText = recognizeText
        }
    }

    /// Pins opened, closed, hidden, shown, locked, or unlocked: what captures include and the menu bar's
    /// entries follow.
    public var onChange: (() -> Void)?

    private let settings: SettingsStore
    private let actions: Actions
    private var windows: [PinWindow] = []
    private var windowLease: ActiveResources.Lease?
    public private(set) var areHidden = false

    public init(settings: SettingsStore, actions: Actions) {
        self.settings = settings
        self.actions = actions
    }

    public var isEmpty: Bool { windows.isEmpty }
    public var count: Int { windows.count }
    public var hasLockedPins: Bool { windows.contains { $0.isLocked } }

    /// The pins' windows, for captures to include as they are on screen: none while they are hidden or
    /// when Settings leaves pins out of captures.
    public var capturedWindowIDs: Set<CGWindowID> {
        guard settings.pinsAppearInCaptures, !areHidden else { return [] }
        return Set(windows.map { CGWindowID($0.windowNumber) })
    }

    private var appearance: PinAppearance {
        PinAppearance(cornerRadius: CGFloat(settings.pinCornerRadius), shadow: settings.pinShadow, border: settings.pinBorder)
    }

    /// Pins `image`: over `area` (global points) at its own size when it came from there, else centered
    /// on the pointer's display.
    @discardableResult
    public func pin(_ image: CGImage, scale: CGFloat, origin: Origin, over area: CGRect? = nil) -> UUID {
        if areHidden { setHidden(false) }
        let scale = max(scale, 1)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var placed = PinGeometry.initialFrame(size: size, requested: area, visible: visible)
        // Pins from elsewhere step aside from one already in their place.
        if area == nil {
            while windows.contains(where: { abs($0.frame.minX - placed.frame.minX) < 1 && abs($0.frame.maxY - placed.frame.maxY) < 1 }) {
                placed.frame = placed.frame.offsetBy(dx: 24, dy: -24)
            }
        }
        let pin = Pin(id: UUID(), image: image, scale: scale, origin: origin)
        let window = PinWindow(pin: pin, frame: placed.frame, zoom: placed.zoom, appearance: appearance, actions: actions)
        window.onClose = { [weak self] in self?.close($0) }
        window.onCloseAll = { [weak self] in self?.closeAll() }
        window.onChange = { [weak self] in self?.onChange?() }
        windows.append(window)
        window.orderFrontRegardless()
        // The shadow follows the rounded picture once it has been drawn. It takes the keys only when
        // clicked: a pin stays, and taking them now would leave the app in front unable to type.
        window.invalidateShadow()
        windowLease = windowLease ?? ActiveResources.shared.acquire(.window)
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: String(localized: "Pinned.", bundle: .module),
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        onChange?()
        return pin.id
    }

    /// Hides every pin, or shows them again where they were.
    public func setHidden(_ hidden: Bool) {
        guard hidden != areHidden, !windows.isEmpty || !hidden else { return }
        areHidden = hidden
        for window in windows {
            if hidden { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
        onChange?()
    }

    public func unlockAll() {
        for window in windows { window.setLocked(false) }
    }

    public func closeAll() {
        guard !windows.isEmpty else { return }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        finishClosing()
    }

    /// Settings changed how pins look.
    public func appearanceChanged() {
        let appearance = appearance
        for window in windows { window.apply(appearance) }
    }

    private func close(_ window: PinWindow) {
        window.orderOut(nil)
        windows.removeAll { $0 === window }
        finishClosing()
    }

    private func finishClosing() {
        if windows.isEmpty {
            windowLease = nil
            areHidden = false
            MemoryRelief.returnFreedPages()
        }
        onChange?()
    }

    #if DEBUG
    /// The newest pin, for scripted checks.
    public var debugSummary: String {
        windows.map { "\(NSStringFromRect($0.frame)) zoom=\(String(format: "%.2f", $0.zoom)) opacity=\(String(format: "%.2f", $0.opacity)) locked=\($0.isLocked) key=\($0.isKeyWindow) id=\($0.windowNumber)" }
            .joined(separator: "; ")
    }

    /// The newest pin's window frame, for scripted checks.
    public var newestFrame: CGRect? { windows.last?.frame }

    /// Acts on the newest pin as its controls would, for scripted checks.
    public func debugAct(zoom: CGFloat? = nil, opacity: CGFloat? = nil, locked: Bool? = nil, move: CGVector? = nil) {
        guard let window = windows.last else { return }
        if let zoom { window.setZoom(zoom) }
        if let opacity { window.setOpacity(opacity) }
        if let locked { window.setLocked(locked) }
        if let move { window.move(by: move) }
    }
    #endif
}
