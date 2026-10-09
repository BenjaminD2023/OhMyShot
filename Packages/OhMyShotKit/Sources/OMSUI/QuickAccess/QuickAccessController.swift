import AppKit
import Foundation
import OMSCore

/// Quick Access: after each capture a card appears in the corner of the screen, ready to be copied,
/// saved, dragged into another app, or dismissed. Nothing is saved anywhere until the user asks.
public final class QuickAccessController {
    public struct Actions {
        public var copy: (QuickAccessItem) -> Void
        /// Saves a copy to the export location and returns where it went.
        public var save: (QuickAccessItem) -> URL?
        /// Asks where to save a copy.
        public var saveAs: (QuickAccessItem) -> URL?
        public var open: (QuickAccessItem) -> Void
        /// Opens the capture in the annotation editor.
        public var annotate: (QuickAccessItem) -> Void
        public var reveal: (QuickAccessItem) -> Void
        /// Opens the capture in the OCR panel.
        public var recognizeText: (QuickAccessItem) -> Void
        /// Keeps the capture on screen as a pin.
        public var pin: (QuickAccessItem) -> Void
        public var moveToTrash: (QuickAccessItem) -> Void
        /// A card was dismissed without being trashed.
        public var closed: (QuickAccessItem) -> Void

        public init(
            copy: @escaping (QuickAccessItem) -> Void,
            save: @escaping (QuickAccessItem) -> URL?,
            saveAs: @escaping (QuickAccessItem) -> URL?,
            open: @escaping (QuickAccessItem) -> Void,
            annotate: @escaping (QuickAccessItem) -> Void,
            reveal: @escaping (QuickAccessItem) -> Void,
            recognizeText: @escaping (QuickAccessItem) -> Void,
            pin: @escaping (QuickAccessItem) -> Void,
            moveToTrash: @escaping (QuickAccessItem) -> Void,
            closed: @escaping (QuickAccessItem) -> Void
        ) {
            self.copy = copy
            self.save = save
            self.saveAs = saveAs
            self.open = open
            self.annotate = annotate
            self.reveal = reveal
            self.recognizeText = recognizeText
            self.pin = pin
            self.moveToTrash = moveToTrash
            self.closed = closed
        }
    }

    /// Cards kept at most; fewer when the screen is short.
    public var maximumCards = 5

    private let actions: Actions
    private var panel: QuickAccessPanel?
    private var stack: CardStackView?
    private var items: [QuickAccessItem] = []
    private var recentlyClosed: [QuickAccessItem] = []
    /// The display the stack sits on.
    private var displayID: CGDirectDisplayID?
    private var windowLease: ActiveResources.Lease?

    public init(actions: Actions) {
        self.actions = actions
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The captures currently shown as cards.
    public var itemIDs: Set<UUID> { Set(items.map(\.id)) }

    /// The card showing capture `id`, if one is.
    public func item(_ id: UUID) -> QuickAccessItem? {
        items.first { $0.id == id }
    }

    public var canRestoreRecentlyClosed: Bool {
        recentlyClosed.contains { FileManager.default.fileExists(atPath: $0.fileURL.path(percentEncoded: false)) }
    }

    /// Shows a card for `item`, or brings an existing card for it back to the bottom of the stack.
    public func add(_ item: QuickAccessItem) {
        items.removeAll { $0.id == item.id }
        recentlyClosed.removeAll { $0.id == item.id }
        items.append(item)
        while items.count > maximumCards {
            close(items.removeFirst())
        }
        present(entering: item.id, on: item.displayID)
        panel?.orderFrontRegardless()
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
    }

    /// Shows a capture's new picture (marked up, or put back as taken) on its card, where it is.
    public func update(_ item: QuickAccessItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var item = item
        item.savedURL = item.savedURL ?? items[index].savedURL
        let reshaped = CaptureCardView.preferredHeight(for: item) != CaptureCardView.preferredHeight(for: items[index])
        items[index] = item
        stack?.replace(item)
        if reshaped, let displayID {
            present(entering: nil, on: displayID)
        }
    }

    /// Marks a capture saved elsewhere (from the editor) as saved on its card.
    public func markSaved(_ id: UUID, at url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].savedURL = url
        stack?.markSaved(id, at: url)
    }

    /// Copies the newest card's capture: the keyboard path to Quick Access.
    public func copyLatest() {
        guard let latest = items.last else { return }
        actions.copy(latest)
        stack?.showCopied(latest.id)
    }

    /// Opens the newest card's capture in the editor, as a double-click would, for scripted checks.
    public func annotateLatest() {
        guard let latest = items.last else { return }
        actions.annotate(latest)
    }

