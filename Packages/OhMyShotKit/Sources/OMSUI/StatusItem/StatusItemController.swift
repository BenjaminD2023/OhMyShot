import AppKit
import Foundation
import KeyboardShortcuts

/// The menu bar icon and its menu.
///
/// Plain AppKit on purpose: it lives for the whole session, so it has to stay small and do nothing
/// until clicked.
public final class StatusItemController {
    /// A menu entry with its own action.
    public struct Entry {
        public let title: String
        public let keyEquivalent: String
        /// A global shortcut to show beside the title.
        public let shortcut: CaptureShortcut?
        /// Checked each time the menu opens; the entry is dimmed when it returns false.
        public let isEnabled: (() -> Bool)?
        public let perform: () -> Void

        public init(
            title: String,
            keyEquivalent: String = "",
            shortcut: CaptureShortcut? = nil,
            isEnabled: (() -> Bool)? = nil,
            perform: @escaping () -> Void
        ) {
            self.title = title
            self.keyEquivalent = keyEquivalent
            self.shortcut = shortcut
            self.isEnabled = isEnabled
            self.perform = perform
        }
    }

    private var statusItem: NSStatusItem?
    private let menuTarget = MenuTarget()
    private let captureEntries: [Entry]
    private let historyEntries: [Entry]
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let debugEntries: [Entry]

    public init(
        captureEntries: [Entry],
        historyEntries: [Entry] = [],
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        debugEntries: [Entry] = []
    ) {
        self.captureEntries = captureEntries
        self.historyEntries = historyEntries
        self.openSettings = openSettings
        self.quit = quit
        self.debugEntries = debugEntries
    }

    public func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "OhMyShotStatusItem"
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: appName)
                button.image?.isTemplate = true
            }
            item.menu = makeMenu()
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeMenu() -> NSMenu {
        menuTarget.removeAll()
        let menu = NSMenu()
        for group in [captureEntries, historyEntries] where !group.isEmpty {
            for entry in group {
                let item = menuTarget.item(for: entry)
                if let shortcut = entry.shortcut {
                    item.setShortcut(for: shortcut.name)
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(menuTarget.item(for: Entry(
            title: String(localized: "Settings…", bundle: .module),
            keyEquivalent: ",",
            perform: openSettings
        )))
        if !debugEntries.isEmpty {
            let submenu = NSMenu()
            debugEntries.forEach { submenu.addItem(menuTarget.item(for: $0)) }
            let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            debugItem.submenu = submenu
            menu.addItem(.separator())
            menu.addItem(debugItem)
        }
        menu.addItem(.separator())
        menu.addItem(menuTarget.item(for: Entry(
            title: String(localized: "Quit \(appName)", bundle: .module),
            keyEquivalent: "q",
            perform: quit
        )))
        return menu
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OhMyShot"
    }
}

/// Runs the closure behind each menu item, found by the item's tag.
private final class MenuTarget: NSObject, NSMenuItemValidation {
    private var entries: [StatusItemController.Entry] = []

    func item(for entry: StatusItemController.Entry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(run(_:)), keyEquivalent: entry.keyEquivalent)
        item.target = self
        item.tag = entries.count
        entries.append(entry)
        return item
    }

    func removeAll() {
        entries.removeAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard entries.indices.contains(menuItem.tag) else { return true }
        return entries[menuItem.tag].isEnabled?() ?? true
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        entries[sender.tag].perform()
    }
}
