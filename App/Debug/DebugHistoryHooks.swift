#if DEBUG
import AppIntents
import AppKit
import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ImageIO
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSRecording
import OMSStudio
import OMSUI
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

/// `debug/history-*` and `debug/qa-*` endpoints: the History window, its search and retention, and the Quick Access cards.
extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleHistoryHook(_ hook: String, _ url: URL) -> Bool {
        switch hook {
        case "history":
            showHistory()
        case "qa-hover":
            quickAccess.previewHoverOnLatest()
        case "qa-copied":
            quickAccess.copyLatest()
        case "qa-dismiss-all":
            quickAccess.dismissAll()
        case "qa-restore":
            quickAccess.restoreRecentlyClosed()
        case "qa-dismiss-latest":
            quickAccess.dismissLatest()
        case "qa-trash":
            // The newest card to the Trash as its button does: it waits under Undo, then its capture goes.
            quickAccess.debugTrashLatest()
        case "qa-undo":
            Log.app.notice("debug.qa-undo \(quickAccess.undoTrash(), privacy: .public)")
        case "qa-render":
            // The Quick Access panel captured on its own (only this app's cards, nothing else of the screen)
            // into qa-cards.png. It holds every card showing: run it only when the cards are the checks' own.
            if let panel = quickAccess.debugPanel {
                Task { await captureHiddenWindow(panel, name: "qa-cards") }
            } else {
                Log.app.notice("debug.qa-render no cards")
            }
        case "history-key":
            // key=left|right|up|down|return|space|cmd-c|cmd-s|cmd-delete, sent through the window like a
            // real key press.
            let key = Self.parameter("key", in: url) ?? ""
            // activate=1 brings the app forward first, so the window is key and a ⌘ key goes as the menu sends it.
            if Self.hasParameter("activate", in: url) {
                NSApp.activate()
            }
            sendKey(key, to: historyWindow())
            if key == "return" {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    let window = historyWindow()
                    Log.app.notice("debug.history-key first responder: \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none", privacy: .public)")
                }
            }
        case "history-restore-latest":
            restoreLatestFromHistory()
        case "retention":
            // value=never|oneDay|threeDays|oneWeek|oneMonth
            let value = Self.parameter("value", in: url)
            if let retention = value.flatMap(HistoryRetention.init(rawValue:)) {
                setRetention(retention)
                Log.app.notice("debug.retention \(retention.rawValue, privacy: .public)")
            }
        case "history-retention-preview":
            // value=never|oneDay|…; anything else dismisses the dialog. Never confirms anything.
            let value = Self.parameter("value", in: url)
            previewRetentionChange(value.flatMap(HistoryRetention.init(rawValue:)))
            Log.app.notice("debug.history-retention-preview \(value ?? "dismiss", privacy: .public)")
        case "history-add":
            // path=/…/picture.png: added to the history as a screenshot taken in "OhMyShot Test", then read.
            if let path = Self.parameter("path", in: url) { historySearch.add(URL(filePath: path)) }
        case "history-remove-tests":
            historySearch.removeTests()
        case "history-read":
            historySearch.read()
            Log.app.notice("debug.history-read \(historySearch.reading(), privacy: .public) being read")
        case "history-search":
            // q=words: counts across the history, and what was found in the test pictures.
            let query = Self.parameter("q", in: url) ?? ""
            Log.app.notice("debug.history-search \(historySearch.search(query), privacy: .public)")
        case "history-query":
            // q=words typed into the History window's search field.
            historySearch.setQuery(Self.parameter("q", in: url) ?? "")
        case "history-size":
            // w=points, h=points: the History window's size (at least 560 × 420), its height kept unless given.
            if let width = Self.intParameter("w", in: url), let window = historyWindow() {
                let height = Self.intParameter("h", in: url).map { CGFloat($0) } ?? window.frame.height
                window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: CGFloat(width), height: height)), display: true)
            }
        case "history-filter":
            // value=all|screenshots|recordings
            historySearch.setFilter(Self.parameter("value", in: url) ?? "all")
        case "history-click":
            // count=1|2: a click or a double-click at the middle of the first card's picture, sent through the
            // window like real mouse events.
            clickFirstHistoryCard(times: Self.intParameter("count", in: url) ?? 1)
        case "history-close":
            historyWindow()?.close()
        case "history-count":
            Log.app.notice("debug.history-count \(historyCount(), privacy: .public) in history, \(quickAccess.itemIDs.count, privacy: .public) card(s), can restore: \(quickAccess.canRestoreRecentlyClosed, privacy: .public)")
        case "qa-demo":
            // The drawn page delivered as a capture: into the history and a card, never the clipboard.
            if let image = DebugPanelDemo.image(), let display = displays.layout.primary {
                Task { await captures.deliverDemo(image, displayID: display.id) }
            }
        case "history-print":
            // The selected screenshot printed as File › Print… prints it, the panel a sheet on the window.
            let controller = historyWindow()?.windowController as? HistoryWindowController
            Log.app.notice("debug.history-print started=\(controller?.debugPrintSelection() ?? false, privacy: .public)")
        case "qa-annotate":
            quickAccess.annotateLatest()
        case "history-annotate-latest":
            // The newest capture in the editor, as Capture History's Annotate opens it.
            annotateLatestFromHistory()
        case "history-delete-latest":
            // Deletes the newest capture outright (no Trash), its card too: cleanup after scripted checks.
            deleteLatestFromHistory()
        default:
            return false
        }
        return true
    }

    /// Captures each of this app's on-screen windows to a PNG, so UI can be reviewed from scripts
    /// without granting the terminal Screen Recording permission.
    private func sendKey(_ key: String, to window: NSWindow?) {
        guard let window else {
            Log.app.error("debug.history-key: no history window")
            return
        }
        let table: [String: (code: UInt16, characters: String, flags: NSEvent.ModifierFlags)] = [
            "left": (123, "\u{F702}", [.function, .numericPad]),
            "right": (124, "\u{F703}", [.function, .numericPad]),
            "down": (125, "\u{F701}", [.function, .numericPad]),
            "up": (126, "\u{F700}", [.function, .numericPad]),
            "return": (36, "\r", []),
            "space": (49, " ", []),
            "cmd-c": (8, "c", .command),
            "cmd-s": (1, "s", .command),
            "cmd-delete": (51, "\u{7F}", .command),
            "cmd-f": (3, "f", .command),
            "cmd-p": (35, "p", .command),
        ]
        guard let entry = table[key] else {
            Log.app.error("debug.history-key: unknown key \(key, privacy: .public)")
            return
        }
        if entry.flags.contains(.command) {
            // A ⌘ key is a menu key equivalent: find its item in the main menu, then send the item's
            // action to the key window's responder chain, as the menu does.
            let characters = key == "cmd-delete" ? "\u{8}" : entry.characters
            let item = NSApp.mainMenu.flatMap { Self.menuItem(withKeyEquivalent: characters, in: $0) }
            window.makeKeyAndOrderFront(nil)
            // Up the window's own responder chain, as the menu would while it is the key window (an app
            // opened in the background may not be let in front).
            let handled = item?.action.map { action in
                window.isKeyWindow
                    ? NSApp.sendAction(action, to: nil, from: item)
                    : window.firstResponder?.tryToPerform(action, with: item) ?? false
            } ?? false
            Log.app.notice("debug.history-key \(key, privacy: .public) menu=\(item?.title ?? "none", privacy: .public) handled=\(handled, privacy: .public)")
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                Log.app.notice("debug.history-key first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none", privacy: .public)")
            }
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: entry.flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: entry.characters,
                charactersIgnoringModifiers: entry.characters,
                isARepeat: false,
                keyCode: entry.code
            ) else { continue }
            window.sendEvent(event)
        }
        Log.app.notice("debug.history-key \(key, privacy: .public) key=\(window.isKeyWindow, privacy: .public)")
    }

    private func clickFirstHistoryCard(times: Int) {
        guard let window = historyWindow() else { return Log.app.error("debug.history-click: no history window") }
        // Where the grid puts its first card (DESIGN.md › Layout): 24 pt in, 20 pt below the toolbar, 150 pt tall,
        // as wide as the adaptive columns make it.
        let width = window.frame.width, toolbar = window.frame.height - window.contentLayoutRect.height
        let columns = max(1, Int((width - 48 + 20) / 220))
        let cardWidth = min(280, (width - 48 - 20 * CGFloat(columns - 1)) / CGFloat(columns))
        let point = CGPoint(x: 24 + cardWidth / 2, y: window.frame.height - (toolbar + 20 + 75))
        var number = 0
        for click in 1...max(1, times) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                number += 1
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: click, pressure: 1
                ) else { continue }
                window.sendEvent(event)
            }
        }
        Log.app.notice("debug.history-click \(times, privacy: .public) at \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)")
    }

    private static func menuItem(withKeyEquivalent characters: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == characters, item.keyEquivalentModifierMask == .command { return item }
            if let submenu = item.submenu, let found = menuItem(withKeyEquivalent: characters, in: submenu) { return found }
        }
        return nil
    }
}
#endif
