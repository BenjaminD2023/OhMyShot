import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog

/// Receives URL-scheme commands, checks who sent them, and hands approved ones to the app.
final class AutomationController {
    /// Optional dedicated handlers for OhMyShot's extended commands (`annotate-area`, `translate-area`,
    /// `pick-color`, `measure`, `draw-on-screen`, `save-replay`). Any nil handler falls back to `perform`.
    struct ExtendedActions {
        var annotateArea: ((AutomationRegion) -> Void)?
        var translateArea: ((AutomationRegion) -> Void)?
        var pickColor: (() -> Void)?
        var measure: (() -> Void)?
        var drawOnScreen: (() -> Void)?
        var saveReplay: (() -> Void)?

        init(
            annotateArea: ((AutomationRegion) -> Void)? = nil,
            translateArea: ((AutomationRegion) -> Void)? = nil,
            pickColor: (() -> Void)? = nil,
            measure: (() -> Void)? = nil,
            drawOnScreen: (() -> Void)? = nil,
            saveReplay: (() -> Void)? = nil
        ) {
            self.annotateArea = annotateArea
            self.translateArea = translateArea
            self.pickColor = pickColor
            self.measure = measure
            self.drawOnScreen = drawOnScreen
            self.saveReplay = saveReplay
        }
    }

    var extendedActions: ExtendedActions

    private let scheme: String
    private let settings: SettingsStore
    private let perform: (AutomationCommand) -> Void
    private let receiveShared: (ShareHandoff) -> Void
    private let debugHandler: (URL) -> Bool
    /// Callers refused during this session, so a script in a loop cannot spam the approval prompt.
    private var deniedCallers: Set<String> = []
    /// Guards against nested `NSAlert.runModal()` when another URL arrives while an approval prompt is open.
    private var isAskingApproval = false

    init(
        scheme: String,
        settings: SettingsStore,
        extendedActions: ExtendedActions = .init(),
        perform: @escaping (AutomationCommand) -> Void,
        receiveShared: @escaping (ShareHandoff) -> Void,
        debugHandler: @escaping (URL) -> Bool
    ) {
        self.scheme = scheme
        self.settings = settings
        self.extendedActions = extendedActions
        self.perform = perform
        self.receiveShared = receiveShared
        self.debugHandler = debugHandler
        AutomationDeniedStore.shared.onRemove = { [weak self] identifier in
            self?.deniedCallers.remove(identifier)
        }
        AutomationDeniedStore.shared.onClear = { [weak self] in
            self?.deniedCallers.removeAll()
        }
    }

    func handle(_ url: URL, senderPID: pid_t?) {
        if url.scheme?.lowercased() == scheme, url.host(percentEncoded: false) == "debug", debugHandler(url) {
            return
        }
        if ShareHandoff.isHandoff(url, scheme: scheme) {
            // The Share extension: choosing OhMyShot in a Share menu is the approval, so the gate and its switch
            // do not apply. What it can reach is limited to the pictures in the app's own Share Inbox.
            switch ShareHandoff.parse(url, scheme: scheme) {
            case .success(let handoff): receiveShared(handoff)
            case .failure(let error): Log.automation.error("Rejected share hand-over: \(String(describing: error), privacy: .public)")
            }
            return
        }
        let caller = senderPID.map(AutomationCaller.init(pid:))
        let command: AutomationCommand
        switch AutomationURLParser.parse(url, scheme: scheme) {
        case .success(let parsed):
            command = parsed
        case .failure(let error):
            Log.automation.error("Rejected URL from \(caller?.identifier ?? "unknown", privacy: .public) (pid \(senderPID.map(String.init) ?? "none", privacy: .public)): \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            return
        }
        let decision = AutomationGate.evaluate(
            caller: caller,
            isEnabled: settings.automationEnabled,
            approvedCallers: Set(settings.approvedAutomationCallers),
            deniedCallers: deniedCallers
        )
        switch decision {
        case .allow:
            dispatch(command)
        case .askUser:
            guard let caller else { return }
            guard !isAskingApproval else {
                Log.automation.notice("Ignored overlapping URL command while approval prompt is open")
                return
            }
            isAskingApproval = true
            let approved = askForApproval(caller, url: url)
            isAskingApproval = false
            if approved {
                if !settings.approvedAutomationCallers.contains(caller.identifier) {
                    settings.approvedAutomationCallers.append(caller.identifier)
                }
                deniedCallers.remove(caller.identifier)
                AutomationDeniedStore.shared.remove(caller.identifier)
                dispatch(command)
            } else {
                deniedCallers.insert(caller.identifier)
                AutomationDeniedStore.shared.recordDenied(caller.identifier)
                Log.automation.notice("User refused \(caller.identifier, privacy: .public)")
            }
        case .deny(let reason):
            Log.automation.notice("Denied URL command: \(reason, privacy: .public)")
        }
    }

    private func dispatch(_ command: AutomationCommand) {
        switch command {
        case .annotateArea(let region):
            if let handler = extendedActions.annotateArea { handler(region); return }
        case .translateArea(let region):
            if let handler = extendedActions.translateArea { handler(region); return }
        case .pickColor:
            if let handler = extendedActions.pickColor { handler(); return }
        case .measure:
            if let handler = extendedActions.measure { handler(); return }
        case .drawOnScreen:
            if let handler = extendedActions.drawOnScreen { handler(); return }
        case .saveReplay:
            if let handler = extendedActions.saveReplay { handler(); return }
        default:
            break
        }
        perform(command)
    }

    /// A blocking alert is justified here: the user is deciding whether another app may use this
    /// app's Screen Recording permission.
    private func askForApproval(_ caller: AutomationCaller, url: URL) -> Bool {
        let preview = String(url.absoluteString.prefix(240))
        let alert = NSAlert()
        if caller == .commandLine {
            alert.messageText = String(localized: "A script wants to control OhMyShot")
            alert.informativeText = String(localized: "Command: \(preview)\n\nAllowing this lets every script and command-line tool that uses open or osascript take screenshots and open files in OhMyShot. You can remove this later in Settings › Automation.")
        } else {
            alert.messageText = String(localized: "“\(caller.displayName)” wants to control OhMyShot")
            alert.informativeText = String(localized: "Command: \(preview)\n\nIt will be able to take screenshots and open files in OhMyShot. You can remove its access later in Settings › Automation.")
        }
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension AutomationCaller {
    /// An app is identified by its bundle identifier. Anything else that sent an event, including a
    /// tool that has already exited, belongs to the command-line group.
    init(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            self.init(identifier: bundleID, displayName: app.localizedName ?? bundleID)
        } else {
            self = .commandLine
        }
    }
}
