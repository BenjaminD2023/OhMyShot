import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import OMSDesign
import QuickLook
import SwiftUI

struct HistoryView: View {
    @Bindable var model: HistoryModel
    @State private var gridWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardMinimum: CGFloat = 200
    private static let spacing: CGFloat = 20
    private static let inset: CGFloat = 24
    private let columns = [GridItem(.adaptive(minimum: cardMinimum, maximum: 280), spacing: spacing)]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.items.isEmpty && model.isReloading {
                    ProgressView { Text("Loading captures…", bundle: .module) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.isUpdatingSearch && model.visibleItems.isEmpty {
                    ProgressView { Text("Updating search results…", bundle: .module) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.activeItems.isEmpty {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                bottomOverlays
            }

            if !model.activeItems.isEmpty {
                Divider()
                footerBar
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(.background)
        .toolbar { toolbar }
        .searchable(text: $model.query, placement: .toolbar, prompt: Text("Search Text", bundle: .module))
        .searchFocused($searchFocused)
        // Return in the search field goes to the first capture found, ready for the grid's keys.
        .onSubmit(of: .search) {
            Task {
                guard await model.waitForCurrentResults(), searchFocused, let first = model.visibleItems.first else { return }
                model.click(first.id, modifiers: [])
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
        .quickLookPreview($model.previewURL, in: model.visiblePreviewURLs)
        .confirmingTrash($model.trashRequest) { items in model.moveToTrash(items) }
        .alert(Text("Couldn’t Move to Trash", bundle: .module), isPresented: Binding(
            get: { model.trashFailure != nil }, set: { if !$0 { model.trashFailure = nil } }
        )) {} message: {
            Text(verbatim: model.trashFailure ?? "")
        }
        .confirmingRetentionChange(model.retention)
    }

    private var footerBar: some View {
        HStack {
            Text(verbatim: model.diskUsageSummary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(.background)
        .accessibilityElement(children: .combine)
    }

    private var hasFloatingBottomBar: Bool {
        model.selectedItems.count > 1 || model.pendingTrash != nil || model.reading > 0 || model.failedIndexingCount > 0
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
                    // A card dragged out takes every selected capture when it is one of them, as in Finder, else
                    // itself alone; nothing when one of their copies can't be made.
                    .dragContainer(for: HandedOverFile.self) { (dragged: UUID) in model.filesToHandOver(from: dragged) }
                    .padding(.horizontal, Self.inset)
                    .padding(.top, 20)
                    .padding(.bottom, hasFloatingBottomBar ? 76 : 20)
                    // Measured inside the scroll view, so a visible scroller is not counted as room.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(phases: .down) { press in
                handle(press) ? .handled : .ignored
            }
            // ⌘C, ⌘S, ⇧⌘S, ⌘O, ⌘⌫ and ⌘A arrive from the main menu as commands; with nothing selected they are disabled.
            .onCommand(#selector(NSText.copy(_:)), perform: selectionCommand { model.copy($0) })
            .onCommand(#selector(NSDocument.save(_:)), perform: selectionCommand { $0.forEach(model.actions.save) })
            .onCommand(Selector(("saveProject:")), perform: model.selectedItems.count == 1 ? { model.focusedItem.map(model.actions.saveAs) } : nil)
            .onCommand(Selector(("saveScreenshotAs:")), perform: model.selectedItems.count == 1 ? { model.focusedItem.map(model.actions.saveAs) } : nil)
            // ⌘O does what a double-click does: the editor, a recording's window, a GIF's player.
            .onCommand(Selector(("openInEditor:")), perform: selectionCommand { $0.forEach(model.actions.annotate) })
            // ⌘P prints one selected screenshot; a recording has nothing to print.
            .onCommand(Selector(("printCapture:")), perform: model.selectedItems.count == 1 && model.focusedItem?.kind == .screenshot
                ? { model.focusedItem.map(model.print) } : nil)
            // Combine into Collage wants two screenshots or more, Export as PDF one or more; neither takes a recording.
            .onCommand(Selector(("combineIntoCollage:")), perform: model.collageItems(from: nil).isEmpty ? nil : { model.actions.combine(model.collageItems(from: nil)) })
            .onCommand(Selector(("exportPDF:")), perform: model.pdfItems(from: nil).isEmpty ? nil : { model.actions.exportPDF(model.pdfItems(from: nil), model.window) })
            .onCommand(#selector(NSText.delete(_:)), perform: selectionCommand { _ in model.trashSelection() })
            .onCommand(#selector(NSText.selectAll(_:)), perform: model.visibleItems.isEmpty ? nil : { model.selectAll() })
            .onChange(of: model.focus) { _, focus in
                guard let focus else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(focus) }
            }
            .onAppear { gridFocused = true }
        }
    }

    /// The grid's plain keys: arrows select (with Shift to extend), Return restores, and Space opens Quick Look, as in
    /// Finder; the period adds the selection to Favorites, or takes it out, as in Photos; Escape collapses multi-selection.
    private func handle(_ press: KeyPress) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        let extending = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow: model.moveSelection(by: -1, extending: extending)
        case .rightArrow: model.moveSelection(by: 1, extending: extending)
        case .upArrow: model.moveSelection(by: -columnCount, extending: extending)
        case .downArrow: model.moveSelection(by: columnCount, extending: extending)
        case .return:
            guard !extending else { return false }
            // Every capture selected goes back to Quick Access.
            let selected = model.selectedItems
            guard !selected.isEmpty else { return false }
            selected.forEach(model.actions.restore)
        case .space:
            guard !extending, let item = model.focusedItem else { return false }
            model.quickLook(item)
        case KeyEquivalent("."):
            guard !extending else { return false }
            let selected = model.selectedItems
            guard !selected.isEmpty else { return false }
            model.toggleFavorite(selected)
        case .escape:
            guard !extending, model.selection.count > 1 else { return false }
            if let focused = model.focusedItem {
                model.click(focused.id, modifiers: [])
            } else {
                model.clearSelection()
            }
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
                Text("Favorites", bundle: .module).tag(HistoryModel.Filter.favorites)
            } label: {
                Text("Show", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker(selection: $model.dateFilter) {
                    ForEach(HistoryModel.DateFilter.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                } label: {
                    Text("Date", bundle: .module)
                }
                .pickerStyle(.inline)

                if !model.availableApps.isEmpty {
                    Divider()
                    Picker(selection: $model.appFilter) {
                        Text("All Apps", bundle: .module).tag(String?.none)
                        ForEach(model.availableApps, id: \.self) { app in
                            Text(verbatim: app).tag(Optional(app))
                        }
                    } label: {
                        Text("App", bundle: .module)
                    }
                    .pickerStyle(.inline)
                }

                if model.hasSecondaryFilters {
                    Divider()
                    Button {
                        model.appFilter = nil
                        model.dateFilter = .any
                    } label: {
                        Text("Clear Filters", bundle: .module)
                    }
                }
            } label: {
                Label {
                    Text(filterMenuLabel)
                } icon: {
                    Image(systemName: model.hasSecondaryFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(model.hasSecondaryFilters ? Color.accentColor : Color.primary)
                }
            }
            .help(Text("Filter by date or app", bundle: .module))
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(selection: model.retention.binding) {
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
            .help(Text("How long captures stay in the history. Favorites stay until you take them out, unless History is off.", bundle: .module))
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

    private var filterMenuLabel: String {
        if let app = model.appFilter, model.dateFilter != .any {
            return String(localized: "\(app) · \(model.dateFilter.title)", bundle: .module)
        }
        if let app = model.appFilter { return app }
        if model.dateFilter != .any { return model.dateFilter.title }
        return String(localized: "Filter", bundle: .module)
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

    /// Nothing found under the active filters, though the search found captures they leave out.
    private var foundElsewhere: some View {
        placeholder(
            symbol: "magnifyingglass",
            title: foundElsewhereTitle,
            message: String(localized: "Found in \(model.foundElsewhere) captures under All.", bundle: .module)
        ) {
            Button { model.clearFilters() } label: { Text("Show All", bundle: .module) }
        }
    }

    private var foundElsewhereTitle: Text {
        if model.hasSecondaryFilters {
            return Text("No Matching Captures Found", bundle: .module)
        }
        return switch model.filter {
        case .recordings: Text("No Recordings Found", bundle: .module)
        case .favorites: Text("No Favorites Found", bundle: .module)
        case .all, .screenshots: Text("No Screenshots Found", bundle: .module)
        }
    }

    private var noResults: some View {
        placeholder(
            symbol: "magnifyingglass",
            title: Text("No Results for “\(model.query.trimmingCharacters(in: .whitespaces))”", bundle: .module),
            message: model.reading > 0
                ? String(localized: "Still reading the text in \(model.reading) captures.", bundle: .module)
                : String(localized: "Captures are found by the words in them, the app, window title, or file name.", bundle: .module)
        )
    }

    @ViewBuilder private var filteredEmptyState: some View {
        if model.hasSecondaryFilters {
            placeholder(
                symbol: "line.3.horizontal.decrease.circle",
                title: Text("No Matching Captures", bundle: .module),
                message: String(localized: "No captures match the selected filters.", bundle: .module)
            ) {
                Button { model.clearFilters() } label: { Text("Show All", bundle: .module) }
            }
        } else {
            switch model.filter {
            case .favorites:
                placeholder(
                    symbol: "star",
                    title: Text("No Favorites", bundle: .module),
                    message: model.canFavorite
                        ? String(localized: "Favorites stay until you take them out, however long Keep captures is. Add one from a capture’s menu, or select it and press the period key.", bundle: .module)
                        : HistoryModel.favoritesNeedHistory
                ) {
                    Button { model.clearFilters() } label: { Text("Show All", bundle: .module) }
                }
            case .all, .screenshots, .recordings:
                placeholder(
                    symbol: model.filter == .recordings ? "video" : "photo",
                    title: model.filter == .recordings ? Text("No Recordings", bundle: .module) : Text("No Screenshots", bundle: .module),
                    message: String(localized: "Choose All to see every capture in the history.", bundle: .module)
                )
            }
        }
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

    private var dark: Bool { colorScheme == .dark }
    private var increasedContrast: Bool { contrast == .increased }

    private var capsuleStrokeColor: Color {
        increasedContrast
            ? Color(cgColor: Theme.Material.edge(dark: dark, contrast: true))
            : Color(nsColor: .separatorColor)
    }

    private var capsuleStrokeWidth: CGFloat {
        Theme.Material.edgeWidth(contrast: increasedContrast)
    }

    @ViewBuilder private var bottomOverlays: some View {
        let selected = model.selectedItems
        VStack(spacing: 8) {
            if !model.visibleItems.isEmpty && (model.isUpdatingSearch || model.isReloading) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if model.isUpdatingSearch { Text("Updating search results…", bundle: .module) }
                    else { Text("Loading captures…", bundle: .module) }
                }
                .font(.callout)
                .padding(10)
                .windowNoticeCard()
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
            if model.reading > 0 || model.failedIndexingCount > 0 {
                indexingStatusBar
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            }
            if model.pendingTrash != nil {
                undoTrashToast
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            }
            if let feedback = model.copyFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if feedback.kind == .text {
                        Text("Copied Text", bundle: .module)
                    } else if feedback.count == 1 {
                        Text("Copied", bundle: .module)
                    } else {
                        Text("Copied \(feedback.count) Captures", bundle: .module)
                    }
                }
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(capsuleStrokeColor, lineWidth: capsuleStrokeWidth))
                .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
                .allowsHitTesting(false)
                // VoiceOver already receives an immediate announcement from `HistoryModel.copy`.
                .accessibilityHidden(true)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            }
            if selected.count > 1 {
                selectionBar(for: selected)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, 16)
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade), value: model.copyFeedback?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade), value: model.pendingTrash?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade), value: model.reading > 0 || model.failedIndexingCount > 0)
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade), value: selected.count > 1)
    }

    private var indexingStatusBar: some View {
        HStack(spacing: 8) {
            if model.reading > 0 {
                ProgressView()
                    .controlSize(.small)
                Text("Still reading the text in \(model.reading) captures.", bundle: .module)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Couldn’t index text in \(model.failedIndexingCount) captures", bundle: .module)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    model.retryIndexing()
                } label: {
                    Text("Retry", bundle: .module)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(capsuleStrokeColor, lineWidth: capsuleStrokeWidth))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .accessibilityElement(children: model.reading > 0 ? .combine : .contain)
    }

    private var undoTrashToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Moved to Trash", bundle: .module)
                .font(.callout.weight(.medium))
            Button {
                model.undoPendingTrash()
            } label: {
                Text("Undo", bundle: .module)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(capsuleStrokeColor, lineWidth: capsuleStrokeWidth))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }

    private func selectionBar(for selected: [HistoryItem]) -> some View {
        let collage = model.collageItems(from: nil)
        let pdf = model.pdfItems(from: nil)
        return HStack(spacing: 4) {
            Text("\(selected.count) selected", bundle: .module)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.trailing, 4)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            SelectionBarButton(symbol: "doc.on.doc", title: Text("Copy", bundle: .module)) {
                model.copy(selected)
            }
            SelectionBarButton(symbol: "square.and.arrow.down", title: Text("Save", bundle: .module)) {
                selected.forEach(model.actions.save)
            }
            if !collage.isEmpty {
                SelectionBarButton(symbol: "rectangle.grid.2x2", title: Text("Collage…", bundle: .module)) {
                    model.actions.combine(collage)
                }
                .accessibilityLabel(Text("Combine \(collage.count) into Collage…", bundle: .module))
            }
            if !pdf.isEmpty {
                SelectionBarButton(symbol: "doc.richtext", title: Text("PDF…", bundle: .module)) {
                    model.actions.exportPDF(pdf, model.window)
                }
                .accessibilityLabel(Text("Export \(pdf.count) as PDF…", bundle: .module))
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            SelectionBarButton(symbol: "trash", tint: .red) {
                model.trashSelection()
            }
            .help(Text("Move Selected to Trash", bundle: .module))
            .accessibilityLabel(Text("Move \(selected.count) to Trash", bundle: .module))

            SelectionBarButton(symbol: "xmark.circle.fill", tint: .secondary) {
                model.clearSelection()
            }
            .help(Text("Clear Selection", bundle: .module))
            .accessibilityLabel(Text("Clear Selection", bundle: .module))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(capsuleStrokeColor, lineWidth: capsuleStrokeWidth))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Selection actions", bundle: .module))
    }
}

/// A compact capsule button inside Capture History's floating multi-selection bar.
private struct SelectionBarButton: View {
    let symbol: String
    var title: Text?
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if let title {
                    title
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(tint ?? Color.primary)
            .padding(.horizontal, title == nil ? 8 : 10)
            .frame(height: 28)
            .background {
                if hovering {
                    Capsule().fill(Color(cgColor: Theme.ChipFill.hoverColor(dark: colorScheme == .dark, contrast: contrast == .increased)))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
