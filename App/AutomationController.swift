import AppKit
import Foundation
import OMSCore
import OSLog

/// Receives URL-scheme commands, checks who sent them, and hands approved ones to the app.
final class AutomationController {
    private let scheme: String
    private let settings: SettingsStore
    private let perform: (AutomationCommand) -> Void
    private let debugHandler: (URL) -> Bool
    /// Callers refused during this session, so a script in a loop cannot spam the approval prompt.
    private var deniedCallers: Set<String> = []

    init(
        scheme: String,
        settings: SettingsStore,
        perform: @escaping (AutomationCommand) -> Void,
        debugHandler: @escaping (URL) -> Bool
    ) {
        self.scheme = scheme
        self.settings = settings
        self.perform = perform
        self.debugHandler = debugHandler
    }

    func handle(_ url: URL, senderPID: pid_t?) {
        if url.scheme?.lowercased() == scheme, url.host(percentEncoded: false) == "debug", debugHandler(url) {
            return
        }
        let caller = senderPID.map(AutomationCaller.init(pid:))
        let command: AutomationCommand
        switch AutomationURLParser.parse(url, scheme: scheme) {
        case .success(let parsed):
            command = parsed
        case .failure(let error):
            Log.automation.error("Rejected URL from \(caller?.identifier ?? "unknown", privacy: .public) (pid \(senderPID.map(String.init) ?? "none", privacy: .public)): \(String(describing: error), privacy: .public)")
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
            perform(command)
        case .askUser:
            guard let caller else { return }
            if askForApproval(caller) {
                settings.approvedAutomationCallers.append(caller.identifier)
                perform(command)
            } else {
                deniedCallers.insert(caller.identifier)
                Log.automation.notice("User refused \(caller.identifier, privacy: .public)")
            }
        case .deny(let reason):
            Log.automation.notice("Denied URL command: \(reason, privacy: .public)")
        }
    }

    /// A blocking alert is justified here: the user is deciding whether another app may use this
    /// app's Screen Recording permission.
    private func askForApproval(_ caller: AutomationCaller) -> Bool {
        let alert = NSAlert()
        if caller == .commandLine {
            alert.messageText = String(localized: "A script wants to control OhMyShot")
            alert.informativeText = String(localized: "Allowing this lets every script and command-line tool that uses open or osascript take screenshots and open files in OhMyShot. You can remove this later in Settings › Automation.")
        } else {
            alert.messageText = String(localized: "“\(caller.displayName)” wants to control OhMyShot")
            alert.informativeText = String(localized: "It will be able to take screenshots and open files in OhMyShot. You can remove its access later in Settings › Automation.")
        }
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        NSApp.activate()
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
