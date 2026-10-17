import AppKit
import Foundation
import OMSCore
import SwiftUI

public enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case capture
    case screenshots
    case quickAccess
    case recording
    case tools
    case sharing
    case shortcuts
    case automation
    case permissions
    case about

    /// The sidebar's groups, in order.
    static let groups: [[SettingsTab]] = [
        [.general, .capture, .screenshots, .quickAccess, .recording, .tools],
        [.sharing, .shortcuts, .automation],
        [.permissions, .about],
    ]

    var title: String {
        switch self {
        case .general: String(localized: "General", bundle: .module)
        case .capture: String(localized: "Capture", bundle: .module)
        case .screenshots: String(localized: "Screenshots", bundle: .module)
        case .quickAccess: String(localized: "Quick Access", bundle: .module)
        case .recording: String(localized: "Recording", bundle: .module)
        case .tools: String(localized: "Tools", bundle: .module)
        case .sharing: String(localized: "Sharing", bundle: .module)
        case .shortcuts: String(localized: "Shortcuts", bundle: .module)
        case .permissions: String(localized: "Permissions", bundle: .module)
        case .automation: String(localized: "Automation", bundle: .module)
        case .about: String(localized: "About", bundle: .module)
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .capture: "viewfinder"
        case .screenshots: "photo.on.rectangle"
        case .quickAccess: "rectangle.stack"
        case .recording: "record.circle"
        case .tools: "wrench.and.screwdriver"
        case .sharing: "icloud.and.arrow.up"
        case .shortcuts: "command"
        case .permissions: "hand.raised"
        case .automation: "point.3.connected.trianglepath.dotted"
        case .about: "info.circle"
        }
    }
}

/// What the settings screens read and change.
public struct SettingsDependencies {
    public let settings: SettingsStore
    public let permissions: PermissionCenter
    public let urlScheme: String
    public let relaunch: () -> Void
    public let openHistory: () -> Void
    /// How many captures a retention would delete now, so Settings can ask before shortening it.
    public let expiredCount: (HistoryRetention) -> Int
    public let backgrounds: Backgrounds
    /// The places captures can be uploaded to, which only the Sharing tab shows.
    public let destinations: UploadDestinationStore
    /// The uploads that finished, which only the Sharing tab lists, and what it can do with each.
    public let uploadRecords: UploadRecordStore
    public let recordActions: UploadRecordActions

    /// What Settings › Sharing does with a finished upload.
    public struct UploadRecordActions {
        public var copyLink: (UploadRecord) -> Void
        public var open: (UploadRecord) -> Void
        public var forget: (UploadRecord) -> Void
        public var forgetAll: () -> Void
        /// Whether the file can be removed from its storage from here.
        public var canDelete: (UploadRecord) -> Bool
        /// Asks, then removes the file from its storage.
        public var delete: (UploadRecord) -> Void

        public init(
            copyLink: @escaping (UploadRecord) -> Void,
            open: @escaping (UploadRecord) -> Void,
            forget: @escaping (UploadRecord) -> Void,
            forgetAll: @escaping () -> Void,
            canDelete: @escaping (UploadRecord) -> Bool,
            delete: @escaping (UploadRecord) -> Void
        ) {
            self.copyLink = copyLink
            self.open = open
            self.forget = forget
            self.forgetAll = forgetAll
            self.canDelete = canDelete
            self.delete = delete
        }

        public static let none = UploadRecordActions(
            copyLink: { _ in }, open: { _ in }, forget: { _ in }, forgetAll: {}, canDelete: { _ in false }, delete: { _ in }
        )
    }

    /// The backgrounds saved in the editor, and the one set on every new screenshot.
    public struct Backgrounds {
        public struct Choice: Identifiable, Hashable {
            public let id: UUID
            public let name: String

            public init(id: UUID, name: String) {
                self.id = id
                self.name = name
            }
        }

        public let presets: () -> [Choice]
        public let automatic: () -> UUID?
        public let setAutomatic: (UUID?) -> Void

        public init(presets: @escaping () -> [Choice], automatic: @escaping () -> UUID?, setAutomatic: @escaping (UUID?) -> Void) {
            self.presets = presets
            self.automatic = automatic
            self.setAutomatic = setAutomatic
        }

        public static let none = Backgrounds(presets: { [] }, automatic: { nil }, setAutomatic: { _ in })
    }

    public init(
        settings: SettingsStore,
        permissions: PermissionCenter,
        urlScheme: String,
        relaunch: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        expiredCount: @escaping (HistoryRetention) -> Int,
        destinations: UploadDestinationStore,
        uploadRecords: UploadRecordStore,
        recordActions: UploadRecordActions = .none,
        backgrounds: Backgrounds = .none
    ) {
        self.settings = settings
        self.permissions = permissions
        self.urlScheme = urlScheme
        self.relaunch = relaunch
        self.openHistory = openHistory
        self.expiredCount = expiredCount
        self.backgrounds = backgrounds
        self.destinations = destinations
        self.uploadRecords = uploadRecords
        self.recordActions = recordActions
    }
}

