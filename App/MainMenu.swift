import AppKit
import Foundation

/// The app's main menu. As a menu bar app OhMyShot never shows a menu bar, but key equivalents still go
/// through this menu: without it, ⌘C, ⌘V, ⌘W and the rest would do nothing in its windows.
enum MainMenu {
    /// - Parameter settingsTarget: receives `showSettings(_:)` for ⌘,.
    static func make(settingsTarget: AppDelegate) -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OhMyShot"
        let menu = NSMenu()

        let app = submenu(appName, in: menu)
        app.addItem(withTitle: String(localized: "About \(appName)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = settingsTarget
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(String(localized: "File"), in: menu)
        file.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: String(localized: "Save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let project = file.addItem(withTitle: String(localized: "Save a Copy as Project…"), action: Selector(("saveProject:")), keyEquivalent: "s")
        project.keyEquivalentModifierMask = [.command, .shift]
        let trash = file.addItem(withTitle: String(localized: "Move to Trash"), action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        trash.keyEquivalentModifierMask = .command

        let edit = submenu(String(localized: "Edit"), in: menu)
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findActions: [(String, String, NSEvent.ModifierFlags, NSFindPanelAction)] = [
            (String(localized: "Find…"), "f", .command, .showFindPanel),
            (String(localized: "Find Next"), "g", .command, .next),
            (String(localized: "Find Previous"), "g", [.command, .shift], .previous),
            (String(localized: "Use Selection for Find"), "e", .command, .setFindString),
        ]
        for (title, key, modifiers, action) in findActions {
            let item = edit.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = Int(action.rawValue)
        }

        let window = submenu(String(localized: "Window"), in: menu)
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        return menu
    }

    private static func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        return submenu
    }
}
