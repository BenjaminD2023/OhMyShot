import AppKit
import Foundation
import OMSCore

/// Quick Access: after each capture a card appears in the corner of the screen, ready to be copied,
/// saved, dragged into another app, or dismissed. Nothing is saved anywhere until the user asks.
public final class QuickAccessController {
    public struct Actions {
        public var copy: (QuickAccessItem) -> Void
        /// Saves a copy to the export location and returns where it went; nil when it was not saved. Converting a
        /// large capture takes a while, so a card marks itself saved when this returns.
        public var save: (QuickAccessItem) async -> URL?
        /// Asks where to save a copy.
        public var saveAs: (QuickAccessItem) async -> URL?
        public var open: (QuickAccessItem) -> Void
        /// Opens the capture in the annotation editor.
        public var annotate: (QuickAccessItem) -> Void
        public var reveal: (QuickAccessItem) -> Void
        /// Opens the capture in the OCR panel.
        public var recognizeText: (QuickAccessItem) -> Void
        /// Keeps the capture on screen as a pin.
        public var pin: (QuickAccessItem) -> Void
        /// Prints the capture's picture through the print panel.
        public var print: (QuickAccessItem) -> Void = { _ in }
        public var moveToTrash: (QuickAccessItem) -> Void
        /// A card was dismissed without being trashed.
        public var closed: (QuickAccessItem) -> Void
        /// The file to hand to another app for a capture, when it is dragged out of its card or shared: the capture
        /// itself, or a copy in the format Settings choose.
        public var fileToHandOver: (QuickAccessItem) -> URL = { $0.fileURL }

        /// Where the cards stand, how large they are, and when they close by themselves (Settings); read each
        /// time a card appears.
        public var preferences: () -> QuickAccessPreferences = { QuickAccessPreferences() }

        /// Turns, flips, or scales the capture's picture, and shows the new one on its card (`update`).
        public var changePicture: (QuickAccessItem, PictureChange) -> Void = { _, _ in }
        /// What can be done to the capture's picture now; read when a menu opens or a key arrives.
        public var pictureChangeOffer: (QuickAccessItem) -> PictureChangeOffer = { _ in .unsupported }

        /// Uploading, for a person who set up a destination. Left as it is, the card offers none of it.
        public var sharing = Sharing()

        /// What a card needs to offer Upload, Cancel Upload, Retry and Copy Link.
        public struct Sharing {
            /// What the menu offers; read each time a menu opens, so a destination added or removed shows at once.
            public var menu: () -> UploadMenu = { .hidden }
            /// Uploads to a destination, or to the default for nil.
            public var upload: (QuickAccessItem, UUID?) -> Void = { _, _ in }
            public var cancel: (QuickAccessItem) -> Void = { _ in }
            public var retry: (QuickAccessItem) -> Void = { _ in }
            public var copyLink: (QuickAccessItem) -> Void = { _ in }
            /// Whether the capture has a link from an upload to copy.
            public var hasLink: (QuickAccessItem) -> Bool = { _ in false }
            /// Whether the capture's upload can be removed from its storage, and the card offers to.
            public var canDeleteFromStorage: (QuickAccessItem) -> Bool = { _ in false }
            /// Asks, then removes the capture's upload from its storage.
            public var deleteFromStorage: (QuickAccessItem) -> Void = { _ in }
            /// What a capture's upload is now, for a card shown after the upload began.
            public var current: (QuickAccessItem) -> CardUpload? = { _ in nil }

            public init() {}
        }

