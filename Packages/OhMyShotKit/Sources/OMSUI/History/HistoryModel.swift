import AppKit
import Foundation
import CoreTransferable
import Observation
import OMSCore
import OMSDesign
import SwiftUI

@MainActor
@Observable
final class HistoryModel {
    typealias TextLoader = @MainActor @Sendable ([HistoryItem], HistoryStore) async -> [UUID: HistorySearch.Entry]
    typealias ItemsLoader = @MainActor @Sendable (HistoryStore) async -> [HistoryItem]
    typealias Searcher = @MainActor @Sendable (String, [UUID: UInt64], HistorySearchIndex) async throws -> HistorySearchIndex.Result
    typealias ThumbnailLoader = @MainActor @Sendable (URL) async -> CGImage?

    enum Filter: String, CaseIterable, Identifiable {
        case all, screenshots, recordings, favorites
        var id: String { rawValue }
    }

    enum DateFilter: String, CaseIterable, Identifiable {
        case any, today, last7Days, last30Days
        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: String(localized: "Any Date", bundle: .module)
            case .today: String(localized: "Today", bundle: .module)
            case .last7Days: String(localized: "Last 7 Days", bundle: .module)
            case .last30Days: String(localized: "Last 30 Days", bundle: .module)
            }
        }

        func matches(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
            switch self {
            case .any: true
            case .today: calendar.isDate(date, inSameDayAs: now)
            case .last7Days: now.timeIntervalSince(date) <= 7 * 86_400
            case .last30Days: now.timeIntervalSince(date) <= 30 * 86_400
            }
        }
    }

    /// Brief confirmation shown after copying from History.
    struct CopyFeedback: Equatable {
        enum Kind: Equatable {
            case capture
            case text
        }

        let id = UUID()
        let count: Int
        let itemIDs: Set<UUID>
        let kind: Kind

        init(count: Int, itemIDs: Set<UUID>, kind: Kind = .capture) {
            self.count = count
            self.itemIDs = itemIDs
            self.kind = kind
        }
    }

    /// Single-item deletion deferred for 5 seconds so the user can Undo before the file moves to Trash.
    struct PendingTrash: Equatable {
        let id = UUID()
        let item: HistoryItem
    }

    var items: [HistoryItem] = [] {
        didSet { reconcileItems(from: oldValue) }
    }
    private(set) var isReloading = false
    private(set) var isSearchPending = false
    private(set) var isIndexing = false
    private(set) var searchResultRevision: UInt64 = 0
    var thumbnails: [UUID: CGImage] = [:]
    var filter: Filter = .all
    var appFilter: String?
    var dateFilter: DateFilter = .any
    /// The captures selected, as in Finder: a click selects one, ⌘-click adds one or takes it away, ⇧-click selects
    /// the run from the capture clicked last, and ⌘A every capture shown.
    var selection: Set<UUID> = []
    /// The capture the arrows move from and Space looks at: the one clicked or reached last.
    var focus: UUID?
    /// Where a ⇧-click or ⇧-arrow range starts; stays fixed while extending or contracting the range.
    @ObservationIgnored private var selectionAnchor: UUID?
    /// Brief copy confirmation toast and card indicator, cleared automatically after a moment.
    private(set) var copyFeedback: CopyFeedback?
    @ObservationIgnored private var copyFeedbackReset: Task<Void, Never>?
    /// Single capture hidden immediately and waiting to move to Trash unless Undo is clicked.
    private(set) var pendingTrash: PendingTrash?
    @ObservationIgnored private var pendingTrashTask: Task<Void, Never>?
    @ObservationIgnored private let trashDelay: Duration
    /// Captures waiting for the user to confirm they go to the Trash.
    var trashRequest: TrashRequest?
    var trashFailure: String?
    /// What is typed in the search field.
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    /// Where the search found each capture it found; nil while nothing is searched for.
    private(set) var matches: [UUID: HistorySearch.Match]?
    /// Captures whose text is still being read.
    var reading = 0
    /// Screenshots whose background OCR indexing failed on the latest pass, surfaced with a Retry button.
    var failedIndexingCount = 0
    /// Total disk usage across all active History captures in bytes, computed asynchronously off-main-actor.
    private(set) var totalDiskBytes: Int64?
    /// Optional direct hook to open a screenshot in Translated Recognized Text (overrides `HistoryActions.translate`).
    @ObservationIgnored var onTranslate: ((HistoryItem) -> Void)?
    /// Optional hook wired by `HistoryWindowController` to retry failed OCR indexing passes.
    @ObservationIgnored var onRetryIndexing: (() -> Void)?
    @ObservationIgnored private var diskUsageTask: Task<Void, Never>?
    @ObservationIgnored private var diskUsageRevision: UInt64 = 0
    @ObservationIgnored private var failedIndexingTask: Task<Void, Never>?
    /// The captures' text, ready for searching, as it has been read.
    @ObservationIgnored private var indexedIDs: Set<UUID> = []
    @ObservationIgnored private let copiedReading = CopiedHUD()
    @ObservationIgnored private let searchIndex = HistorySearchIndex()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchRevision: UInt64 = 0
    @ObservationIgnored private var searchTerms: [String] = []
    @ObservationIgnored private var excerptLoaded: Set<UUID> = []
    @ObservationIgnored private var excerptLoading: Set<UUID> = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadRevision: UInt64 = 0
    @ObservationIgnored private let itemsLoader: ItemsLoader
    @ObservationIgnored private let searcher: Searcher
    @ObservationIgnored private let searchDelay: Duration
    @ObservationIgnored private let thumbnailLoader: ThumbnailLoader
    @ObservationIgnored private var thumbnailGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var pendingThumbnails: Set<UUID> = []
    @ObservationIgnored private var thumbnailLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loading: Set<UUID> = []
    @ObservationIgnored private var textGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var pendingText: Set<UUID> = []
    @ObservationIgnored private var textLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let textLoader: TextLoader
    /// The file shown in Quick Look, if any.
    var previewURL: URL?
    let retention: RetentionSelection

    /// Thumbnails being made: the grid asks for every card it shows at once, which would take every core, and the
    /// cards scrolled away while they wait need none.
    @ObservationIgnored private let decodeSlots = Slots(count: 3)
    @ObservationIgnored private var isReleased = false

    @ObservationIgnored let store: HistoryStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let actions: HistoryActions
    /// The history window, for the print panel to come down from.
    @ObservationIgnored weak var window: NSWindow?

    init(
        store: HistoryStore, settings: SettingsStore, actions: HistoryActions, retentionPreview: @escaping RetentionPreview = { _ in nil },
        textLoader: TextLoader? = nil, itemsLoader: ItemsLoader? = nil, searcher: Searcher? = nil,
        searchDelay: Duration = .milliseconds(100), thumbnailLoader: ThumbnailLoader? = nil,
        trashDelay: Duration = .seconds(5)
    ) {
        self.store = store
        self.settings = settings
        self.actions = actions
        self.retention = RetentionSelection(settings: settings, preview: retentionPreview)
        self.textLoader = textLoader ?? { items, store in await Self.entries(of: items, in: store) }
        self.itemsLoader = itemsLoader ?? { store in await store.loadItems() }
        self.searcher = searcher ?? { query, generations, index in try await index.search(query, generations: generations) }
        self.searchDelay = searchDelay
        self.thumbnailLoader = thumbnailLoader ?? { url in await HistoryStore.cardThumbnail(of: url, maxPixels: 520) }
        self.trashDelay = trashDelay
    }

    var resolvedTranslate: ((HistoryItem) -> Void)? {
        onTranslate ?? actions.translate
    }

    /// Loaded captures excluding any single capture currently staged in the 5-second Undo Trash toast.
    var activeItems: [HistoryItem] {
        guard let stagedID = pendingTrash?.item.id else { return items }
        return items.filter { $0.id != stagedID }
    }

    /// Compact disk usage footer summary (e.g., `"42 captures · 184 MB"`).
    var diskUsageSummary: String {
        Self.formattedDiskUsage(count: activeItems.count, bytes: totalDiskBytes)
    }

    /// Formats a capture count and optional total byte size for the History footer.
    static func formattedDiskUsage(count: Int, bytes: Int64?) -> String {
        let captures = String(localized: "\(count) captures", bundle: .module)
        guard let bytes else { return captures }
        let formatted = ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
        return String(localized: "\(captures) · \(formatted)", bundle: .module)
    }

    /// Recomputes total History disk usage off-main-actor (called on load, add, delete, and undo — zero polling).
    func recomputeDiskUsage() {
        guard !isReleased else { return }
        diskUsageTask?.cancel()
        diskUsageRevision &+= 1
        let mine = diskUsageRevision
        let snapshot = activeItems
        guard !snapshot.isEmpty else {
            diskUsageTask = nil
            totalDiskBytes = 0
            return
        }
        let directory = store.directory
        diskUsageTask = Task { [weak self] in
            let total = await Self.computeDiskUsage(directory: directory, items: snapshot)
            guard let self, !Task.isCancelled, !isReleased, mine == diskUsageRevision else { return }
            totalDiskBytes = total
            diskUsageTask = nil
        }
    }

    func waitForDiskUsage() async {
        while let task = diskUsageTask { await task.value }
    }

    @concurrent
    static func computeDiskUsage(directory: URL, items: [HistoryItem]) async -> Int64 {
        guard !items.isEmpty else { return 0 }
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        var total: Int64 = 0
        for item in items {
            guard !Task.isCancelled else { return 0 }
            let candidates = [
                directory.appending(path: item.fileName),
                directory.appending(path: "\(item.fileName).json"),
                directory.appending(path: "\(item.fileName).original"),
                directory.appending(path: "\(item.fileName).annotations"),
                directory.appending(path: "\(item.fileName).text"),
                directory.appending(path: "\(item.fileName).studio"),
            ]
            for url in candidates {
                guard !Task.isCancelled else { return 0 }
                guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
                if values.isDirectory == true {
                    total += directoryByteSize(at: url, fileManager: fm, keys: resourceKeys)
                } else {
                    let bytes = values.fileSize ?? values.fileAllocatedSize ?? values.totalFileAllocatedSize ?? 0
                    total += Int64(bytes)
                }
            }
        }
        return total
    }

    private nonisolated static func directoryByteSize(at url: URL, fileManager: FileManager, keys: Set<URLResourceKey>) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return 0 }
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isDirectory != true else { continue }
            let bytes = values.fileSize ?? values.fileAllocatedSize ?? values.totalFileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    /// Checks off-main-actor how many active screenshots remain unindexed after a background OCR pass finishes.
    func refreshFailedIndexingCount() {
        guard !isReleased, reading == 0 else { return }
        failedIndexingTask?.cancel()
        let snapshot = activeItems
        let store = store
        failedIndexingTask = Task { [weak self] in
            let unread = await Self.countUnreadScreenshots(in: snapshot, store: store)
            guard let self, !Task.isCancelled, !isReleased, reading == 0 else { return }
            failedIndexingCount = unread
            failedIndexingTask = nil
        }
    }

    @concurrent
    private static func countUnreadScreenshots(in items: [HistoryItem], store: HistoryStore) async -> Int {
        store.needingText(items).count
    }

    /// Retries background OCR indexing for any screenshots that failed indexing.
    func retryIndexing() {
        failedIndexingCount = 0
        onRetryIndexing?()
    }

    /// Distinct non-empty source app names present in loaded history, sorted for the toolbar filter menu.
    var availableApps: [String] {
        let names = Set(activeItems.compactMap { item -> String? in
            guard let name = item.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return name
        })
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var hasSecondaryFilters: Bool {
        appFilter != nil || dateFilter != .any
    }

    var hasActiveFilters: Bool {
        filter != .all || hasSecondaryFilters
    }

    func clearFilters() {
        filter = .all
        appFilter = nil
        dateFilter = .any
    }

    var visibleItems: [HistoryItem] {
        visibleItems(now: .now)
    }

    /// File URLs of all visible captures in grid order, enabling Left/Right Quick Look navigation.
    var visiblePreviewURLs: [URL] {
        visibleItems.map { store.fileURL(for: $0) }
    }

    func visibleItems(now: Date) -> [HistoryItem] {
        let shown = activeItems.filter { item in
            switch filter {
            case .all: break
            case .screenshots: if item.kind != .screenshot { return false }
            case .recordings: if item.kind != .recording { return false }
            case .favorites: if !item.isFavorite { return false }
            }
            if let appFilter, item.appName != appFilter { return false }
            if !dateFilter.matches(item.createdAt, now: now) { return false }
            return true
        }
        guard let matches else { return shown }
        return shown.filter { matches[$0.id] != nil }
    }

    /// Whether something is searched for.
    var isSearching: Bool { matches != nil }
    var isUpdatingSearch: Bool { isSearchPending || (isSearching && isIndexing) }

    /// Captures the search found that the active filters leave out.
    var foundElsewhere: Int {
        guard let matches, hasActiveFilters else { return 0 }
        let stagedID = pendingTrash?.item.id
        let activeMatches = stagedID.map { id in matches.keys.filter { $0 != id }.count } ?? matches.count
        return max(0, activeMatches - visibleItems.count)
    }

    /// The selected captures shown, in the grid's order.
    var selectedItems: [HistoryItem] {
        visibleItems.filter { selection.contains($0.id) }
    }

    /// What a command from `item`'s menu acts on: every capture selected when `item` is one of them, else `item` alone;
    /// from the main menu (no `item`), the selection.
    func itemsActedOn(from item: HistoryItem?) -> [HistoryItem] {
        guard let item, !selection.contains(item.id) else { return selectedItems }
        return [item]
    }

    /// The captures Combine into Collage would lay out from `item`'s menu: two or more, all screenshots; else none.
    func collageItems(from item: HistoryItem?) -> [HistoryItem] {
        let items = itemsActedOn(from: item)
        return items.count >= 2 && items.allSatisfy({ $0.kind == .screenshot }) ? items : []
    }

    /// The captures Export as PDF would write from `item`'s menu: screenshots only; else none.
    func pdfItems(from item: HistoryItem?) -> [HistoryItem] {
        let items = itemsActedOn(from: item)
        return !items.isEmpty && items.allSatisfy({ $0.kind == .screenshot }) ? items : []
    }

    /// The files a drag from the card of the capture `id`, or its Share…, hands to another app: every selected capture's
    /// when it is one of them, else its own alone, in the grid's order and each in the format Settings choose. None when
    /// one of them could not be made: the app says why, once, and nothing goes.
    func filesToHandOver(from id: UUID) -> [HandedOverFile] {
        guard let item = items.first(where: { $0.id == id }) else { return [] }
        var files: [HandedOverFile] = []
        for item in itemsActedOn(from: item) {
            guard let url = fileToHandOver(item) else { return [] }
            files.append(HandedOverFile(id: item.id, url: url))
        }
        return files
    }

    /// What Share… on the card of the capture `id` hands the share sheet: the files a drag from it would take, made together
    /// off the main actor, so a large selection does not stop the window. None when one of them could not be made.
    func filesToShare(from id: UUID) async -> [URL] {
        guard let filesToHandOver = actions.filesToHandOver else { return filesToHandOver(from: id).map(\.url) }
        guard let item = items.first(where: { $0.id == id }) else { return [] }
        return await filesToHandOver(itemsActedOn(from: item)) ?? []
    }

    /// The capture's file for another app: a copy in the format Settings choose, made when it is asked for, or the
    /// capture's own; nil when that copy could not be made, and then nothing goes.
    func fileToHandOver(_ item: HistoryItem) -> URL? {
        guard let fileToHandOver = actions.fileToHandOver else { return store.fileURL(for: item) }
        return fileToHandOver(item)
    }

    /// The selected capture the keys act on alone (Space, Print): the one clicked or reached last, else the first.
    var focusedItem: HistoryItem? {
        let selected = selectedItems
        return selected.first { $0.id == focus } ?? selected.first
    }

    /// Whether the window shows every capture, nothing left out by the Show filter or a search.
    var showsEverything: Bool {
        visibleItems.count == activeItems.count
    }

    /// A click on a capture, with the keys held then.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            focus = id
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor ?? focus,
                  let from = visibleItems.firstIndex(where: { $0.id == anchor }), let to = visibleItems.firstIndex(where: { $0.id == id }) {
            // The run from the capture clicked last, which stays the anchor for the next ⇧-click or ⇧-arrow.
            selectionAnchor = anchor
            selection = Set(visibleItems[min(from, to)...max(from, to)].map(\.id))
            focus = id
        } else {
            selection = [id]
            focus = id
            selectionAnchor = id
        }
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.id))
        if focus.map({ !selection.contains($0) }) ?? true { focus = visibleItems.first?.id }
        selectionAnchor = focus
    }

    func clearSelection() {
        selection = []
        focus = nil
        selectionAnchor = nil
    }

    /// Coalesce changes received during a directory scan into one follow-up scan, with only the newest
    /// listing allowed to publish. Reading a large history never occupies the main actor.
    func reload() {
        guard !isReleased else { return }
        reloadRevision &+= 1
        isReloading = true
        if reloadTask == nil { startReload() }
    }

    func reload(changed ids: Set<UUID>) {
        guard !isReleased else { return }
        forgetText(of: ids)
        invalidateThumbnails(ids)
        pendingThumbnails.formUnion(ids)
        reload()
    }

    private func startReload() {
        let mine = reloadRevision
        let store = store, loader = itemsLoader
        reloadTask = Task { [weak self] in
            let loaded = await loader(store)
            guard let self, !Task.isCancelled, !isReleased else { return }
            reloadTask = nil
            guard mine == reloadRevision else {
                startReload()
                return
            }
            items = loaded
            isReloading = false
            let refresh = pendingThumbnails.intersection(items.map(\.id))
            pendingThumbnails = []
            refreshThumbnails(for: refresh)
            search()
            loadText(of: Set(items.map(\.id)).subtracting(indexedIDs))
        }
    }

    private func reconcileItems(from old: [HistoryItem]) {
        let ids = Set(items.map(\.id))
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        // Added to Favorites or taken out, a capture's picture and text are as they were.
        let changed = Set(items.filter { item in previous[item.id].map { $0.favoriting(item.isFavorite) != item } ?? false }.map(\.id))
        let removed = Set(old.map(\.id)).subtracting(ids)
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        pendingText.formIntersection(ids)
        selection.formIntersection(ids)
        if let focus, !ids.contains(focus) { self.focus = nil }
        if let selectionAnchor, !ids.contains(selectionAnchor) { self.selectionAnchor = nil }
        if let appFilter, !items.contains(where: { $0.appName == appFilter }) { self.appFilter = nil }
        if let pending = pendingTrash, !ids.contains(pending.item.id) {
            pendingTrashTask?.cancel()
            pendingTrashTask = nil
            pendingTrash = nil
        }
        if !removed.isEmpty { forgetText(of: removed) }
        invalidateThumbnails(removed.union(changed))
        if !changed.isEmpty {
            forgetText(of: changed)
            pendingThumbnails.formUnion(changed)
        }
        if let matches { self.matches = matches.filter { ids.contains($0.key) } }
        recomputeDiskUsage()
    }

    /// Awaitable completion boundaries for Return in the search field and deterministic integration tests.
    func waitForReload() async {
        while let task = reloadTask { await task.value }
    }

    @discardableResult func waitForSearch() async -> Bool {
        while let task = searchTask { await task.value }
        return !isReleased && !isSearchPending
    }

    func waitForCurrentResults() async -> Bool {
        let requested = query
        if isSearching { await waitForTextLoads() }
        guard query == requested else { return false }
        let ready = await waitForSearch()
        return ready && query == requested
    }

    func waitForTextLoads() async {
        while !textLoads.isEmpty {
            let tasks = Array(textLoads.values)
            for task in tasks { await task.value }
        }
    }

    /// Captures the current operations before cancellation, for deterministic teardown verification.
    func pendingWork() -> Task<Void, Never> {
        let tasks = [reloadTask, searchTask].compactMap { $0 } + Array(textLoads.values) + Array(thumbnailLoads.values)
        return Task { for task in tasks { await task.value } }
    }

    /// Reads the kept text of these captures and makes it ready for searching, off the main actor: a long
    /// history holds megabytes of text. Captures not read yet are skipped; they come with `textRead`.
    func loadText(of ids: Set<UUID>) {
        guard !isReleased else { return }
        let requested = ids.intersection(items.map(\.id))
        for id in requested {
            textGenerations[id, default: 0] &+= 1
            if loading.contains(id) { pendingText.insert(id) }
        }
        startTextLoad(of: requested.subtracting(loading))
    }

    /// One read per capture at a time. Notifications during that read merge into one fresh read;
    /// only the generation requested most recently is allowed to publish its text.
    private func startTextLoad(of ids: Set<UUID>) {
        let wanted = items.filter { ids.contains($0.id) && !loading.contains($0.id) }
        guard !wanted.isEmpty else { return }
        let wantedIDs = Set(wanted.map(\.id))
        let generations = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, textGenerations[$0.id, default: 0]) })
        loading.formUnion(wantedIDs)
        isIndexing = true
        let store = store
        let loader = textLoader
        let taskID = UUID()
        let index = searchIndex
        textLoads[taskID] = Task { [weak self] in
            let loaded = await loader(wanted, store)
            guard let self, !Task.isCancelled, !isReleased else { return }
            let present = Set(items.map(\.id))
            let changes = wantedIDs.compactMap { id -> HistorySearchIndex.Change? in
                guard present.contains(id), textGenerations[id] == generations[id], let generation = generations[id] else { return nil }
                return .init(id: id, generation: generation, entry: loaded[id])
            }
            await index.update(changes)
            guard !Task.isCancelled, !isReleased else { return }
            textLoads[taskID] = nil
            isIndexing = !textLoads.isEmpty
            loading.subtract(wantedIDs)
            let stillPresent = Set(items.map(\.id))
            for change in changes where stillPresent.contains(change.id) && textGenerations[change.id] == change.generation {
                if change.entry != nil { indexedIDs.insert(change.id) } else { indexedIDs.remove(change.id) }
            }
            let retry = pendingText.intersection(wantedIDs).intersection(stillPresent)
            pendingText.subtract(wantedIDs)
            search()
            startTextLoad(of: retry)
        }
    }

    @concurrent
    private static func entries(of items: [HistoryItem], in store: HistoryStore) async -> [UUID: HistorySearch.Entry] {
        var folding = HistorySearch.Folding()
        var entries: [UUID: HistorySearch.Entry] = [:]
        for item in items {
            guard !Task.isCancelled else { break }
            // Recordings have no text, but are found by their app, window title, and file name.
            let text = item.kind == .screenshot ? store.text(of: item) : ""
            guard let text else { continue }
            entries[item.id] = HistorySearch.Entry(
                text: text, appName: item.appName, windowTitle: item.windowTitle, fileName: item.fileName, folding: &folding
            )
        }
        return entries
    }

    /// Forgets the text of captures whose picture changed: it is read again.
    func forgetText(of ids: Set<UUID>) {
        guard !isReleased else { return }
        for id in ids {
            indexedIDs.remove(id)
            textGenerations[id, default: 0] &+= 1
            if loading.contains(id) { pendingText.insert(id) }
            // A redacted picture must stop showing its old excerpt immediately, even during an update.
            matches?[id] = nil
        }
        let changes = ids.map { HistorySearchIndex.Change(id: $0, generation: textGenerations[$0, default: 0], entry: nil) }
        let index = searchIndex
        Task { await index.update(changes) }
        search()
    }

    private func search() {
        guard !isReleased else { return }
        searchRevision &+= 1
        let mine = searchRevision
        searchTask?.cancel()
        searchTask = nil
        excerptLoaded = []
        excerptLoading = []
        searchResultRevision &+= 1
        let query = query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matches = nil
            searchTerms = []
            isSearchPending = false
            return
        }
        // Keep the previous results visible with an explicit updating state while typing settles.
        if matches == nil { matches = [:] }
        isSearchPending = true
        let index = searchIndex, searcher = searcher, delay = searchDelay
        let generations = textGenerations
        searchTask = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                let result = try await searcher(query, generations, index)
                guard let self, !Task.isCancelled, !isReleased, mine == searchRevision else { return }
                let present = Set(items.map(\.id))
                matches = result.terms.isEmpty ? nil : result.matches.filter { present.contains($0.key) }
                searchTerms = result.terms
                isSearchPending = false
                searchResultRevision &+= 1
                searchTask = nil
            } catch {
                guard let self, !isReleased, mine == searchRevision else { return }
                isSearchPending = false
                searchTask = nil
            }
        }
    }

    /// Only visible grid cards ask for excerpts. Membership matching and excerpt construction both stay
    /// on the index actor; stale cards cannot publish text for a different query or picture.
    func loadExcerpt(for id: UUID) async {
        guard !isReleased, !isSearchPending, matches?[id] != nil, !excerptLoaded.contains(id),
              !excerptLoading.contains(id), let generation = textGenerations[id] else { return }
        let mine = searchRevision
        excerptLoading.insert(id)
        defer { if mine == searchRevision { excerptLoading.remove(id) } }
        guard let match = try? await searchIndex.excerpt(for: id, terms: searchTerms, generation: generation),
              !Task.isCancelled, !isReleased, mine == searchRevision, generation == textGenerations[id], matches?[id] != nil else { return }
        matches?[id] = match
        excerptLoaded.insert(id)
    }

    /// Loads the thumbnails of captures whose picture changed, keeping the old ones until then.
    func refreshThumbnails(for ids: Set<UUID>) {
        guard !isReleased else { return }
        for item in items where ids.contains(item.id) {
            let generation = thumbnailGenerations[item.id, default: 0]
            let loader = thumbnailLoader, url = store.fileURL(for: item)
            let slots = decodeSlots
            thumbnailLoads[item.id]?.cancel()
            thumbnailLoads[item.id] = Task { [weak self] in
                await slots.acquire()
                let shouldRead = !Task.isCancelled && self?.isReleased == false && self?.thumbnailGenerations[item.id, default: 0] == generation
                let image = shouldRead ? await loader(url) : nil
                await slots.release()
                guard let self, !isReleased, !Task.isCancelled, thumbnailGenerations[item.id, default: 0] == generation else { return }
                thumbnailLoads[item.id] = nil
                if items.contains(where: { $0.id == item.id }), let image { thumbnails[item.id] = image }
            }
        }
    }

    private func invalidateThumbnails(_ ids: Set<UUID>) {
        for id in ids {
            thumbnailGenerations[id, default: 0] &+= 1
            thumbnailLoads[id]?.cancel()
            thumbnailLoads[id] = nil
        }
    }

    func loadThumbnail(for item: HistoryItem) async {
        guard thumbnails[item.id] == nil, !isReleased else { return }
        let generation = thumbnailGenerations[item.id, default: 0]
        // A few at a time, and not for a card scrolled away while it waited.
        await decodeSlots.acquire()
        let image = Task.isCancelled || isReleased || thumbnailGenerations[item.id, default: 0] != generation
            ? nil : await thumbnailLoader(store.fileURL(for: item))
        await decodeSlots.release()
        if let image, !Task.isCancelled, !isReleased, thumbnailGenerations[item.id, default: 0] == generation,
           items.contains(where: { $0.id == item.id }) { thumbnails[item.id] = image }
    }

    /// The window has closed: commit any deferred single-item trash, release its pictures and search text, and cancel pending reads.
    func release() {
        isReleased = true
        commitPendingTrash()
        retention.cancel()
        for task in textLoads.values { task.cancel() }
        textLoads = [:]
        isIndexing = false
        loading = []
        pendingText = []
        textGenerations = [:]
        for task in thumbnailLoads.values { task.cancel() }
        thumbnailLoads = [:]
        thumbnailGenerations = [:]
        pendingThumbnails = []
        indexedIDs = []
        searchTask?.cancel()
        searchTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        diskUsageTask?.cancel()
        diskUsageTask = nil
        failedIndexingTask?.cancel()
        failedIndexingTask = nil
        copyFeedbackReset?.cancel()
        copyFeedbackReset = nil
        copyFeedback = nil
        searchRevision &+= 1
        reloadRevision &+= 1
        isReloading = false
        isSearchPending = false
        searchTerms = []
        excerptLoaded = []
        excerptLoading = []
        matches = nil
        thumbnails = [:]
        let index = searchIndex
        Task { await index.release() }
    }

    func moveToTrash(_ item: HistoryItem) {
        moveToTrash([item])
    }

    /// Whether captures can be added to Favorites: History keeps a favorite however long Keep captures is, and with
    /// History off it keeps nothing.
    var canFavorite: Bool { settings.historyRetention != .never }

    /// Why captures can't be added to Favorites while History is off.
    static var favoritesNeedHistory: String {
        String(localized: "History is off: captures can’t be kept as favorites.", bundle: .module)
    }

    /// Adds the captures to Favorites, or takes them out when every one is in already, as Photos does. With History
    /// off it beeps and says why.
    func toggleFavorite(_ chosen: [HistoryItem]) {
        guard !chosen.isEmpty else { return }
        guard canFavorite else {
            NSSound.beep()
            AccessibilityNotification.Announcement(Self.favoritesNeedHistory).post()
            return
        }
        let favorite = !chosen.allSatisfy(\.isFavorite)
        var written: [UUID: HistoryItem] = [:]
        for item in chosen {
            // One that left the history meanwhile goes from the window with the next reload.
            if let updated = try? store.setFavorite(favorite, of: item) { written[item.id] = updated }
        }
        items = items.map { written[$0.id] ?? $0 }
    }

    /// Moves captures to the Trash immediately (used after multi-item confirmation or direct calls), one at a time
    /// through the actions, so cards showing them close too. When the selection goes with them it moves on to the
    /// capture after them, as in Finder.
    func moveToTrash(_ gone: [HistoryItem]) {
        let requestedIDs = Set(gone.map(\.id))
        if let pending = pendingTrash {
            if requestedIDs.contains(pending.item.id) {
                pendingTrashTask?.cancel()
                pendingTrashTask = nil
                pendingTrash = nil
            } else {
                commitPendingTrash()
            }
        }
        var ids: Set<UUID> = []
        for item in gone {
            guard !actions.isBeingEdited(item) else {
                trashFailure = String(localized: "Close the capture’s editor first.", bundle: .module)
                continue
            }
            do {
                try actions.moveToTrash(item)
                ids.insert(item.id)
            } catch {
                trashFailure = error.localizedDescription
            }
        }
        guard !ids.isEmpty else { return }
        advanceSelection(removing: ids)
        reload()
    }

    /// Hides a single capture immediately and defers moving it to Trash for `trashDelay` (5 s) with an Undo toast.
    func stageTrash(_ item: HistoryItem) {
        guard !actions.isBeingEdited(item) else {
            trashFailure = String(localized: "Close the capture’s editor first.", bundle: .module)
            return
        }
        if pendingTrash != nil {
            commitPendingTrash()
        }
        advanceSelection(removing: [item.id])
        if previewURL == store.fileURL(for: item) {
            previewURL = nil
        }
        let pending = PendingTrash(item: item)
        pendingTrash = pending
        recomputeDiskUsage()
        VoiceOver.announce(String(localized: "Moved to Trash", bundle: .module), from: window)
        let delay = trashDelay
        pendingTrashTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.pendingTrash?.id == pending.id else { return }
            self.commitPendingTrash()
        }
    }

    /// Cancels a pending single-item trash and restores the capture immediately into the visible grid.
    @discardableResult
    func undoPendingTrash() -> Bool {
        pendingTrashTask?.cancel()
        pendingTrashTask = nil
        guard let pending = pendingTrash else { return false }
        pendingTrash = nil
        if items.contains(where: { $0.id == pending.item.id }) {
            selection = [pending.item.id]
            focus = pending.item.id
            selectionAnchor = pending.item.id
        }
        recomputeDiskUsage()
        VoiceOver.announce(String(localized: "Restored", bundle: .module), from: window)
        return true
    }

    /// Commits any pending single-item trash immediately (timer elapsed, next delete, window close, or app quit).
    func commitPendingTrash() {
        pendingTrashTask?.cancel()
        pendingTrashTask = nil
        guard let pending = pendingTrash else { return }
        pendingTrash = nil
        if actions.isBeingEdited(pending.item) {
            trashFailure = String(localized: "Close the capture’s editor first.", bundle: .module)
            restoreFailedPendingTrash(pending.item)
            return
        }
        do {
            try actions.moveToTrash(pending.item)
        } catch {
            trashFailure = error.localizedDescription
            restoreFailedPendingTrash(pending.item)
            return
        }
        if !isReleased {
            items.removeAll { $0.id == pending.item.id }
            reload()
        }
    }

    private func restoreFailedPendingTrash(_ item: HistoryItem) {
        guard !isReleased else { return }
        if items.contains(where: { $0.id == item.id }) {
            selection = [item.id]
            focus = item.id
            selectionAnchor = item.id
        }
        recomputeDiskUsage()
    }

    private func advanceSelection(removing ids: Set<UUID>) {
        let visible = visibleItems
        if !selection.isDisjoint(with: ids), selection.isSubset(of: ids), let index = visible.firstIndex(where: { ids.contains($0.id) }) {
            let rest = visible.filter { !ids.contains($0.id) }
            let next = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
            selection = next.map { [$0] } ?? []
            focus = next
            selectionAnchor = next
        } else {
            selection.subtract(ids)
            if let focus, ids.contains(focus) { self.focus = visible.first { selection.contains($0.id) }?.id }
            if let selectionAnchor, ids.contains(selectionAnchor) { self.selectionAnchor = nil }
        }
    }

    /// Moves captures to the Trash: a single capture stages a 5-second undoable delete; several ask confirmation first.
    func requestTrash(_ targets: [HistoryItem]) {
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            stageTrash(targets[0])
        } else {
            trashRequest = TrashRequest(items: targets, isEverything: targets.count == activeItems.count)
        }
    }

    /// Moves the selection to the Trash: one capture stages an undoable delete, several ask confirmation first.
    func trashSelection() {
        requestTrash(selectedItems)
    }

    /// Asks before moving every capture the window shows to the Trash.
    func trashShown() {
        let shown = visibleItems
        guard !shown.isEmpty else { return }
        trashRequest = TrashRequest(items: shown, isEverything: showsEverything)
    }

    /// Copies one capture as Copy always has; several as their files, as Finder's Copy does.
    func copy(_ items: [HistoryItem]) {
        guard !items.isEmpty else { return }
        if items.count == 1 { actions.copy(items[0]) } else { actions.copyFiles(items) }
        showCopyFeedback(for: items, kind: .capture)
    }

    private func showCopyFeedback(for items: [HistoryItem], kind: CopyFeedback.Kind) {
        let feedback = CopyFeedback(count: items.count, itemIDs: Set(items.map(\.id)), kind: kind)
        copyFeedback = feedback
        copyFeedbackReset?.cancel()
        copyFeedbackReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled, let self, self.copyFeedback?.id == feedback.id else { return }
            self.copyFeedback = nil
        }
        let announcement = switch kind {
        case .text:
            String(localized: "Copied text", bundle: .module)
        case .capture:
            items.count == 1
                ? String(localized: "Copied", bundle: .module)
                : String(localized: "Copied \(items.count) captures", bundle: .module)
        }
        VoiceOver.announce(announcement, from: window)
    }

    func quickLook(_ item: HistoryItem) {
        previewURL = store.fileURL(for: item)
    }

    /// Copy Text: the screenshot's text goes to the clipboard, and the Copied reading by the pointer says how much, or
    /// that it held none; a reading overtaken by a newer copy says nothing.
    func copyText(_ item: HistoryItem) {
        guard item.kind == .screenshot else { return }
        Task {
            guard let message = await actions.copyText(item).message else { return }
            copiedReading.show(message, near: NSEvent.mouseLocation)
        }
    }

    /// Prints a screenshot; a recording has nothing to print.
    func print(_ item: HistoryItem) {
        guard item.kind == .screenshot else { return }
        actions.print(item, window)
    }

    /// Moves the selection through the grid: by one for left and right, by a row for up and down.
    /// When `extending` is true (⇧+Arrow), extends or contracts the selection range from the anchor capture.
    func moveSelection(by offset: Int, extending: Bool = false) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        guard let current = visible.firstIndex(where: { $0.id == focus }) ?? visible.firstIndex(where: { selection.contains($0.id) }) else {
            let first = visible[0].id
            focus = first
            selectionAnchor = first
            selection = [first]
            return
        }
        let nextIndex = min(max(current + offset, 0), visible.count - 1)
        let next = visible[nextIndex].id
        focus = next
        if extending {
            let anchorID = selectionAnchor.flatMap { id in visible.contains(where: { $0.id == id }) ? id : nil } ?? visible[current].id
            selectionAnchor = anchorID
            let anchorIndex = visible.firstIndex(where: { $0.id == anchorID }) ?? current
            selection = Set(visible[min(anchorIndex, nextIndex)...max(anchorIndex, nextIndex)].map(\.id))
        } else {
            selectionAnchor = next
            selection = [next]
        }
    }
}

/// A capture's file as it is dragged out of the window, one of several when a selection is: dropped as the file itself,
/// as Finder drops one.
nonisolated struct HandedOverFile: Transferable, Identifiable, Sendable {
    /// The capture's.
    let id: UUID
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.url)
    }
}

/// A fixed number of places, taken in turn: `acquire` waits until one is free.
private actor Slots {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        free = count
    }

    func acquire() async {
        if free > 0 {
            free -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func release() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
