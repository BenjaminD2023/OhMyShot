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
        case .tools: .indigo
        case .sharing: .cyan
        case .shortcuts: .gray
        case .automation: .green
        case .permissions: .blue
        case .about: .teal
        }
    }

    /// What a search finds the pane by besides its title: the labels of its rows and the names of its controls.
    var searchTerms: [String] {
        switch self {
        case .general:
            [
                String(localized: "Launch at login", bundle: .module),
                String(localized: "Menu bar", bundle: .module),
                String(localized: "Show icon", bundle: .module),
                String(localized: "Play sounds", bundle: .module),
                String(localized: "Keep captures", bundle: .module),
                String(localized: "Open History", bundle: .module),
            ]
        case .capture:
            [
                String(localized: "Freeze the screen", bundle: .module),
                String(localized: "Show the pointer in screenshots", bundle: .module),
                String(localized: "Shift keeps", bundle: .module),
                String(localized: "Snap the selection to text", bundle: .module),
                String(localized: "All-In-One remembers the last area", bundle: .module),
                String(localized: "Self-Timer", bundle: .module),
                String(localized: "Capture the shadow", bundle: .module),
                String(localized: "Window background", bundle: .module),
            ]
        case .screenshots:
            [
                String(localized: "After screenshot", bundle: .module),
                String(localized: "Save to", bundle: .module),
                String(localized: "Background", bundle: .module),
                String(localized: "Format", bundle: .module),
                String(localized: "Quality", bundle: .module),
                String(localized: "Save Retina screenshots at 1×", bundle: .module),
                String(localized: "Convert to sRGB", bundle: .module),
                String(localized: "Add a 1 px border", bundle: .module),
                String(localized: "File name", bundle: .module),
                String(localized: "Clipboard", bundle: .module),
            ]
        case .quickAccess:
            [
                String(localized: "Position", bundle: .module),
                String(localized: "Size", bundle: .module),
                String(localized: "Show on the display with the pointer", bundle: .module),
                String(localized: "Close cards", bundle: .module),
            ]
        case .recording:
            [
                String(localized: "Countdown", bundle: .module),
                String(localized: "Show controls", bundle: .module),
                String(localized: "Show the pointer", bundle: .module),
                String(localized: "Recorded area", bundle: .module),
                String(localized: "Audio", bundle: .module),
                String(localized: "Clicks", bundle: .module),
                String(localized: "Keystrokes", bundle: .module),
                String(localized: "Keep the keys pressed", bundle: .module),
                String(localized: "Frame rate", bundle: .module),
                String(localized: "Video format", bundle: .module),
                String(localized: "GIF frame rate", bundle: .module),
                String(localized: "After recording", bundle: .module),
            ]
        case .tools:
            [
                String(localized: "Capture Text", bundle: .module),
                String(localized: "Translate into", bundle: .module),
                String(localized: "Copy colors as", bundle: .module),
                String(localized: "Measure in", bundle: .module),
                String(localized: "Pins", bundle: .module),
                String(localized: "Show in screenshots", bundle: .module),
            ]
        case .sharing:
            [
                String(localized: "Destinations", bundle: .module),
                String(localized: "After upload", bundle: .module),
                String(localized: "Recent uploads", bundle: .module),
            ]
        case .shortcuts:
            CaptureShortcut.allCases.filter(\.isAvailable).map(\.title)
        case .automation:
            [
                String(localized: "URL scheme", bundle: .module),
                String(localized: "Approved apps", bundle: .module),
            ]
        case .permissions:
            Permission.allCases.map(\.title)
        case .about:
            []
        }
    }

    /// The rows a search finds in the pane, or nil when it finds neither them nor the pane's title.
    func matches(_ query: String) -> [String]? {
        let found = searchTerms.filter { $0.localizedStandardContains(query) }
        return found.isEmpty && !title.localizedStandardContains(query) ? nil : found
    }
}

let sidebarWidth: CGFloat = 215

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
                .navigationSplitViewColumnWidth(sidebarWidth)
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
            if let first = SettingsTab.allCases.first(where: { $0.matches(navigator.query) != nil }) {
                navigator.go(to: first)
            }
        }
        .background {
            // Command-F goes to the search field, as in System Settings.
            Button { isSearching = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(minWidth: sidebarWidth + paneWidth, minHeight: 420)
    }
}

/// The panes down the window's left side: in groups, or while searching, those the search finds with the rows it
/// found in each.
private struct SettingsSidebar: View {
    @Bindable var navigator: SettingsNavigator

    var body: some View {
        let query = navigator.query.trimmingCharacters(in: .whitespaces)
        let selection = Binding<SettingsTab?>(get: { navigator.tab }, set: { if let tab = $0 { navigator.go(to: tab) } })
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
            let results = SettingsTab.allCases.compactMap { tab in tab.matches(query).map { (tab, $0) } }
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: selection) {
                    ForEach(results, id: \.0) { tab, rows in
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