    /// Shows the newest card's hover state without a pointer, for scripted checks.
    public func previewHoverOnLatest() {
        guard let latest = items.last else { return }
        stack?.previewHover(latest.id)
    }

    public func dismiss(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        close(items.remove(at: index))
        refresh()
    }

    /// Closes the newest card, the one nearest the corner.
    public func dismissLatest() {
        guard let latest = items.last else { return }
        dismiss(latest.id)
    }

    public func dismissAll() {
        items.forEach(close)
        items.removeAll()
        refresh()
    }

    /// Removes a capture that was deleted elsewhere: its card goes without the closed callback, and it
    /// can no longer be restored.
    public func remove(_ id: UUID) {
        recentlyClosed.removeAll { $0.id == id }
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        refresh()
    }

    /// Brings back the most recently closed card whose capture still exists.
    public func restoreRecentlyClosed() {
        while let item = recentlyClosed.popLast() {
            if FileManager.default.fileExists(atPath: item.fileURL.path(percentEncoded: false)) {
                add(item)
                return
            }
        }
    }

    private func close(_ item: QuickAccessItem) {
        recentlyClosed.append(item)
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        actions.closed(item)
    }

    /// Re-lays the stack after cards left it; the last card slides out before the panel goes.
    private func refresh() {
        guard let stack else { return }
        if items.isEmpty {
            stack.show([], entering: nil) { [weak self] in self?.tearDown() }
        } else {
            present(entering: nil, on: displayID ?? items[items.count - 1].displayID)
        }
    }

    /// Keeps the stack in the bottom-left corner of the display, clear of the Dock, dropping the oldest
    /// cards when it would not fit. The panel grows before the cards move up, and shrinks only after
    /// they have moved down, so no card is clipped mid-motion.
    private func present(entering: UUID?, on displayID: CGDirectDisplayID) {
        let screen = NSScreen.screens.first { $0.cgDirectDisplayID == displayID } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // Cards sit 26 pt from the screen's edges; the panel reaches past them by the shadow's margin.
        let edge: CGFloat = 26
        let margin = CardStackView.margin
        while CardStackView.height(for: items) - margin * 2 > visible.height - edge * 2, items.count > 1 {
            close(items.removeFirst())
        }
        let stack = self.stack ?? makeStack()
        guard let panel else { return }
        let frame = CGRect(
            x: visible.minX + edge - margin,
            y: visible.minY + edge - margin,
            width: CardStackView.width,
            height: CardStackView.height(for: items)
        )
        if !panel.isVisible || panel.frame.origin != frame.origin || frame.height >= panel.frame.height {
            panel.setFrame(frame, display: true)
            stack.show(items, entering: entering)
        } else {
            stack.show(items, entering: entering) { [weak panel] in
                panel?.setFrame(frame, display: true)
            }
        }
        self.displayID = displayID
    }

    private func tearDown() {
        guard items.isEmpty else { return }
        panel?.orderOut(nil)
        panel = nil
        stack = nil
        displayID = nil
        windowLease = nil
        MemoryRelief.returnFreedPages()
    }

    private func makeStack() -> CardStackView {
        let stack = CardStackView()
        stack.onCopy = { [weak self] item in self?.actions.copy(item) }
        stack.onSave = { [weak self] item in self?.recordSave(of: item, at: self?.actions.save(item)) }
        stack.onSaveAs = { [weak self] item in self?.recordSave(of: item, at: self?.actions.saveAs(item)) }
        stack.onOpen = { [weak self] item in self?.actions.open(item) }
        stack.onAnnotate = { [weak self] item in self?.actions.annotate(item) }
        stack.onReveal = { [weak self] item in self?.actions.reveal(item) }
        stack.onRecognizeText = { [weak self] item in self?.actions.recognizeText(item) }
        stack.onPin = { [weak self] item in self?.actions.pin(item) }
        stack.onMoveToTrash = { [weak self] item in
            guard let self else { return }
            items.removeAll { $0.id == item.id }
            actions.moveToTrash(item)
            refresh()
        }
        stack.onClose = { [weak self] item in self?.dismiss(item.id) }
        let panel = QuickAccessPanel()
        panel.contentView = stack
        self.panel = panel
        self.stack = stack
        return stack
    }

    private func recordSave(of item: QuickAccessItem, at url: URL?) {
        guard let url, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].savedURL = url
        stack?.markSaved(item.id, at: url)
    }
}

/// A transparent floating panel that never takes focus from the app being worked in. The cards draw
/// their own shadows.
final class QuickAccessPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // A step above pins, which share the floating level: a card that comes and goes stays on top.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
