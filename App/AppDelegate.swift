import AppKit
import CoreServices
import Foundation
import OMSCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var root: CompositionRoot?
    private var pendingURLs: [(url: URL, senderPID: pid_t?)] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(settingsTarget: self)
        // Registered before launch finishes, so a URL that launched the app is not lost.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After a relaunch the previous copy may still be quitting; let it release its shortcuts and
        // menu bar icon first. URLs that arrive meanwhile wait in `pendingURLs`.
        Relauncher.afterOtherInstancesExit { [weak self] in
            self?.start()
        }
    }

    private func start() {
        let root = CompositionRoot()
        self.root = root
        root.start()
        for pending in pendingURLs {
            root.handle(url: pending.url, senderPID: pending.senderPID)
        }
        pendingURLs.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        root?.prepareForTermination()
    }

    /// ⌘, while one of the app's windows is in front.
    @objc func showSettings(_ sender: Any?) {
        root?.showSettings()
    }

    /// Opening the app again (from Finder, Spotlight, or the Dock) shows Settings. The menu bar icon
    /// may be hidden by the user or pushed into the menu bar's overflow, so this is the way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        root?.showSettings()
        return false
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard
            let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: string)
        else { return }
        let senderPID = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)).map { pid_t($0.int32Value) }
        if let root {
            root.handle(url: url, senderPID: senderPID)
        } else {
            pendingURLs.append((url, senderPID))
        }
    }
}
