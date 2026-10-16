import AppKit
import Foundation
import ImageIO
import Observation
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSRecording
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
    /// Uploads to the user's own storage; idle unless one is in flight.
    private lazy var uploads: UploadCoordinator = {
        let uploads = UploadCoordinator(settings: settings, quickAccess: quickAccess)
        uploads.restoreCard = { [weak self] id in
            guard let self, let entry = history.item(id: id) else { return }
            Task { await self.restore(entry) }
        }
        uploads.ended = { [weak self] id, outcome in self?.uploadEnded(id, outcome) }
        return uploads
    }()
    private lazy var textCapture = TextCaptureCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay)
    private lazy var annotations = AnnotationCoordinator(history: history)
    /// Reads the text in the history's screenshots for its search, in the text reader beside the app.
    private lazy var textReader: HistoryTextReader = {
        let reader = HistoryTextReader(store: history, helper: Bundle.main.url(forAuxiliaryExecutable: "OhMyShot Text Reader"))
        reader.onRead = { [weak self] id in self?.historyWindow?.textRead(id) }
        return reader
    }()
    private lazy var pins = PinController(settings: settings, actions: makePinActions())
    private lazy var colorPicker = ColorPickerCoordinator(settings: settings, overlay: overlay)
    private lazy var measurer = MeasureCoordinator(settings: settings, overlay: overlay, colorPicker: colorPicker)
    private lazy var recordings = RecordingCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay, history: history, permissions: permissions)
    private lazy var scrolling = ScrollingCaptureCoordinator(displays: displays, capturer: capturer, overlay: overlay, permissions: permissions, captures: captures)
    /// Hide Desktop Icons: nothing exists unless the icons are hidden.
    private lazy var desktopIcons: DesktopCover = {
        let cover = DesktopCover(topology: displays, capturer: capturer)
        cover.onChange = { [weak self] in self?.shareableContent.refresh() }
        cover.canReadScreen = { [weak self] in self?.permissions.status(of: .screenRecording) == .granted }
        return cover
    }()
    /// The replay (macOS 27), kept as any object: a stored property can't be of a type this macOS may lack.
    private var replayStorage: AnyObject?
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
        // As Finder draws it, at the largest size anything of the app shows it (About, alerts): AppKit keeps a
        // snapshot of it at this size.
        let icon = AppActivation.appIcon
        icon.size = NSSize(width: 128, height: 128)
        NSApp.applicationIconImage = icon
        // A capture's text, read on this Mac for the annotation tools, one reading for both: the redaction
        // tool's suggestions, what reading finds better covered, and the lines of text the highlighter snaps
        // to, where they lie, never what they say.
        AnnotationSession.readText = { image in
            let recognition = TextRecognition(image)
            return CaptureReading(
                redactionSuggestions: {
                    let probe = LatencyProbe("annotate.redactions")
                    defer { probe.end() }
                    do {
                        let found = try await SensitiveTextScanner().scan(recognition)
                        Log.app.notice("Redaction suggestions: \(found.count, privacy: .public) found")
                        return found.map { RedactionSuggestion(rect: $0.box, label: Self.label(for: $0.kind)) }
                    } catch {
                        Self.logUnread("Redaction suggestions", error)
                        throw error
                    }
                },
                textLines: {
                    let probe = LatencyProbe("annotate.textlines")
                    defer { probe.end() }
                    do {
                        let lines = try await TextLineReader().read(recognition)
                        Log.app.notice("Text lines: \(lines.count, privacy: .public) found")
                        return lines.map { TextLine(rect: $0.box, words: $0.words) }
                    } catch {
                        Self.logUnread("Text lines", error)
                        throw error
                    }
                }
            )
        }
        if #available(macOS 27, *) {
            replayStorage = ReplayCoordinator(settings: settings, displays: displays, capturer: capturer, permissions: permissions, recordings: recordings)
        }
        let statusItem = StatusItemController(
            captureEntries: [
                .init(title: String(localized: "All-In-One"), shortcut: .allInOne) { [weak self] in self?.handle(.allInOne) },
                .init(title: String(localized: "Capture Area"), shortcut: .captureArea) { [weak self] in self?.handle(.captureArea) },
                .init(title: String(localized: "Annotate Area"), shortcut: .annotateArea) { [weak self] in self?.handle(.annotateArea) },
                .init(title: String(localized: "Capture Area and Pin"), shortcut: .pinArea) { [weak self] in self?.handle(.pinArea) },
                .init(
                    title: String(localized: "Capture Area and Upload"),
                    shortcut: .captureAreaAndUpload,
                    isHidden: { [weak self] in self?.uploads.destinations.menu.isHidden != false }
                ) { [weak self] in self?.handle(.captureAreaAndUpload) },
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
                .init(
                    title: String(localized: "Scrolling Capture"),
                    shortcut: .scrollingCapture,
                    currentTitle: { [weak self] in self?.scrolling.menuTitle ?? String(localized: "Scrolling Capture") }
                ) { [weak self] in
                    self?.handle(.scrollingCapture)
                },
                .init(
                    title: String(localized: "Cancel Scrolling Capture"),
                    isHidden: { [weak self] in self?.scrolling.isCapturing != true }
                ) { [weak self] in
                    self?.scrolling.cancel()
                },
                .init(
                    title: String(localized: "Record Screen"),
                    shortcut: .recordScreen,
                    currentTitle: { [weak self] in
                        guard let self else { return String(localized: "Record Screen") }
                        if recordings.isRecording { return String(localized: "Stop Recording") }
                        if recordings.isCountingDown { return String(localized: "Cancel Recording") }
                        return String(localized: "Record Screen")
                    }
                ) { [weak self] in
                    self?.handle(.recordScreen)
                },
                // While a Studio movie is exported after its window closed, it can be stopped from here.
                .init(
                    title: String(localized: "Cancel Studio Export"),
                    isHidden: { [weak self] in self?.recordings.isExportingStudio != true }
                ) { [weak self] in
                    self?.recordings.cancelStudioExports()
                },
            ] + replayEntries() + [
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
                .init(
                    title: String(localized: "Hide Desktop Icons"),
                    currentTitle: { [weak self] in
                        self?.settings.hidesDesktopIcons == true ? String(localized: "Show Desktop Icons") : String(localized: "Hide Desktop Icons")
                    }
                ) { [weak self] in
                    guard let self else { return }
                    setDesktopIconsHidden(!settings.hidesDesktopIcons)
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
        recordings.onRecorded = { [weak self] item in
            self?.didCapture(item)
        }
        captures.uploadKept = { [weak self] entry in self?.uploadKept(entry) }
        recordings.uploadKept = { [weak self] entry in self?.uploadKept(entry) }
        recordings.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .recording(let time, let paused):
                self.statusItem?.showRecording(elapsed: time, paused: paused) { [weak self] in self?.recordings.stop() }
            case .makingGIF(let progress):
                self.statusItem?.showProgress(progress)
            case .exportingStudio(let progress):
                self.statusItem?.showProgress(progress, symbolName: "wand.and.sparkles")
            case .idle:
                self.statusItem?.endRecording()
            }
        }
        recordings.save = { [weak self] url in
            self?.captures.save(fileAt: url)
        }
        recordings.copyFile = { url in
            CaptureFiles.copy(url)
        }
        recordings.onChanged = { [weak self] entry in
            self?.recordingChanged(entry)
        }
        recordings.shortcutKeys = { [weak self] in
            self?.hotkeys.keys(for: .recordScreen)
        }
        captures.openInEditor = { [weak self] entry, scale in
            self?.annotations.annotate(entry, scale: scale)
        }
        // All-In-One hands on what it does not do itself.
        captures.allInOneText = { [weak self] area, frozen in
            Task { await self?.textCapture.recognize(region: area, frozen: frozen, joinLines: false) }
        }
        captures.allInOneScroll = { [weak self] area in self?.scrolling.begin(area: area, starts: true) }
        captures.onRecord = { [weak self] target, display, choices, app in
            self?.recordings.record(target, on: display, choices: choices, appName: app)
        }
        captures.recordingSetupCancelled = { [weak self] in self?.recordings.recordingSetupCancelled() }
        captures.canUpload = { [weak self] in self?.uploads.destinations.defaultDestination != nil }
        captures.onColor = { [weak self] color, point, modifiers, keyboard in
            self?.colorPicker.deliver(color, at: point, modifiers: modifiers, keyboard: keyboard)
        }
        colorPicker.pin = { [weak self] color in
            guard let pinned = PinColor(color.cgColor) else { return NSSound.beep() }
            self?.pins.pin(color: pinned)
        }
        scrolling.doneKeys = { [weak self] in
            self?.hotkeys.keys(for: .scrollingCapture)
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
        capturer.includedWindowIDs = { [weak self] in
            guard let self else { return Self.standardWindowIDs() }
            // The cover over the desktop icons too: a capture shows the desktop as it looks.
            let covers = settings.hidesDesktopIcons ? desktopIcons.windowIDs : []
            return pins.capturedWindowIDs.union(Self.standardWindowIDs()).union(covers)
        }
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
            quickAccess.displaysChanged()
            if settings.hidesDesktopIcons { desktopIcons.refresh() }
        }

        logStartup()
        // What a crash or a forced quit left of a recording is finished and kept.
        recordings.recoverLeftovers()
        permissions.refresh([.screenRecording])
        // After the permission is known: without it the cover draws the wallpaper's file, never asking for the screen.
        if settings.hidesDesktopIcons { desktopIcons.setShown(true) }
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
        textReader.stop()
    }

    /// Stops a recording and keeps it before the app quits, and the replay's buffers once the clips being
    /// saved are kept; `done` runs once all of it is. False when nothing needed waiting for.
    func finishRecordingBeforeQuitting(_ done: @escaping () -> Void) -> Bool {
        var waiting = 1
        let finished = {
            waiting -= 1
            if waiting == 0 { done() }
        }
        if recordings.finishBeforeQuitting(finished) { waiting += 1 }
        // An upload still going is cancelled, and quitting waits until its transfer has stopped and cleaned up.
        if uploads.cancelAll(then: finished) { waiting += 1 }
        if #available(macOS 27, *), replay?.finishBeforeQuitting(finished) == true { waiting += 1 }
        // The count's own share: what still waits calls `done` when it ends.
        waiting -= 1
        return waiting > 0
    }

    @available(macOS 27, *)
    private var replay: ReplayCoordinator? {
        replayStorage as? ReplayCoordinator
    }

    /// The replay's menu bar entries: the displays to keep (with how saved clips sound), and Save.
    private func replayEntries() -> [StatusItemController.Entry] {
        guard #available(macOS 27, *), replay != nil else { return [] }
        return [
            .init(title: String(localized: "Keep Last 15 Seconds")) { [weak self] in self?.replayMenu() ?? [] },
            .init(
                title: String(localized: "Save Last 15 Seconds"), shortcut: .saveReplay,
                isEnabled: { [weak self] in self?.replay?.canSave == true }
            ) { [weak self] in
                self?.handle(.saveReplay)
            },
        ]
    }

    /// The replay's submenu, made each time it opens: a checkmark for each display kept, then the sound
    /// saved clips keep.
    @available(macOS 27, *)
    private func replayMenu() -> [StatusItemController.Entry] {
        guard let replay else { return [] }
        var entries: [StatusItemController.Entry] = [.header(String(localized: "Displays"))]
        for display in displays.layout.displays {
            entries.append(.init(title: display.name, isChecked: { [weak replay] in replay?.isKeeping(display.id) == true }) { [weak self, weak replay] in
                guard self?.permissions.status(of: .screenRecording) == .granted else {
                    self?.showOnboarding()
                    return
                }
                replay?.toggle(display)
            })
        }
        entries.append(.separator)
        entries.append(.header(String(localized: "Sound in Saved Clips")))
        for sound in ReplaySound.allCases {
            let title = switch sound {
            case .all: String(localized: "System and Microphone")
            case .system: String(localized: "System Only")
            case .microphone: String(localized: "Microphone Only")
            case .none: String(localized: "No Sound")
            }
            // Without microphone access only the system's sound is kept: the choices with the microphone
            // step back, their check kept for when access comes back.
            let needsMicrophone = sound.keepsMicrophone
            entries.append(.init(
                title: title,
                isEnabled: { [weak self] in !needsMicrophone || self?.permissions.status(of: .microphone) != .denied },
                isChecked: { [weak self] in self?.settings.replaySound == sound }
            ) { [weak self] in
                self?.settings.replaySound = sound
            })
        }
        return entries
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
        // Its search waits on captures not read yet, Low Power Mode or not; with history off they leave with
        // their cards.
        if settings.historyRetention != .never { textReader.readNow() }
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
        case .captureArea:
            captures.captureArea()
        case .allInOne:
            captures.allInOne()
        case .annotateArea:
            captures.annotateArea()
        case .pinArea:
            captures.pinArea()
        case .captureFullscreen:
            captures.captureFullscreen()
        case .captureAreaAndUpload:
            guard let followUp = followUp(for: .upload) else { return }
            captures.captureArea(followUp: followUp)
        case .captureFullscreenAndUpload:
            guard let followUp = followUp(for: .upload) else { return }
            captures.captureFullscreen(followUp: followUp)
        case .captureWindow:
            captures.captureWindow()
        case .selfTimer:
            captures.selfTimer()
        case .capturePreviousArea:
            captures.capturePreviousArea()
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
        case .recordScreen:
            captures.cancelSelfTimer()
            recordings.recordScreen()
        case .saveReplay:
            if #available(macOS 27, *) { replay?.save() }
        case .scrollingCapture:
            scrolling.begin()
        default:
            Log.hotkeys.notice("Not available yet: \(shortcut.rawValue, privacy: .public)")
        }
    }

    /// Runs a URL API command from an approved caller, as CleanShot X runs it under the same name and parameters.
    private func perform(_ command: AutomationCommand) {
        if command.readsScreen, permissions.status(of: .screenRecording) != .granted { return showOnboarding() }
        switch command {
        case .allInOne(let region):
            guard let area = area(of: region) else { return }
            captures.allInOne(choosing: area)
        case .captureArea(let region, let action):
            guard let area = area(of: region), let followUp = followUp(for: action) else { return }
            if let area { captures.captureArea(at: area, followUp: followUp) } else { captures.captureArea(followUp: followUp) }
        case .capturePreviousArea(let action):
            guard let followUp = followUp(for: action) else { return }
            captures.capturePreviousArea(followUp: followUp)
        case .captureFullscreen(let action):
            guard let followUp = followUp(for: action) else { return }
            captures.cancelSelfTimer()
            captures.captureFullscreen(followUp: followUp)
        case .captureWindow(let action):
            guard let followUp = followUp(for: action) else { return }
            captures.captureWindow(followUp: followUp)
        case .selfTimer(let action):
            guard let followUp = followUp(for: action) else { return }
            captures.selfTimer(followUp: followUp)
        case .scrollingCapture(let region, let start, let autoScrolls):
            guard let area = area(of: region) else { return }
            scrolling.begin(autoScrolls: autoScrolls, area: area, starts: start)
        case .pin(let file):
            if let file { pin(fileAt: file) } else { choosePicturesToPin() }
        case .recordScreen(let region):
            guard let area = area(of: region) else { return }
            captures.cancelSelfTimer()
            recordings.recordScreen(area: area)
        case .captureText(let file?, _, let lineBreaks):
            Task { await textCapture.recognize(fileAt: file, joinLines: lineBreaks == false) }
        case .captureText(nil, let region, let lineBreaks):
            guard let area = area(of: region) else { return }
            captures.cancelSelfTimer()
            if let area {
                Task { await textCapture.recognize(region: area, joinLines: lineBreaks == false) }
            } else {
                textCapture.captureText(joinLines: lineBreaks == false)
            }
        case .openAnnotate(let file):
            if let file { open([file]) } else { chooseFilesToAnnotate() }
        case .openFromClipboard:
            annotateClipboard()
        case .toggleDesktopIcons:
            setDesktopIconsHidden(!settings.hidesDesktopIcons)
        case .hideDesktopIcons:
            setDesktopIconsHidden(true)
        case .showDesktopIcons:
            setDesktopIconsHidden(false)
        case .addQuickAccessOverlay(let file):
            Task { await addToQuickAccess(file) }
        case .openHistory:
            showHistory()
        case .restoreRecentlyClosed:
            quickAccess.restoreRecentlyClosed()
        case .openSettings(let tab):
            showSettings(SettingsTab(urlTab: tab))
        }
    }

    /// A URL command's area in global points: `.some(nil)` when the user is to choose it, nil (with a beep) when it
    /// lies on no display.
    private func area(of region: AutomationRegion) -> CGRect?? {
        do {
            return .some(try region.area(in: displays.layout, pointer: NSEvent.mouseLocation))
        } catch {
            Log.automation.error("URL command's area refused: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    /// The URL API's `action` (or an upload shortcut's) as a capture's follow-up; nil when it cannot be done: an
    /// upload with no destination, which is said by the pointer.
    private func followUp(for action: CaptureAction?, done: ((HistoryItem?) -> Void)? = nil) -> CaptureFollowUp? {
        if action == .upload, uploads.destinations.defaultDestination == nil {
            uploads.tellNoDestination()
            done?(nil)
            return nil
        }
        return CaptureFollowUp(action: action, done: done)
    }

    private func setDesktopIconsHidden(_ hidden: Bool) {
        settings.hidesDesktopIcons = hidden
        desktopIcons.setShown(hidden)
    }

    /// The URL API's `open-from-clipboard`: the clipboard's picture in the editor, added to the history first.
    private func annotateClipboard() {
        let scale = displays.layout.display(at: NSEvent.mouseLocation)?.pixelsPerPoint ?? 2
        switch PasteboardImage.read(.general) {
        case .file(let url):
            open([url])
        case .data(let data):
            guard let loaded = ImageLoader.load(data: data, fallbackScale: scale) else { return NSSound.beep() }
            Task { await annotate(image: loaded.image, scale: loaded.scale, name: String(localized: "Clipboard")) }
        case nil:
            Log.automation.notice("Open from Clipboard: no picture on the clipboard")
            NSSound.beep()
        }
    }

    /// The URL API's `add-quick-access-overlay`: a copy of a picture or a recording joins the history and gets a card,
    /// whatever Settings says about cards: it is what was asked for. The file itself stays where it is.
    private func addToQuickAccess(_ url: URL) async {
        do {
            let entry = try await history.add(copyOf: url)
            historyWindow?.reload()
            if entry.kind == .screenshot { readTextSoon() }
            guard let item = await quickAccessItem(for: entry) else {
                history.delete(entry)
                throw CocoaError(.fileReadCorruptFile)
            }
            quickAccess.add(item)
        } catch {
            Log.automation.error("Could not add \(url.lastPathComponent, privacy: .public) to Quick Access: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: - Shortcuts

    /// What a shortcut's capture action takes.
    enum ShortcutCapture {
        case area
        case window
        case fullscreen
        case previousArea
        case selfTimer
    }

    enum ShortcutError: Error {
        case needsScreenRecording
        case noUploadDestination
        case unreadableImage
    }

    /// A shortcut's capture, run as its keyboard shortcut runs it with `action` after it: the capture's record once it
    /// is kept, or nil when it was cancelled or failed.
    func captureForShortcut(_ capture: ShortcutCapture, action: CaptureAction?) async throws -> HistoryItem? {
        guard permissions.status(of: .screenRecording) == .granted else {
            showOnboarding()
            throw ShortcutError.needsScreenRecording
        }
        if action == .upload, uploads.destinations.defaultDestination == nil { throw ShortcutError.noUploadDestination }
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            let followUp = CaptureFollowUp(action: action) { answer.give($0) }
            switch capture {
            case .area: captures.captureArea(followUp: followUp)
            case .window: captures.captureWindow(followUp: followUp)
            case .fullscreen:
                captures.cancelSelfTimer()
                captures.captureFullscreen(followUp: followUp)
            case .previousArea: captures.capturePreviousArea(followUp: followUp)
            case .selfTimer: captures.selfTimer(followUp: followUp)
            }
        }
    }

    /// A kept capture's file, to hand to a shortcut.
    func fileForShortcut(_ entry: HistoryItem) -> URL {
        history.fileURL(for: entry)
    }

    /// A shortcut's Capture Text: the text copied, or nil when none was.
    func captureTextForShortcut(keepsLineBreaks: Bool) async throws -> String? {
        guard permissions.status(of: .screenRecording) == .granted else {
            showOnboarding()
            throw ShortcutError.needsScreenRecording
        }
        captures.cancelSelfTimer()
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            textCapture.captureText(joinLines: !keepsLineBreaks) { answer.give($0) }
        }
    }

    /// The text in a picture a shortcut hands over, read as Capture Text reads it; nothing is copied or shown.
    func textForShortcut(inImage data: Data, keepsLineBreaks: Bool) async throws -> String? {
        guard let loaded = ImageLoader.load(data: data, fallbackScale: 1) else { throw ShortcutError.unreadableImage }
        return await textCapture.text(in: loaded.image, joinLines: !keepsLineBreaks)
    }

    /// Pins a picture a shortcut hands over.
    func pinForShortcut(_ data: Data) throws {
        let scale = displays.layout.display(at: NSEvent.mouseLocation)?.pixelsPerPoint ?? 2
        guard let loaded = ImageLoader.load(data: data, fallbackScale: scale) else { throw ShortcutError.unreadableImage }
        pins.pin(loaded.image, scale: loaded.scale, origin: .clipboard)
    }

    /// Opens a picture a shortcut hands over in the editor, added to the history first.
    func annotateForShortcut(_ data: Data, name: String) async throws {
        let scale = displays.layout.display(at: NSEvent.mouseLocation)?.pixelsPerPoint ?? 2
        guard let loaded = ImageLoader.load(data: data, fallbackScale: scale) else { throw ShortcutError.unreadableImage }
        await annotate(image: loaded.image, scale: loaded.scale, name: name)
    }

    /// Runs a URL API command for a shortcut, which needs no caller's approval: the user made the shortcut.
    func performForShortcut(_ command: AutomationCommand) throws {
        if command.readsScreen, permissions.status(of: .screenRecording) != .granted {
            showOnboarding()
            throw ShortcutError.needsScreenRecording
        }
        perform(command)
    }

    /// Hands a continuation its value once, however many times a follow-up says it is done.
    private final class Answer<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func give(_ value: Value) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    // MARK: - Quick Access and history

    private func didCapture(_ item: QuickAccessItem) {
        if settings.showQuickAccess {
            quickAccess.add(item)
        } else if settings.historyRetention == .never, !uploads.uploadingIDs.contains(item.id), let entry = history.item(id: item.id) {
            // Nothing else holds on to it: it already went to the clipboard or the export folder.
            history.delete(entry)
        }
        removeExpiredHistory()
        readTextSoon()
    }

    /// Settings' Upload after a capture: to the default destination, when there is one.
    private func uploadKept(_ entry: HistoryItem) {
        guard uploads.destinations.defaultDestination != nil else { return }
        uploadAfterCapture(entry)
    }

    /// The URL API's `action=upload`: the capture just kept goes to the default destination.
    private func uploadAfterCapture(_ entry: HistoryItem) {
        uploads.upload(captureID: entry.id, fileURL: history.fileURL(for: entry))
    }

    /// An upload ended. With history off a capture lives as long as something shows it, and an upload was one
    /// of those things: let it go now unless a card (or, after a failure, the card that comes back with Retry),
    /// or the editor, still holds it.
    private func uploadEnded(_ id: UUID, _ outcome: UploadCoordinator.Outcome) {
        if outcome == .failed, settings.showQuickAccess { return }
        releaseIfUnheld(id)
    }

    private func releaseIfUnheld(_ id: UUID) {
        guard
            settings.historyRetention == .never, !quickAccess.itemIDs.contains(id), !annotations.openCaptureIDs.contains(id),
            !uploads.uploadingIDs.contains(id), let entry = history.item(id: id)
        else { return }
        history.delete(entry)
        historyWindow?.reload()
    }

    /// Has the text read in captures new to the history or with a new picture: now while the History window
    /// is open, else in a moment; not with history off, where they leave the history with their card.
    private func readTextSoon() {
        guard settings.historyRetention != .never else { return }
        if historyWindow != nil {
            textReader.readNow()
        } else {
            textReader.readSoon()
        }
    }

    /// A capture's picture changed in the editor: its card and its History thumbnail follow.
    private func pictureChanged(_ entry: HistoryItem, data: Data) {
        Task {
            if let card = quickAccess.item(entry.id), let thumbnail = await HistoryStore.cardThumbnail(of: data, maxPixels: 560) {
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
            readTextSoon()
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
        chooser.orderFrontRegardless()
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
            readTextSoon()
            annotations.annotate(entry, scale: scale)
        } catch {
            Log.capture.error("Adding \(name, privacy: .public) to the history failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// What a redaction suggestion's kind is called in its tooltip.
    /// Notes a reading for the annotation tools that failed; one dropped because nobody waits for it is no
    /// failure.
    nonisolated private static func logUnread(_ what: StaticString, _ error: any Error) {
        guard !(error is CancellationError) else { return }
        Log.app.error("\(String(describing: what), privacy: .public): the capture could not be read (\(String(describing: error), privacy: .public))")
    }

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

    /// The app's own standard windows on screen (Settings, Capture History, the editor, the OCR panel), which
    /// captures and recordings take in as they would any app's. What floats over the screen to capture it
    /// (the overlay, Quick Access, readings, the countdown, the recording's bar) is borderless and stays out.
    private static func standardWindowIDs() -> Set<CGWindowID> {
        Set(NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
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
        chooser.orderFrontRegardless()
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
        let removed = history.removeExpired(retention: settings.historyRetention, keeping: heldCaptureIDs)
        if removed > 0 {
            Log.capture.notice("Removed \(removed, privacy: .public) expired capture(s) from the history")
        }
        historyWindow?.reload()
    }

    private func makeQuickAccessActions() -> QuickAccessController.Actions {
        var actions = QuickAccessController.Actions(
            copy: { item in CaptureFiles.copy(item.fileURL) },
            save: { [weak self] item in self?.captures.save(item) },
            saveAs: { [weak self] item in self?.captures.saveAs(item) },
            open: { item in NSWorkspace.shared.open(item.fileURL) },
            annotate: { [weak self] item in
                guard let self, let entry = history.item(id: item.id) else { return }
                // A recording opens in the recording window.
                guard item.kind == .screenshot else { return recordings.open(entry) }
                annotate(entry, displayID: item.displayID)
            },
            reveal: { item in NSWorkspace.shared.activateFileViewerSelecting([item.savedURL ?? item.fileURL]) },
            recognizeText: { [weak self] item in
                guard let self, item.kind == .screenshot else { return }
                // Captures are saved without a resolution, so the scale is their display's.
                let scale = displays.layout.display(id: item.displayID)?.pixelsPerPoint ?? 1
                Task { await self.textCapture.openPanel(forFileAt: item.fileURL, fallbackScale: scale) }
            },
            pin: { [weak self] item in
                guard let self, item.kind == .screenshot else { return }
                let scale = displays.layout.display(id: item.displayID)?.pixelsPerPoint ?? 2
                pin(fileAt: item.fileURL, origin: .capture(item.id), fallbackScale: scale)
            },
            moveToTrash: { [weak self] item in
                guard let self else { return }
                uploads.cancel(captureID: item.id)
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
                    !uploads.uploadingIDs.contains(item.id), let entry = history.item(id: item.id)
                else { return }
                history.delete(entry)
            }
        )
        actions.sharing = makeSharingActions()
        return actions
    }

    /// What cards offer for uploading. Every closure asks the destinations when it is called, so a destination
    /// added or removed in Settings shows in the next menu that opens.
    private func makeSharingActions() -> QuickAccessController.Actions.Sharing {
        var sharing = QuickAccessController.Actions.Sharing()
        sharing.menu = { [weak self] in self?.uploads.destinations.menu ?? .hidden }
        sharing.upload = { [weak self] item, destination in self?.uploads.upload(captureID: item.id, fileURL: item.fileURL, destinationID: destination) }
        sharing.cancel = { [weak self] item in self?.uploads.cancel(captureID: item.id) }
        sharing.retry = { [weak self] item in self?.uploads.retry(captureID: item.id) }
        sharing.copyLink = { [weak self] item in self?.uploads.copyLink(captureID: item.id) }
        sharing.hasLink = { [weak self] item in self?.uploads.hasLink(item.id) ?? false }
        sharing.canDeleteFromStorage = { [weak self] item in self?.uploads.canDeleteFromStorage(item.id) ?? false }
        sharing.deleteFromStorage = { [weak self] item in self?.uploads.deleteFromStorage(captureID: item.id) }
        sharing.current = { [weak self] item in self?.uploads.cardState(item.id) }
        return sharing
    }

    /// How many captures a retention would delete now; captures still on screen as cards are kept.
    private func expiredCount(for retention: HistoryRetention) -> Int {
        history.expired(retention: retention, keeping: heldCaptureIDs).count
    }

    /// Captures something still needs the file of: a card, an open editor, an upload on its way.
    private var heldCaptureIDs: Set<UUID> {
        quickAccess.itemIDs.union(annotations.openCaptureIDs).union(uploads.uploadingIDs)
    }

    private func makeHistoryWindow() -> HistoryWindowController {
        var historyActions = HistoryActions(
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
                guard let self else { return }
                guard entry.kind == .screenshot else { return recordings.open(entry) }
                annotate(entry, displayID: quickAccess.item(entry.id)?.displayID)
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
                self?.uploads.cancel(captureID: entry.id)
                self?.quickAccess.remove(entry.id)
                self?.history.moveToTrash(entry)
            }
        )
        historyActions.sharing.menu = { [weak self] in self?.uploads.destinations.menu ?? .hidden }
        historyActions.sharing.upload = { [weak self] entry, destination in
            guard let self else { return }
            uploads.upload(captureID: entry.id, fileURL: history.fileURL(for: entry), destinationID: destination)
        }
        historyActions.sharing.isUploading = { [weak self] entry in self?.uploads.isUploading(entry.id) ?? false }
        historyActions.sharing.cancel = { [weak self] entry in self?.uploads.cancel(captureID: entry.id) }
        historyActions.sharing.hasLink = { [weak self] entry in self?.uploads.hasLink(entry.id) ?? false }
        historyActions.sharing.copyLink = { [weak self] entry in self?.uploads.copyLink(captureID: entry.id) }
        historyActions.sharing.canDeleteFromStorage = { [weak self] entry in self?.uploads.canDeleteFromStorage(entry.id) ?? false }
        historyActions.sharing.deleteFromStorage = { [weak self] entry in self?.uploads.deleteFromStorage(captureID: entry.id) }
        let controller = HistoryWindowController(
            store: history, settings: settings, actions: historyActions, textReader: textReader,
            expiredCount: { [weak self] retention in self?.expiredCount(for: retention) ?? 0 }
        )
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.historyWindow = nil
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    /// A recording was edited or put back as it was made: its card shows it as it is now.
    private func recordingChanged(_ entry: HistoryItem) {
        historyWindow?.reload()
        guard let card = quickAccess.item(entry.id) else { return }
        Task {
            let url = history.fileURL(for: entry)
            guard let thumbnail = await HistoryStore.cardThumbnail(of: url, maxPixels: 560) else { return }
            quickAccess.update(QuickAccessItem(
                id: entry.id, kind: entry.kind, fileURL: url, thumbnail: thumbnail, pixelWidth: entry.pixelWidth,
                pixelHeight: entry.pixelHeight, displayID: card.displayID, createdAt: entry.createdAt, duration: entry.duration,
                savedURL: card.savedURL
            ))
        }
    }

    /// Brings a history item back as a Quick Access card.
    private func restore(_ entry: HistoryItem) async {
        guard let item = await quickAccessItem(for: entry) else { return }
        quickAccess.add(item)
    }

    private func quickAccessItem(for entry: HistoryItem) async -> QuickAccessItem? {
        let url = history.fileURL(for: entry)
        guard let thumbnail = await HistoryStore.cardThumbnail(of: url, maxPixels: 560) else { return nil }
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
            createdAt: entry.createdAt,
            duration: entry.duration
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
            destinations: uploads.destinations,
            uploadRecords: uploads.records,
            recordActions: SettingsDependencies.UploadRecordActions(
                copyLink: { [weak self] in self?.uploads.copyLink(of: $0) },
                open: { [weak self] in self?.uploads.open($0) },
                forget: { [weak self] in self?.uploads.forget($0) },
                forgetAll: { [weak self] in self?.uploads.forgetAllRecords() },
                canDelete: { [weak self] in self?.uploads.canDelete($0) ?? false },
                delete: { [weak self] in self?.uploads.deleteFromStorage($0) }
            ),
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
            historySearch: makeHistorySearchHooks(),
            textCapture: textCapture,
            annotations: annotations,
            pins: pins,
            colorPicker: colorPicker,
            measurer: measurer,
            recordings: recordings,
            scrolling: scrolling,
            settings: settings,
            uploads: uploads,
            desktopIcons: desktopIcons,
            removeCheckCaptures: { [weak self] in
                guard let self else { return 0 }
                let mine = history.items().filter { ["Demo", "Test"].contains($0.appName ?? "") && $0.createdAt > .now.addingTimeInterval(-4 * 3600) }
                for entry in mine {
                    quickAccess.remove(entry.id)
                    history.delete(entry)
                }
                historyWindow?.reload()
                return mine.count
            },
            perform: { [weak self] in self?.perform($0) },
            uploadAfterCapture: { [weak self] in self?.uploadAfterCapture($0) },
            pressShortcut: { [weak self] in self?.handle($0) },
            latestCaptureID: { [weak self] in self?.history.items().first?.id },
            replay: { [weak self] in self?.replayStorage }
        )
    }

    private func makeHistorySearchHooks() -> DebugHooks.HistorySearchHooks {
        let testApp = "OhMyShot Test"
        return DebugHooks.HistorySearchHooks(
            add: { [weak self] url in
                guard let self, let data = try? Data(contentsOf: url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      let entry = try? history.add(
                          data: data, name: url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension,
                          kind: .screenshot, pixelWidth: width, pixelHeight: height, appName: testApp
                      )
                else { return Log.app.notice("debug.history-add failed") }
                Log.app.notice("debug.history-add \(entry.fileName, privacy: .public)")
                historyWindow?.reload()
                readTextSoon()
            },
            removeTests: { [weak self] in
                guard let self else { return }
                let tests = history.items().filter { $0.appName == testApp }
                tests.forEach(history.delete)
                historyWindow?.reload()
                Log.app.notice("debug.history-remove-tests \(tests.count, privacy: .public)")
            },
            search: { [weak self] query in
                // Counts for the whole history; names and what was found only for the test pictures.
                guard let self else { return "" }
                let items = history.items(), terms = HistorySearch.terms(in: query)
                var folding = HistorySearch.Folding()
                var found = 0, unread = 0, tests: [String] = []
                for item in items {
                    guard let text = item.kind == .screenshot ? history.text(of: item) : "" else {
                        unread += 1
                        continue
                    }
                    guard let match = HistorySearch.match(terms, in: HistorySearch.Entry(text: text, appName: item.appName, folding: &folding)) else { continue }
                    found += 1
                    if item.appName == testApp { tests.append("\(item.fileName) [\(match.excerpt.map { $0.before + "|" + $0.found + "|" + $0.after } ?? "app")]") }
                }
                return "found \(found) of \(items.count), unread \(unread); tests: \(tests.joined(separator: "; "))"
            },
            read: { [weak self] in self?.textReader.readNow() },
            reading: { [weak self] in self?.textReader.reading ?? 0 },
            setQuery: { [weak self] query in self?.historyWindow?.previewSearch(query) },
            setFilter: { [weak self] name in self?.historyWindow?.previewFilter(name) }
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
    /// Maps CleanShot's `open-settings?tab=` names onto ours, and takes ours as they are.
    init(urlTab: String?) {
        let name = urlTab?.lowercased() ?? ""
        if let tab = SettingsTab(rawValue: name) {
            self = tab
            return
        }
        switch name {
        // Backgrounds, Quick Access, and what happens after a screenshot are all in General.
        case "wallpaper", "quickaccess", "screenshots": self = .general
        // Pins and the reading tools.
        case "annotate": self = .tools
        // CleanShot's Cloud tab is where uploads are set up.
        case "cloud": self = .sharing
        // The URL scheme is set up there.
        case "advanced": self = .automation
        default: self = .general
        }
    }
}

/// File actions on captures.
enum CaptureFiles {
    /// Copies a capture's image. Image only, no file: some apps paste a file reference instead of the
    /// picture when both are offered. A recording, a movie or a GIF, is copied as its file: a GIF's picture
    /// alone would paste as its first frame.
    static func copy(_ url: URL) {
        if HistoryStore.isRecording(url) { return PasteboardWriter.write(fileURL: url) }
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
