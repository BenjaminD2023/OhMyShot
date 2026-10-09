import AppKit
import Foundation
import ImageIO
import Observation
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// Builds the app's services once and wires them together. Feature modules never import each other;
/// they meet here, through closures.
final class CompositionRoot {
    private let settings = SettingsStore()
    private let permissions = PermissionCenter()
    private let displays = DisplayTopology()
    private let history = HistoryStore.standard()
    private let shareableContent = ShareableContentCache()
    private lazy var capturer = ScreenCapturer(content: shareableContent)
    private lazy var overlay = OverlayController(topology: displays, capturer: capturer)
    private lazy var captures = CaptureCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay, history: history)
    private lazy var quickAccess = QuickAccessController(actions: makeQuickAccessActions())
    private lazy var textCapture = TextCaptureCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay)
    private lazy var annotations = AnnotationCoordinator(history: history)
    private lazy var pins = PinController(settings: settings, actions: makePinActions())
    private lazy var colorPicker = ColorPickerCoordinator(settings: settings, overlay: overlay)
    private lazy var measurer = MeasureCoordinator(settings: settings, overlay: overlay, colorPicker: colorPicker)
    private let hotkeys: HotkeyCenter
    private let urlScheme: String
    private var statusItem: StatusItemController?
    private var automation: AutomationController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var historyWindow: HistoryWindowController?
    private var observations: [Task<Void, Never>] = []

    init() {
        #if DEBUG
        hotkeys = HotkeyCenter(profile: .development)
        #else
        hotkeys = HotkeyCenter(profile: .release)
        #endif
        urlScheme = Bundle.main.object(forInfoDictionaryKey: "OMSURLScheme") as? String ?? "ohmyshot"
    }

    func start() {
        // The redaction tool's suggestions: what reading finds better covered, read on this Mac.
        AnnotationSession.findRedactions = { image in
            let probe = LatencyProbe("annotate.redactions")
            let found = (try? await SensitiveTextScanner().scan(image)) ?? []
            probe.end()
            Log.app.notice("Redaction suggestions: \(found.count, privacy: .public) found")
            return found.map { RedactionSuggestion(rect: $0.box, label: Self.label(for: $0.kind)) }
        }
        // The lines of text the highlighter snaps to: where they lie, never what they say.
        AnnotationSession.findTextLines = { image in
            let probe = LatencyProbe("annotate.textlines")
            let lines = (try? await TextLineReader().read(image)) ?? []
            probe.end()
            Log.app.notice("Text lines: \(lines.count, privacy: .public) found")
            return lines.map { TextLine(rect: $0.box, words: $0.words) }
        }
        let statusItem = StatusItemController(
            captureEntries: [
                .init(title: String(localized: "Capture Area"), shortcut: .captureArea) { [weak self] in self?.handle(.captureArea) },
                .init(title: String(localized: "Annotate Area"), shortcut: .annotateArea) { [weak self] in self?.handle(.annotateArea) },
                .init(title: String(localized: "Capture Area and Pin"), shortcut: .pinArea) { [weak self] in self?.handle(.pinArea) },
                .init(title: String(localized: "Capture Window"), shortcut: .captureWindow) { [weak self] in self?.handle(.captureWindow) },
                .init(title: String(localized: "Capture Fullscreen"), shortcut: .captureFullscreen) { [weak self] in self?.handle(.captureFullscreen) },
                .init(
                    title: String(localized: "Self-Timer"),
                    shortcut: .selfTimer,
                    currentTitle: { [weak self] in
                        self?.captures.isSelfTimerRunning == true ? String(localized: "Cancel Self-Timer") : String(localized: "Self-Timer")
                    }
                ) { [weak self] in
                    self?.handle(.selfTimer)
                },
                .init(title: String(localized: "Capture Text"), shortcut: .captureText) { [weak self] in self?.handle(.captureText) },
                .init(title: String(localized: "Translate Area"), shortcut: .translateArea) { [weak self] in self?.handle(.translateArea) },
                .init(title: String(localized: "Pick Color"), shortcut: .pickColor) { [weak self] in self?.handle(.pickColor) },
                .init(title: String(localized: "Measure"), shortcut: .measure) { [weak self] in self?.handle(.measure) },
            ],
            textEntries: [
                .init(
                    title: String(localized: "Recognize Text in Clipboard Image"),
                    isEnabled: { PasteboardImage.mayHoldImage(.general) }
                ) { [weak self] in
                    self?.textCapture.openClipboardImage()
                },
                .init(title: String(localized: "Recognize Text in Image…")) { [weak self] in self?.textCapture.openImageFile() },
            ],
            pinEntries: [
                .init(
                    title: String(localized: "Pin from Clipboard"),
                    isEnabled: { Self.clipboardMayHoldPin() }
                ) { [weak self] in
                    self?.pinClipboard()
                },
                .init(title: String(localized: "Pin Image…")) { [weak self] in self?.choosePicturesToPin() },
                .init(
                    title: String(localized: "Hide Pins"),
                    isEnabled: { [weak self] in !(self?.pins.isEmpty ?? true) },
                    currentTitle: { [weak self] in self?.pins.areHidden == true ? String(localized: "Show Pins") : String(localized: "Hide Pins") }
                ) { [weak self] in
                    guard let self else { return }
                    pins.setHidden(!pins.areHidden)
                },
                .init(
                    title: String(localized: "Unlock Pins"),
                    isEnabled: { [weak self] in self?.pins.hasLockedPins ?? false }
                ) { [weak self] in
                    self?.pins.unlockAll()
                },
                .init(
                    title: String(localized: "Close All Pins"),
                    isEnabled: { [weak self] in !(self?.pins.isEmpty ?? true) }
                ) { [weak self] in
                    self?.pins.closeAll()
                },
            ],
            historyEntries: [
                .init(title: String(localized: "Annotate Image…")) { [weak self] in self?.chooseFilesToAnnotate() },
                .init(title: String(localized: "Capture History…"), shortcut: .openHistory) { [weak self] in self?.showHistory() },
                .init(
                    title: String(localized: "Restore Recently Closed"),
                    isEnabled: { [weak self] in self?.quickAccess.canRestoreRecentlyClosed ?? false }
                ) { [weak self] in
                    self?.quickAccess.restoreRecentlyClosed()
                },
            ],
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            debugEntries: debugMenuEntries()
        )
        statusItem.onDrop = { [weak self] pasteboard in
            self?.textCapture.openPanel(from: pasteboard, source: String(localized: "Dropped Image")) ?? false
        }
        self.statusItem = statusItem
        automation = makeAutomationController()

        hotkeys.installDefaultShortcutsIfNeeded()
        hotkeys.activate { [weak self] shortcut in
            self?.handle(shortcut)
        }

        let settings = settings
        observations.append(Task { [weak self] in
            for await format in Observations({ settings.colorFormat }) {
                // Every overlay's magnifier reads in it, not only Pick Color's: C copies it while capturing.
                self?.overlay.colorFormat = format
            }
        })
        observations.append(Task { [weak statusItem] in
            for await visible in Observations({ settings.showMenuBarIcon }) {
                statusItem?.setVisible(visible)
            }
        })
        // Also runs once now, which is the launch-time cleanup.
        observations.append(Task { [weak self] in
            for await _ in Observations({ settings.historyRetention }) {
                self?.removeExpiredHistory()
            }
        })
        observations.append(Task { [weak self] in
            for await _ in Observations({ "\(settings.pinCornerRadius) \(settings.pinShadow) \(settings.pinBorder)" }) {
                self?.pins.appearanceChanged()
            }
        })

        captures.onCaptured = { [weak self] item in
            self?.didCapture(item)
        }
        captures.openInEditor = { [weak self] entry, scale in
            self?.annotations.annotate(entry, scale: scale)
        }
        captures.onColor = { [weak self] color, point, modifiers, keyboard in
            self?.colorPicker.deliver(color, at: point, modifiers: modifiers, keyboard: keyboard)
        }
        colorPicker.pin = { [weak self] color in
            guard let pinned = PinColor(color.cgColor) else { return NSSound.beep() }
            self?.pins.pin(color: pinned)
        }
        captures.selfTimerKeys = { [weak self] in
            self?.hotkeys.keys(for: .selfTimer)
        }
        captures.onPin = { [weak self] frame, entry in
            guard let self else { return }
            // A window captured with its shadow is larger than its frame: the scale is its display's.
            let scale = displays.layout.display(id: frame.displayID)?.pixelsPerPoint ?? frame.pixelsPerPoint
            pins.pin(frame.image, scale: scale, origin: entry.map { .capture($0.id) } ?? .clipboard, over: frame.frame)
        }
        // Pins are in new captures as they are on screen (Settings can leave them out); a pin just opened
        // is fetched into the capturable content at once, so the next capture has it.
        capturer.includedWindowIDs = { [weak self] in self?.pins.capturedWindowIDs ?? [] }
        pins.onChange = { [weak self] in self?.shareableContent.refresh() }
        annotations.onChange = { [weak self] entry, data in
            self?.pictureChanged(entry, data: data)
        }
        annotations.saveCopy = { [weak self] entry, file in
            guard let self, let saved = captures.save(fileAt: file) else { return nil }
            quickAccess.markSaved(entry.id, at: saved)
            return saved
        }
        annotations.saveFile = { [weak self] file in
            self?.captures.save(fileAt: file)
        }

        displays.onChange = { [weak self] _ in
            guard let self else { return }
            shareableContent.refresh()
            overlay.cancel()
            captures.cancelSelfTimer()
            overlay.prepare()
        }

        logStartup()
        permissions.refresh([.screenRecording])
        if permissions.status(of: .screenRecording) == .granted {
            // Built and fetched once now so the first capture does not pay for them. The panels come
            // first: the app is listed in the shareable content only once it has windows.
            overlay.prepare()
            shareableContent.refresh()
        } else {
            showOnboarding()
        }
    }

    /// Keeps edits still open in the editor before the app quits.
    func prepareForTermination() {
        annotations.keepAll()
    }

    func handle(url: URL, senderPID: pid_t?) {
        automation?.handle(url, senderPID: senderPID)
    }

    func showSettings(_ tab: SettingsTab = .general) {
        let controller = settingsWindow ?? makeSettingsWindow()
        settingsWindow = controller
        controller.show(tab)
    }

    func showHistory() {
        let controller = historyWindow ?? makeHistoryWindow()
        historyWindow = controller
        controller.show()
    }

    func showOnboarding() {
        let controller = onboardingWindow ?? OnboardingWindowController(
            permissions: permissions,
            relaunch: { Relauncher.relaunch() }
        )
        controller.onClose = { [weak self] in
            // Released on the next turn so the window is not deallocated inside its own delegate call.
            Task { @MainActor in
                self?.onboardingWindow = nil
                MemoryRelief.returnFreedPages()
            }
        }
        onboardingWindow = controller
        controller.show()
    }

    // MARK: - Commands

    private func handle(_ shortcut: CaptureShortcut) {
        Log.signposter.emitEvent("hotkey")
        Log.hotkeys.notice("hotkey.\(shortcut.rawValue, privacy: .public)")
        switch shortcut {
        case .openHistory:
            showHistory()
            return
        case .copyLatestCapture:
            quickAccess.copyLatest()
            return
        default:
            break
        }
        guard permissions.status(of: .screenRecording) == .granted else {
            showOnboarding()
            return
        }
        switch shortcut {
        case .captureArea, .allInOne:
            captures.captureArea()
        case .annotateArea:
            captures.annotateArea()
        case .pinArea:
            captures.pinArea()
        case .captureFullscreen:
            captures.captureFullscreen()
        case .captureWindow:
            captures.captureWindow()
        case .selfTimer:
            captures.selfTimer()
        case .captureText:
            captures.cancelSelfTimer()
            textCapture.captureText(joinLines: false)
        case .captureTextJoined:
            captures.cancelSelfTimer()
            textCapture.captureText(joinLines: true)
        case .translateArea:
            captures.cancelSelfTimer()
            textCapture.translateArea()
        case .pickColor:
            captures.cancelSelfTimer()
            colorPicker.pickColor()
        case .measure:
            captures.cancelSelfTimer()
            measurer.measure()
        default:
            Log.hotkeys.notice("Not available yet: \(shortcut.rawValue, privacy: .public)")
        }
    }

    private func perform(_ command: AutomationCommand) {
        switch command {
        case .openSettings(let tab):
            showSettings(SettingsTab(urlTab: tab))
        case .captureArea(let region, .pin) where region.rect == nil:
            guard permissions.status(of: .screenRecording) == .granted else {
                showOnboarding()
                return
            }
            captures.pinArea()
        case .pin(let file):
            if let file { pin(fileAt: file) } else { pinClipboard() }
        case .captureArea(let region, _) where region.rect == nil:
            captures.captureArea()
        case .allInOne(let region) where region.rect == nil:
            captures.captureArea()
        case .captureFullscreen:
            captures.captureFullscreen()
        case .captureWindow:
            captures.captureWindow()
        case .selfTimer:
            guard permissions.status(of: .screenRecording) == .granted else {
                showOnboarding()
                return
            }
            captures.selfTimer()
        case .captureText(nil, let region, let lineBreaks) where region.rect == nil:
            guard permissions.status(of: .screenRecording) == .granted else {
                showOnboarding()
                return
            }
            captures.cancelSelfTimer()
            textCapture.captureText(joinLines: lineBreaks == false)
        case .openHistory:
            showHistory()
        case .restoreRecentlyClosed:
            quickAccess.restoreRecentlyClosed()
        default:
            Log.automation.notice("Not available yet: \(String(describing: command), privacy: .public)")
        }
    }

    // MARK: - Quick Access and history

    private func didCapture(_ item: QuickAccessItem) {
        if settings.showQuickAccess {
            quickAccess.add(item)
        } else if settings.historyRetention == .never, let entry = history.item(id: item.id) {
            // Nothing else holds on to it: it already went to the clipboard or the export folder.
            history.delete(entry)
        }
        removeExpiredHistory()
    }

    /// A capture's picture changed in the editor: its card and its History thumbnail follow.
    private func pictureChanged(_ entry: HistoryItem, data: Data) {
        Task {
            if let card = quickAccess.item(entry.id), let thumbnail = await HistoryStore.thumbnail(of: data, maxPixels: 560) {
                quickAccess.update(QuickAccessItem(
                    id: entry.id,
                    kind: entry.kind,
                    fileURL: history.fileURL(for: entry),
                    thumbnail: thumbnail,
                    pixelWidth: entry.pixelWidth,
                    pixelHeight: entry.pixelHeight,
                    displayID: card.displayID,
                    createdAt: entry.createdAt,
                    savedURL: card.savedURL
                ))
            }
            historyWindow?.reload(changed: [entry.id])
        }
    }

    // MARK: Opening files

    /// Opens files in the editor: projects as they are; pictures are added to the history first, so
    /// their marks are kept and stay editable like a capture's.
    func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            if url.pathExtension.lowercased() == AnnotationProject.fileExtension {
                annotations.openProject(at: url)
            } else if ImageLoader.canLoad(url) {
                Task { await annotateImage(at: url) }
            }
        }
    }

    /// Chooses pictures or projects to open in the editor.
    private func chooseFilesToAnnotate() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image, AnnotationProject.contentType]
        chooser.allowsMultipleSelection = true
        chooser.message = String(localized: "Choose a picture to mark up, or a project to go on with.")
        chooser.prompt = String(localized: "Annotate")
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(chooser.urls)
        }
    }

    private func annotateImage(at url: URL) async {
        guard let loaded = await Self.loadImage(url) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to annotate it")
            NSSound.beep()
            return
        }
        await annotate(image: loaded.image, scale: loaded.scale, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Opens a picture with no capture of its own in the editor, added to the history first so its marks
    /// are kept like a capture's.
    private func annotate(image: CGImage, scale: CGFloat, name: String) async {
        do {
            let png = try await ImageExporter.encode(image, as: .png)
            let entry = try history.add(
                data: png, name: name, fileExtension: ImageExporter.Format.png.fileExtension,
                kind: .screenshot, pixelWidth: image.width, pixelHeight: image.height, appName: nil
            )
            historyWindow?.reload()
            annotations.annotate(entry, scale: scale)
        } catch {
            Log.capture.error("Adding \(name, privacy: .public) to the history failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// What a redaction suggestion's kind is called in its tooltip.
    nonisolated static func label(for kind: SensitiveText.Kind) -> String {
        switch kind {
        case .email: String(localized: "Email address")
        case .phone: String(localized: "Phone number")
        case .card: String(localized: "Card number")
        case .idNumber: String(localized: "ID number")
        case .secret: String(localized: "Key or token")
        case .ipAddress: String(localized: "IP address")
        case .password: String(localized: "Password")
        case .address: String(localized: "Address")
        case .name: String(localized: "Name")
        }
    }

    // MARK: Pins

    /// What a picture pin's menu does; text and color pins copy their own values.
    private func makePinActions() -> PinController.Actions {
        PinController.Actions(
            copy: { pin in
                guard case .image(let image, _) = pin.content else { return }
                Task {
                    guard let png = try? await ImageExporter.encode(image, as: .png) else { return NSSound.beep() }
                    PasteboardWriter.write(png: png, image: image)
                }
            },
            save: { [weak self] pin in
                guard let self, case .image(let image, _) = pin.content else { return }
                if case .capture(let id) = pin.origin, let entry = history.item(id: id) {
                    _ = captures.save(fileAt: history.fileURL(for: entry))
                } else {
                    Task { _ = await self.captures.save(image: image) }
                }
            },
            saveAs: { [weak self] pin in self?.savePinAs(pin) },
            annotate: { [weak self] pin in
                guard let self, case .image(let image, let scale) = pin.content else { return }
                if case .capture(let id) = pin.origin, let entry = history.item(id: id) {
                    annotations.annotate(entry, scale: scale)
                } else {
                    Task { await self.annotate(image: image, scale: scale, name: String(localized: "Pin")) }
                }
            },
            recognizeText: { [weak self] pin in
                guard case .image(let image, let scale) = pin.content else { return }
                self?.textCapture.openPanel(image: image, scale: scale, source: String(localized: "Pin"))
            }
        )
    }

    /// Whether the clipboard may hold something to pin, judged by its types alone: reading the types
    /// never asks for clipboard access, reading the contents may.
    private static func clipboardMayHoldPin() -> Bool {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types else { return false }
        return PasteboardImage.mayHoldImage(pasteboard) || types.contains(.string) || types.contains(.color)
    }

    /// Pins what the clipboard holds: a picture first, then a color (a color, or text that is exactly a
    /// color's value), then text. Beeps when there is nothing to pin.
    private func pinClipboard() {
        let pasteboard = NSPasteboard.general
        let scale = displays.layout.display(at: NSEvent.mouseLocation)?.pixelsPerPoint ?? 2
        switch PasteboardImage.read(pasteboard) {
        case .file(let url):
            return pin(fileAt: url, fallbackScale: scale)
        case .data(let data):
            guard let loaded = ImageLoader.load(data: data, fallbackScale: scale) else { return NSSound.beep() }
            pins.pin(loaded.image, scale: loaded.scale, origin: .clipboard)
            return
        case nil:
            break
        }
        // A copied file that is not a picture brings its name along as text: that is not what was meant.
        if pasteboard.types?.contains(.fileURL) == true { return NSSound.beep() }
        if let color = NSColor(from: pasteboard).flatMap({ PinColor($0.cgColor) }) {
            pins.pin(color: color)
        } else if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let color = PinColor.parse(text) { pins.pin(color: color) } else { pins.pin(text: text) }
        } else {
            NSSound.beep()
        }
    }

    /// Pins a picture file; `origin` says when it is a capture's. A file with no resolution of its own is
    /// taken at `fallbackScale`, its display's for a capture.
    private func pin(fileAt url: URL, origin: PinController.Origin? = nil, fallbackScale: CGFloat = 2) {
        Task {
            guard let loaded = await Self.loadImage(url, fallbackScale: fallbackScale) else {
                Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to pin it")
                return NSSound.beep()
            }
            pins.pin(loaded.image, scale: loaded.scale, origin: origin ?? .file(url))
        }
    }

    private func choosePicturesToPin() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image]
        chooser.allowsMultipleSelection = true
        chooser.message = String(localized: "Choose pictures to keep on screen.")
        chooser.prompt = String(localized: "Pin")
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard response == .OK else { return }
            for url in chooser.urls { self?.pin(fileAt: url) }
        }
    }

    private func savePinAs(_ pin: PinController.Pin) {
        guard case .image(let image, _) = pin.content else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FilenameTemplate.standard.name(date: .now, appName: nil) + "." + ImageExporter.Format.png.fileExtension
        panel.directoryURL = settings.exportDirectory
        panel.allowedContentTypes = [.png]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await ImageExporter.encode(image, as: .png).write(to: url)
            } catch {
                Log.capture.error("Save As failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    /// Decodes off the main actor: a large photo takes a while.
    @concurrent private nonisolated static func loadImage(_ url: URL, fallbackScale: CGFloat = 1) async -> ImageLoader.Loaded? {
        ImageLoader.load(contentsOf: url, fallbackScale: fallbackScale)
    }

    /// Opens a capture in the annotation editor; `displayID` is the screen it came from, for its scale.
    private func annotate(_ entry: HistoryItem, displayID: CGDirectDisplayID?) {
        let layout = displays.layout
        // The display a history capture came from is not recorded; most come from the sharpest.
        let scale = displayID.flatMap { layout.display(id: $0)?.pixelsPerPoint } ?? layout.displays.map(\.pixelsPerPoint).max() ?? 1
        annotations.annotate(entry, scale: scale)
    }

    private func removeExpiredHistory() {
        let removed = history.removeExpired(retention: settings.historyRetention, keeping: quickAccess.itemIDs.union(annotations.openCaptureIDs))
        if removed > 0 {
            Log.capture.notice("Removed \(removed, privacy: .public) expired capture(s) from the history")
        }
        historyWindow?.reload()
    }

    private func makeQuickAccessActions() -> QuickAccessController.Actions {
        QuickAccessController.Actions(
            copy: { item in CaptureFiles.copy(item.fileURL) },
            save: { [weak self] item in self?.captures.save(item) },
            saveAs: { [weak self] item in self?.captures.saveAs(item) },
            open: { item in NSWorkspace.shared.open(item.fileURL) },
            annotate: { [weak self] item in
                guard let self, let entry = history.item(id: item.id) else { return }
                annotate(entry, displayID: item.displayID)
            },
            reveal: { item in NSWorkspace.shared.activateFileViewerSelecting([item.savedURL ?? item.fileURL]) },
            recognizeText: { [weak self] item in
                guard let self else { return }
                // Captures are saved without a resolution, so the scale is their display's.
                let scale = displays.layout.display(id: item.displayID)?.pixelsPerPoint ?? 1
                Task { await self.textCapture.openPanel(forFileAt: item.fileURL, fallbackScale: scale) }
            },
            pin: { [weak self] item in
                guard let self else { return }
                let scale = displays.layout.display(id: item.displayID)?.pixelsPerPoint ?? 2
                pin(fileAt: item.fileURL, origin: .capture(item.id), fallbackScale: scale)
            },
            moveToTrash: { [weak self] item in
                guard let self else { return }
                // As in CleanShot, the capture goes as a whole: the copy this card saved goes to the Trash
                // with it. Both can be put back from the Trash.
                if let saved = item.savedURL {
                    try? FileManager.default.trashItem(at: saved, resultingItemURL: nil)
                }
                if let entry = history.item(id: item.id) {
                    history.moveToTrash(entry)
                }
                historyWindow?.reload()
            },
            closed: { [weak self] item in
                // With history off, a capture lives only as long as its card, or its editor.
                guard
                    let self, settings.historyRetention == .never, !annotations.openCaptureIDs.contains(item.id),
                    let entry = history.item(id: item.id)
                else { return }
                history.delete(entry)
            }
        )
    }

    /// How many captures a retention would delete now; captures still on screen as cards are kept.
    private func expiredCount(for retention: HistoryRetention) -> Int {
        history.expired(retention: retention, keeping: quickAccess.itemIDs.union(annotations.openCaptureIDs)).count
    }

    private func makeHistoryWindow() -> HistoryWindowController {
        let controller = HistoryWindowController(store: history, settings: settings, actions: HistoryActions(
            restore: { [weak self] entry in Task { await self?.restore(entry) } },
            copy: { [weak self] entry in
                guard let self else { return }
                CaptureFiles.copy(history.fileURL(for: entry))
            },
            save: { [weak self] entry in
                guard let self else { return }
                Task {
                    guard let item = await self.quickAccessItem(for: entry) else { return }
                    if let url = self.captures.save(item) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            },
            open: { [weak self] entry in
                guard let self else { return }
                NSWorkspace.shared.open(history.fileURL(for: entry))
            },
            annotate: { [weak self] entry in
                self?.annotate(entry, displayID: self?.quickAccess.item(entry.id)?.displayID)
            },
            reveal: { [weak self] entry in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([history.fileURL(for: entry)])
            },
            recognizeText: { [weak self] entry in
                guard let self else { return }
                // The display a capture came from is not recorded; most captures come from the sharpest.
                let scale = displays.layout.displays.map(\.pixelsPerPoint).max() ?? 1
                Task { await self.textCapture.openPanel(forFileAt: self.history.fileURL(for: entry), fallbackScale: scale) }
            },
            pin: { [weak self] entry in
                guard let self else { return }
                let scale = displays.layout.displays.map(\.pixelsPerPoint).max() ?? 2
                pin(fileAt: history.fileURL(for: entry), origin: .capture(entry.id), fallbackScale: scale)
            },
            moveToTrash: { [weak self] entry in
                self?.quickAccess.remove(entry.id)
                self?.history.moveToTrash(entry)
            }
        ), expiredCount: { [weak self] retention in self?.expiredCount(for: retention) ?? 0 })
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.historyWindow = nil
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    /// Brings a history item back as a Quick Access card.
    private func restore(_ entry: HistoryItem) async {
        guard let item = await quickAccessItem(for: entry) else { return }
        quickAccess.add(item)
    }

    private func quickAccessItem(for entry: HistoryItem) async -> QuickAccessItem? {
        let url = history.fileURL(for: entry)
        guard let thumbnail = await HistoryStore.thumbnail(of: url, maxPixels: 560) else { return nil }
        let layout = displays.layout
        let displayID = layout.display(at: NSEvent.mouseLocation)?.id ?? layout.primary?.id ?? 0
        return QuickAccessItem(
            id: entry.id,
            kind: entry.kind,
            fileURL: url,
            thumbnail: thumbnail,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight,
            displayID: displayID,
            createdAt: entry.createdAt
        )
    }

    // MARK: - Wiring

    private func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController(dependencies: SettingsDependencies(
            settings: settings,
            permissions: permissions,
            urlScheme: urlScheme,
            relaunch: { Relauncher.relaunch() },
            openHistory: { [weak self] in self?.showHistory() },
            expiredCount: { [weak self] retention in self?.expiredCount(for: retention) ?? 0 },
            backgrounds: SettingsDependencies.Backgrounds(
                presets: { BackdropPresets.shared.all.map { SettingsDependencies.Backgrounds.Choice(id: $0.id, name: $0.name) } },
                automatic: { BackdropPresets.shared.automatic?.id },
                setAutomatic: { BackdropPresets.shared.setAutomatic($0) }
            )
        ))
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.settingsWindow = nil
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    private func makeAutomationController() -> AutomationController {
        #if DEBUG
        let hooks = makeDebugHooks()
        #endif
        return AutomationController(scheme: urlScheme, settings: settings) { [weak self] command in
            self?.perform(command)
        } debugHandler: { url in
            #if DEBUG
            hooks.handle(url)
            return true
            #else
            return false
            #endif
        }
    }

    private func debugMenuEntries() -> [StatusItemController.Entry] {
        #if DEBUG
        let hooks = makeDebugHooks()
        return [
            .init(title: "Log Displays") { hooks.logDisplays() },
            .init(title: "Log Active Resources") { hooks.logResources() },
            .init(title: "Show Onboarding") { [weak self] in self?.showOnboarding() },
            .init(title: "Relaunch") { Relauncher.relaunch() },
        ]
        #else
        return []
        #endif
    }

    #if DEBUG
    private func makeDebugHooks() -> DebugHooks {
        DebugHooks(
            displays: displays,
            permissions: permissions,
            capturer: capturer,
            overlay: overlay,
            captures: captures,
            quickAccess: quickAccess,
            showSettings: { [weak self] tab in self?.showSettings(tab) },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            showHistory: { [weak self] in self?.showHistory() },
            restoreLatestFromHistory: { [weak self] in
                guard let self, let entry = history.items().first else { return }
                Task { await self.restore(entry) }
            },
            annotateLatestFromHistory: { [weak self] in
                guard let self, let entry = history.items().first else { return }
                annotate(entry, displayID: nil)
            },
            deleteLatestFromHistory: { [weak self] in
                guard let self, let entry = history.items().first else { return }
                quickAccess.remove(entry.id)
                history.delete(entry)
                historyWindow?.reload()
            },
            setRetention: { [weak self] retention in self?.settings.historyRetention = retention },
            historyWindow: { [weak self] in self?.historyWindow?.window },
            historyCount: { [weak self] in self?.history.items().count ?? 0 },
            latestCaptureFile: { [weak self] in
                guard let self, let entry = history.items().first else { return nil }
                return history.fileURL(for: entry)
            },
            previewRetentionChange: { [weak self] retention in self?.historyWindow?.previewRetentionChange(to: retention) },
            textCapture: textCapture,
            annotations: annotations,
            pins: pins,
            colorPicker: colorPicker,
            measurer: measurer,
            settings: settings
        )
    }
    #endif

    private func logStartup() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        Log.app.notice("Started \(Log.subsystem, privacy: .public) \(version, privacy: .public) (\(build, privacy: .public)), \(self.displays.layout.displays.count, privacy: .public) display(s), URL scheme \(self.urlScheme, privacy: .public)")
    }
}

private extension SettingsTab {
    /// Maps CleanShot's `open-settings?tab=` names onto ours.
    init(urlTab: String?) {
        switch urlTab?.lowercased() {
        case "screenshots", "quickaccess": self = .capture
        case "shortcuts": self = .shortcuts
        case "advanced": self = .automation
        case "about": self = .about
        default: self = .general
        }
    }
}

/// File actions on captures.
enum CaptureFiles {
    /// Copies a capture's image. Image only, no file: some apps paste a file reference instead of the
    /// picture when both are offered.
    static func copy(_ url: URL) {
        guard
            let data = try? Data(contentsOf: url),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to copy it")
            return
        }
        PasteboardWriter.write(png: data, image: image)
    }
}
