import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import QuickLook
import SwiftUI

struct HistoryView: View {
    @Bindable var model: HistoryModel
    @State private var gridWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardMinimum: CGFloat = 200
    private static let spacing: CGFloat = 20
    private static let inset: CGFloat = 24
    private let columns = [GridItem(.adaptive(minimum: cardMinimum, maximum: 280), spacing: spacing)]

    var body: some View {
        Group {
            if model.items.isEmpty && model.isReloading {
                ProgressView { Text("Loading captures…", bundle: .module) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isUpdatingSearch && model.visibleItems.isEmpty {
                ProgressView { Text("Updating search results…", bundle: .module) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
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
        .overlay(alignment: .bottom) {
            if !model.visibleItems.isEmpty && (model.isUpdatingSearch || model.isReloading) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if model.isUpdatingSearch { Text("Updating search results…", bundle: .module) }
                    else { Text("Loading captures…", bundle: .module) }
                }
                .font(.callout)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
        }
        .toolbar { toolbar }
        .searchable(text: $model.query, placement: .toolbar, prompt: Text("Search Text", bundle: .module))
        .searchFocused($searchFocused)
        // Return in the search field goes to the first capture found, ready for the grid's keys.
        .onSubmit(of: .search) {
            Task {
                guard await model.waitForCurrentResults(), searchFocused, let first = model.visibleItems.first else { return }
                model.selection = [first.id]
                model.focus = first.id
                gridFocused = true
            }
        }
        // ⌘F, Find… in the Edit menu: to the search field, whatever the window shows.
        .onCommand(#selector(NSTextView.performFindPanelAction(_:))) { searchFocused = true }
        // What a search found is said once typing pauses, for VoiceOver.
        .task(id: model.searchResultRevision) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, !model.isUpdatingSearch, model.isSearching else { return }
            let count = model.visibleItems.count
            AccessibilityNotification.Announcement(count == 0
                ? String(localized: "No Results", bundle: .module)
                : String(localized: "\(count) captures found", bundle: .module)).post()
        }
        .quickLookPreview($model.previewURL)
        .confirmingTrash($model.trashRequest) { items in model.moveToTrash(items) }
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
                            HistoryCard(item: item, model: model, isSelected: model.selection.contains(item.id))
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
            // ⌘C, ⌘S, ⌘O, ⌘⌫ and ⌘A arrive from the main menu as commands; with nothing selected they are disabled.
            .onCommand(#selector(NSText.copy(_:)), perform: selectionCommand { model.copy($0) })
            .onCommand(#selector(NSDocument.save(_:)), perform: selectionCommand { $0.forEach(model.actions.save) })
            // ⌘O does what a double-click does: the editor, a recording's window, a GIF's player.
            .onCommand(Selector(("openInEditor:")), perform: selectionCommand { $0.forEach(model.actions.annotate) })
            // ⌘P prints one selected screenshot; a recording has nothing to print.
            .onCommand(Selector(("printCapture:")), perform: model.selectedItems.count == 1 && model.focusedItem?.kind == .screenshot
                ? { model.focusedItem.map(model.print) } : nil)
            .onCommand(#selector(NSText.delete(_:)), perform: selectionCommand { _ in model.trashSelection() })
            .onCommand(#selector(NSText.selectAll(_:)), perform: model.visibleItems.isEmpty ? nil : { model.selectAll() })
            .onChange(of: model.focus) { _, focus in
                guard let focus else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(focus) }
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
            // Every capture selected goes back to Quick Access.
            let selected = model.selectedItems
            guard !selected.isEmpty else { return false }
            selected.forEach(model.actions.restore)
        case .space:
            guard let item = model.focusedItem else { return false }
            model.quickLook(item)
        default:
            return false
        }
        return true
    }

    /// A menu command on the selected captures, or nil (a disabled command) when nothing is selected.
    private func selectionCommand(_ action: @escaping ([HistoryItem]) -> Void) -> (() -> Void)? {
        let selected = model.selectedItems
        guard !selected.isEmpty else { return nil }
        return { action(selected) }
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
            // Every capture shown: under the Show filter or a search, only those.
            Button {
                model.trashShown()
            } label: {
                Label {
                    model.showsEverything ? Text("Move All to Trash", bundle: .module) : Text("Move Shown to Trash", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .help(model.showsEverything
                ? Text("Move all captures in the history to the Trash", bundle: .module)
                : Text("Move the captures shown to the Trash", bundle: .module))
            .disabled(model.visibleItems.isEmpty)
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
            title: Text("No Captures Yet", bundle: .module),
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
            title: model.filter == .recordings ? Text("No Recordings", bundle: .module) : Text("No Screenshots", bundle: .module),
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
            : String(localized: "Captures stay here for \(model.settings.historyRetention.duration).", bundle: .module)
        guard let shortcut = KeyboardShortcuts.getShortcut(for: CaptureShortcut.captureArea.name) else { return keep }
        return Sentences.joined(keep, String(localized: "Press \(shortcut.description) to capture an area.", bundle: .module))
    }
}