        public init(
            copy: @escaping (QuickAccessItem) -> Void,
            save: @escaping (QuickAccessItem) async -> URL?,
            saveAs: @escaping (QuickAccessItem) async -> URL?,
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

    #if DEBUG
    /// The cards' panel while it shows, for scripted captures of it.
    public var debugPanel: NSWindow? { panel }

    /// Opens the system share sheet for the newest card, as its Share… does.
    public func debugShareLatest() {
        guard let latest = items.last else { return }
        stack?.debugShare(of: latest.id)
    }

    /// Opens the newest card's menu as More does and keeps it open for a moment, long enough for `whileOpen` to
    /// look at it (it gets the menu's titles, submenus indented) and for a snapshot; then closes it. A menu
    /// blocks until it closes, so the closing is scheduled before it opens and cannot be missed.
    public func debugShowMenuOnLatest(whileOpen: @escaping @MainActor ([String]) async -> Void) {
        guard let latest = items.last else { return }
        stack?.debugShowMenu(of: latest.id, whileOpen: whileOpen)
    }
    #endif
    private var stack: CardStackView?
    /// The captures being saved now.
    private var saving: Set<UUID> = []
    private var items: [QuickAccessItem] = []
    private var recentlyClosed: [QuickAccessItem] = []
    /// The display the stack sits on.
    private var displayID: CGDirectDisplayID?
    private var windowLease: ActiveResources.Lease?

    /// What keeps each card from closing by itself right now, and when each card closes while Settings says
    /// cards do.
    private var schedule = CardCloseSchedule()
    private var closer: Task<Void, Never>?
    /// The card that has the keyboard, once the panel was clicked or asked for.
    private var selectedID: UUID?
    /// A card's hold by the keyboard, to be given back when the keys go to another card.
    private var keyboardHolder: UUID?

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
        let preferences = actions.preferences()
        let target = QuickAccessPlacement.display(forCaptureOn: item.displayID, pointerOn: Self.pointerDisplayID(), followsPointer: preferences.onPointerDisplay)
        present(entering: item.id, on: target)
        panel?.orderFrontRegardless()
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        // A card brought back anew starts its time again; one already up keeps its own.
        schedule.restart(item.id)
        if let upload = actions.sharing.current(item) { hold(.upload, for: item.id, if: upload.holdsCard) }
        reselectIfNeeded()
        updateCountdowns()
    }

    /// Shows a capture's new picture (marked up, or put back as taken) on its card, where it is. The copy
    /// saved from the card stays the card's, unless `keepsSaved` is false: it is of the picture as it was, and
    /// the card offers Save again.
    public func update(_ item: QuickAccessItem, keepsSaved: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var item = item
        if keepsSaved {
            item.savedURL = item.savedURL ?? items[index].savedURL
        } else {
            item.savedURL = nil
            stack?.markUnsaved(item.id)
        }
        let size = actions.preferences().size
        let reshaped = CaptureCardView.preferredHeight(for: item, size: size) != CaptureCardView.preferredHeight(for: items[index], size: size)
        items[index] = item
        stack?.replace(item)
        if reshaped, let displayID {
            present(entering: nil, on: displayID)
        }
        // The preview, if it shows this card, shows the new picture.
        if selectedID == item.id { stack?.quickLook.replace(with: item.fileURL) }
    }

    /// Marks a capture saved elsewhere (from the editor) as saved on its card.
    public func markSaved(_ id: UUID, at url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].savedURL = url
        stack?.markSaved(id, at: url)
    }

    /// Shows how a capture's upload stands on its card, if it has one; a card made later asks the actions. A card
    /// is not closed by itself while its upload goes, nor after it failed and waits for Retry.
    public func setUpload(_ upload: CardUpload?, for id: UUID) {
        stack?.setUpload(upload, for: id)
        hold(.upload, for: id, if: upload?.holdsCard ?? false)
    }

    /// Where a capture's card is on screen, if it has one: for a confirmation shown beside it.
    public func screenFrame(ofCard id: UUID) -> CGRect? {
        stack?.screenFrame(ofCard: id)
    }

    /// Copies the newest card's capture: the keyboard path to Quick Access.
    public func copyLatest() {
        guard let latest = items.last else { return }
        actions.copy(latest)
        stack?.showCopied(latest.id)
    }

