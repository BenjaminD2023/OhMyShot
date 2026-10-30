import AppKit
import OMSCore
import SwiftUI

extension SettingsTab {
    /// The tile behind the pane's symbol in the sidebar, in a system color as System Settings has them.
    var tint: Color {
        switch self {
        case .general: .gray
        case .capture: .blue
        case .screenshots: .purple
        case .quickAccess: .orange
        case .recording: .red
        case .text: .green
        case .tools: .indigo
        case .sharing: .cyan
        case .shortcuts: .gray
        case .automation: .green
        case .permissions: .blue
        case .about: .teal
        }
    }

    /// The rows of the pane as a search finds them: each row's title, where a search for it lands, and the names of
    /// its controls and choices. `SettingsSearchTests` checks that every row a pane draws is here.
    var searchRows: [SettingsSearchRow] {
        switch self {
        case .general:
            [
                SettingsSearchRow(String(localized: "Language", bundle: .module), terms: [
                    String(localized: "System Default", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Startup", bundle: .module), terms: [
                    String(localized: "Launch at login", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Updates", bundle: .module), terms: [
                    String(localized: "Check for updates automatically", bundle: .module),
                    String(localized: "Check Now", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Menu bar", bundle: .module), terms: [
                    String(localized: "Show icon", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Sound", bundle: .module), terms: [
                    String(localized: "Play sounds", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Keep captures", bundle: .module), terms: [
                    String(localized: "Open History", bundle: .module),
                    String(localized: "Capture History", bundle: .module),
                ]),
            ]
        case .capture:
            [
                SettingsSearchRow(String(localized: "Selecting", bundle: .module), terms: [
                    String(localized: "Freeze the screen", bundle: .module),
                    String(localized: "Show the pointer in screenshots", bundle: .module),
                    String(localized: "Shift keeps", bundle: .module),
                    String(localized: "A square", bundle: .module),
                    String(localized: "Snap the selection to text", bundle: .module),
                    String(localized: "All-In-One remembers the last area", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Magnifier", bundle: .module), terms: [
                    String(localized: "Size", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Self-Timer", bundle: .module)),
                SettingsSearchRow(String(localized: "Windows", bundle: .module), terms: [
                    String(localized: "Capture the shadow", bundle: .module),
                    String(localized: "Window background", bundle: .module),
                    String(localized: "Same background as screenshots", bundle: .module),
                    String(localized: "No background", bundle: .module),
                    String(localized: "Desktop wallpaper", bundle: .module),
                ]),
            ]
        case .screenshots:
            [
                SettingsSearchRow(String(localized: "After screenshot", bundle: .module), terms: [
                    String(localized: "Copy", bundle: .module),
                    String(localized: "Quick Access", bundle: .module),
                    String(localized: "Save", bundle: .module),
                    String(localized: "Upload", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Save to", bundle: .module)),
                SettingsSearchRow(String(localized: "Background", bundle: .module)),
                SettingsSearchRow(String(localized: "Format", bundle: .module), terms: [
                    String(localized: "Quality", bundle: .module),
                    "PNG",
                    "JPEG",
                    "HEIC",
                ]),
                SettingsSearchRow(String(localized: "Pictures", bundle: .module), terms: [
                    String(localized: "Save Retina screenshots at 1×", bundle: .module),
                    String(localized: "Convert to sRGB", bundle: .module),
                    String(localized: "Add a 1 px border", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "File name", bundle: .module), terms: [
                    String(localized: "Ask for a name when saving", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Clipboard", bundle: .module), terms: [
                    String(localized: "Picture only", bundle: .module),
                    String(localized: "File and picture", bundle: .module),
                ]),
            ]
        case .quickAccess:
            [
                SettingsSearchRow(String(localized: "Position", bundle: .module), terms: [
                    String(localized: "Bottom left", bundle: .module),
                    String(localized: "Bottom right", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Size", bundle: .module), terms: [
                    String(localized: "Small", bundle: .module),
                    String(localized: "Medium", bundle: .module),
                    String(localized: "Large", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Display", bundle: .module), terms: [
                    String(localized: "Show on the display with the pointer", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Close cards", bundle: .module), terms: [
                    String(localized: "Save and Close", bundle: .module),
                ]),
            ]
        case .recording:
            [
                SettingsSearchRow(String(localized: "Countdown", bundle: .module)),
                SettingsSearchRow(String(localized: "While recording", bundle: .module), terms: [
                    String(localized: "Show controls", bundle: .module),
                    String(localized: "Show the pointer", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Recorded area", bundle: .module), terms: [
                    String(localized: "Outline", bundle: .module),
                    String(localized: "Dim the rest of the screen", bundle: .module),
                    String(localized: "Red frame", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Audio", bundle: .module)),
                SettingsSearchRow(String(localized: "Clicks", bundle: .module), terms: [
                    String(localized: "Accent rings", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Keystrokes", bundle: .module), terms: [
                    String(localized: "All keys", bundle: .module),
                    String(localized: "Shortcuts only", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Studio", bundle: .module), terms: [
                    String(localized: "Keep the keys pressed", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Frame rate", bundle: .module)),
                SettingsSearchRow(String(localized: "Video format", bundle: .module), terms: [
                    String(localized: "HEVC", bundle: .module),
                    "H.264",
                ]),
                SettingsSearchRow(String(localized: "GIF", bundle: .module), terms: [
                    String(localized: "GIF frame rate", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "After recording", bundle: .module)),
            ]
        case .text:
            [
                SettingsSearchRow(String(localized: "Capture Text", bundle: .module), terms: [
                    String(localized: "Show the copied text", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Text card position", bundle: .module), terms: [
                    String(localized: "Below selection", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Close text card", bundle: .module)),
                SettingsSearchRow(String(localized: "Image line breaks", bundle: .module), terms: [
                    String(localized: "Keep Line Breaks", bundle: .module),
                    String(localized: "Join Lines", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Recognized Text", bundle: .module), terms: [
                    String(localized: "Wrap text to window", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Text from apps", bundle: .module), terms: [
                    String(localized: "Accessibility", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Translate into", bundle: .module)),
                SettingsSearchRow(String(localized: "Model packs", bundle: .module)),
                SettingsSearchRow(String(localized: "Cloud reading", bundle: .module), terms: [
                    String(localized: "API key", bundle: .module),
                    String(localized: "Base URL", bundle: .module),
                    String(localized: "Model", bundle: .module),
                ]),
            ]
        case .tools:
            [
                SettingsSearchRow(String(localized: "Copy colors as", bundle: .module)),
                SettingsSearchRow(String(localized: "Measure in", bundle: .module), terms: [
                    String(localized: "Points", bundle: .module),
                    String(localized: "Pixels", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Measurement snapping", bundle: .module), terms: [
                    String(localized: "Snap selections to content", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Edge tolerance", bundle: .module)),
                SettingsSearchRow(String(localized: "Pins", bundle: .module), terms: [
                    String(localized: "Corners", bundle: .module),
                    String(localized: "Shadow", bundle: .module),
                    String(localized: "Border", bundle: .module),
                    String(localized: "Show in screenshots", bundle: .module),
                ]),
            ]
        case .sharing:
            [
                SettingsSearchRow(String(localized: "Destinations", bundle: .module), terms: [
                    String(localized: "Add Destination", bundle: .module),
                    String(localized: "Import ShareX Uploader…", bundle: .module),
                    "S3",
                    "WebDAV",
                ]),
                SettingsSearchRow(String(localized: "After upload", bundle: .module), terms: [
                    String(localized: "Copy link after upload", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Recent uploads", bundle: .module), terms: [
                    String(localized: "Forget All", bundle: .module),
                ]),
            ]
        case .shortcuts:
            CaptureShortcut.allCases.filter(\.isAvailable).map { SettingsSearchRow($0.title) }
        case .automation:
            [
                SettingsSearchRow(String(localized: "URL scheme", bundle: .module), terms: [
                    String(localized: "Allow other apps to control OhMyShot", bundle: .module),
                ]),
                SettingsSearchRow(String(localized: "Approved apps", bundle: .module), terms: [
                    String(localized: "Command-line tools", bundle: .module),
                ]),
            ]
        case .permissions:
            Permission.allCases.map { SettingsSearchRow($0.title) }
        case .about:
            [SettingsSearchRow(String(localized: "Acknowledgments", bundle: .module))]
        }
    }

    /// What a search finds the pane by besides its title: the titles of its rows and the names of their controls.
    var searchTerms: [String] {
        var seen = Set<String>()
        return searchRows.flatMap { [$0.title] + $0.terms }.filter { seen.insert($0).inserted }
    }

    /// The rows a search finds in the pane, or nil when it finds neither them nor the pane's title.
    func matches(_ query: String) -> [String]? {
        let found = searchTerms.filter { $0.localizedStandardContains(query) }
        return found.isEmpty && !title.localizedStandardContains(query) ? nil : found
    }

    /// The panes a search finds, with the rows it found in each: those whose title it found first ("text" lists Text
    /// before Capture's "Snap the selection to text"), then the others in the sidebar's order. Return opens the first.
    static func found(_ query: String) -> [(tab: SettingsTab, rows: [String])] {
        let found = allCases.compactMap { tab in tab.matches(query).map { (tab: tab, rows: $0) } }
        return found.filter { $0.tab.title.localizedStandardContains(query) } + found.filter { !$0.tab.title.localizedStandardContains(query) }
    }

    /// The title of the first row a search finds in the pane, where opening the pane from the search lands.
    func row(matching query: String) -> String? {
        searchRows.first { row in ([row.title] + row.terms).contains { $0.localizedStandardContains(query) } }?.title
    }
}

/// A row of a settings pane as a search finds it.
struct SettingsSearchRow {
    /// The row's title, as `SettingsRow` shows it: what a search lands on.
    let title: String
    /// The names of its controls and choices.
    var terms: [String] = []

    init(_ title: String, terms: [String] = []) {
        self.title = title
        self.terms = terms
    }
}

/// Where a search sends the pane it opens: the row to scroll to and light up for a moment.
@Observable
final class SettingsSearchTarget {
    /// The title of the row to land on.
    private(set) var row: String?
    /// The row lit up now, which goes after a moment.
    var lit: String?
    /// Counts the requests, so the same row asked for twice lands twice.
    private(set) var request = 0

    func land(on row: String?) {
        self.row = row
        request += 1
    }
}

let sidebarWidth: CGFloat = 215

/// The smallest and largest the settings window's content gets. Wider than the maximum, a pane's rows sit in a band
/// of empty space; taller, there is nothing more to show.
let settingsMinSize = CGSize(width: sidebarWidth + paneWidth, height: 420)
let settingsMaxSize = CGSize(width: settingsMinSize.width + 280, height: 900)

/// The pane's symbol, white on a rounded tile of its color, as System Settings draws its panes.
struct SettingsIcon: View {
    let tab: SettingsTab
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(systemName: tab.symbolName)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(tab.tint.gradient, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// The pane on show, the panes visited before and after it, and the sidebar's search.
@Observable
final class SettingsNavigator {
    private(set) var tab: SettingsTab = .general {
        didSet { if tab != oldValue { onChange?(tab) } }
    }

    var query = ""
    /// Where a search sends the pane it opens.
    let target = SettingsSearchTarget()

    private var back: [SettingsTab] = []
    private var forward: [SettingsTab] = []

    @ObservationIgnored var onChange: ((SettingsTab) -> Void)?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Shows a pane, which Back then leaves for the one shown now.
    func go(to tab: SettingsTab) {
        guard tab != self.tab else { return }
        back.append(self.tab)
        forward.removeAll()
        self.tab = tab
    }

    /// Shows a pane with no history either side of it.
    func start(at tab: SettingsTab) {
        back.removeAll()
        forward.removeAll()
        self.tab = tab
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(tab)
        tab = previous
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(tab)
        tab = next
    }

    /// Opens a pane the search found, on the first row it found there.
    func open(_ tab: SettingsTab, searchedFor query: String) {
        go(to: tab)
        target.land(on: tab.row(matching: query))
    }
}

/// The window's content: the sidebar of panes with its search field, and the chosen pane beside it, titled in the
/// toolbar after the Back and Forward buttons, as in System Settings.
struct SettingsRootView: View {
    @Bindable var navigator: SettingsNavigator
    /// The pane for a tab, made the first time it is asked for and the same one after.
    let pane: (SettingsTab) -> NSViewController
    @FocusState private var isSearching: Bool

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(navigator: navigator)
                .toolbar(removing: .sidebarToggle)
                // The sidebar can't be dragged: not wider or narrower, and not shut, as it could not be opened again
                // with no sidebar button.
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
                .background(FixedSidebar())
        } detail: {
            SettingsPaneHost(controller: pane(navigator.tab))
                .id(navigator.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(navigator.tab.title)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            navigator.goBack()
                        } label: {
                            Label { Text("Back", bundle: .module) } icon: { Image(systemName: "chevron.left") }
                        }
                        .disabled(!navigator.canGoBack)
                        .keyboardShortcut("[", modifiers: .command)
                        .help(Text("Show the previous pane", bundle: .module))
                        Button {
                            navigator.goForward()
                        } label: {
                            Label { Text("Forward", bundle: .module) } icon: { Image(systemName: "chevron.right") }
                        }
                        .disabled(!navigator.canGoForward)
                        .keyboardShortcut("]", modifiers: .command)
                        .help(Text("Show the next pane", bundle: .module))
                    }
                }
        }
        .searchable(text: $navigator.query, placement: .sidebar, prompt: Text("Search", bundle: .module))
        .searchFocused($isSearching)
        .onSubmit(of: .search) {
            if let first = SettingsTab.found(navigator.query).first {
                navigator.open(first.tab, searchedFor: navigator.query)
            }
        }
        .background {
            // Command-F goes to the search field, as in System Settings.
            Button { isSearching = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(
            minWidth: settingsMinSize.width, maxWidth: settingsMaxSize.width,
            minHeight: settingsMinSize.height, maxHeight: settingsMaxSize.height
        )
    }
}

/// Keeps the sidebar from collapsing, which SwiftUI has no way to say: it finds the split view the sidebar sits in and
/// marks the sidebar's column as one that can't collapse, neither by dragging its edge nor by narrowing the window.
/// SwiftUI marks it collapsible again each time it updates the split view (on choosing a pane, say), so it is
/// watched and set back.
private struct FixedSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var observation: NSKeyValueObservation?
        private weak var sidebar: NSSplitViewItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard window != nil else { return }
            // The split view is laid out around the sidebar a moment after the sidebar joins the window.
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        private func pin() {
            var view = superview
            while let current = view, !(current is NSSplitView) { view = current.superview }
            guard let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first else { return }
            self.sidebar = sidebar
            fix()
            observation = sidebar.observe(\.canCollapse) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.fix() }
            }
        }

        private func fix() {
            guard let sidebar else { return }
            if sidebar.canCollapse { sidebar.canCollapse = false }
            if sidebar.canCollapseFromWindowResize { sidebar.canCollapseFromWindowResize = false }
        }
    }
}

/// The panes down the window's left side: in groups, or while searching, those the search finds with the rows it
/// found in each.
private struct SettingsSidebar: View {
    @Bindable var navigator: SettingsNavigator

    var body: some View {
        let query = navigator.query.trimmingCharacters(in: .whitespaces)
        let selection = Binding<SettingsTab?>(get: { navigator.tab }, set: { tab in
            guard let tab else { return }
            // A pane chosen from what a search found opens on the row it found.
            if query.isEmpty { navigator.go(to: tab) } else { navigator.open(tab, searchedFor: query) }
        })
        if query.isEmpty {
            List(selection: selection) {
                ForEach(SettingsTab.groups.indices, id: \.self) { index in
                    Section {
                        ForEach(SettingsTab.groups[index], id: \.self) { tab in
                            SettingsSidebarRow(tab: tab).tag(tab)
                        }
                    }
                }
            }
        } else {
            let results = SettingsTab.found(query)
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: selection) {
                    ForEach(results, id: \.tab) { tab, rows in
                        SettingsSidebarRow(tab: tab, found: rows).tag(tab)
                    }
                }
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    /// The rows a search found in the pane, listed under its title.
    var found: [String] = []

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                if !found.isEmpty {
                    Text(found.formatted(.list(type: .and, width: .narrow)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            SettingsIcon(tab: tab)
        }
        .padding(.vertical, 2)
    }
}

/// A pane made in AppKit, kept by the window between visits so it is made once.
private struct SettingsPaneHost: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}
