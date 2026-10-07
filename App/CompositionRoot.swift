import AppKit
import Foundation
import Observation
import OMSCore
import OMSUI
import OSLog

/// Builds the app's services once and wires them together. Feature modules never import each other;
/// they meet here, through closures.
final class CompositionRoot {
    private let settings = SettingsStore()
    private let permissions = PermissionCenter()
    private let displays = DisplayTopology()
    private let hotkeys: HotkeyCenter
    private let urlScheme: String
    private var statusItem: StatusItemController?
    private var automation: AutomationController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
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

        logStartup()
        permissions.refresh([.screenRecording])
        if permissions.status(of: .screenRecording) != .granted {
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

    // MARK: - Capture

    private func handle(_ shortcut: CaptureShortcut) {
        Log.signposter.emitEvent("hotkey")
        Log.hotkeys.notice("hotkey.\(shortcut.rawValue, privacy: .public)")
    }

    private func perform(_ command: AutomationCommand) {
        switch command {
        case .openSettings(let tab):
            showSettings(SettingsTab(urlTab: tab))
        default:
            Log.automation.notice("Not available yet: \(String(describing: command), privacy: .public)")
        }
    }

    // MARK: - Wiring

    private func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController(dependencies: SettingsDependencies(
            settings: settings,
            permissions: permissions,
            urlScheme: urlScheme,
            relaunch: { Relauncher.relaunch() }
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
            showSettings: { [weak self] tab in self?.showSettings(tab) },
            showOnboarding: { [weak self] in self?.showOnboarding() }
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
