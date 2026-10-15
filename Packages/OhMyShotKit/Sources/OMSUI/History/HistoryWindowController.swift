import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import OMSCore
import QuickLook
import SwiftUI

/// What the history window can do with an item.
public struct HistoryActions {
    public var restore: (HistoryItem) -> Void
    public var copy: (HistoryItem) -> Void
    public var save: (HistoryItem) -> Void
    public var open: (HistoryItem) -> Void
    /// Opens the capture in the annotation editor, or a recording in the recording window.
    public var annotate: (HistoryItem) -> Void
    public var reveal: (HistoryItem) -> Void
    /// Opens the capture in the OCR panel.
    public var recognizeText: (HistoryItem) -> Void
    /// Keeps the capture on screen as a pin.
    public var pin: (HistoryItem) -> Void
    /// Moves the capture to the Trash, where it can be put back from.
    public var moveToTrash: (HistoryItem) -> Void

    public init(
        restore: @escaping (HistoryItem) -> Void,
        copy: @escaping (HistoryItem) -> Void,
        save: @escaping (HistoryItem) -> Void,
        open: @escaping (HistoryItem) -> Void,
        annotate: @escaping (HistoryItem) -> Void,
        reveal: @escaping (HistoryItem) -> Void,
        recognizeText: @escaping (HistoryItem) -> Void,
        pin: @escaping (HistoryItem) -> Void,
        moveToTrash: @escaping (HistoryItem) -> Void
    ) {
        self.restore = restore
        self.copy = copy
        self.save = save
        self.open = open
        self.annotate = annotate
        self.reveal = reveal
        self.recognizeText = recognizeText
        self.pin = pin
        self.moveToTrash = moveToTrash
    }
}

