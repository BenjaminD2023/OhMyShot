#if DEBUG
import AppKit
import Foundation
import OMSCapture
import OMSCore
import OMSUI
import OSLog

/// Isolated first-use previews: no real permission requests, progress writes, captures, or clipboard operations.
/// onboarding-render?step=welcome|permission|shortcuts|capture&granted=1&asked=1&keys=on|off|mixed&mode=dark&corner=right&width=520&height=600
/// result=cancelled|failed shows retry copy; result=success shows a drawn practice card and its real hint.
struct DebugOnboardingHooks {
    let captureWindow: (NSWindow, String) async -> Void
    private static var controller: OnboardingWindowController?
    private static var cards: QuickAccessController?

    func handle(_ url: URL) -> Bool {
        if url.pathComponents.dropFirst().first == "onboarding-check" {
            Task { await Self.checkCaptureDelivery() }
            return true
        }
        guard url.pathComponents.dropFirst().first == "onboarding-render" else { return false }
        func value(_ key: String) -> String? { DebugHooks.parameter(key, in: url) }
        Self.controller?.close()
        Self.controller = nil
        Self.cards?.dismissFirstCaptureHint()
        Self.cards?.dismissAll()
        Self.cards = nil
        if value("close") == "1" { return true }
        if value("result") == "success" {
            showSuccess(copies: value("copy") != "0", saved: value("saved") == "1")
            if value("mode") == "dark" {
                Self.cards?.debugFirstCaptureHintWindow?.appearance = NSAppearance(named: .darkAqua)
            }
        } else {
            var granted = value("granted") == "1"
            var asked = value("asked") == "1"
            let access = OnboardingWindowController.Access(
                isGranted: { granted }, hasAsked: { asked }, refresh: {},
                request: { asked = true; granted = true }, openSettings: { granted = true }
            )
            let off = Dictionary(uniqueKeysWithValues: ["28", "29", "30", "31", "184"].map { ($0, ["enabled": false] as [String: Any]) })
            let keys: [String: Any]? = switch value("keys") {
            case "off": off
            case "mixed": ["28": ["enabled": false]]
            default: nil
            }
            let step = value("step").flatMap(OnboardingProgress.Step.init(rawValue:)) ?? .welcome
            let result = value("result")
            let controller = OnboardingWindowController(
                permissions: PermissionCenter(), startingAt: step, mode: value("recovery") == "1" ? .permissionRecovery : .tour,
                readHotKeys: { keys }, bindings: { SystemScreenshotKeys.defaultBindings(for: .release) }, access: access,
                captureMessage: result == "cancelled" || result == "failed" ? String(localized: "No capture was completed. Try again, or skip the guide. If access just changed, relaunch OhMyShot.") : nil,
                cardCorner: value("corner") == "right" ? .bottomRight : .bottomLeft,
                capture: { Log.app.notice("debug.onboarding practice requested") }, relaunch: { Log.app.notice("debug.onboarding relaunch requested") }
            )
            controller.window?.appearance = NSAppearance(named: value("mode") == "dark" ? .darkAqua : .aqua)
            controller.window?.title = "onboarding-\(step.rawValue)-\(value("mode") ?? "light")"
            let width = value("width").flatMap(Double.init), height = value("height").flatMap(Double.init)
            if width != nil || height != nil, let window = controller.window {
                window.setContentSize(NSSize(width: width ?? window.contentLayoutRect.width, height: height ?? window.contentLayoutRect.height))
            }
            if value("keep") == "1" {
                controller.show()
            } else if let window = controller.window {
                window.center()
                window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
                window.orderFrontRegardless()
            }
            Self.controller = controller
        }
        let controller = Self.controller
        let cards = Self.cards
        let keep = value("keep") == "1"
        let name = "onboarding-hint-\(value("mode") ?? "light")"
        Task { @MainActor in
            if let window = controller?.window { await captureWindow(window, window.title) }
            if let hint = cards?.debugFirstCaptureHintWindow { await captureWindow(hint, name) }
            if let panel = cards?.debugPanel { await captureWindow(panel, "onboarding-practice-card") }
            if !keep {
                controller?.close()
                cards?.dismissFirstCaptureHint()
                cards?.dismissAll()
                if Self.controller === controller { Self.controller = nil }
                if Self.cards === cards { Self.cards = nil }
            }
        }
        return true
    }