/// The settings window: a sidebar of the panes beside the chosen one, each a SwiftUI pane. A pane is made the first
/// time it is chosen; the window is created when opened and released when closed, so it costs no memory while hidden.
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private let selection: SettingsSelection
    private let detail: SettingsDetailController
    private var windowLease: ActiveResources.Lease?

    public init(dependencies: SettingsDependencies) {
        let selection = SettingsSelection()
        let detail = SettingsDetailController { tab in Self.makeContent(for: tab, dependencies: dependencies) }

        let sidebar = NSHostingController(rootView: SettingsSidebar(selection: selection))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = paneWidth
        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // An empty toolbar puts the pane's title beside the sidebar, as in System Settings.
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.sidebarWidth + paneWidth, height: 420)
        window.setContentSize(NSSize(width: Self.sidebarWidth + paneWidth, height: 640))
        self.selection = selection
        self.detail = detail
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Settings")

        selection.onChange = { [weak self] tab in self?.display(tab) }
        display(selection.tab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show(_ tab: SettingsTab) {
        selection.tab = tab
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        showWindow(nil)
        AppActivation.bringForward(window)
        Self.leaveNothingFocused(in: window)
    }

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }

    private func display(_ tab: SettingsTab) {
        detail.show(tab)
        window?.title = tab.title
        Self.leaveNothingFocused(in: window)
    }

    private static let sidebarWidth: CGFloat = 200

    /// A pane leaves no control holding the keyboard when it is chosen: AppKit gives it to the first text field
    /// (the file name pattern in Screenshots), all of it selected, where a stray key would replace it. After AppKit
    /// has given the keyboard out, the window takes it back.
    private static func leaveNothingFocused(in window: NSWindow?) {
        DispatchQueue.main.async { [weak window] in
            guard let window, window.firstResponder is NSText else { return }
            window.makeFirstResponder(nil)
        }
    }

    private static func makeContent(for tab: SettingsTab, dependencies: SettingsDependencies) -> NSViewController {
        switch tab {
        case .general:
            host(GeneralSettingsView(
                settings: dependencies.settings,
                openHistory: dependencies.openHistory,
                expiredCount: dependencies.expiredCount
            ))
        case .capture:
            host(CaptureSettingsView(settings: dependencies.settings))
        case .screenshots:
            host(ScreenshotsSettingsView(
                settings: dependencies.settings,
                destinations: dependencies.destinations,
                backgrounds: dependencies.backgrounds
            ))
        case .quickAccess:
            host(QuickAccessSettingsView(settings: dependencies.settings))
        case .recording:
            host(RecordingSettingsView(settings: dependencies.settings, destinations: dependencies.destinations))
        case .tools:
            host(ToolsSettingsView(settings: dependencies.settings))
        case .sharing:
            host(SharingSettingsView(
                settings: dependencies.settings, destinations: dependencies.destinations,
                records: dependencies.uploadRecords, actions: dependencies.recordActions
            ))
        case .shortcuts:
            host(ShortcutsSettingsView(destinations: dependencies.destinations))
        case .permissions:
            host(PermissionsSettingsView(permissions: dependencies.permissions, relaunch: dependencies.relaunch))
        case .automation:
            host(AutomationSettingsView(settings: dependencies.settings, urlScheme: dependencies.urlScheme))
        case .about:
            host(AboutSettingsView())
        }
    }

    private static func host(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        // The window keeps its size whichever pane is chosen; a pane taller than it scrolls.
        controller.sizingOptions = []
        return controller
    }
}

/// The pane the sidebar has chosen.
@Observable
private final class SettingsSelection {
    var tab: SettingsTab = .general {
        didSet { if tab != oldValue { onChange?(tab) } }
    }

    @ObservationIgnored var onChange: ((SettingsTab) -> Void)?
}

/// The list of panes down the window's left side, in groups.
private struct SettingsSidebar: View {
    @Bindable var selection: SettingsSelection

    var body: some View {
        List(selection: Binding(get: { selection.tab }, set: { if let tab = $0 { selection.tab = tab } })) {
            ForEach(SettingsTab.groups.indices, id: \.self) { index in
                Section {
                    ForEach(SettingsTab.groups[index], id: \.self) { tab in
                        Label {
                            Text(tab.title)
                        } icon: {
                            Image(systemName: tab.symbolName)
                        }
                        .tag(tab)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Holds the chosen pane, making each the first time it is chosen and keeping it after.
private final class SettingsDetailController: NSViewController {
    private let makeContent: (SettingsTab) -> NSViewController
    private var panes: [SettingsTab: NSViewController] = [:]
    private var current: NSViewController?

    init(makeContent: @escaping (SettingsTab) -> NSViewController) {
        self.makeContent = makeContent
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView()
    }

    func show(_ tab: SettingsTab) {
        let pane = panes[tab] ?? {
            let pane = makeContent(tab)
            panes[tab] = pane
            addChild(pane)
            return pane
        }()
        guard pane !== current else { return }
        current?.view.removeFromSuperview()
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: view.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = pane
    }
}
