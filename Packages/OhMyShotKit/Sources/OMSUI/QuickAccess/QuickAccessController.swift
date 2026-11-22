import AppKit
import Foundation
import OMSCore
import OMSDesign

/// Quick Access: after each capture a card appears in the corner of the screen, ready to be copied,
/// saved, dragged into another app, or dismissed. Nothing is saved anywhere until the user asks.
public final class QuickAccessController {
    public struct Actions {
        public var copy: (QuickAccessItem) async -> Bool
        /// Saves a copy to the export location and says how it went: where it went, cancelled, or why it failed, which
        /// the card then shows. Converting a large capture takes a while, so a card marks itself saved when this returns.
        /// `asks`: whether it may ask for the name first, as Settings say; false for a save nobody waits at (Save All, a
        /// card closing by itself).
        public var save: (QuickAccessItem, _ asks: Bool) async -> SaveOutcome
        /// Asks where to save a copy, and says how it went.
        public var saveAs: (QuickAccessItem) async -> SaveOutcome
        public var open: (QuickAccessItem) -> Void
        /// Opens the capture in the annotation editor.
        public var annotate: (QuickAccessItem) -> Void
        /// Opens a screenshot in a compact, editable preview. Movies keep the system's Quick Look.
        public var preview: ((QuickAccessItem) -> Void)?
        public var reveal: (QuickAccessItem) -> Void
        /// Opens the capture in the OCR panel.
        public var recognizeText: (QuickAccessItem) -> Void
        /// Reads the text in a screenshot and copies it (`TextCopier`).
        public var copyText: (QuickAccessItem) async -> TextCopy = { _ in .noText }
        /// Keeps the capture on screen as a pin.
        public var pin: (QuickAccessItem) async -> Bool
        /// Prints the capture's picture through the print panel.
        public var print: (QuickAccessItem) async -> Bool = { _ in false }
        public var moveToTrash: (QuickAccessItem) throws -> Void
        /// Neither the visible stack nor Recently Closed holds this capture any longer.
        public var closed: (QuickAccessItem) -> Void
        /// The file to hand to another app for a capture, when it is dragged out of its card or shared: the capture
        /// itself, or a copy in the format Settings choose; or why that copy could not be made, which the card then
        /// shows, and nothing goes.
        public var fileToHandOver: (QuickAccessItem) -> Result<URL, ExportFailure> = { .success($0.fileURL) }
        /// The QR codes and barcodes in a screenshot, looked for once its card shows, which its menu then offers to
        /// open or copy; none when Settings say not to look.
        public var codes: (QuickAccessItem) async -> [FoundCode] = { _ in [] }

        /// Where the cards stand, how large they are, and when they close by themselves (Settings); read each
        /// time a card appears.
        public var preferences: () -> QuickAccessPreferences = { QuickAccessPreferences() }

        /// Whether the annotation editor has the capture open: a card is not closed by itself under it.
        public var isBeingEdited: (QuickAccessItem) -> Bool = { _ in false }

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
            copy: @escaping (QuickAccessItem) async -> Bool,
            save: @escaping (QuickAccessItem, _ asks: Bool) async -> SaveOutcome,
            saveAs: @escaping (QuickAccessItem) async -> SaveOutcome,
            open: @escaping (QuickAccessItem) -> Void,
            annotate: @escaping (QuickAccessItem) -> Void,
            reveal: @escaping (QuickAccessItem) -> Void,
            recognizeText: @escaping (QuickAccessItem) -> Void,
            pin: @escaping (QuickAccessItem) async -> Bool,
            moveToTrash: @escaping (QuickAccessItem) throws -> Void,
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
    private let history: HistoryStore?
    lazy var showTrashFailure: (String) -> Void = {
        let notice = CopiedHUD()
        return { notice.show($0, near: NSEvent.mouseLocation) }
    }()
    /// Says by the pointer why a copy to hand over from a card could not be made, while the card itself says why a copy
    /// could not be saved.
    lazy var showHandOverFailure: (String) -> Void = { [unowned self] in showTrashFailure($0) }
    private var panel: QuickAccessPanel?
    private var firstCaptureHint: FirstCaptureHintController?

    /// Only the practice capture gets this hint. It holds that card's countdown without changing preferences.
    public func showFirstCaptureHint(for id: UUID, isCopied: Bool) {
        dismissFirstCaptureHint()
        guard let item = item(id), let frame = screenFrame(ofCard: id), !isTrashing(id) else { return }
        let hint = FirstCaptureHintController(captureID: id, isCopied: isCopied, isSaved: item.savedURL != nil) { [weak self] in
            self?.dismissFirstCaptureHint()
        }
        firstCaptureHint = hint
        hold(.onboarding, for: id, if: true)
        hint.show(near: frame)
    }

    public func dismissFirstCaptureHint() {
        guard let hint = firstCaptureHint else { return }
        firstCaptureHint = nil
        hint.dismiss()
        hold(.onboarding, for: hint.captureID, if: false)
    }

    private func updateFirstCaptureHint() {
        guard let hint = firstCaptureHint else { return }
        guard item(hint.captureID) != nil, !isTrashing(hint.captureID), let frame = screenFrame(ofCard: hint.captureID) else {
            return dismissFirstCaptureHint()
        }
        hint.place(near: frame)
    }

    #if DEBUG
    /// The cards' panel while it shows, for scripted captures of it.
    public var debugPanel: NSWindow? { panel }
    public var debugFirstCaptureHintWindow: NSWindow? { firstCaptureHint?.debugWindow }
    /// The hint's card on screen, without the room its panel leaves around it for the shadow.
    public var debugFirstCaptureHintCardFrame: CGRect? { firstCaptureHint?.debugCardFrame }

