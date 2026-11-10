#if DEBUG
import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog

/// `debug/updates-*` endpoints: Sparkle against a feed served from this Mac (made with Scripts/release.sh's tools, see
/// Docs/release.md), and Settings › General rendered behind the wallpaper. A found version only waits in the menu, so
/// nothing is shown; never choose it there, as installing it would replace this app.
@MainActor
struct DebugUpdateHooks {
    /// Makes and starts the app's updater against the feed, or nil when Sparkle refused the setup.
    let start: (URL) -> UpdateController?
    let current: () -> UpdateController?
    let stop: () -> Void
    let showMenu: () -> Void
    /// The launcher's view in a window behind the wallpaper (dark or light, after these key codes), and closing it again.
    let renderMenu: (Bool, [UInt16]) -> NSWindow?
    let closeMenuRender: () -> Void
    /// A Settings window of the hooks' own, not the one the user may have open.
    let makeSettings: () -> SettingsWindowController
    let capture: (NSWindow, String) async -> Void

    private static var settings: SettingsWindowController?

    /// Returns true when `url` was one of these.
    func handle(_ url: URL) -> Bool {
        let hook = url.pathComponents.dropFirst().first ?? ""
        guard hook.hasPrefix("updates-") else { return false }
        func value(_ name: String) -> String? { DebugHooks.parameter(name, in: url) }
        switch hook {
        case "updates-start":
            // feed=http://127.0.0.1:19020/appcast.xml (default)
            let feed = value("feed").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:19020/appcast.xml")!
            let started = start(feed) != nil
            Log.updates.notice("debug.updates-start \(feed.absoluteString, privacy: .public): \(started ? "started" : "refused", privacy: .public)")
        case "updates-preview":
            let controller = current() ?? start(URL(string: "http://127.0.0.1:19020/appcast.xml")!)
            // render=1&mode=dark&name=: What's New behind the wallpaper as <name>.png (release-notes-<light|dark>), then
            // closed; nothing is shown and no version is left waiting in the menu.
            if value("render") == "1" {
                let dark = value("mode") == "dark"
                guard let controller, let window = controller.renderReleaseNotes(dark: dark) else { return true }
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    await capture(window, value("name") ?? "release-notes-\(dark ? "dark" : "light")")
                    controller.closeReleaseNotes()
                }
                return true
            }
            controller?.status.waiting = "0.2.0"
            controller?.showReleaseNotes(preview: true)
        case "updates-menu":
            // render=1&mode=dark&keys=125,124&name=: the launcher's view behind the wallpaper as <name>.png
            // (capture-launcher-<light|dark>), after those key codes were pressed in it (125 Down, 124 Right), then
            // closed; without render the real popover opens at the menu bar.
            if value("render") == "1" {
                let dark = value("mode") == "dark"
                let keys = (value("keys") ?? "").split(separator: ",").compactMap { UInt16($0) }
                guard let window = renderMenu(dark, keys) else { return true }
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    await capture(window, value("name") ?? "capture-launcher-\(dark ? "dark" : "light")")
                    closeMenuRender()
                }
                return true
            }
            showMenu()
        case "updates-reminder-preview":
            current()?.presentReminderIfNeeded(preview: true)
        case "updates-check":
            // As the daily background activity does, without skipping a recent look.
            current()?.checkInBackground(skippingRecent: false)
        case "updates-schedule":
            // on=1|0: the daily background activity, as the setting turns it on and off.
            current()?.setChecksAutomatically(value("on") != "0")
            Log.updates.notice("debug.updates-schedule \(value("on") != "0" ? "on" : "off", privacy: .public)")
        case "updates-state":
            guard let updates = current() else {
                Log.updates.notice("debug.updates-state no updater")
                return true
            }
            let status = updates.status
            Log.updates.notice("debug.updates-state waiting \(status.waiting ?? "none", privacy: .public), last check \(status.lastCheck?.description ?? "never", privacy: .public), can check \(status.canCheck, privacy: .public), menu \(updates.menuTitle, privacy: .public)")
        case "updates-stop":
            stop()
            Log.updates.notice("debug.updates-stop")
        case "updates-render":
            // Settings › General behind the wallpaper as <name>.png (updates-general); the window closes once captured.
            Self.settings?.close()
            Self.settings = nil
            let controller = makeSettings()
            Self.settings = controller
            controller.showBehindWallpaper(.general)
            Task {
                defer {
                    if Self.settings === controller {
                        controller.close()
                        Self.settings = nil
                    }
                }
                try? await Task.sleep(for: .milliseconds(600))
                guard let window = controller.window else { return }
                await capture(window, value("name") ?? "updates-general")
            }
        default:
            Log.app.error("debug.unknown \(hook, privacy: .public)")
        }
        return true
    }
}
#endif
