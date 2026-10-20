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
        case .general: "gearshape.fill"
        case .capture: "viewfinder"
        case .screenshots: "photo.fill.on.rectangle.fill"
        case .quickAccess: "rectangle.stack.fill"
        case .recording: "record.circle.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .sharing: "icloud.and.arrow.up.fill"
        case .shortcuts: "command"
        case .permissions: "hand.raised.fill"
        case .automation: "point.3.connected.trianglepath.dotted"
        case .about: "info"
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
    /// The model packs, which only the Tools tab shows, and only when the build offers one.
    public let modelPacks: ModelPackCenter?
    /// App-owned update preferences; this module does not depend on an update framework.
    public let updates: Updates?

    public struct Updates {
        public let status: UpdateStatus
        public let canCheck: () -> Bool
        public let check: () -> Void
        public let automaticallyChecks: () -> Bool
        public let setAutomaticallyChecks: (Bool) -> Void
        public let automaticallyDownloads: () -> Bool
        public let setAutomaticallyDownloads: (Bool) -> Void

        public init(
            canCheck: @escaping () -> Bool,
            check: @escaping () -> Void,
            automaticallyChecks: @escaping () -> Bool,
            setAutomaticallyChecks: @escaping (Bool) -> Void,
            automaticallyDownloads: @escaping () -> Bool,
            setAutomaticallyDownloads: @escaping (Bool) -> Void,
            status: UpdateStatus = UpdateStatus()
        ) {
            self.status = status
            self.canCheck = canCheck
            self.check = check
            self.automaticallyChecks = automaticallyChecks
            self.setAutomaticallyChecks = setAutomaticallyChecks
            self.automaticallyDownloads = automaticallyDownloads
            self.setAutomaticallyDownloads = setAutomaticallyDownloads
        }
    }
    /// The cloud models the OCR panel reads with, which only the Tools tab shows.
    public let cloudModels: CloudModelStore?
    /// The notices of OhMyShot and of the software it is built with (App/Acknowledgments.md), which About shows.
    public let acknowledgments: URL?

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
        backgrounds: Backgrounds = .none,
        modelPacks: ModelPackCenter? = nil,
        cloudModels: CloudModelStore? = nil,
        updates: Updates? = nil,
        acknowledgments: URL? = nil
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
        self.modelPacks = modelPacks
        self.updates = updates
        self.cloudModels = cloudModels
        self.acknowledgments = acknowledgments
    }
}

/// The settings window: a sidebar of the panes, with a search field, beside the chosen one, each a SwiftUI pane, and
/// Back and Forward in the toolbar, as in System Settings. A pane is made the first time it is chosen; the window is
/// created when opened and released when closed, so it costs no memory while hidden.
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private let navigator: SettingsNavigator
    private var windowLease: ActiveResources.Lease?

    public init(dependencies: SettingsDependencies) {
        let navigator = SettingsNavigator()
        var panes: [SettingsTab: NSViewController] = [:]
        let root = SettingsRootView(navigator: navigator) { tab in
            if let pane = panes[tab] { return pane }
            let pane = Self.makeContent(for: tab, dependencies: dependencies)
            panes[tab] = pane
            return pane
        }
        let content = NSHostingController(rootView: root)
        // The window keeps its size whichever pane is chosen; a pane taller than it scrolls.
        content.sizingOptions = []
        // The toolbar's Back and Forward and the pane's title come from SwiftUI.
        content.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let minimum = NSSize(width: sidebarWidth + paneWidth, height: 420)
        window.contentMinSize = minimum
        window.setContentSize(NSSize(width: minimum.width, height: 640))
        self.navigator = navigator
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Settings")
        // A size saved before the sidebar was as wide as it is now would cut its edge off: the content keeps its
        // width and hangs out of the window on both sides.
        let restored = window.contentRect(forFrameRect: window.frame).size
        if restored.width < minimum.width || restored.height < minimum.height {
            window.setContentSize(NSSize(width: max(restored.width, minimum.width), height: max(restored.height, minimum.height)))
        }

        navigator.onChange = { [weak window] _ in Self.leaveNothingFocused(in: window) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show(_ tab: SettingsTab) {
        // Opened afresh, the window starts at the pane asked for with nothing to go back to.
        if window?.isVisible == true { navigator.go(to: tab) } else { navigator.start(at: tab) }
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        showWindow(nil)
        AppActivation.bringForward(window)
        Self.leaveNothingFocused(in: window)
    }

    /// Searches the panes, as typing into the sidebar's search field does.
    public func search(_ query: String) {
        navigator.query = query
    }

    #if DEBUG
    /// For scripted screenshots that show nothing: the window behind the wallpaper in the middle of the main
    /// display, on `tab`, ordered in without making the app active.
    public func showBehindWallpaper(_ tab: SettingsTab) {
        guard let window else { return }
        navigator.start(at: tab)
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
        }
        window.orderFront(nil)
    }
    #endif

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }

    /// A pane leaves no control holding the keyboard when it is chosen: AppKit gives it to the first text field
    /// (the file name pattern in Screenshots), all of it selected, where a stray key would replace it. After AppKit
    /// has given the keyboard out, the window takes it back. The sidebar's search field keeps it.
    private static func leaveNothingFocused(in window: NSWindow?) {
        DispatchQueue.main.async { [weak window] in
            guard let window, let editor = window.firstResponder as? NSText,
                  !(editor.delegate is NSSearchField) else { return }
            window.makeFirstResponder(nil)
        }
    }

    private static func makeContent(for tab: SettingsTab, dependencies: SettingsDependencies) -> NSViewController {
        switch tab {
        case .general:
            host(GeneralSettingsView(
                settings: dependencies.settings,
                openHistory: dependencies.openHistory,
                expiredCount: dependencies.expiredCount,
                updates: dependencies.updates
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
            host(ToolsSettingsView(settings: dependencies.settings, permissions: dependencies.permissions, modelPacks: dependencies.modelPacks, cloudModels: dependencies.cloudModels))
        case .sharing:
            host(SharingSettingsView(
                settings: dependencies.settings, destinations: dependencies.destinations,
                records: dependencies.uploadRecords, actions: dependencies.recordActions
            ))
        case .shortcuts:
            host(ShortcutsSettingsView(destinations: dependencies.destinations) { [modelPacks = dependencies.modelPacks] in
                modelPacks?.installedFolder(of: ModelPackCatalog.ppFormulaNetPlusL) != nil
            })
        case .permissions:
            host(PermissionsSettingsView(permissions: dependencies.permissions, relaunch: dependencies.relaunch))
        case .automation:
            host(AutomationSettingsView(settings: dependencies.settings, urlScheme: dependencies.urlScheme))
        case .about:
            host(AboutSettingsView(acknowledgments: dependencies.acknowledgments))
        }
    }

    private static func host(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        // The window keeps its size whichever pane is chosen; a pane taller than it scrolls.
        controller.sizingOptions = []
        return controller
    }
}