    /// Gives the newest card the keyboard, without the pointer: the cards then answer the keys of
    /// `CardKeys`. The app in front stays in front; Escape gives the keyboard back.
    public func focusLatest() {
        focus(on: items.last?.id)
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

    /// Saves a copy of every card's capture that has not been saved, as Save does on each.
    public func saveAll() {
        let unsaved = items.filter { $0.savedURL == nil }
        Task {
            for item in unsaved { recordSave(of: item, at: await actions.save(item)) }
        }
    }

    /// Removes a capture that was deleted elsewhere: its card goes without the closed callback, and it
    /// can no longer be restored.
    public func remove(_ id: UUID) {
        recentlyClosed.removeAll { $0.id == id }
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        schedule.forget(id)
        refresh()
    }

    /// Puts the stack back in its corner after a display is attached, removed, or changes mode: on the
    /// display it was on if that is still connected, otherwise on the main one.
    public func displaysChanged() {
        guard let displayID, !items.isEmpty else { return }
        present(entering: nil, on: displayID)
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
        schedule.forget(item.id)
        actions.closed(item)
    }

    /// Re-lays the stack after cards left it; the last card slides out before the panel goes.
    private func refresh() {
        updateCountdowns()
        reselectIfNeeded()
        guard let stack else { return }
        if items.isEmpty {
            stack.show([], entering: nil) { [weak self] in self?.tearDown() }
        } else {
            present(entering: nil, on: displayID ?? items[items.count - 1].displayID)
        }
    }

    /// Keeps the stack in its corner of the display, clear of the Dock, dropping the oldest cards when it
    /// would not fit. The panel grows before the cards move up, and shrinks only after they have moved down, so
    /// no card is clipped mid-motion.
    private func present(entering: UUID?, on displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.cgDirectDisplayID == displayID }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let preferences = actions.preferences()
        let margin = CardStackView.margin
        while CardStackView.height(for: items, size: preferences.size) - margin * 2 > QuickAccessPlacement.tallestStack(visible: visible), items.count > 1 {
            close(items.removeFirst())
        }
        let stack = self.stack ?? makeStack()
        stack.size = preferences.size
        stack.corner = preferences.corner
        guard let panel else { return }
        let frame = QuickAccessPlacement.panelFrame(
            corner: preferences.corner, visible: visible, panelWidth: CardStackView.width(for: preferences.size),
            panelHeight: CardStackView.height(for: items, size: preferences.size), margin: margin
        )
        if !panel.isVisible || panel.frame.origin != frame.origin || frame.height >= panel.frame.height {
            panel.setFrame(frame, display: true)
            stack.show(items, entering: entering)
        } else {
            stack.show(items, entering: entering) { [weak panel] in
                panel?.setFrame(frame, display: true)
            }
        }
        // The display actually used, so a stack moved off a removed display stays where it now is.
        self.displayID = screen.cgDirectDisplayID ?? displayID
    }

    private func tearDown() {
        guard items.isEmpty else { return }
        closer?.cancel()
        closer = nil
        schedule.removeAll()
        selectedID = nil
        keyboardHolder = nil
        stack?.quickLook.close()
        stack?.quickLook.detach()
        panel?.orderOut(nil)
        panel = nil
        stack = nil
        displayID = nil
        windowLease = nil
        MemoryRelief.returnFreedPages()
    }

