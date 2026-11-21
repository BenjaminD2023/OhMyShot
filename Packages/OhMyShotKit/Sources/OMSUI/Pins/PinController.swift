import AppKit
import OMSCore
import OMSDesign

/// Pins: things kept above every app's windows, for reference while working — a capture, a picture from
/// the clipboard or a file, or the clipboard's text or color. Each is its own small window: dragged to move, scrolled or pinched to
/// zoom, Option-scrolled to fade, moved with the arrows, closed with Escape, its close button, or a
/// middle click; its menu holds the rest. A locked pin lets every click through and is unlocked from the
/// menu bar. A pin keeps its own copy of the picture, so it outlives the capture's place in the history.
/// A picture's text can be selected in place with Live Text, as in Preview. While Settings brings pins back after a
/// relaunch, the pins open are kept on disk as they change (`PinArchive`) and open again at the next launch; a pin
/// left on no display when the displays change, or when it comes back, moves onto the nearest one.
public final class PinController {
    /// What is pinned and where it came from.
    public struct Pin {
        public let id: UUID
        public let content: Content
        public let origin: Origin
        /// When it was pinned: a capture whose file changed since holds a picture other than the pin's.
        public let pinnedAt = Date.now

        /// A picture pin's own picture as a file to drag out: the file it was opened from while that is there, else a
        /// PNG of it in the temporary folder. Nil for a text or color pin, or when the PNG cannot be written.
        public func ownFile() -> URL? {
            guard case .image(let image, _) = content else { return nil }
            if case .file(let url) = origin, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
            let tempURL = FileManager.default.temporaryDirectory.appending(path: "OhMyShot Pin \(id.uuidString).png")
            if FileManager.default.fileExists(atPath: tempURL.path(percentEncoded: false)) {
                return tempURL
            }
            do {
                try ImageExporter.write(ImageExporter.encoded(image, as: .png), to: tempURL)
                return tempURL
            } catch {
                return nil
            }
        }
    }

    public enum Content {
        /// A picture, at `scale` pixels per point.
        case image(CGImage, scale: CGFloat)
        case text(String)
        case color(PinColor)
    }

    public nonisolated enum Origin: Equatable, Codable, Sendable {
        /// A capture in the history.
        case capture(UUID)
        case file(URL)
        case clipboard
    }

    /// What a picture pin's menu does beyond the window itself; the composition root has the history,
    /// the editor, and the OCR panel. Text and color pins copy their own text and values.
    public struct Actions {
        public var copy: (Pin) -> Void
        public var save: (Pin) -> Void
        public var saveAs: (Pin) -> Void
        public var annotate: (Pin) -> Void
        public var recognizeText: (Pin) -> Void
        /// The file a picture pin hands over when Option-dragged into another app; nil when it could not be made, which
        /// the app says, and then nothing goes. Left out, the pin's own picture goes (`Pin.ownFile()`).
        public var fileForDrag: ((Pin) -> URL?)?

        public init(
            copy: @escaping (Pin) -> Void,
            save: @escaping (Pin) -> Void,
            saveAs: @escaping (Pin) -> Void,
            annotate: @escaping (Pin) -> Void,
            recognizeText: @escaping (Pin) -> Void,
            fileForDrag: ((Pin) -> URL?)? = nil
        ) {
            self.copy = copy
            self.save = save
            self.saveAs = saveAs
            self.annotate = annotate
            self.recognizeText = recognizeText
            self.fileForDrag = fileForDrag
        }
    }

    /// Pins opened, closed, hidden, shown, locked, or unlocked: what captures include and the menu bar's
    /// entries follow.
    public var onChange: (() -> Void)?

    private let settings: SettingsStore
    private let actions: Actions
    /// Back to front, as they are stacked: a pin opened or clicked goes last.
    private var windows: [PinWindow] = []
    private let textReader = PinTextReader()
    private var windowLease: ActiveResources.Lease?
    public private(set) var areHidden = false
    private let archive = PinArchive()
    /// Whether the pins are kept for the next launch, as Settings says; asked again when Settings changes.
    private var isKeeping: Bool
    /// The next write of what is kept, a moment after a change, so a whole drag or zoom writes once.
    private var pendingSave: Task<Void, Never>?

