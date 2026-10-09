import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore

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
        /// Asked each time the menu opens, for an entry whose title follows what is going on.
        public let currentTitle: (() -> String)?
        public let perform: () -> Void

        public init(
            title: String,
            keyEquivalent: String = "",
            shortcut: CaptureShortcut? = nil,
            isEnabled: (() -> Bool)? = nil,
            currentTitle: (() -> String)? = nil,
            perform: @escaping () -> Void
        ) {
            self.title = title
            self.keyEquivalent = keyEquivalent
            self.shortcut = shortcut
            self.isEnabled = isEnabled
            self.currentTitle = currentTitle
            self.perform = perform
        }
    }

    /// An image dropped on the icon: return whether it was taken. Set before the icon is shown.
    public var onDrop: ((NSPasteboard) -> Bool)?

    private var statusItem: NSStatusItem?
    private let menuTarget = MenuTarget()
    private let captureEntries: [Entry]
    private let textEntries: [Entry]
    private let historyEntries: [Entry]
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let debugEntries: [Entry]

    public init(
        captureEntries: [Entry],
        textEntries: [Entry] = [],
        historyEntries: [Entry] = [],
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        debugEntries: [Entry] = []
    ) {
        self.captureEntries = captureEntries
        self.textEntries = textEntries
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
                if let onDrop {
                    let dropView = StatusItemDropView(frame: button.bounds, button: button, onDrop: onDrop)
                    dropView.autoresizingMask = [.width, .height]
                    button.addSubview(dropView)
                }
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
        for group in [captureEntries, textEntries, historyEntries] where !group.isEmpty {
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

/// Takes images dropped on the menu bar icon. Invisible to clicks and to VoiceOver: the hit test skips it,
/// so the icon's button gets every click as before; dragging finds views by their registered types.
private final class StatusItemDropView: NSView {
    private weak var button: NSStatusBarButton?
    private let onDrop: (NSPasteboard) -> Bool

    init(frame: CGRect, button: NSStatusBarButton, onDrop: @escaping (NSPasteboard) -> Bool) {
        self.button = button
        self.onDrop = onDrop
        super.init(frame: frame)
        registerForDraggedTypes(PasteboardImage.draggedTypes)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard PasteboardImage.holdsImage(sender.draggingPasteboard) else { return [] }
        button?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        button?.highlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        button?.highlight(false)
        return onDrop(sender.draggingPasteboard)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        button?.highlight(false)
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
        let entry = entries[menuItem.tag]
        if let title = entry.currentTitle?() { menuItem.title = title }
        return entry.isEnabled?() ?? true
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        entries[sender.tag].perform()
    }
}