    private func showSuccess(copies: Bool, saved: Bool) {
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            ("Hello, OhMyShot" as NSString).draw(at: NSPoint(x: 44, y: 240), withAttributes: [
                .font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ])
            ("Your first screenshot." as NSString).draw(at: NSPoint(x: 46, y: 194), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let cards = QuickAccessController(actions: .init(
            copy: { _ in }, save: { _, _ in nil }, saveAs: { _ in nil }, open: { _ in }, annotate: { _ in },
            reveal: { _ in }, recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }, closed: { _ in }
        ))
        let file = URL(filePath: "/tmp/ohmyshot-onboarding-preview.png")
        let item = QuickAccessItem(id: UUID(), fileURL: file, thumbnail: cg, pixelWidth: 640, pixelHeight: 400,
                                   displayID: NSScreen.main?.cgDirectDisplayID ?? 0, savedURL: saved ? file : nil)
        cards.add(item)
        cards.showFirstCaptureHint(for: item.id, isCopied: copies)
        Self.cards = cards
    }

    /// Exercises the app-level capture callback with a drawn image, private defaults and history. The clipboard,
    /// the person's captures, and their preferences are untouched. The cancelled overlay never reads the screen.
    private static func checkCaptureDelivery() async {
        let suite = "OnboardingCheck-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appending(path: suite)
        guard let defaults = UserDefaults(suiteName: suite), let image = DebugPanelDemo.image() else { return }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let beforeClipboard = NSPasteboard.general.changeCount
        let settings = SettingsStore(defaults: defaults)
        settings.showQuickAccess = false
        settings.historyRetention = .never
        settings.playSounds = false
        let history = HistoryStore(directory: folder)
        let displays = DisplayTopology()
        let capturer = ScreenCapturer(content: ShareableContentCache())
        let overlay = OverlayController(topology: displays, capturer: capturer)
        let captures = CaptureCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay,
                                          history: history, files: ScreenshotFiles(settings: settings, history: history))
        let cards = QuickAccessController(actions: .init(
            copy: { _ in }, save: { _, _ in nil }, saveAs: { _ in nil }, open: { _ in }, annotate: { _ in },
            reveal: { _ in }, recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in },
            closed: { item in if let entry = history.item(id: item.id) { history.delete(entry) } }
        ))
        defer { overlay.cancel(); cards.dismissFirstCaptureHint(); cards.dismissAll() }
        let progress = OnboardingProgress(defaults: defaults)
        progress.move(to: .capture)
        var ordinaryCards = 0, delivered = 0, finished = 0
        var retained = false, clipboardReportedCorrectly = false, focusKept = false
        captures.onCaptured = { _ in ordinaryCards += 1 }
        let entry = await captures.deliverDemo(image, displayID: displays.layout.primary?.id ?? 0, followUp: .init(deliverCard: { item, isCopied in
            delivered += 1
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let key = NSApp.keyWindow
            cards.add(item)
            cards.showFirstCaptureHint(for: item.id, isCopied: isCopied)
            focusKept = front == NSWorkspace.shared.frontmostApplication?.processIdentifier && key === NSApp.keyWindow
            clipboardReportedCorrectly = !isCopied
            _ = history.removeExpired(retention: .never, keeping: cards.itemIDs)
            retained = FileManager.default.fileExists(atPath: item.fileURL.path(percentEncoded: false))
        }, done: { entry in
            finished += 1
            if entry != nil { progress.complete() }
        }))
        let hintShown = cards.debugFirstCaptureHintWindow.map { $0.isVisible && $0.frame.width == 320 && $0.frame.height > 100 } ?? false
        cards.dismissAll()
        let hintClosed = cards.debugFirstCaptureHintWindow == nil
        let released = entry.map { !FileManager.default.fileExists(atPath: history.fileURL(for: $0).path(percentEncoded: false)) } ?? false
        var cancelled = 0
        captures.captureArea(copiesToClipboard: false, freezes: false, followUp: .init(done: { entry in
            if entry == nil { cancelled += 1 }
        }))
        overlay.cancel()
        let success = delivered == 1 && ordinaryCards == 0 && finished == 1 && retained && released
            && hintShown && hintClosed && focusKept && clipboardReportedCorrectly && cancelled == 1
            && progress.status == .completed && !settings.showQuickAccess && settings.historyRetention == .never
            && beforeClipboard == NSPasteboard.general.changeCount
        let report = "passed=\(success) delivered=\(delivered) completed=\(finished) cancelled=\(cancelled) retained=\(retained) released=\(released) hint=\(hintShown)/\(hintClosed) focus=\(focusKept) clipboard=\(clipboardReportedCorrectly)"
        Log.app.notice("debug.onboarding-check \(report, privacy: .public)")
        let output = DebugHooks.snapshotDirectory.appending(path: "onboarding-check.txt")
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? report.write(to: output, atomically: true, encoding: .utf8)
    }
}
#endif
