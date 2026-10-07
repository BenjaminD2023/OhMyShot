import AppKit
import Foundation
import ImageIO
import Observation
import OMSCapture
import OMSCore
import OMSUI
import OSLog

/// Builds the app's services once and wires them together. Feature modules never import each other;
/// they meet here, through closures.
final class CompositionRoot {
    private let settings = SettingsStore()
    private let permissions = PermissionCenter()
    private let displays = DisplayTopology()
    private let history = HistoryStore.standard()
    private let shareableContent = ShareableContentCache()
    private lazy var capturer = ScreenCapturer(content: shareableContent)
    private lazy var overlay = OverlayController(topology: displays, capturer: capturer)
    private lazy var captures = CaptureCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay, history: history)
    private lazy var quickAccess = QuickAccessController(actions: makeQuickAccessActions())
    private let hotkeys: HotkeyCenter
    private let urlScheme: String
    private var statusItem: StatusItemController?
    private var automation: AutomationController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var historyWindow: HistoryWindowController?
    private var observations: [Task<Void, Never>] = []

    init() {
        #if DEBUG
        hotkeys = HotkeyCenter(profile: .development)
        #else
        hotkeys = HotkeyCenter(profile: .release)
        #endif
        urlScheme = Bundle.main.object(forInfoDictionaryKey: "OMSURLScheme") as? String ?? "ohmyshot"
    }

    func start() {
        let statusItem = StatusItemController(
            captureEntries: [
                .init(title: String(localized: "Capture Area"), shortcut: .captureArea) { [weak self] in self?.handle(.captureArea) },
                .init(title: String(localized: "Capture Window"), shortcut: .captureWindow) { [weak self] in self?.handle(.captureWindow) },
                .init(title: String(localized: "Capture Fullscreen"), shortcut: .captureFullscreen) { [weak self] in self?.handle(.captureFullscreen) },
            ],
            historyEntries: [
                .init(title: String(localized: "Capture History…"), shortcut: .openHistory) { [weak self] in self?.showHistory() },
                .init(
                    title: String(localized: "Restore Recently Closed"),
                    isEnabled: { [weak self] in self?.quickAccess.canRestoreRecentlyClosed ?? false }
                ) { [weak self] in
                    self?.quickAccess.restoreRecentlyClosed()
                },
            ],
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            debugEntries: debugMenuEntries()
        )
        self.statusItem = statusItem
        automation = makeAutomationController()

        hotkeys.installDefaultShortcutsIfNeeded()
        hotkeys.activate { [weak self] shortcut in
            self?.handle(shortcut)
        }

        let settings = settings
        observations.append(Task { [weak statusItem] in
            for await visible in Observations({ settings.showMenuBarIcon }) {
                statusItem?.setVisible(visible)
            }
        })
        // Also runs once now, which is the launch-time cleanup.
        observations.append(Task { [weak self] in
            for await _ in Observations({ settings.historyRetention }) {
                self?.removeExpiredHistory()
            }
        })

        captures.onCaptured = { [weak self] item in
            self?.didCapture(item)
        }

        displays.onChange = { [weak self] _ in
            guard let self else { return }
            shareableContent.refresh()
            overlay.cancel()
            overlay.prepare()
        }

        logStartup()
        permissions.refresh([.screenRecording])
        if permissions.status(of: .screenRecording) == .granted {
            // Built and fetched once now so the first capture does not pay for them. The panels come
            // first: the app is listed in the shareable content only once it has windows.
            overlay.prepare()
            shareableContent.refresh()
        } else {
            showOnboarding()
        }
    }

    func handle(url: URL, senderPID: pid_t?) {
        automation?.handle(url, senderPID: senderPID)
    }

    func showSettings(_ tab: SettingsTab = .general) {
        let controller = settingsWindow ?? makeSettingsWindow()
        settingsWindow = controller
        controller.show(tab)
    }

    func showHistory() {
        let controller = historyWindow ?? makeHistoryWindow()
        historyWindow = controller
        controller.show()
    }

    func showOnboarding() {
        let controller = onboardingWindow ?? OnboardingWindowController(
            permissions: permissions,
            relaunch: { Relauncher.relaunch() }
        )
        controller.onClose = { [weak self] in
            // Released on the next turn so the window is not deallocated inside its own delegate call.
            Task { @MainActor in
                self?.onboardingWindow = nil
                MemoryRelief.returnFreedPages()
            }
        }
        onboardingWindow = controller
        controller.show()
    }

    // MARK: - Commands

    private func handle(_ shortcut: CaptureShortcut) {
        Log.signposter.emitEvent("hotkey")
        Log.hotkeys.notice("hotkey.\(shortcut.rawValue, privacy: .public)")
        switch shortcut {
        case .openHistory:
            showHistory()
            return
        case .copyLatestCapture:
            quickAccess.copyLatest()
            return
        default:
            break
        }
        guard permissions.status(of: .screenRecording) == .granted else {
            showOnboarding()
            return
        }
        switch shortcut {
        case .captureArea, .allInOne:
            captures.captureArea()
        case .captureFullscreen:
            captures.captureFullscreen()
        case .captureWindow:
            captures.captureWindow()
        default:
            Log.hotkeys.notice("Not available yet: \(shortcut.rawValue, privacy: .public)")
        }
    }

    private func perform(_ command: AutomationCommand) {
        switch command {
        case .openSettings(let tab):
            showSettings(SettingsTab(urlTab: tab))
        case .captureArea(let region, _) where region.rect == nil:
            captures.captureArea()
        case .allInOne(let region) where region.rect == nil:
            captures.captureArea()
        case .captureFullscreen:
            captures.captureFullscreen()
        case .captureWindow:
            captures.captureWindow()
        case .openHistory:
            showHistory()
        case .restoreRecentlyClosed:
            quickAccess.restoreRecentlyClosed()
        default:
            Log.automation.notice("Not available yet: \(String(describing: command), privacy: .public)")
        }
    }

    // MARK: - Quick Access and history

    private func didCapture(_ item: QuickAccessItem) {
        if settings.showQuickAccess {
            quickAccess.add(item)
        } else if settings.historyRetention == .never, let entry = history.item(id: item.id) {
            // Nothing else holds on to it: it already went to the clipboard or the export folder.
            history.delete(entry)
        }
        removeExpiredHistory()
    }

    private func removeExpiredHistory() {
        let removed = history.removeExpired(retention: settings.historyRetention, keeping: quickAccess.itemIDs)
        if removed > 0 {
            Log.capture.notice("Removed \(removed, privacy: .public) expired capture(s) from the history")
        }
        historyWindow?.reload()
    }

    private func makeQuickAccessActions() -> QuickAccessController.Actions {
        QuickAccessController.Actions(
            copy: { item in CaptureFiles.copy(item.fileURL) },
            save: { [weak self] item in self?.captures.save(item) },
            saveAs: { [weak self] item in self?.captures.saveAs(item) },
            open: { item in NSWorkspace.shared.open(item.fileURL) },
            reveal: { item in NSWorkspace.shared.activateFileViewerSelecting([item.savedURL ?? item.fileURL]) },
            moveToTrash: { [weak self] item in
                guard let self else { return }
                // As in CleanShot, the capture goes as a whole: the copy this card saved goes to the Trash
                // with it. Both can be put back from the Trash.
                if let saved = item.savedURL {
                    try? FileManager.default.trashItem(at: saved, resultingItemURL: nil)
                }
                if let entry = history.item(id: item.id) {
                    history.moveToTrash(entry)
                }
                historyWindow?.reload()
            },
            closed: { [weak self] item in
                // With history off, a capture lives only as long as its card.
                guard let self, settings.historyRetention == .never, let entry = history.item(id: item.id) else { return }
                history.delete(entry)
            }
        )
    }

    /// How many captures a retention would delete now; captures still on screen as cards are kept.
    private func expiredCount(for retention: HistoryRetention) -> Int {
        history.expired(retention: retention, keeping: quickAccess.itemIDs).count
    }

    private func makeHistoryWindow() -> HistoryWindowController {
        let controller = HistoryWindowController(store: history, settings: settings, actions: HistoryActions(
            restore: { [weak self] entry in Task { await self?.restore(entry) } },
            copy: { [weak self] entry in
                guard let self else { return }
                CaptureFiles.copy(history.fileURL(for: entry))
            },
            save: { [weak self] entry in
                guard let self else { return }
                Task {
                    guard let item = await self.quickAccessItem(for: entry) else { return }
                    if let url = self.captures.save(item) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            },
            open: { [weak self] entry in
                guard let self else { return }
                NSWorkspace.shared.open(history.fileURL(for: entry))
            },
            reveal: { [weak self] entry in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([history.fileURL(for: entry)])
            },
            moveToTrash: { [weak self] entry in
                self?.quickAccess.remove(entry.id)
                self?.history.moveToTrash(entry)
            }
        ), expiredCount: { [weak self] retention in self?.expiredCount(for: retention) ?? 0 })
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.historyWindow = nil
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    /// Brings a history item back as a Quick Access card.
    private func restore(_ entry: HistoryItem) async {
        guard let item = await quickAccessItem(for: entry) else { return }
        quickAccess.add(item)
    }

    private func quickAccessItem(for entry: HistoryItem) async -> QuickAccessItem? {
        let url = history.fileURL(for: entry)
        guard let thumbnail = await HistoryStore.thumbnail(of: url, maxPixels: 560) else { return nil }
        let layout = displays.layout
        let displayID = layout.display(at: NSEvent.mouseLocation)?.id ?? layout.primary?.id ?? 0
        return QuickAccessItem(
            id: entry.id,
            kind: entry.kind,
            fileURL: url,
            thumbnail: thumbnail,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight,
            displayID: displayID,
            createdAt: entry.createdAt
        )
    }

    // MARK: - Wiring

    private func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController(dependencies: SettingsDependencies(
            settings: settings,
            permissions: permissions,
            urlScheme: urlScheme,
            relaunch: { Relauncher.relaunch() },
            openHistory: { [weak self] in self?.showHistory() },
            expiredCount: { [weak self] retention in self?.expiredCount(for: retention) ?? 0 }
        ))
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.settingsWindow = nil
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    private func makeAutomationController() -> AutomationController {
        #if DEBUG
        let hooks = makeDebugHooks()
        #endif
        return AutomationController(scheme: urlScheme, settings: settings) { [weak self] command in
            self?.perform(command)
        } debugHandler: { url in
            #if DEBUG
            hooks.handle(url)
            return true
            #else
            return false
            #endif
        }
    }

    private func debugMenuEntries() -> [StatusItemController.Entry] {
        #if DEBUG
        let hooks = makeDebugHooks()
        return [
            .init(title: "Log Displays") { hooks.logDisplays() },
            .init(title: "Log Active Resources") { hooks.logResources() },
            .init(title: "Show Onboarding") { [weak self] in self?.showOnboarding() },
            .init(title: "Relaunch") { Relauncher.relaunch() },
        ]
        #else
        return []
        #endif
    }

    #if DEBUG
    private func makeDebugHooks() -> DebugHooks {
        DebugHooks(
            displays: displays,
            permissions: permissions,
            capturer: capturer,
            overlay: overlay,
            captures: captures,
            quickAccess: quickAccess,
            showSettings: { [weak self] tab in self?.showSettings(tab) },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            showHistory: { [weak self] in self?.showHistory() },
            restoreLatestFromHistory: { [weak self] in
                guard let self, let entry = history.items().first else { return }
                Task { await self.restore(entry) }
            },
            setRetention: { [weak self] retention in self?.settings.historyRetention = retention },
            historyWindow: { [weak self] in self?.historyWindow?.window },
            historyCount: { [weak self] in self?.history.items().count ?? 0 },
            previewRetentionChange: { [weak self] retention in self?.historyWindow?.previewRetentionChange(to: retention) }
        )
    }
    #endif

    private func logStartup() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        Log.app.notice("Started \(Log.subsystem, privacy: .public) \(version, privacy: .public) (\(build, privacy: .public)), \(self.displays.layout.displays.count, privacy: .public) display(s), URL scheme \(self.urlScheme, privacy: .public)")
    }
}

private extension SettingsTab {
    /// Maps CleanShot's `open-settings?tab=` names onto ours.
    init(urlTab: String?) {
        switch urlTab?.lowercased() {
        case "shortcuts": self = .shortcuts
        case "advanced": self = .automation
        case "about": self = .about
        default: self = .general
        }
    }
}

/// File actions on captures.
enum CaptureFiles {
    /// Copies a capture's image. Image only, no file: some apps paste a file reference instead of the
    /// picture when both are offered.
    static func copy(_ url: URL) {
        guard
            let data = try? Data(contentsOf: url),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to copy it")
            return
        }
        PasteboardWriter.write(png: data, image: image)
    }
}