    public init(settings: SettingsStore, actions: Actions) {
        self.settings = settings
        self.actions = actions
        isKeeping = settings.pinsComeBack
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
    /// on the pointer's display. A scale below 1 is kept, for a picture resized to fewer pixels than points; one that is
    /// no scale at all is taken as 1.
    @discardableResult
    public func pin(_ image: CGImage, scale: CGFloat, origin: Origin, over area: CGRect? = nil) -> UUID {
        open(.image(image, scale: scale.isFinite && scale > 0 ? scale : 1), origin: origin, over: area)
    }

    /// Pins text on a card, centered on the pointer's display.
    @discardableResult
    public func pin(text: String) -> UUID {
        open(.text(text), origin: .clipboard, over: nil)
    }

    /// Pins a color as a swatch with its value, centered on the pointer's display.
    @discardableResult
    public func pin(color: PinColor) -> UUID {
        open(.color(color), origin: .clipboard, over: nil)
    }

    private func open(_ content: Content, origin: Origin, over area: CGRect?) -> UUID {
        if areHidden { setHidden(false) }
        let size = PinWindow.baseSize(of: content)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var placed = PinGeometry.initialFrame(size: size, requested: area, visible: visible)
        // Pins from elsewhere step aside from one already in their place.
        if area == nil {
            while windows.contains(where: { abs($0.frame.minX - placed.frame.minX) < 1 && abs($0.frame.maxY - placed.frame.maxY) < 1 }) {
                placed.frame = placed.frame.offsetBy(dx: 24, dy: -24)
            }
        }
        let pin = Pin(id: UUID(), content: content, origin: origin)
        let window = add(pin, frame: placed.frame, zoom: placed.zoom)
        window.show()
        if isKeeping, case .image(let image, _) = content { archive.keepPicture(image, id: pin.id) }
        VoiceOver.announce(String(localized: "Pinned.", bundle: .module), from: window, priority: .medium)
        changed()
        return pin.id
    }

    /// A pin's window, not yet shown, in front of the others once it is.
    private func add(_ pin: Pin, frame: CGRect, zoom: CGFloat, opacity: CGFloat = 1) -> PinWindow {
        let window = PinWindow(pin: pin, frame: frame, zoom: zoom, opacity: opacity, appearance: appearance, actions: actions, textReader: textReader)
        window.onClose = { [weak self] in self?.close($0) }
        window.onCloseAll = { [weak self] in self?.closeAll() }
        window.onChange = { [weak self] in self?.changed() }
        window.onAdjust = { [weak self] in self?.scheduleSave() }
        window.onRaise = { [weak self] in self?.raise($0) }
        windows.append(window)
        windowLease = windowLease ?? ActiveResources.shared.acquire(.window)
        return window
    }

    /// Opens the pins that were open when the app last quit, where they were (on the nearest display when theirs is
    /// gone) and hidden if they were. While Settings doesn't keep pins, removes what an earlier launch kept instead.
    public func restore() {
        guard isKeeping else { return archive.removeAll() }
        archive.load { [weak self] manifest, pictures in self?.reopen(manifest, pictures: pictures) }
    }

    private func reopen(_ manifest: PinArchive.Manifest, pictures: [UUID: CGImage]) {
        // A pin opened while these were read keeps the pins shown or hidden as they are now.
        let hidden = windows.isEmpty ? manifest.hidden : areHidden
        let screens = Self.screens
        for record in manifest.pins where !windows.contains(where: { $0.pin.id == record.id }) {
            guard let content = record.pinContent(picture: pictures[record.id]) else { continue }
            let zoom = PinGeometry.keptZoom(record.zoom)
            let base = PinWindow.baseSize(of: content)
            // Its size from its own size and zoom, its top left corner where it was.
            let kept = CGRect(x: record.frame.minX, y: record.frame.maxY - base.height * zoom, width: base.width * zoom, height: base.height * zoom)
            let frame = PinGeometry.recovered(kept, on: screens) ?? kept
            let window = add(Pin(id: record.id, content: content, origin: record.origin), frame: frame, zoom: zoom, opacity: record.opacity)
            if record.locked { window.setLocked(true) }
            if !hidden { window.show() }
        }
        guard !windows.isEmpty else { return }
        areHidden = hidden
        changed()
    }

    /// Settings turned keeping pins for the next launch on or off: what is open is written at once, or all that was
    /// kept goes.
    public func keepingChanged() {
        guard settings.pinsComeBack != isKeeping else { return }
        isKeeping = settings.pinsComeBack
        guard isKeeping else {
            pendingSave?.cancel()
            pendingSave = nil
            return archive.removeAll()
        }
        for window in windows {
            if case .image(let image, _) = window.pin.content { archive.keepPicture(image, id: window.pin.id) }
        }
        saveNow()
    }

    /// The app is quitting: what changed and isn't written yet is, and every write asked for is finished first.
    public func finishKeeping() {
        if pendingSave != nil { saveNow(waits: true) } else { archive.finish() }
    }

    /// The displays changed: a pin no longer on any of them moves onto the nearest, inside its visible frame.
    public func displaysChanged() {
        let screens = Self.screens
        for window in windows {
            guard let moved = PinGeometry.recovered(window.frame, on: screens) else { continue }
            window.move(by: CGVector(dx: moved.minX - window.frame.minX, dy: moved.minY - window.frame.minY))
        }
    }

    private static var screens: [(frame: CGRect, visible: CGRect)] {
        NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
    }

    /// Hides every pin, or shows them again where they were.
    public func setHidden(_ hidden: Bool) {
        guard hidden != areHidden, !windows.isEmpty || !hidden else { return }
        areHidden = hidden
        for window in windows {
            if hidden { window.orderOut(nil) } else { window.show() }
        }
        changed()
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

    /// A pin clicked is in front of the others, and is kept so.
    private func raise(_ window: PinWindow) {
        guard windows.last !== window, let index = windows.firstIndex(where: { $0 === window }) else { return }
        windows.append(windows.remove(at: index))
        scheduleSave()
    }

    private func close(_ window: PinWindow) {
        window.orderOut(nil)
        windows.removeAll { $0 === window }
        if isKeeping { archive.forget(window.pin.id) }
        finishClosing()
    }

    private func finishClosing() {
        if windows.isEmpty {
            windowLease = nil
            areHidden = false
            textReader.release()
            MemoryRelief.returnFreedPages()
        }
        onChange?()
        // With the last pin gone, what was kept goes at once.
        if windows.isEmpty { saveNow() } else { scheduleSave() }
    }

    /// Pins opened, closed, hidden, shown, locked, or unlocked: captures and the menu bar follow, and what is kept.
    private func changed() {
        onChange?()
        scheduleSave()
    }

    /// Writes what is kept a moment after a change, once for a whole drag or zoom.
    private func scheduleSave() {
        guard isKeeping, pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes what is kept now, or with no pin open removes it; `waits` until that is on disk.
    private func saveNow(waits: Bool = false) {
        pendingSave?.cancel()
        pendingSave = nil
        guard isKeeping else { return }
        var pictures: [UUID: CGImage] = [:]
        for window in windows {
            if case .image(let image, _) = window.pin.content { pictures[window.pin.id] = image }
        }
        archive.save(PinArchive.Manifest(hidden: areHidden, pins: windows.compactMap(\.record)), pictures: pictures, waits: waits)
    }

    #if DEBUG
    /// The newest pin, for scripted checks.
    public var debugSummary: String {
        windows.map { "\(NSStringFromRect($0.frame)) zoom=\(String(format: "%.2f", $0.zoom)) opacity=\(String(format: "%.2f", $0.opacity)) locked=\($0.isLocked) key=\($0.isKeyWindow) id=\($0.windowNumber)" }
            .joined(separator: "; ")
    }

    /// The newest pin's window frame, for scripted checks.
    public var newestFrame: CGRect? { windows.last?.frame }

    /// Opens a pin of `content` at `zoom` behind the desktop picture of the main display, in the light or
    /// dark appearance and without its shadow, with Close and More showing as on hover when `controls`, for
    /// a scripted capture of how pins draw: the window server captures only windows on a display, and there
    /// nothing shows. It is no pin of the controller's; the caller orders it out.
    public func debugHiddenPin(_ content: Content, zoom: CGFloat, dark: Bool, controls: Bool = false) -> NSWindow {
        let base = PinWindow.baseSize(of: content)
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = PinWindow(
            pin: Pin(id: UUID(), content: content, origin: .clipboard),
            frame: CGRect(x: visible.minX + 40, y: visible.minY + 40, width: base.width * zoom, height: base.height * zoom),
            zoom: zoom, appearance: appearance, actions: actions, textReader: textReader
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.hasShadow = false
        window.orderFrontRegardless()
        if controls { window.debugShowControls() }
        window.displayIfNeeded()
        return window
    }

    /// Reads the text of a picture pin from `debugHiddenPin` and waits for it, selecting all of it when
    /// `selectAll`: how many characters Live Text found, 0 for none.
    public func debugReadText(in window: NSWindow, selectAll: Bool) async -> Int {
        guard let pin = window as? PinWindow else { return 0 }
        return await pin.debugReadText(selectAll: selectAll)
    }

    /// Selects part of a text card's text, for scripted renders of a selection.
    public func debugSelectText(in window: NSWindow, range: NSRange) {
        (window as? PinWindow)?.debugSelectText(range)
    }

    /// Lets the text reader go, as closing the last pin does.
    public func debugReleaseTextReader() {
        textReader.release()
    }

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