    /// The display the pointer is on.
    private static func pointerDisplayID() -> CGDirectDisplayID? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }?.cgDirectDisplayID
    }

    private func makeStack() -> CardStackView {
        let stack = CardStackView()
        stack.onCopy = { [weak self] item in self?.actions.copy(item) }
        stack.onSave = { [weak self] item in self?.save(item, asking: false) }
        stack.onSaveAs = { [weak self] item in self?.save(item, asking: true) }
        stack.onOpen = { [weak self] item in self?.actions.open(item) }
        stack.onAnnotate = { [weak self] item in self?.actions.annotate(item) }
        stack.onReveal = { [weak self] item in self?.actions.reveal(item) }
        stack.onRecognizeText = { [weak self] item in self?.actions.recognizeText(item) }
        stack.onPin = { [weak self] item in self?.actions.pin(item) }
        stack.onPrint = { [weak self] item in self?.actions.print(item) }
        stack.onMoveToTrash = { [weak self] item in self?.trash(item) }
        stack.onClose = { [weak self] item in self?.dismiss(item.id) }
        stack.fileToHandOver = { [weak self] item in self?.actions.fileToHandOver(item) ?? item.fileURL }
        let sharing = actions.sharing
        stack.uploadMenu = sharing.menu
        stack.onUpload = sharing.upload
        stack.onCancelUpload = sharing.cancel
        stack.onRetryUpload = sharing.retry
        stack.onCopyLink = sharing.copyLink
        stack.hasLink = sharing.hasLink
        stack.canDeleteFromStorage = sharing.canDeleteFromStorage
        stack.onDeleteFromStorage = sharing.deleteFromStorage
        stack.currentUpload = sharing.current
        stack.onCommand = { [weak self] command, item in self?.perform(command, on: item) }
        stack.pictureOffer = actions.pictureChangeOffer
        stack.cardCount = { [weak self] in self?.items.count ?? 0 }
        stack.onHold = { [weak self] id, hold, on in self?.hold(hold, for: id, if: on) }
        stack.onFocus = { [weak self] id in self?.focus(on: id) }
        stack.onKey = { [weak self] command in self?.performKeyed(command) ?? false }
        stack.quickLook.onMove = { [weak self] offset in self?.move(by: offset)?.fileURL }
        stack.quickLook.onClose = { [weak self] in self?.previewClosed() }
        let panel = QuickAccessPanel()
        panel.contentView = stack
        panel.onResignKey = { [weak self] in self?.keyboardLost() }
        self.panel = panel
        self.stack = stack
        return stack
    }

    /// Saves a capture, and marks its card saved once it is. A second request for a capture still being saved waits for
    /// the first.
    private func save(_ item: QuickAccessItem, asking: Bool) {
        guard saving.insert(item.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            let url = await asking ? actions.saveAs(item) : actions.save(item)
            saving.remove(item.id)
            recordSave(of: item, at: url)
        }
    }

    private func recordSave(of item: QuickAccessItem, at url: URL?) {
        guard let url, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].savedURL = url
        stack?.markSaved(item.id, at: url)
    }

    /// Moves a capture to the Trash: its card goes, and when that card had the keyboard it moves on to the card
    /// beside it. A card trashed with the pointer leaves the keyboard where it is.
    private func trash(_ item: QuickAccessItem) {
        let next = neighbor(of: item.id)
        let hadKeyboard = selectedID == item.id
        items.removeAll { $0.id == item.id }
        schedule.forget(item.id)
        if hadKeyboard { selectedID = nil }
        actions.moveToTrash(item)
        refresh()
        if hadKeyboard, next != nil, panel?.isKeyWindow == true { select(next) }
    }

    // MARK: Closing by itself

    /// The time now, to count the cards' time against; stops while the Mac sleeps.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A card is kept from closing by itself (the pointer over it, its menu open, a drag out of it, an upload),
    /// or let go.
    private func hold(_ hold: CardCountdown.Hold, for id: UUID, if on: Bool) {
        guard items.contains(where: { $0.id == id }) else { return }
        schedule.hold(hold, for: id, if: on, at: Self.now)
        if schedule.isCounting(id) { scheduleCloser() }
    }

    /// Starts the time of every card that has none while Settings has cards close by themselves, and stops all of
    /// it while they do not. Cards already counting keep their own time, whatever the interval was.
    private func updateCountdowns() {
        schedule.sync(cards: items.map(\.id), interval: actions.preferences().closeInterval, at: Self.now)
        scheduleCloser()
    }

    /// Sleeps until the first card is due; nothing runs while every card is held or none counts down.
    private func scheduleCloser() {
        closer?.cancel()
        closer = nil
        guard let soonest = schedule.timeUntilNextClose(at: Self.now) else { return }
        closer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(soonest + 0.02))
            guard !Task.isCancelled else { return }
            self?.closeDueCards()
        }
    }

    private func closeDueCards() {
        for id in schedule.takeDue(at: Self.now) {
            guard let item = item(id) else { continue }
            if actions.preferences().closeAction == .saveAndClose, item.savedURL == nil {
                // The card goes once its copy is saved (which may first ask for a name). A copy that could not be
                // saved leaves the card, which may be the capture's only holder; it is not tried again.
                Task {
                    guard let url = await actions.save(item) else { return schedule.keepOpen(id) }
                    recordSave(of: item, at: url)
                    dismiss(id)
                }
                continue
            }
            dismiss(id)
        }
        scheduleCloser()
    }

    // MARK: Keyboard

    /// Gives the keyboard to a card: ringed, and its keys answered. The panel takes the keys without the
    /// app coming forward, so the app in front stays in front and is typed in again once the keys go back.
    private func focus(on id: UUID?) {
        guard let id, items.contains(where: { $0.id == id }), let panel, let stack else { return }
        select(id)
        panel.allowsKey = true
        panel.makeKey()
        panel.makeFirstResponder(stack)
    }

    /// Rings a card, holds it from closing, and lets the one before go; nil takes the ring away.
    private func select(_ id: UUID?) {
        if let previous = keyboardHolder { hold(.keyboard, for: previous, if: false) }
        selectedID = id
        keyboardHolder = id
        if let id { hold(.keyboard, for: id, if: true) }
        stack?.select(id)
    }

    /// The panel lost the keys (a click elsewhere, a window of this app in front). The ring goes unless the
    /// preview is up, which has the keys itself and returns them.
    private func keyboardLost() {
        guard stack?.quickLook.isShowing != true else { return }
        endKeyboard()
    }

    /// Gives the keyboard back to the app in front: the ring goes, and the panel is ordered out and in again,
    /// which hands the keys on without hiding the cards.
    private func endKeyboard() {
        select(nil)
        // With no card selected, the preview closing does not take the keys back.
        stack?.quickLook.close()
        guard let panel else { return }
        let hadKeys = panel.isKeyWindow
        panel.allowsKey = false
        if hadKeys {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// The keyboard moves to the newest card when the card that had it is gone.
    private func reselectIfNeeded() {
        guard let selectedID, !items.contains(where: { $0.id == selectedID }) else { return }
        select(items.last?.id)
    }

    private func previewClosed() {
        // The keys come back to the card, which the preview took them from.
        if let selectedID { focus(on: selectedID) }
    }

    private func neighbor(of id: UUID) -> UUID? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < items.count { return items[index + 1].id }
        return index > 0 ? items[index - 1].id : nil
    }

    /// Moves the keyboard `offset` cards on (-1 is the card above, an older one); the card it lands on, if any.
    @discardableResult
    private func move(by offset: Int) -> QuickAccessItem? {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let target = index + offset
        guard items.indices.contains(target) else { return nil }
        select(items[target].id)
        return items[target]
    }

    /// A key of the table arrived: done on the card that has the keyboard. False when no card has it.
    private func performKeyed(_ command: CardCommand) -> Bool {
        guard let selectedID, let item = item(selectedID) else { return false }
        perform(command, on: item)
        return true
    }

    // MARK: Commands

    /// What a card is told to do by its menu, its buttons, or the keyboard.
    private func perform(_ command: CardCommand, on item: QuickAccessItem) {
        switch command {
        case .copy:
            actions.copy(item)
            stack?.showCopied(item.id)
        case .save:
            // As the card's Save button: a saved card shows the copy in Finder.
            if item.savedURL != nil { actions.reveal(item) } else { Task { recordSave(of: item, at: await actions.save(item)) } }
        case .saveAs:
            endKeyboard()
            Task { recordSave(of: item, at: await actions.saveAs(item)) }
        case .annotate:
            endKeyboard()
            actions.annotate(item)
        case .open:
            endKeyboard()
            actions.open(item)
        case .recognizeText:
            endKeyboard()
            actions.recognizeText(item)
        case .print:
            endKeyboard()
            actions.print(item)
        case .pin:
            actions.pin(item)
        case .upload:
            if !actions.sharing.menu().isHidden { actions.sharing.upload(item, nil) }
        case .quickLook:
            toggleQuickLook(of: item)
        case .picture(let change):
            // Asked again: a key arrives without a menu having been read.
            guard actions.pictureChangeOffer(item).availability == .available else { return NSSound.beep() }
            actions.changePicture(item, change)
        case .moveToTrash:
            trash(item)
        case .close:
            dismiss(item.id)
            endKeyboard()
        case .saveAll:
            saveAll()
        case .closeAll:
            dismissAll()
            endKeyboard()
        case .selectOlder:
            move(by: -1)
            refreshPreview()
        case .selectNewer:
            move(by: 1)
            refreshPreview()
        }
    }

    private func toggleQuickLook(of item: QuickAccessItem) {
        guard let stack else { return }
        if stack.quickLook.isShowing {
            stack.quickLook.close()
            return
        }
        focus(on: item.id)
        stack.quickLook.show(item.fileURL)
    }

    private func refreshPreview() {
        guard let selectedID, let item = item(selectedID), stack?.quickLook.isShowing == true else { return }
        stack?.quickLook.replace(with: item.fileURL)
    }
}

extension CardUpload {
    /// Whether a card shows this upload and is kept from closing: one going, or one that failed and offers Retry.
    fileprivate var holdsCard: Bool {
        switch self {
        case .uploading, .failed: true
        case .finished: false
        }
    }
}

/// A transparent floating panel that never takes focus from the app being worked in. The cards draw
/// their own shadows. It takes the keys only when asked to (a click on a card, or the shortcut), and then
/// without bringing the app forward.
final class QuickAccessPanel: NSPanel {
    /// Whether the panel may become key: set when a card is clicked or the keyboard is asked for, and taken
    /// away when the keys go back.
    var allowsKey = false
    /// The panel gave up the keys.
    var onResignKey: (() -> Void)?

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

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
