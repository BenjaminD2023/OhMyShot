#if DEBUG
import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog

/// `debug/about-render`: Settings › About behind the wallpaper, and its Acknowledgments sheet, captured into the debug
/// snapshots; `debug/settings-render`, any pane the same way. Nothing is shown.
@MainActor
struct DebugAboutHooks {
    /// A Settings window of the hooks' own, not the one the user may have open.
    let makeSettings: () -> SettingsWindowController
    let capture: (NSWindow, String) async -> Void

    private static var settings: SettingsWindowController?

    /// Returns true when `url` was one of these.
    func handle(_ url: URL) -> Bool {
        let hook = url.pathComponents.dropFirst().first ?? ""
        guard hook == "about-render" || hook == "settings-render" else { return false }
        func value(_ name: String) -> String? { DebugHooks.parameter(name, in: url) }
        if hook == "settings-render" {
            if value("close") == "1" {
                Self.settings?.close()
                Self.settings = nil
                return true
            }
            renderPane(tab: value("tab").flatMap(SettingsTab.init(rawValue:)) ?? .general, dark: value("mode") == "dark",
                       height: value("height").flatMap(Double.init), name: value("name"), keep: value("keep") == "1")
            return true
        }
        // Settings › About as <name>.png (about); acknowledgments=1 opens Acknowledgments… and captures the sheet as
        // <name>-acknowledgments.png, scrolled to the first "at=<text>" when given. The window closes once captured.
        Self.settings?.close()
        Self.settings = nil
        let controller = makeSettings()
        Self.settings = controller
        controller.showBehindWallpaper(.about)
        Task {
            defer {
                if Self.settings === controller {
                    controller.close()
                    Self.settings = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard let window = controller.window else { return }
            let name = value("name") ?? "about"
            guard value("acknowledgments") == "1" else {
                await capture(window, name)
                return
            }
            NotificationCenter.default.post(name: .debugOpenAcknowledgments, object: nil)
            try? await Task.sleep(for: .milliseconds(Int(value("wait") ?? "") ?? 1000))
            guard let sheet = window.attachedSheet else {
                Log.app.error("debug.about-render no sheet")
                return
            }
            if let textView = sheet.contentView.flatMap(Self.textView(in:)) {
                let text = textView.string as NSString
                Log.app.notice("debug.about-render acknowledgments \(text.length, privacy: .public) characters, \(textView.textStorage?.length ?? 0, privacy: .public) in the view")
                if let at = value("at") {
                    let range = text.range(of: at)
                    if range.location == NSNotFound {
                        Log.app.error("debug.about-render no “\(at, privacy: .public)” in the acknowledgments")
                    } else {
                        textView.scrollRangeToVisible(range)
                        textView.showFindIndicator(for: range)
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            } else {
                Log.app.error("debug.about-render no text view in the sheet")
            }
            await capture(sheet, "\(name)-acknowledgments")
        }
        return true
    }

    /// The pane `tab` as settings-<tab>-<light|dark>.png (or <name>.png), in a window of its own `height` points tall
    /// (640 by default) in the appearance asked for, whatever the app's; the window closes once captured, unless `keep`
    /// leaves it for an ax-audit until settings-render?close=1.
    private func renderPane(tab: SettingsTab, dark: Bool, height: Double?, name: String?, keep: Bool) {
        Self.settings?.close()
        Self.settings = nil
        let controller = makeSettings()
        Self.settings = controller
        // Its frame isn't saved, so the height asked for and the place behind the wallpaper never reach the user's window.
        controller.window?.setFrameAutosaveName("")
        controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let height, let window = controller.window {
            window.setContentSize(NSSize(width: window.contentRect(forFrameRect: window.frame).width, height: height))
        }
        controller.showBehindWallpaper(tab)
        Task {
            defer {
                if !keep, Self.settings === controller {
                    controller.close()
                    Self.settings = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(800))
            guard let window = controller.window else { return }
            await capture(window, name ?? "settings-\(tab.rawValue)-\(dark ? "dark" : "light")")
        }
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
#endif
