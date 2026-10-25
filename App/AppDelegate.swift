import AppKit
import CoreServices
import Foundation
import OMSCore
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var root: CompositionRoot?
    private var pendingURLs: [(url: URL, senderPID: pid_t?)] = []
    private var pendingFiles: [URL] = []

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
        ShortcutsBridge.started(root)
        for pending in pendingURLs {
            root.handle(url: pending.url, senderPID: pending.senderPID)
        }
        pendingURLs.removeAll()
        root.open(pendingFiles)
        pendingFiles.removeAll()
    }

    /// Files opened with the app from Finder: projects, and pictures to mark up.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if let root {
            root.open(files)
        } else {
            pendingFiles.append(contentsOf: files)
        }
    }

    /// After a permission changes, System Settings offers Quit & Reopen, but it only quits a menu bar
    /// app. When the quit comes from System Settings, start the new copy here before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let requester = Self.quitRequester()
        if let requester { Log.app.notice("Quit requested by \(requester, privacy: .public)") }
        let reopens = requester.map { $0.hasPrefix("com.apple.systempreferences") || $0.hasPrefix("com.apple.settings.") } ?? false
        let quit = { (mayQuit: Bool) in
            guard mayQuit else { return sender.reply(toApplicationShouldTerminate: false) }
            guard reopens else { return sender.reply(toApplicationShouldTerminate: true) }
            Relauncher.startNewCopy { _ in sender.reply(toApplicationShouldTerminate: true) }
        }
        // A recording is stopped and kept first; quitting goes on once it is.
        if let root, root.finishRecordingBeforeQuitting(quit) { return .terminateLater }
        guard reopens else { return .terminateNow }
        quit(true)
        return .terminateLater
    }

    /// The bundle identifier of the app that sent the Quit Apple event being handled, if any.
    private static func quitRequester() -> String? {
        guard
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == AEEventClass(kCoreEventClass),
            event.eventID == AEEventID(kAEQuitApplication),
            let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? "pid \(pid)"
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
