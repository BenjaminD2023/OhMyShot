import AppKit
import Foundation
import OMSCore
import SwiftUI

public enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case quickAccess
    case recording
    case tools
    case sharing
    case shortcuts
    case permissions
    case automation
    case about

    var title: String {
        switch self {
        case .general: String(localized: "General", bundle: .module)
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

/// The settings window: AppKit toolbar tabs hosting SwiftUI panes. It is created when opened and
/// released when closed, so it costs no memory while hidden.
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private let tabs: NSTabViewController
    private var windowLease: ActiveResources.Lease?

    public init(dependencies: SettingsDependencies) {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let content = Self.makeContent(for: tab, dependencies: dependencies)
            // The tab view controller passes the selected tab's title on to the window.
            content.title = tab.title
            let item = NSTabViewItem(viewController: content)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        self.tabs = tabs
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show(_ tab: SettingsTab) {
        if let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs.selectedTabViewItemIndex = index
        }
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        showWindow(nil)
        AppActivation.bringForward(window)
        SettingsTabs.leaveNothingFocused(in: window)
    }

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }

    private static func makeContent(for tab: SettingsTab, dependencies: SettingsDependencies) -> NSViewController {
        switch tab {
        case .general:
            host(GeneralSettingsView(
                settings: dependencies.settings,
                destinations: dependencies.destinations,
                backgrounds: dependencies.backgrounds,
                openHistory: dependencies.openHistory,
                expiredCount: dependencies.expiredCount
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
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }
}

/// The tabs, which leave no control holding the keyboard when one is chosen: AppKit gives it to the first text field
/// (the file name pattern in General), all of it selected, where a stray key would replace it.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        Self.leaveNothingFocused(in: tabView.window)
    }

    /// After AppKit has given the keyboard out, the window takes it back.
    static func leaveNothingFocused(in window: NSWindow?) {
        DispatchQueue.main.async { [weak window] in
            guard let window, window.firstResponder is NSText else { return }
            window.makeFirstResponder(nil)
        }
    }
}