    /// Moves the newest card to the Trash as its Trash button does, for scripted checks.
    public func debugTrashLatest() {
        guard let latest = liveItems.last else { return }
        trash(latest)
    }

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
    /// The saves under way, by capture: a second request for one joins it instead of saving again, so a double ⌘S, or a
    /// card closing by itself under a Save being asked for, saves once and takes one number.
    private let saves = SingleFlight<UUID, SaveOutcome>()
    /// Why a copy of a card's capture could not be saved, by capture, while its card says so and is held from closing.
    private var failures: [UUID: ExportFailure] = [:]
    private var items: [QuickAccessItem] = []
    private var recentlyClosed: [(item: QuickAccessItem, evicted: Bool)] = []
    private struct SavedCopies {
        var savedURL: URL?
        var ownSavedURL: URL?
    }
    private var savedCopiesByID: [UUID: SavedCopies] = [:]
    private var savedCopiesPrunedAt: TimeInterval?
    private static let savedCopiesPruneInterval: TimeInterval = 60
    private static let hiddenThumbnail: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }()
    private var thumbnailUpdates: [UUID: Task<Void, Never>] = [:]
    /// Cards moved to the Trash and waiting to go, oldest first, each with the task that sends it on. A card stays
    /// `trashDelay` under Undo, still in `items`, and only then is its capture moved to the Trash, which takes its
    /// record, marks, and text with it: Undo, ⌘Z, and Restore Recently Closed bring it back until then.
    private var trashing: [(id: UUID, sender: Task<Void, Never>)] = []
    /// How long a card moved to the Trash waits under Undo.
    static let trashDelay: Duration = .seconds(5)
    /// The display the stack sits on.
    private var displayID: CGDirectDisplayID?
    private var windowLease: ActiveResources.Lease?

    /// What keeps each card from closing by itself right now, and when each card closes while Settings says
    /// cards do.
    private var schedule = CardCloseSchedule()
    private var closer: Task<Void, Never>?
    /// The card that has the keyboard, once the panel was clicked or asked for; it is held from closing by the
    /// keyboard, and let go when the keys go to another card.
    private var selectedID: UUID?
    /// The card the pointer is actively hovering over (`mouseEntered`).
    private(set) var hoveredID: UUID?
    private let hoverPreviewShortcut = HoverPreviewShortcut()

    public init(actions: Actions, history: HistoryStore? = nil) {
        self.actions = actions
        self.history = history
        hoverPreviewShortcut.onPreview = { [weak self] in self?.previewHoveredCard() }
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The captures currently shown as cards.
    public var itemIDs: Set<UUID> { Set(items.map(\.id)) }

    /// With history off, a displaced card needs its capture until it leaves Recently Closed.
    /// With timed history, the restore offer lasts only as long as the file does.
    public func heldCaptureIDs(for retention: HistoryRetention) -> Set<UUID> {
        guard retention == .never else { return itemIDs }
        return itemIDs.union(recentlyClosed.compactMap { $0.evicted ? $0.item.id : nil })
    }

    /// The card showing capture `id`, if one is.
    public func item(_ id: UUID) -> QuickAccessItem? {
        items.first { $0.id == id }
    }

    private func rememberSavedCopies(for item: QuickAccessItem) {
        setSavedCopies(SavedCopies(savedURL: item.savedURL, ownSavedURL: item.ownSavedURL), for: item.id)
    }

    private func setSavedCopies(_ copies: SavedCopies, for id: UUID) {
        if copies.savedURL == nil && copies.ownSavedURL == nil {
            savedCopiesByID[id] = nil
        } else {
            savedCopiesByID[id] = copies
        }
    }

    private func pruneSavedCopiesIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard savedCopiesPrunedAt.map({ now - $0 >= Self.savedCopiesPruneInterval }) ?? true else { return }
        savedCopiesPrunedAt = now
        if let history {
            savedCopiesByID = savedCopiesByID.filter { history.item(id: $0.key) != nil }
        } else {
            var trackedIDs = Set(items.map(\.id))
            trackedIDs.formUnion(recentlyClosed.map { $0.item.id })
            trackedIDs.formUnion(trashing.map(\.id))
            savedCopiesByID = savedCopiesByID.filter { trackedIDs.contains($0.key) }
        }
    }

