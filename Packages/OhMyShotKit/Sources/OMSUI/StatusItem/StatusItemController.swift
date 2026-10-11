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
        public enum Kind: Sendable {
            case item
            /// A line between groups, in a submenu.
            case separator
            /// A group's title, in a submenu.
            case header
        }

        public let kind: Kind
        public let title: String
        public let keyEquivalent: String
        /// A global shortcut to show beside the title.
        public let shortcut: CaptureShortcut?
        /// Checked each time the menu opens; the entry is dimmed when it returns false.
        public let isEnabled: (() -> Bool)?
        /// Asked each time the menu opens, for an entry whose title follows what is going on.
        public let currentTitle: (() -> String)?
        /// Asked each time the menu opens, for an entry shown only while it applies.
        public let isHidden: (() -> Bool)?
        /// Asked each time the menu opens, for an entry with a checkmark while it is on.
        public let isChecked: (() -> Bool)?
        /// The entries of a submenu, asked for each time it opens, for a list that changes (the displays).
        public let children: (() -> [Entry])?
        public let perform: () -> Void

        public init(
            title: String,
            keyEquivalent: String = "",
            shortcut: CaptureShortcut? = nil,
            isEnabled: (() -> Bool)? = nil,
            currentTitle: (() -> String)? = nil,
            isHidden: (() -> Bool)? = nil,
            isChecked: (() -> Bool)? = nil,
            perform: @escaping () -> Void
        ) {
            kind = .item
            self.title = title
            self.keyEquivalent = keyEquivalent
            self.shortcut = shortcut
            self.isEnabled = isEnabled
            self.currentTitle = currentTitle
            self.isHidden = isHidden
            self.isChecked = isChecked
            children = nil
            self.perform = perform
        }

        /// An entry that opens a submenu of `children`, made each time it opens.
        public init(title: String, children: @escaping () -> [Entry]) {
            kind = .item
            self.title = title
            keyEquivalent = ""
            shortcut = nil
            isEnabled = nil
            currentTitle = nil
            isHidden = nil
            isChecked = nil
            self.children = children
            perform = {}
        }

        private init(kind: Kind, title: String) {
            self.kind = kind
            self.title = title
            keyEquivalent = ""
            shortcut = nil
            isEnabled = nil
            currentTitle = nil
            isHidden = nil
            isChecked = nil
            children = nil
            perform = {}
        }

        public static var separator: Entry {
            Entry(kind: .separator, title: "")
        }

        public static func header(_ title: String) -> Entry {
            Entry(kind: .header, title: title)
        }
    }

    /// An image dropped on the icon: return whether it was taken. Set before the icon is shown.
    public var onDrop: ((NSPasteboard) -> Bool)?

    private var statusItem: NSStatusItem?
    private let menuTarget = MenuTarget()
    /// Whether Settings wants the icon; a recording shows it regardless while it runs.
    private var wantsVisible = false
    /// Stops the recording when the item is clicked; set only while recording.
    private var stopRecording: (() -> Void)?
    /// While recording or making a GIF, the item shows that in place of the icon and its menu.
    private var showsActivity = false
    /// The symbol a progress shows, so a change of what is being made changes it.
    private var shownSymbol: String?
    private let captureEntries: [Entry]
    private let textEntries: [Entry]
    private let pinEntries: [Entry]
    private let historyEntries: [Entry]
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let debugEntries: [Entry]

    public init(
        captureEntries: [Entry],
        textEntries: [Entry] = [],
        pinEntries: [Entry] = [],
        historyEntries: [Entry] = [],
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        debugEntries: [Entry] = []
    ) {
        self.captureEntries = captureEntries
        self.textEntries = textEntries
        self.pinEntries = pinEntries
        self.historyEntries = historyEntries
        self.openSettings = openSettings
        self.quit = quit
        self.debugEntries = debugEntries
    }

    public func setVisible(_ visible: Bool) {
        wantsVisible = visible
        // While recording the item stays: it is how the recording is stopped. Settings applies afterwards.
        guard !showsActivity else { return }
        if visible, statusItem == nil {
            statusItem = makeItem()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "OhMyShotStatusItem"
        if let button = item.button {
            button.image = NSImage.statusItemIcon(accessibilityDescription: appName)
            if let onDrop {
                let dropView = StatusItemDropView(frame: button.bounds, button: button, onDrop: onDrop)
                dropView.autoresizingMask = [.width, .height]
                button.addSubview(dropView)
            }
        }
        item.menu = makeMenu()
        return item
    }

    /// While recording: the icon gives way to a stop symbol and the time, and a click stops the recording.
    /// Shown even when Settings hides the icon, since it is one of the ways to stop. Call again each second.
    public func showRecording(elapsed: String, paused: Bool, stop: @escaping () -> Void) {
        stopRecording = stop
        showsActivity = true
        let item = statusItem ?? makeItem()
        statusItem = item
        item.menu = nil
        item.length = NSStatusItem.variableLength
        guard let button = item.button else { return }
        if button.action != #selector(MenuTarget.stopClicked(_:)) {
            button.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = menuTarget
            button.action = #selector(MenuTarget.stopClicked(_:))
            menuTarget.stop = { [weak self] in self?.stopRecording?() }
        }
        let title = paused ? String(localized: "Paused \(elapsed)", bundle: .module) : elapsed
        if button.title != title {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        }
        button.setAccessibilityLabel(paused
            ? String(localized: "Stop Recording, paused at \(elapsed)", bundle: .module)
            : String(localized: "Stop Recording, \(elapsed)", bundle: .module))
    }

    /// While a recording is made into a GIF: its mark and how far along it is, `fraction` from 0 to 1, with
    /// the menu still there; the card comes when it is done. Shown even when Settings hides the icon, as while
    /// recording, since it says the recording isn't kept yet.
    public func showProgress(_ fraction: Double, symbolName: String = "photo.stack") {
        stopRecording = nil
        menuTarget.stop = nil
        showsActivity = true
        let item = statusItem ?? makeItem()
        statusItem = item
        if item.menu == nil { item.menu = makeMenu() }
        item.length = NSStatusItem.variableLength
        guard let button = item.button else { return }
        if button.action != nil || button.title.isEmpty || shownSymbol != symbolName {
            shownSymbol = symbolName
            button.target = nil
            button.action = nil
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        let title = "\(percent)%"
        if button.title != title {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        }
        button.setAccessibilityLabel(symbolName == "photo.stack"
            ? String(localized: "Making the GIF, \(percent) percent", bundle: .module)
            : String(localized: "Exporting the Studio movie, \(percent) percent", bundle: .module))
    }

    /// The recording ended, or its GIF is made: the icon and its menu come back, or the item goes if
    /// Settings hides it.
    public func endRecording() {
        guard showsActivity else { return }
        showsActivity = false
        stopRecording = nil
        menuTarget.stop = nil
        guard let item = statusItem else { return }
        guard wantsVisible else {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            return
        }
        item.length = NSStatusItem.squareLength
        if let button = item.button {
            button.target = nil
            button.action = nil
            button.title = ""
            button.setAccessibilityLabel(nil)
            button.image = NSImage.statusItemIcon(accessibilityDescription: appName)
            button.imagePosition = .imageOnly
        }
        item.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        menuTarget.removeAll()
        let menu = NSMenu()
        for group in [captureEntries, textEntries, pinEntries, historyEntries] where !group.isEmpty {
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

/// Runs the closure behind each menu item, found by the item's tag (or, in a submenu made as it opens, the
/// entry it holds), and the recording's Stop.
private final class MenuTarget: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private var entries: [StatusItemController.Entry] = []
    /// The submenus made again each time they open, and what makes their entries.
    private var submenus: [ObjectIdentifier: () -> [StatusItemController.Entry]] = [:]
    var stop: (() -> Void)?

    /// A submenu's entry, held by its item.
    private final class Held {
        let entry: StatusItemController.Entry

        init(_ entry: StatusItemController.Entry) {
            self.entry = entry
        }
    }

    @objc func stopClicked(_ sender: Any?) {
        stop?()
    }

    func item(for entry: StatusItemController.Entry) -> NSMenuItem {
        if let special = Self.special(entry) { return special }
        let item = NSMenuItem(title: entry.title, action: entry.children == nil ? #selector(run(_:)) : nil, keyEquivalent: entry.keyEquivalent)
        item.target = self
        item.tag = entries.count
        entries.append(entry)
        if let children = entry.children {
            let submenu = NSMenu(title: entry.title)
            submenu.delegate = self
            submenus[ObjectIdentifier(submenu)] = children
            item.submenu = submenu
        }
        return item
    }

    func removeAll() {
        entries.removeAll()
        submenus.removeAll()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let children = submenus[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        for entry in children() {
            if let special = Self.special(entry) {
                menu.addItem(special)
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(runHeld(_:)), keyEquivalent: entry.keyEquivalent)
            item.target = self
            item.representedObject = Held(entry)
            menu.addItem(item)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let entry: StatusItemController.Entry
        if let held = menuItem.representedObject as? Held {
            entry = held.entry
        } else if entries.indices.contains(menuItem.tag) {
            entry = entries[menuItem.tag]
        } else {
            return true
        }
        if let title = entry.currentTitle?() { menuItem.title = title }
        if let isHidden = entry.isHidden { menuItem.isHidden = isHidden() }
        if let isChecked = entry.isChecked { menuItem.state = isChecked() ? .on : .off }
        return entry.isEnabled?() ?? true
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        perform(entries[sender.tag])
    }

    @objc private func runHeld(_ sender: NSMenuItem) {
        guard let held = sender.representedObject as? Held else { return }
        perform(held.entry)
    }

    private func perform(_ entry: StatusItemController.Entry) {
        // Once the menu has closed: a window opened while it was still up went behind the app in front
        // again as the menu closed, and a capture began over the closing menu.
        Task { @MainActor in entry.perform() }
    }

    /// The item for a separator or a group's title.
    private static func special(_ entry: StatusItemController.Entry) -> NSMenuItem? {
        switch entry.kind {
        case .item: nil
        case .separator: .separator()
        case .header: .sectionHeader(title: entry.title)
        }
    }
}
