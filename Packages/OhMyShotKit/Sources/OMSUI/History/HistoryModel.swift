import AppKit
import Foundation
import Observation
import OMSCore

@MainActor
@Observable
final class HistoryModel {
    typealias TextLoader = @MainActor @Sendable ([HistoryItem], HistoryStore) async -> [UUID: HistorySearch.Entry]
    typealias ItemsLoader = @MainActor @Sendable (HistoryStore) async -> [HistoryItem]
    typealias Searcher = @MainActor @Sendable (String, [UUID: UInt64], HistorySearchIndex) async throws -> HistorySearchIndex.Result
    typealias ThumbnailLoader = @MainActor @Sendable (URL) async -> CGImage?

    enum Filter: String, CaseIterable, Identifiable {
        case all, screenshots, recordings
        var id: String { rawValue }
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
    /// The captures selected, as in Finder: a click selects one, ⌘-click adds one or takes it away, ⇧-click selects
    /// the run from the capture clicked last, and ⌘A every capture shown.
    var selection: Set<UUID> = []
    /// The capture the arrows move from and Space looks at: the one clicked or reached last.
    var focus: UUID?
    /// Captures waiting for the user to confirm they go to the Trash.
    var trashRequest: TrashRequest?
    /// What is typed in the search field.
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    /// Where the search found each capture it found; nil while nothing is searched for.
    private(set) var matches: [UUID: HistorySearch.Match]?
    /// Captures whose text is still being read.
    var reading = 0
    /// The captures' text, ready for searching, as it has been read.
    @ObservationIgnored private var indexedIDs: Set<UUID> = []
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
    var retentionRequest: RetentionChangeRequest?

    /// Thumbnails being made: the grid asks for every card it shows at once, which would take every core, and the
    /// cards scrolled away while they wait need none.
    @ObservationIgnored private let decodeSlots = Slots(count: 3)
    @ObservationIgnored private var isReleased = false

    @ObservationIgnored let store: HistoryStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let actions: HistoryActions
    @ObservationIgnored let expiredCount: (HistoryRetention) -> Int
    /// The history window, for the print panel to come down from.
    @ObservationIgnored weak var window: NSWindow?

    init(
        store: HistoryStore, settings: SettingsStore, actions: HistoryActions, expiredCount: @escaping (HistoryRetention) -> Int,
        textLoader: TextLoader? = nil, itemsLoader: ItemsLoader? = nil, searcher: Searcher? = nil,
        searchDelay: Duration = .milliseconds(100), thumbnailLoader: ThumbnailLoader? = nil
    ) {
        self.store = store
        self.settings = settings
        self.actions = actions
        self.expiredCount = expiredCount
        self.textLoader = textLoader ?? { items, store in await Self.entries(of: items, in: store) }
        self.itemsLoader = itemsLoader ?? { store in await store.loadItems() }
        self.searcher = searcher ?? { query, generations, index in try await index.search(query, generations: generations) }
        self.searchDelay = searchDelay
        self.thumbnailLoader = thumbnailLoader ?? { url in await HistoryStore.cardThumbnail(of: url, maxPixels: 520) }
    }

    var visibleItems: [HistoryItem] {
        let shown = switch filter {
        case .all: items
        case .screenshots: items.filter { $0.kind == .screenshot }
        case .recordings: items.filter { $0.kind == .recording }
        }
        guard let matches else { return shown }
        return shown.filter { matches[$0.id] != nil }
    }

    /// Whether something is searched for.
    var isSearching: Bool { matches != nil }
    var isUpdatingSearch: Bool { isSearchPending || (isSearching && isIndexing) }

    /// Captures the search found that the Show filter leaves out.
    var foundElsewhere: Int {
        guard let matches, filter != .all else { return 0 }
        return matches.count - visibleItems.count
    }

    /// The selected captures shown, in the grid's order.
    var selectedItems: [HistoryItem] {
        visibleItems.filter { selection.contains($0.id) }
    }

