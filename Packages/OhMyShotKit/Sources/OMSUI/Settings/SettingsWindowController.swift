import AppKit
import Foundation
import OMSCore
import SwiftUI

public enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case capture
    case recording
    case tools
    case shortcuts
    case permissions
    case automation
    case about

    var title: String {
        switch self {
        case .general: String(localized: "General", bundle: .module)
        case .capture: String(localized: "Capture", bundle: .module)
        case .recording: String(localized: "Recording", bundle: .module)
        case .tools: String(localized: "Tools", bundle: .module)
        case .shortcuts: String(localized: "Shortcuts", bundle: .module)
        case .permissions: String(localized: "Permissions", bundle: .module)
        case .automation: String(localized: "Automation", bundle: .module)
        case .about: String(localized: "About", bundle: .module)
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .recording: "record.circle"
        case .tools: "wrench.and.screwdriver"
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
        backgrounds: Backgrounds = .none
    ) {
        self.settings = settings
        self.permissions = permissions
        self.urlScheme = urlScheme
        self.relaunch = relaunch
        self.openHistory = openHistory
        self.expiredCount = expiredCount
        self.backgrounds = backgrounds
    }
}

/// The settings window: AppKit toolbar tabs hosting SwiftUI forms. It is created when opened and
/// released when closed, so it costs no memory while hidden.
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private let tabs: NSTabViewController
    private var windowLease: ActiveResources.Lease?

    public init(dependencies: SettingsDependencies) {
        let tabs = NSTabViewController()
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
    }

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }

    private static func makeContent(for tab: SettingsTab, dependencies: SettingsDependencies) -> NSViewController {
        switch tab {
        case .general:
            host(GeneralSettingsView(settings: dependencies.settings, openHistory: dependencies.openHistory, expiredCount: dependencies.expiredCount))
        case .capture:
            host(CaptureSettingsView(settings: dependencies.settings, backgrounds: dependencies.backgrounds))
        case .recording:
            host(RecordingSettingsView(settings: dependencies.settings))
        case .tools:
            host(ToolsSettingsView(settings: dependencies.settings))
        case .shortcuts:
            host(ShortcutsSettingsView())
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
