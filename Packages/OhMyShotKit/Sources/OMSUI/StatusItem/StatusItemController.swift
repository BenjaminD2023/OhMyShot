import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import SwiftUI

/// The menu bar icon and its capture launcher. The launcher is built only when opened.
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
        /// The SF Symbol the capture launcher shows beside the title.
        public let systemImage: String?
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
            systemImage: String? = nil,
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
            self.systemImage = systemImage
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
        public init(title: String, systemImage: String? = nil, children: @escaping () -> [Entry]) {
            kind = .item
            self.title = title
            self.systemImage = systemImage
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
            systemImage = nil
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
    private let launcher = NSPopover()
    private let launcherDelegate = LauncherDelegate()
    private let menuTarget = MenuTarget()
    /// Runs the menus the launcher's rows open, closing the launcher before the command.
    private let launcherMenuTarget = MenuTarget()
    /// The launcher's lit command, moved by the pointer and by the arrow keys while it is open.
    private let launcherHighlight = LauncherHighlight()
    /// The open launcher's commands, for the arrow keys; nil while it is closed.
    private var activeLauncherModel: CaptureLauncherModel?
    private var launcherKeyMonitor: Any?
    /// Whether Settings wants the icon; a recording shows it regardless while it runs.
    private var wantsVisible = false
    /// Stops the recording when the item is clicked; set only while recording.
    private var stopRecording: (() -> Void)?
    /// While recording or making a GIF, the item shows that in place of the icon and its menu.
    private var showsActivity = false
    /// The symbol a progress shows, so a change of what is being made changes it.
    private var shownSymbol: String?
    private let captureEntries: [Entry]
    /// The status menu's Tools submenu; the launcher lists them.
    private let toolEntries: [Entry]
    /// Pictures already on disk or on the clipboard, and the pins.
    private let imageEntries: [Entry]
    private let historyEntries: [Entry]
    /// The app's own entries above Settings…, such as Check for Updates….
    private let priorityEntries: [Entry]
    private var updateVersion: String?
    private let appEntries: [Entry]
    private let openSettings: () -> Void
    /// Opens Settings › Shortcuts on a shortcut's row, or on the pane for none.
    private let editShortcut: (CaptureShortcut?) -> Void
    private let quit: () -> Void
    private let debugEntries: [Entry]
    private let updateEntries: [Entry]

    public init(
        captureEntries: [Entry],
        toolEntries: [Entry] = [],
        imageEntries: [Entry] = [],
        historyEntries: [Entry] = [],
        priorityEntries: [Entry] = [],
        appEntries: [Entry] = [],
        openSettings: @escaping () -> Void,
        editShortcut: @escaping (CaptureShortcut?) -> Void,
        quit: @escaping () -> Void,
        debugEntries: [Entry] = [],
        updateEntries: [Entry] = []
    ) {
        self.captureEntries = captureEntries
        self.toolEntries = toolEntries
        self.imageEntries = imageEntries
        self.historyEntries = historyEntries
        self.priorityEntries = priorityEntries
        self.appEntries = appEntries
        self.openSettings = openSettings
        self.editShortcut = editShortcut
        self.quit = quit
        self.debugEntries = debugEntries
        self.updateEntries = updateEntries
    }

    public func setVisible(_ visible: Bool) {
        wantsVisible = visible
        // While recording the item stays: it is how the recording is stopped. Settings applies afterwards.
        guard !showsActivity else { return }
        if visible, statusItem == nil {
            statusItem = makeItem()
        } else if !visible, let item = statusItem {
            dismissLauncher()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    #if DEBUG
    public func showMenuForDebugging(capture: ((NSWindow) async -> Void)? = nil) {
        if statusItem == nil { statusItem = makeItem() }
        showLauncher()
        if let capture, let window = launcher.contentViewController?.view.window {
            Task { await capture(window) }
        }
    }

    private var debugLauncherWindow: NSWindow?

    /// For scripted captures: the launcher's own view in a plain window behind the desktop picture, never in front of
    /// anyone. The popover's material is the system's and is not drawn here; its layout and states are. `keys` are
    /// key codes pressed first, as the open launcher takes them (125 is Down, 124 Right), to show where they lead.
    public func launcherWindowForDebugging(dark: Bool, keys: [UInt16] = []) -> NSWindow {
        debugLauncherWindow?.close()
        let model = makeLauncherModel()
        launcherHighlight.cell = nil
        launcherHighlight.fromKeys = false
        activeLauncherModel = model
        for key in keys { _ = handleLauncherKey(code: key, modifiers: []) }
        activeLauncherModel = nil
        let view = CaptureLauncherView(model: model, highlight: launcherHighlight, perform: { _ in }, showMenu: { _, _ in })
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.center()
        window.orderFront(nil)
        debugLauncherWindow = window
        return window
    }

    public func closeLauncherWindowForDebugging() {
        debugLauncherWindow?.close()
        debugLauncherWindow = nil
    }
    #endif

    public func setUpdateVersion(_ version: String?) {
        updateVersion = version
        if let item = statusItem, !showsActivity { applyUpdateBadge(to: item) }
    }

    private func applyUpdateBadge(to item: NSStatusItem) {
        item.length = updateVersion == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        item.button?.title = updateVersion == nil ? "" : " ↑"
        item.button?.imagePosition = updateVersion == nil ? .imageOnly : .imageLeading
        item.button?.toolTip = updateVersion.map { String(localized: "Update to Version \($0)…", bundle: .module) } ?? appName
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
        configureLauncherButton(item)
        applyUpdateBadge(to: item)
        return item
    }

    /// While recording: the icon gives way to a stop symbol and the time, and a click stops the recording.
    /// Shown even when Settings hides the icon, since it is one of the ways to stop. Call again each second.
    public func showRecording(elapsed: String, paused: Bool, stop: @escaping () -> Void) {
        dismissLauncher()
        stopRecording = stop
        shownSymbol = nil
        showsActivity = true
        let item = statusItem ?? makeItem()
        statusItem = item
        item.menu = nil
        item.length = NSStatusItem.variableLength
        guard let button = item.button else { return }
        button.sendAction(on: [.leftMouseUp])
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

    /// What the menu bar shows the progress of after a recording, each with how far along it is, from 0 to 1.
    public enum Progress: Equatable, Sendable {
        /// The recording is being made into a GIF.
        case makingGIF(Double)
        /// A Studio movie is being exported after its window closed.
        case exportingStudio(Double)

        var fraction: Double {
            switch self {
            case .makingGIF(let fraction), .exportingStudio(let fraction): fraction
            }
        }

        /// Its mark beside the percentage, the one the recording bar's chip for it has.
        var symbolName: String {
            switch self {
            case .makingGIF: "photo.stack"
            case .exportingStudio: "wand.and.sparkles"
            }
        }

        func accessibilityLabel(percent: Int) -> String {
            switch self {
            case .makingGIF: String(localized: "Making the GIF, \(percent) percent", bundle: .module)
            case .exportingStudio: String(localized: "Exporting the Studio movie, \(percent) percent", bundle: .module)
            }
        }
    }

    /// While a recording is made into a GIF, or a Studio movie exported: its mark and how far along it is, with
    /// the menu still there; the card comes when it is done. Shown even when Settings hides the icon, as while
    /// recording, since it says the recording isn't kept yet.
    public func showProgress(_ progress: Progress) {
        stopRecording = nil
        menuTarget.stop = nil
        showsActivity = true
        let item = statusItem ?? makeItem()
        statusItem = item
        configureLauncherButton(item)
        item.length = NSStatusItem.variableLength
        guard let button = item.button else { return }
        if button.title.isEmpty || shownSymbol != progress.symbolName {
            shownSymbol = progress.symbolName
            button.image = NSImage(systemSymbolName: progress.symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }
        let percent = Int((min(max(progress.fraction, 0), 1) * 100).rounded(.down))
        let title = "\(percent)%"
        if button.title != title {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        }
        button.setAccessibilityLabel(progress.accessibilityLabel(percent: percent))
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
            dismissLauncher()
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
        configureLauncherButton(item)
        applyUpdateBadge(to: item)
    }

    /// Close synchronously before a capture freezes the screen, including captures started by a hotkey.
    public func dismissLauncher() {
        launcher.close()
    }

    private func configureLauncherButton(_ item: NSStatusItem) {
        item.menu = nil
        item.button?.target = menuTarget
        item.button?.action = #selector(MenuTarget.launcherClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menuTarget.launcher = { [weak self] in
            guard let self else { return }
            if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button {
                dismissLauncher()
                let menu = makeMenu()
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            } else if launcher.isShown {
                dismissLauncher()
            } else {
                showLauncher()
            }
        }
    }

    /// Share the exact launcher command wiring with regression checks.
    var launcherModel: CaptureLauncherModel {
        CaptureLauncherModel(captureEntries: captureEntries, toolEntries: toolEntries,
                                         imageEntries: imageEntries, historyEntries: historyEntries,
                                         priorityEntries: priorityEntries, appEntries: appEntries + updateEntries,
                                         debugEntries: debugEntries, openSettings: openSettings,
                                         editShortcut: editShortcut, quit: quit)
    }

    private func makeLauncherModel() -> CaptureLauncherModel {
        launcherModel
    }

    private func showLauncher() {
        guard let button = statusItem?.button else { return }
        let model = makeLauncherModel()
        launcher.behavior = .transient
        // No closing animation: the next frame may already be the screenshot being captured.
        launcher.animates = false
        launcher.delegate = launcherDelegate
        launcherDelegate.didClose = { [weak self, weak button] in
            button?.highlight(false)
            self?.launcher.contentViewController = nil
            self?.stopLauncherKeys()
        }
        launcherHighlight.cell = nil
        launcherHighlight.fromKeys = false
        activeLauncherModel = model
        let view = CaptureLauncherView(model: model, highlight: launcherHighlight) { [weak self] entry in
            self?.dismissLauncher()
            Task { @MainActor in entry.perform() }
        } showMenu: { [weak self] entry, anchor in
            self?.showLauncherMenu(entry, below: anchor)
        }
        let host = NSHostingController(rootView: view)
        // The popover takes the launcher's own height, so nothing in it scrolls.
        host.sizingOptions = [.preferredContentSize]
        launcher.contentViewController = host
        launcher.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        launcher.contentViewController?.view.window?.makeKey()
        startLauncherKeys()
    }

    /// While the launcher is open its window's keys pass here first: the arrow keys move the highlight as they move
    /// a menu's, whatever in the launcher has the keyboard focus.
    private func startLauncherKeys() {
        stopLauncherKeys()
        launcherKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = launcher.contentViewController?.view.window, event.window === window else { return event }
            return handleLauncherKey(code: event.keyCode, modifiers: event.modifierFlags) ? nil : event
        }
    }

    private func stopLauncherKeys() {
        if let launcherKeyMonitor { NSEvent.removeMonitor(launcherKeyMonitor) }
        launcherKeyMonitor = nil
        activeLauncherModel = nil
    }

    /// An arrow key moves the launcher's highlight, passing over dimmed commands; Return or Space presses the
    /// command the arrow keys reached, which opens its menu when it has one. Returns whether the key was taken:
    /// with a modifier, or Return and Space before any arrow key, it is the focused control's as before.
    func handleLauncherKey(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let model = activeLauncherModel, modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let direction: CaptureLauncherModel.Direction
        switch code {
        case 126: direction = .up
        case 125: direction = .down
        case 123: direction = .left
        case 124: direction = .right
        case 36, 76, 49:
            guard launcherHighlight.fromKeys, launcherHighlight.cell != nil else { return false }
            launcherHighlight.presses += 1
            return true
        default:
            return false
        }
        let rows = model.rows
        launcherHighlight.cell = CaptureLauncherModel.move(from: launcherHighlight.cell, direction,
                                                           rows: rows.map { ($0.entries.count, $0.columns) }) { cell in
            rows[cell.row].entries[cell.column].isEnabled?() != false
        }
        launcherHighlight.fromKeys = true
        return true
    }

    /// A row's commands in a native menu under it: nested menus, checkmarks, and validation as in the status menu.
    /// `anchor` is the row's frame in the launcher's coordinate space, origin at the top left.
    private func showLauncherMenu(_ entry: Entry, below anchor: CGRect) {
        guard let children = entry.children, let view = launcher.contentViewController?.view else { return }
        launcherMenuTarget.removeAll()
        launcherMenuTarget.willPerform = { [weak self] in self?.dismissLauncher() }
        let menu = NSMenu()
        for child in children() {
            let item = launcherMenuTarget.item(for: child)
            if let shortcut = child.shortcut { item.setShortcut(for: shortcut.name) }
            menu.addItem(item)
        }
        let y = view.isFlipped ? anchor.maxY + 2 : view.bounds.height - anchor.maxY - 2
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: y), in: view)
    }

    private func makeMenu() -> NSMenu {
        menuTarget.removeAll()
        let menu = NSMenu()
        for entry in priorityEntries {
            let item = menuTarget.item(for: entry)
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        let tools = toolEntries.isEmpty ? [] : [Entry(title: String(localized: "Tools", bundle: .module)) { [toolEntries] in toolEntries }]
        for group in [captureEntries + tools, imageEntries, historyEntries, updateEntries] where !group.isEmpty {
            for entry in group {
                let item = menuTarget.item(for: entry)
                if let shortcut = entry.shortcut {
                    item.setShortcut(for: shortcut.name)
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        for entry in appEntries {
            menu.addItem(menuTarget.item(for: entry))
        }
        menu.addItem(menuTarget.item(for: Entry(
            title: String(localized: "Settings…", bundle: .module),
            keyEquivalent: ",",
            perform: openSettings
        )))
        if !debugEntries.isEmpty {
            let submenu = NSMenu()
            debugEntries.forEach { submenu.addItem(menuTarget.item(for: $0)) }
            let debugItem = NSMenuItem(title: String(localized: "Debug", bundle: .module), action: nil, keyEquivalent: "")
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
        AppIdentity.displayName
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
    var launcher: (() -> Void)?
    /// Called as a command is chosen, before it runs.
    var willPerform: (() -> Void)?

    @objc func launcherClicked(_ sender: Any?) { launcher?() }

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
            if let shortcut = entry.shortcut {
                item.setShortcut(for: shortcut.name)
            }
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
        willPerform?()
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

/// Releases the hosting tree on dismissal, so the closed launcher has no timer or retained UI work.
private final class LauncherDelegate: NSObject, NSPopoverDelegate {
    var didClose: (() -> Void)?
    func popoverDidClose(_ notification: Notification) { didClose?() }
}