    /// Whether two copies are one file: the same address, or the same file now however its folders are written, and in
    /// either letter case on a disk that ignores case.
    private static func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs == rhs || AtomicFileCopy.isSameFile(lhs, rhs)
    }

    private func visibleOrRecentlyClosedItem(_ id: UUID) -> QuickAccessItem? {
        item(id) ?? recentlyClosed.first { $0.item.id == id }?.item
    }

    public var canRestoreRecentlyClosed: Bool {
        !trashing.isEmpty || recentlyClosed.reversed().contains { canRestore($0.item) }
    }

    private func canRestore(_ item: QuickAccessItem) -> Bool {
        history?.item(forFileAt: item.fileURL)?.id == item.id
    }

    /// History may have finished loading before the file was replaced. Check its record before showing
    /// anything, and register a new card before decoding so a subsequent edit supersedes that decoding.
    public func restore(_ entry: HistoryItem, on displayID: CGDirectDisplayID) {
        guard let history else { return }
        let url = history.fileURL(for: entry)
        guard let current = history.item(forFileAt: url), current.id == entry.id else { return }
        pruneSavedCopiesIfNeeded()
        if let card = visibleOrRecentlyClosedItem(entry.id) {
            add(card)
        } else {
            add(QuickAccessItem(current, fileURL: url, thumbnail: Self.hiddenThumbnail, displayID: displayID))
            pictureChanged(current, savedCopyIsStale: false) {
                await HistoryStore.cardThumbnail(of: url, maxPixels: QuickAccessItem.thumbnailPixels)
            }
        }
    }

    private func isTrashing(_ id: UUID) -> Bool {
        trashing.contains { $0.id == id }
    }

    /// The cards not waiting to go to the Trash: what the keyboard, closing by itself, and the stack's commands act on.
    private var liveItems: [QuickAccessItem] {
        items.filter { !isTrashing($0.id) }
    }

    /// Shows a card for `item`, or brings an existing card for it back to the bottom of the stack.
    public func add(_ item: QuickAccessItem) {
        if firstCaptureHint?.captureID != item.id { dismissFirstCaptureHint() }
        completing[item.id] = nil
        hold(.action, for: item.id, if: false)
        // Restored while its card waits to go to the Trash: it stays.
        if let index = trashing.firstIndex(where: { $0.id == item.id }) {
            trashing.remove(at: index).sender.cancel()
            stack?.setTrashing(false, for: item.id)
        }
        insertIntoStack(item)
        let preferences = actions.preferences()
        let target = QuickAccessPlacement.display(forCaptureOn: item.displayID, pointerOn: Self.pointerDisplayID(), followsPointer: preferences.onPointerDisplay)
        present(entering: item.id, on: target)
        panel?.orderFrontRegardless()
        stack?.updatePointerHover()
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        // A card brought back anew starts its time again; one already up keeps its own.
        schedule.restart(item.id)
        if let upload = actions.sharing.current(item) { hold(.upload, for: item.id, if: upload.holdsCard) }
        if actions.isBeingEdited(item) { hold(.editor, for: item.id, if: true) }
        reselectIfNeeded()
        updateCountdowns()
    }

    func insertIntoStack(_ item: QuickAccessItem) {
        pruneSavedCopiesIfNeeded()
        var item = item
        if let copies = savedCopiesByID[item.id] {
            let cachedSavedIsExternal = copies.savedURL.map { savedURL in
                copies.ownSavedURL.map { !Self.sameFileURL(savedURL, $0) } ?? true
            } ?? false
            if cachedSavedIsExternal || item.savedURL == nil { item.savedURL = copies.savedURL }
            item.ownSavedURL = item.ownSavedURL ?? copies.ownSavedURL
            if cachedSavedIsExternal, let savedURL = copies.savedURL, let ownURL = item.ownSavedURL,
               Self.sameFileURL(savedURL, ownURL) {
                item.ownSavedURL = nil
            }
        }
        rememberSavedCopies(for: item)
        items.removeAll { $0.id == item.id }
        recentlyClosed.removeAll { $0.item.id == item.id }
        items.append(item)
        while items.count > maximumCards { letGo(items.removeFirst(), evicted: true) }
    }

    /// Shows a capture's new picture (marked up, or put back as taken) on its card, where it is. When `keepsSaved` is
    /// false, its old export no longer counts as saved and the card offers Save again; ownership of that export remains.
    private func update(_ item: QuickAccessItem, keepsSaved: Bool = true) {
        var item = item
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            if let closed = recentlyClosed.firstIndex(where: { $0.item.id == item.id }) {
                item.savedURL = keepsSaved ? item.savedURL ?? recentlyClosed[closed].item.savedURL : nil
                item.ownSavedURL = item.ownSavedURL ?? recentlyClosed[closed].item.ownSavedURL
                recentlyClosed[closed].item = item
                rememberSavedCopies(for: item)
            }
            return
        }
        if keepsSaved {
            item.savedURL = item.savedURL ?? items[index].savedURL
            item.ownSavedURL = item.ownSavedURL ?? items[index].ownSavedURL
        } else {
            item.savedURL = nil
            item.ownSavedURL = item.ownSavedURL ?? items[index].ownSavedURL
            stack?.markUnsaved(item.id)
        }
        rememberSavedCopies(for: item)
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

    /// The old pixels must not be restored while the edited thumbnail is decoding, even if decoding fails.
    @discardableResult
    public func pictureChanged(_ entry: HistoryItem, savedCopyIsStale: Bool, thumbnail: @escaping () async -> CGImage?) -> Task<Void, Never>? {
        pruneSavedCopiesIfNeeded()
        // A capture without a card forgets its saved copy too, so a card restored later offers Save again.
        if savedCopyIsStale, var copies = savedCopiesByID[entry.id] {
            copies.savedURL = nil
            setSavedCopies(copies, for: entry.id)
        }
        guard let card = visibleOrRecentlyClosedItem(entry.id) else { return nil }
        update(QuickAccessItem(entry, fileURL: card.fileURL, thumbnail: Self.hiddenThumbnail, displayID: card.displayID), keepsSaved: !savedCopyIsStale)
        thumbnailUpdates[entry.id]?.cancel()
        let task = Task { [weak self] in
            let image = await thumbnail()
            guard !Task.isCancelled, let self else { return }
            thumbnailUpdates[entry.id] = nil
            guard let image, let current = visibleOrRecentlyClosedItem(entry.id) else { return }
            update(QuickAccessItem(entry, fileURL: current.fileURL, thumbnail: image, displayID: current.displayID))
        }
        thumbnailUpdates[entry.id] = task
        return task
    }

    /// Shows on capture `id`'s card why a copy of it could not be saved, or made to be dragged out, shared, or uploaded,
    /// says it to VoiceOver, and holds the card from closing by itself until a copy is saved (or, for one to hand over,
    /// made) or the card is closed, as a failed upload holds it. False when the capture has no card on screen to say it,
    /// so the caller can say it elsewhere; so too for a copy to hand over while the card says a copy could not be saved,
    /// which stays said and held, since making one to hand over saves nothing.
    @discardableResult
    public func showFailure(_ failure: ExportFailure, for id: UUID) -> Bool {
        guard item(id) != nil, !isTrashing(id) else { return false }
        guard failure.step == .saving || failures[id]?.step != .saving else { return false }
        failures[id] = failure
        stack?.setFailure(failure, for: id)
        hold(.failure, for: id, if: true)
        return true
    }

    /// Why capture `id`'s card says a copy of it could not be saved, while it does.
    func failure(for id: UUID) -> ExportFailure? {
        failures[id]
    }

    /// Capture `id`'s card no longer has a failure to show: a copy was saved, or made to hand over, after all.
    func clearFailure(for id: UUID) {
        guard failures.removeValue(forKey: id) != nil else { return }
        stack?.setFailure(nil, for: id)
        hold(.failure, for: id, if: false)
    }

    /// A copy of capture `id` to hand over (dragged out, shared, or uploaded) was made after all: its card no longer says
    /// one couldn't be. A copy that could not be saved is still said and held.
    public func clearHandOverFailure(for id: UUID) {
        if failures[id]?.step == .converting { clearFailure(for: id) }
    }

    /// Marks a capture saved on its card: a copy of it is at `url`, so the card is not saved again when it closes by itself.
    /// `byCard`: the card saved it itself, and its Move to Trash takes it with the capture. A copy saved elsewhere (from the
    /// editor or Capture History) is not the card's to take: its Trash leaves it, and takes only a copy of its own, if any.
    /// A stale external copy never marks the capture saved or clears a failure; it invalidates a matching saved URL and relinquishes matching card ownership.
    public func markSaved(_ id: UUID, at url: URL, byCard: Bool = false, isCurrent: Bool = true) {
        pruneSavedCopiesIfNeeded()
        if let history, history.item(id: id) == nil {
            savedCopiesByID[id] = nil
            return
        }
        let currentItem = visibleOrRecentlyClosedItem(id)
        let currentOwnURL = currentItem?.ownSavedURL ?? savedCopiesByID[id]?.ownSavedURL
        if !isCurrent {
            guard !byCard else { return }
            let currentSavedURL: URL?
            if let currentItem {
                currentSavedURL = currentItem.savedURL
            } else {
                currentSavedURL = savedCopiesByID[id]?.savedURL
            }
            let replacesSavedCopy = currentSavedURL.map { Self.sameFileURL(url, $0) } ?? false
            let replacesOwnedCopy = currentOwnURL.map { Self.sameFileURL(url, $0) } ?? false
            guard replacesSavedCopy || replacesOwnedCopy else { return }
            let copies = SavedCopies(
                savedURL: replacesSavedCopy ? nil : currentSavedURL,
                ownSavedURL: replacesOwnedCopy ? nil : currentOwnURL
            )
            setSavedCopies(copies, for: id)
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].savedURL = copies.savedURL
                items[index].ownSavedURL = copies.ownSavedURL
                if replacesSavedCopy { stack?.markUnsaved(id) }
            }
            if let index = recentlyClosed.firstIndex(where: { $0.item.id == id }) {
                recentlyClosed[index].item.savedURL = copies.savedURL
                recentlyClosed[index].item.ownSavedURL = copies.ownSavedURL
            }
            return
        }
        var copies = SavedCopies(savedURL: url, ownSavedURL: byCard ? url : currentOwnURL)
        if !byCard, let ownURL = copies.ownSavedURL, Self.sameFileURL(url, ownURL) {
            copies.ownSavedURL = nil
        }
        setSavedCopies(copies, for: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].savedURL = url
            items[index].ownSavedURL = copies.ownSavedURL
            stack?.markSaved(id, at: url)
            clearFailure(for: id)
        } else if let index = recentlyClosed.firstIndex(where: { $0.item.id == id }) {
            recentlyClosed[index].item.savedURL = url
            recentlyClosed[index].item.ownSavedURL = copies.ownSavedURL
        }
    }

    /// Shows how a capture's upload stands on its card, if it has one; a card made later asks the actions. A card
    /// is not closed by itself while its upload goes, nor after it failed and waits for Retry.
    public func setUpload(_ upload: CardUpload?, for id: UUID) {
        stack?.setUpload(upload, for: id)
        hold(.upload, for: id, if: upload?.holdsCard ?? false)
    }

    /// The annotation editor opened (or closed) on a capture. A card is not closed by itself while it is open, and has
    /// at least `CardCountdown.grace` more seconds once it is closed.
    public func setEditing(_ editing: Bool, for id: UUID) {
        if editing, firstCaptureHint?.captureID == id { dismissFirstCaptureHint() }
        hold(.editor, for: id, if: editing)
    }

    /// Where a capture's card is on screen, if it has one: for a confirmation shown beside it.
    public func screenFrame(ofCard id: UUID) -> CGRect? {
        stack?.screenFrame(ofCard: id)
    }

    /// The stack of cards as it stands on screen, shadow room left out, while it shows: what the text card keeps clear of.
    public var cardsFrame: CGRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame.insetBy(dx: CardStackView.margin, dy: CardStackView.margin)
    }

    /// Copies the newest card's capture: the keyboard path to Quick Access.
    public func copyLatest() {
        guard let latest = liveItems.last else { return }
        perform(.copy, on: latest, keyed: false)
    }

    /// Gives the newest card the keyboard, without the pointer: the cards then answer the keys of
    /// `CardKeys`. The app in front stays in front; Escape gives the keyboard back.
    public func focusLatest() {
        focus(on: liveItems.last?.id)
    }

    /// Opens the newest card's capture in the editor, as a double-click would, for scripted checks.
    public func annotateLatest() {
        guard let latest = liveItems.last else { return }
        actions.annotate(latest)
    }

    /// Shows the newest card's hover state without a pointer, for scripted checks.
    public func previewHoverOnLatest() {
        guard let latest = liveItems.last else { return }
        stack?.previewHover(latest.id)
    }

    public func dismiss(_ id: UUID) {
        guard !isTrashing(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        close(items.remove(at: index))
        refresh()
    }

    /// Closes the newest card, the one nearest the corner.
    public func dismissLatest() {
        guard let latest = liveItems.last else { return }
        dismiss(latest.id)
    }

    /// Closes every card; one waiting to go to the Trash goes there now.
    public func dismissAll() {
        // The cards are out of the stack when each is told it closed, so none of them still counts as holding its capture.
        let closing = items
        items.removeAll()
        closing.forEach { letGo($0, evicted: false) }
        refresh()
    }

    /// The app is quitting: drop the restore history and send cards waiting under Undo on to the Trash.
    public func finishTrashingNow() {
        for id in trashing.map(\.id) { finishTrashing(id) }
        let released = recentlyClosed.filter(\.evicted)
        recentlyClosed.removeAll()
        for entry in released { actions.closed(entry.item) }
    }

    /// Brings back a card waiting to go to the Trash: the one moved last, without `id`. False when none waits.
    @discardableResult
    public func undoTrash(_ id: UUID? = nil) -> Bool {
        let index = if let id { trashing.firstIndex { $0.id == id } } else { trashing.indices.last }
        guard let index else { return false }
        let pending = trashing.remove(at: index)
        pending.sender.cancel()
        stack?.setTrashing(false, for: pending.id)
        // Brought back, it starts its time again, as a card restored from Recently Closed does; one whose copy could not
        // be saved is held again, as it was before it went.
        schedule.restart(pending.id)
        if failures[pending.id] != nil { hold(.failure, for: pending.id, if: true) }
        // The Trash let its holds go; a Copy Text still reading holds it again.
        if readingText[pending.id] != nil { hold(.reading, for: pending.id, if: true) }
        updateCountdowns()
        return true
    }

    /// Saves a copy of every card's capture that has not been saved, as Save does on each, but under the file name
    /// pattern without asking: it is one command for many files, which Escape on one would not stop.
    public func saveAll() {
        let saving = liveItems
        Task {
            for item in saving {
                await finish(item) { [self] in
                    guard let current = self.item(item.id), !isTrashing(item.id) else { return true }
                    if current.savedURL != nil { return true }
                    return await save(current, .quiet).url != nil
                }
            }
        }
    }

    /// Removes a capture that was deleted elsewhere: its card goes without the closed callback, and it
    /// can no longer be restored.
    public func remove(_ id: UUID) {
        clearHover(for: id)
        savedCopiesByID[id] = nil
        thumbnailUpdates.removeValue(forKey: id)?.cancel()
        if firstCaptureHint?.captureID == id { dismissFirstCaptureHint() }
        completing[id] = nil
        failures[id] = nil
        recentlyClosed.removeAll { $0.item.id == id }
        if let index = trashing.firstIndex(where: { $0.id == id }) { trashing.remove(at: index).sender.cancel() }
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

    /// Brings back the card moved to the Trash last while it waits to go, or else the most recently closed card
    /// whose capture still exists.
    public func restoreRecentlyClosed() {
        if undoTrash() { return }
        if let item = takeRecentlyClosed() { add(item) }
    }

    func takeRecentlyClosed() -> QuickAccessItem? {
        while let entry = recentlyClosed.popLast() {
            if canRestore(entry.item) {
                return entry.item
            }
            if entry.evicted { actions.closed(entry.item) }
        }
        return nil
    }

    /// A card that left the stack goes on as it was: to the Trash if it waited to go there, else closed.
    private func letGo(_ item: QuickAccessItem, evicted: Bool) {
        if isTrashing(item.id) { sendToTrash(item) } else { close(item, evicted: evicted) }
    }

    private func rememberEvicted(_ item: QuickAccessItem) {
        close(item, evicted: true)
    }

    private func close(_ item: QuickAccessItem, evicted: Bool = false) {
        clearHover(for: item.id)
        if firstCaptureHint?.captureID == item.id { dismissFirstCaptureHint() }
        completing[item.id] = nil
        failures[item.id] = nil
        recentlyClosed.append((item, evicted))
        if recentlyClosed.count > 20 {
            let oldest = recentlyClosed.removeFirst()
            if oldest.evicted { actions.closed(oldest.item) }
        }
        schedule.forget(item.id)
        if !evicted { actions.closed(item) }
        pruneSavedCopiesIfNeeded()
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
        fitStack(to: QuickAccessPlacement.tallestStack(visible: visible), size: preferences.size)
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
        stack.updatePointerHover()
        // The display actually used, so a stack moved off a removed display stays where it now is.
        self.displayID = screen.cgDirectDisplayID ?? displayID
        updateFirstCaptureHint()
    }

    func fitStack(to height: CGFloat, size: QuickAccessSize) {
        while items.count > 1, CardStackView.height(for: items, size: size) - CardStackView.margin * 2 > height {
            letGo(items.removeFirst(), evicted: true)
        }
    }

    private func tearDown() {
        guard items.isEmpty else { return }
        dismissFirstCaptureHint()
        closer?.cancel()
        closer = nil
        schedule.removeAll()
        selectedID = nil
        hoveredID = nil
        hoverPreviewShortcut.stop()
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
        stack.onCommand = { [weak self] command, item in self?.perform(command, on: item, keyed: false) }
        stack.fileToHandOver = { [weak self] item in
            guard let self else { return nil }
            switch actions.fileToHandOver(item) {
            case .success(let file):
                clearHandOverFailure(for: item.id)
                return file
            case .failure(let failure):
                if !showFailure(failure, for: item.id) { showHandOverFailure(failure.summary) }
                return nil
            }
        }
        stack.findCodes = actions.codes
        let sharing = actions.sharing
        stack.uploadMenu = sharing.menu
        stack.hasLink = sharing.hasLink
        stack.canDeleteFromStorage = sharing.canDeleteFromStorage
        stack.currentUpload = sharing.current
        stack.currentFailure = { [weak self] item in self?.failure(for: item.id) }
        stack.pictureOffer = actions.pictureChangeOffer
        stack.cardCount = { [weak self] in self?.liveItems.count ?? 0 }
        stack.onHold = { [weak self] id, hold, on in
            if hold == .drag, on, self?.firstCaptureHint?.captureID == id { self?.dismissFirstCaptureHint() }
            self?.hold(hold, for: id, if: on)
        }
        stack.onFocus = { [weak self] id in self?.focus(on: id) }
        stack.onPointerHover = { [weak self] id, hovering in self?.pointerHovered(id, hovering: hovering) }
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

    /// How a capture is saved.
    private enum SaveKind {
        /// The card's Save: named from the file name pattern, asking for the name when Settings say so.
        case save
        /// Save As…, in the system's panel.
        case saveAs
        /// A save nobody waits at (Save All, a card closing by itself): named from the pattern, never asked.
        case quiet
    }

    /// Saves a capture, and marks its card saved once it is, or has it say why it was not. A second request for a
    /// capture still being saved waits for the first and has its answer, whatever kind it is, so a capture is saved
    /// once however many ways ask.
    @discardableResult
    private func save(_ item: QuickAccessItem, _ kind: SaveKind) async -> SaveOutcome {
        await saves.run(item.id) { [self] in
            let outcome = switch kind {
            case .save: await actions.save(item, true)
            case .saveAs: await actions.saveAs(item)
            case .quiet: await actions.save(item, false)
            }
            switch outcome {
            case .saved(let url): markSaved(item.id, at: url, byCard: true)
            case .failed(let failure): showFailure(failure, for: item.id)
            case .cancelled: break
            }
            return outcome
        }
    }

    /// Moves a capture to the Trash: its card waits `trashDelay` under Undo, then goes, and its capture with it. When
    /// that card had the keyboard, the keyboard moves on to the card beside it; a card trashed with the pointer leaves
    /// the keyboard where it is.
    private func trash(_ item: QuickAccessItem) {
        guard items.contains(where: { $0.id == item.id }), !isTrashing(item.id) else { return }
        guard !actions.isBeingEdited(item) else {
            showTrashFailure(String(localized: "Close the capture’s editor first.", bundle: .module))
            return
        }
        completing[item.id] = nil
        let next = neighbor(of: item.id)
        let hadKeyboard = selectedID == item.id
        clearHover(for: item.id)
        schedule.forget(item.id)
        if hadKeyboard { select(nil) }
        let sender = Task { [weak self] in
            try? await Task.sleep(for: Self.trashDelay)
            guard !Task.isCancelled else { return }
            self?.finishTrashing(item.id)
        }
        trashing.append((item.id, sender))
        stack?.setTrashing(true, for: item.id)
        updateCountdowns()
        if hadKeyboard, next != nil, panel?.isKeyWindow == true { select(next) }
        if let panel {
            VoiceOver.announce(String(localized: "Moved to Trash", bundle: .module), from: panel)
        }
    }

    /// A card's wait under Undo is over: it goes, and its capture to the Trash.
    private func finishTrashing(_ id: UUID) {
        guard isTrashing(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        sendToTrash(items[index])
        refresh()
    }

    /// Moves a capture to the Trash after Undo expires. A failure keeps its card available for retry.
    private func sendToTrash(_ item: QuickAccessItem) {
        if let index = trashing.firstIndex(where: { $0.id == item.id }) { trashing.remove(at: index).sender.cancel() }
        let message: String
        if actions.isBeingEdited(item) {
            message = String(localized: "Close the capture’s editor first.", bundle: .module)
        } else {
            do {
                try actions.moveToTrash(item)
                savedCopiesByID[item.id] = nil
                items.removeAll { $0.id == item.id }
                failures[item.id] = nil
                return
            } catch {
                message = String(localized: "Couldn’t Move to Trash", bundle: .module)
            }
        }
        if items.contains(where: { $0.id == item.id }) {
            stack?.setTrashing(false, for: item.id)
            schedule.keepOpen(item.id)
            updateCountdowns()
        } else {
            rememberEvicted(item)
        }
        showTrashFailure(message)
    }

    // MARK: Closing by itself

    /// The time now, to count the cards' time against; stops while the Mac sleeps.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A card is kept from closing by itself (the pointer over it, its menu open, a drag out of it, an upload),
    /// or let go.
    private func hold(_ hold: CardCountdown.Hold, for id: UUID, if on: Bool) {
        guard items.contains(where: { $0.id == id }), !isTrashing(id) else { return }
        schedule.hold(hold, for: id, if: on, at: Self.now)
        if hold == .pointer {
            if on { hoveredID = id } else if hoveredID == id { hoveredID = nil }
        }
        if hold == .pointer || hold == .editor || hold == .menu || hold == .drag { updateHoverPreviewShortcut() }
        if schedule.isCounting(id) { scheduleCloser() }
    }

    private func updateHoverPreviewShortcut() {
        let hovered = hoveredID.flatMap { item($0) }
        let eligible = hovered.map {
            schedule.holds(on: $0.id).isDisjoint(with: [.menu, .drag, .editor, .preview])
                && !actions.isBeingEdited($0) && stack?.quickLook.isShowing != true && NSApp.modalWindow == nil
        } ?? false
        hoverPreviewShortcut.setEnabled(eligible)
    }

    private func clearHover(for id: UUID) {
        guard hoveredID == id else { return }
        hoveredID = nil
        hoverPreviewShortcut.stop()
    }

    private func previewHoveredCard() {
        guard let id = hoveredID, let item = item(id) else {
            hoveredID = nil
            hoverPreviewShortcut.stop()
            return
        }
        // A stale exit event must never open a card after the pointer has left the actual card.
        guard stack?.screenFrame(ofCard: id)?.contains(NSEvent.mouseLocation) == true else {
            hold(.pointer, for: id, if: false)
            return
        }
        hoverPreviewShortcut.stop()
        toggleQuickLook(of: item)
    }

    /// Starts the time of every card that has none while Settings has cards close by themselves, and stops all of
    /// it while they do not. Cards already counting keep their own time, whatever the interval was.
    private func updateCountdowns() {
        schedule.sync(cards: liveItems.map(\.id), interval: actions.preferences().closeInterval, at: Self.now)
        scheduleCloser()
    }

    /// Sleeps until the first card is due; nothing runs while every card is held or none counts down.
    private func scheduleCloser() {
        closer?.cancel()
        closer = nil
        let now = Self.now
        for item in liveItems {
            stack?.setCountdown(schedule.countdownState(for: item.id, at: now), for: item.id)
        }
        guard let soonest = schedule.timeUntilNextClose(at: now) else { return }
        closer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(soonest + 0.02))
            guard !Task.isCancelled else { return }
            self?.closeDueCards(at: Self.now)
        }
    }

    func closeDueCards(at now: TimeInterval) {
        for id in schedule.takeDue(at: now) {
            guard let item = item(id) else { continue }
            if actions.preferences().closeAction == .saveAndClose, item.savedURL == nil {
                // The card goes once its copy is saved, which never asks for a name: nobody is waiting for it. A copy that
                // could not be saved leaves the card, which may be the capture's only holder; it is not tried again. A
                // copy being saved already (by hand) is the one waited for.
                Task {
                    let saved = await save(item, .quiet)
                    guard self.item(id) != nil else { return }
                    guard saved.url != nil else { return schedule.keepOpen(id) }
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

    /// The pointer actively entered a card (or left it, which changes nothing): when the panel already holds the
    /// keyboard, the selection ring moves to the card under it, without ordering or re-keying the panel.
    private func pointerHovered(_ id: UUID, hovering: Bool) {
        guard hovering, items.contains(where: { $0.id == id }), !isTrashing(id) else { return }
        if panel?.isKeyWindow == true, selectedID != id {
            select(id)
        }
    }

    /// Rings a card, holds it from closing, and lets the one before go; nil takes the ring away.
    private func select(_ id: UUID?) {
        if let previous = selectedID { hold(.keyboard, for: previous, if: false) }
        selectedID = id
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
        guard let selectedID, !liveItems.contains(where: { $0.id == selectedID }) else { return }
        select(liveItems.last?.id)
    }

    private func previewClosed() {
        // The keys come back to the card, which the preview took them from.
        if let selectedID { focus(on: selectedID) }
        updateHoverPreviewShortcut()
    }

    /// The card beside `id` that is not waiting to go to the Trash: the newer one, else the older.
    private func neighbor(of id: UUID) -> UUID? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let live = { (item: QuickAccessItem) in !self.isTrashing(item.id) }
        return items[(index + 1)...].first(where: live)?.id ?? items[..<index].last(where: live)?.id
    }

    /// Moves the keyboard `offset` cards on (-1 is the card above, an older one); the card it lands on, if any.
    @discardableResult
    private func move(by offset: Int) -> QuickAccessItem? {
        let items = liveItems
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let target = index + offset
        guard items.indices.contains(target) else { return nil }
        select(items[target].id)
        return items[target]
    }

    /// A key of the table arrived: done on the card that has the keyboard. False when no card has it.
    private func performKeyed(_ command: CardCommand) -> Bool {
        // ⌘Z brings back the card moved to the Trash last, whichever card has the ring.
        if command == .undoTrash { return undoTrash() }
        guard let selectedID, let item = item(selectedID) else { return false }
        perform(command, on: item, keyed: true)
        return true
    }

    /// Keep the source alive while an action consumes it. Failure or cancellation leaves the card available.
    private var completing: [UUID: UUID] = [:]

    /// `keepsCard`: the card stays once the action succeeds, as it does after a copy made with Option.
    private func complete(
        _ item: QuickAccessItem, showsCopyConfirmation: Bool = false, keepsCard: Bool = false, action: @escaping () async -> Bool
    ) {
        Task { await finish(item, showsCopyConfirmation: showsCopyConfirmation, keepsCard: keepsCard, action: action) }
    }

    private func finish(_ item: QuickAccessItem, showsCopyConfirmation: Bool = false, keepsCard: Bool = false, action: () async -> Bool) async {
        guard self.item(item.id) != nil, !isTrashing(item.id), completing[item.id] == nil else { return }
        let completion = UUID()
        completing[item.id] = completion
        hold(.action, for: item.id, if: true)
        let succeeded = await action()
        guard completing[item.id] == completion else { return }
        if succeeded, showsCopyConfirmation {
            stack?.showCopied(item.id)
            try? await Task.sleep(for: .milliseconds(900))
            guard completing[item.id] == completion else { return }
        }
        completing[item.id] = nil
        hold(.action, for: item.id, if: false)
        if succeeded, !keepsCard { dismiss(item.id) }
    }

    // MARK: Commands

    /// What a card is told to do by its buttons, its menu, VoiceOver, or the keyboard: every way in comes here, so
    /// each command is done one way. `keyed`: it came from a key, and one that takes the person to a window or a
    /// panel, or closes the card, gives the keyboard back to the app in front first, as the click that would have
    /// done it with the pointer never came. Close All gives it back however it was asked for: no card is left to hold it.
    func perform(_ command: CardCommand, on item: QuickAccessItem, keyed: Bool) {
        if firstCaptureHint?.captureID == item.id { dismissFirstCaptureHint() }
        // A card waiting to go to the Trash only comes back.
        guard !isTrashing(item.id) else {
            if command == .undoTrash { undoTrash(item.id) }
            return
        }
        switch command {
        case .copy:
            if keyed { endKeyboard() }
            complete(item, showsCopyConfirmation: true) { [self] in await actions.copy(item) }
        case .copyAndKeep:
            complete(item, showsCopyConfirmation: true, keepsCard: true) { [self] in await actions.copy(item) }
        case .save:
            if keyed { endKeyboard() }
            complete(item) { [self] in
                if item.savedURL != nil {
                    actions.reveal(item)
                    return true
                }
                return await save(item, .save).url != nil
            }
        case .saveAs:
            if keyed { endKeyboard() }
            complete(item) { [self] in await save(item, .saveAs).url != nil }
        case .annotate:
            if keyed { endKeyboard() }
            actions.annotate(item)
        case .open:
            if keyed { endKeyboard() }
            actions.open(item)
        case .reveal:
            actions.reveal(item)
        case .recognizeText:
            if keyed { endKeyboard() }
            actions.recognizeText(item)
        case .copyText:
            copyText(item)
        case .print:
            if keyed { endKeyboard() }
            complete(item) { [self] in await actions.print(item) }
        case .pin:
            if keyed { endKeyboard() }
            complete(item) { [self] in await actions.pin(item) }
        case .upload:
            // Asked again: a key arrives without a menu having been read.
            if !actions.sharing.menu().isHidden { actions.sharing.upload(item, nil) }
        case .uploadTo(let destination):
            actions.sharing.upload(item, destination)
        case .cancelUpload:
            actions.sharing.cancel(item)
        case .retryUpload:
            actions.sharing.retry(item)
        case .copyLink:
            guard actions.sharing.hasLink(item) else { return }
            actions.sharing.copyLink(item)
            dismiss(item.id)
            if keyed { endKeyboard() }
        case .deleteFromStorage:
            actions.sharing.deleteFromStorage(item)
        case .quickLook:
            toggleQuickLook(of: item)
        case .picture(let change):
            // Asked again: a key arrives without a menu having been read.
            guard actions.pictureChangeOffer(item).availability == .available else { return NSSound.beep() }
            actions.changePicture(item, change)
        case .moveToTrash:
            trash(item)
        case .undoTrash:
            // Only a card waiting to go comes back (above); ⌘Z, which brings back the last one, never reaches here.
            break
        case .close:
            dismiss(item.id)
            if keyed { endKeyboard() }
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

    /// The Copy Text reading going on each card: asked again, the newer one is the one the card waits for.
    private var readingText: [UUID: UUID] = [:]

    /// Copy Text: the screenshot's text goes to the clipboard and the card says how much, or that it held none, and
    /// stays, held from closing by itself while it is read. A reading overtaken by a newer copy says nothing.
    private func copyText(_ item: QuickAccessItem) {
        guard item.kind == .screenshot else { return }
        let reading = UUID()
        readingText[item.id] = reading
        hold(.reading, for: item.id, if: true)
        Task {
            let copy = await actions.copyText(item)
            guard readingText[item.id] == reading else { return }
            readingText[item.id] = nil
            hold(.reading, for: item.id, if: false)
            guard self.item(item.id) != nil, !isTrashing(item.id) else { return }
            stack?.showTextCopy(copy, on: item.id)
        }
    }

    private func toggleQuickLook(of item: QuickAccessItem) {
        guard let stack else { return }
        hoverPreviewShortcut.stop()
        if item.kind == .screenshot, let preview = actions.preview {
            endKeyboard()
            preview(item)
            return
        }
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
        // The buttons' names show while the app in front is another's, as it nearly always is.
        allowsToolTipsWhenApplicationIsInactive = true
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
