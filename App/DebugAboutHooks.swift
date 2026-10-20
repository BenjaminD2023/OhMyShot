#if DEBUG
import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog

/// `debug/about-render`: Settings › About behind the wallpaper, and its Acknowledgments sheet, captured into the debug
/// snapshots. Nothing is shown.
@MainActor
struct DebugAboutHooks {
    /// A Settings window of the hooks' own, not the one the user may have open.
    let makeSettings: () -> SettingsWindowController
    let capture: (NSWindow, String) async -> Void

    private static var settings: SettingsWindowController?

    /// Returns true when `url` was one of these.
    func handle(_ url: URL) -> Bool {
        let hook = url.pathComponents.dropFirst().first ?? ""
        guard hook == "about-render" else { return false }
        func value(_ name: String) -> String? { DebugHooks.parameter(name, in: url) }
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

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
#endif