    /// The selected capture the keys act on alone (Space, Print): the one clicked or reached last, else the first.
    var focusedItem: HistoryItem? {
        let selected = selectedItems
        return selected.first { $0.id == focus } ?? selected.first
    }

    /// Whether the window shows every capture, nothing left out by the Show filter or a search.
    var showsEverything: Bool {
        visibleItems.count == items.count
    }

    /// A click on a capture, with the keys held then.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            focus = id
        } else if modifiers.contains(.shift), let anchor = focus,
                  let from = visibleItems.firstIndex(where: { $0.id == anchor }), let to = visibleItems.firstIndex(where: { $0.id == id }) {
            // The run from the capture clicked last, which stays the anchor for the next ⇧-click.
            selection = Set(visibleItems[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [id]
            focus = id
        }
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.id))
        if focus.map({ !selection.contains($0) }) ?? true { focus = visibleItems.first?.id }
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
        let changed = Set(items.filter { item in previous[item.id].map { $0 != item } ?? false }.map(\.id))
        let removed = Set(old.map(\.id)).subtracting(ids)
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        pendingText.formIntersection(ids)
        selection.formIntersection(ids)
        if let focus, !ids.contains(focus) { self.focus = nil }
        if !removed.isEmpty { forgetText(of: removed) }
        invalidateThumbnails(removed.union(changed))
        if !changed.isEmpty {
            forgetText(of: changed)
            pendingThumbnails.formUnion(changed)
        }
        if let matches { self.matches = matches.filter { ids.contains($0.key) } }
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
            // Recordings have no text, but are found by their app.
            let text = item.kind == .screenshot ? store.text(of: item) : ""
            guard let text else { continue }
            entries[item.id] = HistorySearch.Entry(text: text, appName: item.appName, folding: &folding)
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

    /// The window has closed: release its pictures and search text, and cancel pending reads.
    func release() {
        isReleased = true
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

    /// Moves captures to the Trash, one at a time through the actions, so cards showing them close too. When the
    /// selection goes with them it moves on to the capture after them, as in Finder.
    func moveToTrash(_ gone: [HistoryItem]) {
        let ids = Set(gone.map(\.id))
        let visible = visibleItems
        if !selection.isDisjoint(with: ids), selection.isSubset(of: ids), let index = visible.firstIndex(where: { ids.contains($0.id) }) {
            let rest = visible.filter { !ids.contains($0.id) }
            let next = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
            selection = next.map { [$0] } ?? []
            focus = next
        } else {
            selection.subtract(ids)
        }
        gone.forEach(actions.moveToTrash)
        reload()
    }

    /// Moves the selection to the Trash: one capture at once, as Finder does, several once confirmed.
    func trashSelection() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        if selected.count == 1 {
            moveToTrash(selected[0])
        } else {
            trashRequest = TrashRequest(items: selected, isEverything: selected.count == items.count)
        }
    }

    /// Asks before moving every capture the window shows to the Trash.
    func trashShown() {
        let shown = visibleItems
        guard !shown.isEmpty else { return }
        trashRequest = TrashRequest(items: shown, isEverything: showsEverything)
    }

    /// Copies one capture as Copy always has; several as their files, as Finder's Copy does.
    func copy(_ items: [HistoryItem]) {
        if items.count == 1 { actions.copy(items[0]) } else if !items.isEmpty { actions.copyFiles(items) }
    }

    func quickLook(_ item: HistoryItem) {
        previewURL = store.fileURL(for: item)
    }

    /// Prints a screenshot; a recording has nothing to print.
    func print(_ item: HistoryItem) {
        guard item.kind == .screenshot else { return }
        actions.print(item, window)
    }

    /// Moves the selection through the grid: by one for left and right, by a row for up and down.
    func moveSelection(by offset: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        guard let current = visible.firstIndex(where: { $0.id == focus }) ?? visible.firstIndex(where: { selection.contains($0.id) }) else {
            focus = visible.first?.id
            selection = Set(focus.map { [$0] } ?? [])
            return
        }
        let next = visible[min(max(current + offset, 0), visible.count - 1)].id
        focus = next
        selection = [next]
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