/// Capture History: every recent capture, restorable to Quick Access, and found by the text in it. Created
/// when opened and released when closed.
public final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private let model: HistoryModel
    private let textReader: HistoryTextReader?
    private var windowLease: ActiveResources.Lease?
    private var readingShown: Task<Void, Never>?

    /// - Parameters:
    ///   - expiredCount: how many captures a retention would delete now, so the window can ask before
    ///     shortening it.
    ///   - textReader: what reads the captures' text, so the window can say while it does.
    public init(
        store: HistoryStore, settings: SettingsStore, actions: HistoryActions, textReader: HistoryTextReader?,
        expiredCount: @escaping (HistoryRetention) -> Int
    ) {
        model = HistoryModel(store: store, settings: settings, actions: actions, expiredCount: expiredCount)
        self.textReader = textReader
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = String(localized: "Capture History", bundle: .module)
        // The toolbar's room goes to the filter and the search field; the title stays in the Window menu.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSHostingController(rootView: HistoryView(model: model))
        // The SwiftUI toolbar becomes the window's toolbar; the view sets only the minimum size.
        content.sceneBridgingOptions = [.toolbars]
        content.sizingOptions = [.minSize]
        window.contentViewController = content
        window.setContentSize(CGSize(width: 920, height: 640))
        window.setFrameAutosaveName("CaptureHistory")
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show() {
        model.reload()
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        showReading()
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    /// Picks up captures taken while the window is open.
    public func reload() {
        model.reload()
    }

    /// Picks up new pictures of existing captures (marked up, or put back as taken).
    public func reload(changed ids: Set<UUID>) {
        model.forgetText(of: ids)
        model.reload()
        model.refreshThumbnails(for: ids)
    }

    /// Picks up the text just read in a capture, for searching it.
    public func textRead(_ id: UUID) {
        model.loadText(of: [id])
    }

    /// While captures are being read, a search says how many are left.
    private func showReading() {
        guard readingShown == nil, let textReader else { return }
        readingShown = Task { [weak self] in
            for await count in Observations({ textReader.reading }) {
                self?.model.reading = count
            }
        }
    }

    #if DEBUG
    /// Raises the confirmation that choosing `retention` would, or dismisses it with nil, without
    /// changing anything: for scripted checks of the dialog.
    public func previewRetentionChange(to retention: HistoryRetention?) {
        model.retentionRequest = retention.map { RetentionChangeRequest(retention: $0, count: model.expiredCount($0)) }
    }

    /// Searches for `query` as if it were typed into the search field.
    public func previewSearch(_ query: String) {
        model.query = query
    }

    /// Chooses All, Screenshots, or Recordings in the Show filter by name.
    public func previewFilter(_ name: String) {
        if let filter = HistoryModel.Filter(rawValue: name) { model.filter = filter }
    }
    #endif

    public func windowWillClose(_ notification: Notification) {
        readingShown?.cancel()
        readingShown = nil
        windowLease?.end()
        windowLease = nil
        onClose?()
    }
}

@MainActor
@Observable
final class HistoryModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, screenshots, recordings
        var id: String { rawValue }
    }

    var items: [HistoryItem] = []
    var thumbnails: [UUID: CGImage] = [:]
    var filter: Filter = .all
    var selection: UUID?
    /// What is typed in the search field.
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    /// Where the search found each capture it found; nil while nothing is searched for.
    private(set) var matches: [UUID: HistorySearch.Match]?
    /// Captures whose text is still being read.
    var reading = 0
    /// The captures' text, ready for searching, as it has been read.
    @ObservationIgnored private var entries: [UUID: HistorySearch.Entry] = [:]
    @ObservationIgnored private var loading: Set<UUID> = []
    /// The file shown in Quick Look, if any.
    var previewURL: URL?
    var retentionRequest: RetentionChangeRequest?

    @ObservationIgnored let store: HistoryStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let actions: HistoryActions
    @ObservationIgnored let expiredCount: (HistoryRetention) -> Int

    init(store: HistoryStore, settings: SettingsStore, actions: HistoryActions, expiredCount: @escaping (HistoryRetention) -> Int) {
        self.store = store
        self.settings = settings
        self.actions = actions
        self.expiredCount = expiredCount
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

    /// Captures the search found that the Show filter leaves out.
    var foundElsewhere: Int {
        guard let matches, filter != .all else { return 0 }
        return matches.count - visibleItems.count
    }

    var selectedItem: HistoryItem? {
        visibleItems.first { $0.id == selection }
    }

    func reload() {
        items = store.items()
        let ids = Set(items.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        entries = entries.filter { ids.contains($0.key) }
        if let selection, !ids.contains(selection) { self.selection = nil }
        loadText(of: ids.subtracting(entries.keys))
    }

    /// Reads the kept text of these captures and makes it ready for searching, off the main actor: a long
    /// history holds megabytes of text. Captures not read yet are skipped; they come with `textRead`.
    func loadText(of ids: Set<UUID>) {
        let wanted = items.filter { ids.contains($0.id) && !loading.contains($0.id) }
        guard !wanted.isEmpty else { return }
        loading.formUnion(wanted.map(\.id))
        let store = store
        Task {
            let loaded = await Self.entries(of: wanted, in: store)
            loading.subtract(wanted.map(\.id))
            let present = Set(items.map(\.id))
            for (id, entry) in loaded where present.contains(id) { entries[id] = entry }
            search()
        }
    }

    @concurrent
    private static func entries(of items: [HistoryItem], in store: HistoryStore) async -> [UUID: HistorySearch.Entry] {
        var folding = HistorySearch.Folding()
        var entries: [UUID: HistorySearch.Entry] = [:]
        for item in items {
            // Recordings have no text, but are found by their app.
            let text = item.kind == .screenshot ? store.text(of: item) : ""
            guard let text else { continue }
            entries[item.id] = HistorySearch.Entry(text: text, appName: item.appName, folding: &folding)
        }
        return entries
    }

    /// Forgets the text of captures whose picture changed: it is read again.
    func forgetText(of ids: Set<UUID>) {
        for id in ids { entries[id] = nil }
        search()
    }

    private func search() {
        let terms = HistorySearch.terms(in: query)
        guard !terms.isEmpty else {
            matches = nil
            return
        }
        var found: [UUID: HistorySearch.Match] = [:]
        for (id, entry) in entries {
            if let match = HistorySearch.match(terms, in: entry) { found[id] = match }
        }
        matches = found
    }

    /// Loads the thumbnails of captures whose picture changed, keeping the old ones until then.
    func refreshThumbnails(for ids: Set<UUID>) {
        for item in items where ids.contains(item.id) {
            Task {
                if let image = await HistoryStore.cardThumbnail(of: store.fileURL(for: item), maxPixels: 520) {
                    thumbnails[item.id] = image
                }
            }
        }
    }

    func loadThumbnail(for item: HistoryItem) async {
        guard thumbnails[item.id] == nil else { return }
        if let image = await HistoryStore.cardThumbnail(of: store.fileURL(for: item), maxPixels: 520) {
            thumbnails[item.id] = image
        }
    }

    func moveToTrash(_ item: HistoryItem) {
        // The selection moves on to the next capture, as in Finder.
        if selection == item.id, let index = visibleItems.firstIndex(of: item) {
            let rest = visibleItems.filter { $0.id != item.id }
            selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        actions.moveToTrash(item)
        reload()
    }

    func moveAllToTrash() {
        // One at a time through the actions, so cards showing these captures close too.
        items.forEach(actions.moveToTrash)
        reload()
    }

    func quickLook(_ item: HistoryItem) {
        previewURL = store.fileURL(for: item)
    }

    /// Moves the selection through the grid: by one for left and right, by a row for up and down.
    func moveSelection(by offset: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        guard let current = visible.firstIndex(where: { $0.id == selection }) else {
            selection = visible.first?.id
            return
        }
        selection = visible[min(max(current + offset, 0), visible.count - 1)].id
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel
    @State private var confirmingTrashAll = false
    @State private var gridWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool

    private static let cardMinimum: CGFloat = 200
    private static let spacing: CGFloat = 20
    private static let inset: CGFloat = 24
    private let columns = [GridItem(.adaptive(minimum: cardMinimum, maximum: 280), spacing: spacing)]

    var body: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else if model.visibleItems.isEmpty {
                if !model.isSearching {
                    filteredEmptyState
                } else if model.foundElsewhere > 0 {
                    foundElsewhere
                } else {
                    noResults
                }
            } else {
                grid
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(.background)
        .toolbar { toolbar }
        .searchable(text: $model.query, placement: .toolbar, prompt: Text("Search Text", bundle: .module))
        .searchFocused($searchFocused)
        // Return in the search field goes to the first capture found, ready for the grid's keys.
        .onSubmit(of: .search) {
            guard let first = model.visibleItems.first else { return }
            model.selection = first.id
            gridFocused = true
        }
        // ⌘F, Find… in the Edit menu: to the search field, whatever the window shows.
        .onCommand(#selector(NSTextView.performFindPanelAction(_:))) { searchFocused = true }
        // What a search found is said once typing pauses, for VoiceOver.
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, model.isSearching else { return }
            let count = model.visibleItems.count
            AccessibilityNotification.Announcement(count == 0
                ? String(localized: "No Results", bundle: .module)
                : String(localized: "\(count) captures found", bundle: .module)).post()
        }
        .quickLookPreview($model.previewURL)
        .confirmationDialog(
            Text("Move all captures in the history to the Trash?", bundle: .module),
            isPresented: $confirmingTrashAll
        ) {
            Button(role: .destructive) {
                model.moveAllToTrash()
            } label: {
                Text("Move to Trash", bundle: .module)
            }
        } message: {
            Text("You can put them back from the Trash. Copies you saved elsewhere are not affected.", bundle: .module)
        }
        .confirmingRetentionChange($model.retentionRequest) { retention in
            model.settings.historyRetention = retention
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Relative times ("2 minutes ago") are redrawn twice a minute while the window is open.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(model.visibleItems) { item in
                            HistoryCard(item: item, model: model, isSelected: model.selection == item.id)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 20)
                    // Measured inside the scroll view, so a visible scroller is not counted as room.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                    if model.isSearching, model.reading > 0 {
                        stillReading
                            .padding(.bottom, 20)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(phases: .down) { press in
                handle(press) ? .handled : .ignored
            }
            // ⌘C, ⌘S and ⌘⌫ arrive from the main menu as commands; with nothing selected they are disabled.
            .onCommand(#selector(NSText.copy(_:)), perform: selectionCommand(model.actions.copy))
            .onCommand(#selector(NSDocument.save(_:)), perform: selectionCommand(model.actions.save))
            .onCommand(#selector(NSText.delete(_:)), perform: selectionCommand(model.moveToTrash))
            .onChange(of: model.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selection) }
            }
            .onAppear { gridFocused = true }
        }
    }

    /// The grid's plain keys: arrows select, Return restores, and Space opens Quick Look, as in Finder.
    private func handle(_ press: KeyPress) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        switch press.key {
        case .leftArrow: model.moveSelection(by: -1)
        case .rightArrow: model.moveSelection(by: 1)
        case .upArrow: model.moveSelection(by: -columnCount)
        case .downArrow: model.moveSelection(by: columnCount)
        case .return:
            guard let item = model.selectedItem else { return false }
            model.actions.restore(item)
        case .space:
            guard let item = model.selectedItem else { return false }
            model.quickLook(item)
        default:
            return false
        }
        return true
    }

    /// A menu command on the selected capture, or nil (a disabled command) when nothing is selected.
    private func selectionCommand(_ action: @escaping (HistoryItem) -> Void) -> (() -> Void)? {
        guard let item = model.selectedItem else { return nil }
        return { action(item) }
    }

    /// Columns in the adaptive grid at its current width.
    private var columnCount: Int {
        let available = gridWidth - Self.inset * 2
        return max(1, Int((available + Self.spacing) / (Self.cardMinimum + Self.spacing)))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker(selection: $model.filter) {
                Text("All", bundle: .module).tag(HistoryModel.Filter.all)
                Text("Screenshots", bundle: .module).tag(HistoryModel.Filter.screenshots)
                Text("Recordings", bundle: .module).tag(HistoryModel.Filter.recordings)
            } label: {
                Text("Show", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(selection: retention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.title).tag(retention)
                    }
                } label: {
                    Text("Keep captures for", bundle: .module)
                }
                .pickerStyle(.inline)
            } label: {
                Text(retentionLabel)
            }
            .help(Text("How long captures stay in the history", bundle: .module))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                confirmingTrashAll = true
            } label: {
                Label {
                    Text("Move All to Trash", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .help(Text("Move all captures in the history to the Trash", bundle: .module))
            .disabled(model.items.isEmpty)
        }
    }

    private var retention: Binding<HistoryRetention> {
        retentionSelection(settings: model.settings, expiredCount: model.expiredCount, request: $model.retentionRequest)
    }

    private var retentionLabel: String {
        let retention = model.settings.historyRetention
        return retention == .never
            ? String(localized: "History Off", bundle: .module)
            : String(localized: "Keep for \(retention.title)", bundle: .module)
    }

    private var emptyState: some View {
        placeholder(
            symbol: "photo.on.rectangle.angled",
            title: Text("No captures yet", bundle: .module),
            message: emptyHint
        )
    }

    /// Below what a search found while captures are still being read: more may be found.
    private var stillReading: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Still reading the text in \(model.reading) captures.", bundle: .module)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Nothing found under the Show filter, though the search found captures it leaves out.
    private var foundElsewhere: some View {
        placeholder(
            symbol: "magnifyingglass",
            title: model.filter == .recordings
                ? Text("No Recordings Found", bundle: .module)
                : Text("No Screenshots Found", bundle: .module),
            message: String(localized: "Found in \(model.foundElsewhere) captures under All.", bundle: .module)
        ) {
            Button { model.filter = .all } label: { Text("Show All", bundle: .module) }
        }
    }

    private var noResults: some View {
        placeholder(
            symbol: "magnifyingglass",
            title: Text("No Results for “\(model.query.trimmingCharacters(in: .whitespaces))”", bundle: .module),
            message: model.reading > 0
                ? String(localized: "Still reading the text in \(model.reading) captures.", bundle: .module)
                : String(localized: "Captures are found by the words in them and the app they were taken in.", bundle: .module)
        )
    }

    private var filteredEmptyState: some View {
        placeholder(
            symbol: model.filter == .recordings ? "video" : "photo",
            title: model.filter == .recordings ? Text("No recordings", bundle: .module) : Text("No screenshots", bundle: .module),
            message: String(localized: "Choose All to see every capture in the history.", bundle: .module)
        )
    }

    private func placeholder(symbol: String, title: Text, message: String) -> some View {
        placeholder(symbol: symbol, title: title, message: message) { EmptyView() }
    }

    private func placeholder(symbol: String, title: Text, message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            title
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                // A count that changes while it is read keeps its width.
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            action()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHint: String {
        let keep = model.settings.historyRetention == .never
            ? String(localized: "History is off, so captures are removed when their card closes.", bundle: .module)
            : String(localized: "Captures stay here for \(model.settings.historyRetention.title.lowercased()).", bundle: .module)
        guard let shortcut = KeyboardShortcuts.getShortcut(for: CaptureShortcut.captureArea.name) else { return keep }
        return keep + " " + String(localized: "Press \(shortcut.description) to capture an area.", bundle: .module)
    }
}

struct HistoryCard: View {
    let item: HistoryItem
    let model: HistoryModel
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                // The picture fills the card and is cropped to it, like a photo grid; the clear base keeps
                // the picture's own size out of the layout.
                Color.clear
                    .background(.background.secondary)
                    .overlay {
                        if let thumbnail = model.thumbnails[item.id] {
                            Image(decorative: thumbnail, scale: 2)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                if item.kind == .recording {
                    recordingBadge
                }
                if hovering {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(.black.opacity(0.28))
                    hoverActions
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(-5)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { model.actions.restore(item) }
            .simultaneousGesture(TapGesture().onEnded { model.selection = item.id })
            .task { await model.loadThumbnail(for: item) }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.callout.weight(.medium))
                if let excerpt {
                    // What the search found, in the line it was found in.
                    Text(Self.attributed(excerpt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(verbatim: "\(item.pixelWidth) × \(item.pixelHeight)" + (item.appName.map { "  ·  \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Restore", bundle: .module)) { model.actions.restore(item) }
        .accessibilityAction(named: Text("Copy", bundle: .module)) { model.actions.copy(item) }
        .accessibilityAction(named: Text("Save", bundle: .module)) { model.actions.save(item) }
        .accessibilityAction(named: Text("Quick Look", bundle: .module)) { model.quickLook(item) }
        .accessibilityActions {
            if item.kind == .screenshot {
                Button { model.actions.annotate(item) } label: { Text("Annotate", bundle: .module) }
                Button { model.actions.recognizeText(item) } label: { Text("Recognize Text", bundle: .module) }
                Button { model.actions.pin(item) } label: { Text("Pin to Screen", bundle: .module) }
            }
        }
        .accessibilityAction(named: Text("Move to Trash", bundle: .module)) { model.moveToTrash(item) }
    }

    private var isGIF: Bool {
        item.fileName.lowercased().hasSuffix(".gif")
    }

    private var excerpt: HistorySearch.Excerpt? {
        model.matches?[item.id]?.excerpt
    }

    /// The excerpt with what was found in label ink and semibold, the rest left to the line's secondary ink.
    static func attributed(_ excerpt: HistorySearch.Excerpt) -> AttributedString {
        var found = AttributedString(excerpt.found)
        found.foregroundColor = .primary
        found.font = .caption.weight(.semibold)
        return AttributedString((excerpt.continuesBefore ? "…" : "") + excerpt.before) + found + AttributedString(excerpt.after)
    }

    /// When it was taken, and what the search found in it.
    private var accessibilityValue: Text {
        let time = Text(item.createdAt, format: .relative(presentation: .named))
        guard let excerpt else { return time }
        return Text("\(time), \(excerpt.before + excerpt.found + excerpt.after)", bundle: .module)
    }

    private var accessibilityLabel: Text {
        item.kind == .recording
            ? isGIF
                ? Text("GIF, \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
                : Text("Recording, \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
            : Text("Screenshot, \(item.pixelWidth) by \(item.pixelHeight) pixels", bundle: .module)
    }

    /// A small play badge in the corner, or "GIF" for a GIF, with the length when it is known.
    private var recordingBadge: some View {
        HStack(spacing: 4) {
            if isGIF {
                Text(verbatim: "GIF")
            } else {
                Image(systemName: "play.fill")
            }
            if let duration = item.duration {
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var hoverActions: some View {
        VStack(spacing: 10) {
            Button {
                model.actions.restore(item)
            } label: {
                Label {
                    Text("Restore", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .font(.callout.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            HStack(spacing: 6) {
                iconButton("doc.on.doc", Text("Copy", bundle: .module)) { model.actions.copy(item) }
                iconButton("square.and.arrow.down", Text("Save", bundle: .module)) { model.actions.save(item) }
                iconButton("folder", Text("Show in Finder", bundle: .module)) { model.actions.reveal(item) }
                iconButton("trash", Text("Move to Trash", bundle: .module)) { model.moveToTrash(item) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.glass)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var menu: some View {
        Button { model.actions.restore(item) } label: { Text("Restore", bundle: .module) }
            .keyboardShortcut(.return, modifiers: [])
        Button { model.actions.copy(item) } label: { Text("Copy", bundle: .module) }
            .keyboardShortcut("c")
        Button { model.actions.save(item) } label: { Text("Save", bundle: .module) }
            .keyboardShortcut("s")
        Divider()
        Button { model.quickLook(item) } label: { Text("Quick Look", bundle: .module) }
            .keyboardShortcut(.space, modifiers: [])
        if item.kind == .screenshot {
            Button { model.actions.annotate(item) } label: { Text("Annotate…", bundle: .module) }
        } else if isGIF {
            Button { model.actions.annotate(item) } label: { Text("Play", bundle: .module) }
        } else {
            Button { model.actions.annotate(item) } label: { Text("Edit…", bundle: .module) }
        }
        Button { model.actions.open(item) } label: { Text("Open", bundle: .module) }
        if item.kind == .screenshot {
            Button { model.actions.recognizeText(item) } label: { Text("Recognize Text…", bundle: .module) }
            Button { model.actions.pin(item) } label: { Text("Pin to Screen", bundle: .module) }
        }
        Button { model.actions.reveal(item) } label: { Text("Show in Finder", bundle: .module) }
        Divider()
        Button(role: .destructive) { model.moveToTrash(item) } label: { Text("Move to Trash", bundle: .module) }
            .keyboardShortcut(.delete)
    }
}

extension HistoryRetention {
    var title: String {
        switch self {
        case .never: String(localized: "Never", bundle: .module)
        case .oneDay: String(localized: "1 Day", bundle: .module)
        case .threeDays: String(localized: "3 Days", bundle: .module)
        case .oneWeek: String(localized: "1 Week", bundle: .module)
        case .oneMonth: String(localized: "1 Month", bundle: .module)
        }
    }
}
