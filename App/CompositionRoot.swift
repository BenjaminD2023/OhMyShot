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
    let settings = SettingsStore()
    let permissions = PermissionCenter()
    let displays = DisplayTopology()
    let history = HistoryStore.standard()
    private let shareableContent = ShareableContentCache()
    lazy var capturer = ScreenCapturer(content: shareableContent)
    lazy var overlay = OverlayController(topology: displays, capturer: capturer)
    /// Saves, copies, and hands over captures in the format Settings choose.
    lazy var files = ScreenshotFiles(settings: settings, history: history)
    lazy var captures = CaptureCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay, history: history, files: files)
    lazy var quickAccess = QuickAccessController(actions: makeQuickAccessActions())
    /// Uploads to the user's own storage; idle unless one is in flight.
    lazy var uploads: UploadCoordinator = {
        let uploads = UploadCoordinator(settings: settings, quickAccess: quickAccess)
        uploads.restoreCard = { [weak self] id in
            guard let self, let entry = history.item(id: id) else { return }
            Task { await self.restore(entry) }
        }
        uploads.ended = { [weak self] id, outcome in self?.uploadEnded(id, outcome) }
        uploads.showsCard = { [weak self] id in self?.showsQuickAccess(forCaptureWith: id) ?? true }
        return uploads
    }()
    lazy var textCapture: TextCaptureCoordinator = {
        let coordinator = TextCaptureCoordinator(settings: settings, displays: displays, capturer: capturer, overlay: overlay)
        coordinator.cardsInTheWay = { [weak self] in self?.quickAccess.cardsFrame }
        coordinator.readers = { [weak self] in self?.readerPacks.installed }
        coordinator.cloud = { [weak self] in self?.panelCloud() }
        coordinator.captureTextCloud = { [weak self] in self?.captureTextCloud() }
        return coordinator
    }()
    /// The cloud model the OCR panel's Read with, and Capture Text while Settings says so, send a picture to (L4,
    /// Docs/ocr.md › Cloud models). Its key is read from the Keychain only when a picture is sent or Settings shows it.
    private lazy var cloudModels = CloudModelStore(secrets: KeychainSecretStore(service: "OhMyShot Cloud Models (\(AppIdentity.bundleIdentifier))"))
    #if DEBUG
    /// Scripted checks' models, in memory, in place of the person's while set.
    var demoCloudModels: CloudModelStore?
    private var shownCloudModels: CloudModelStore { demoCloudModels ?? cloudModels }
    #else
    private var shownCloudModels: CloudModelStore { cloudModels }
    #endif

    /// How the OCR panel reads with a cloud model: a reader over the models' keys, made for each panel window.
    private func panelCloud() -> TextRecognitionWindowController.Cloud {
        let store = shownCloudModels
        let reader = CloudReader(secrets: store.secrets)
        return .init(store: store) { image, model, progress in
            #if DEBUG
            if let stub = DebugCloudDemo.stub(for: model) { return try await stub(progress) }
            #endif
            return try await reader.read(image, with: model, progress: progress)
        }
    }

    /// The cloud model Capture Text reads with, while Settings says so, and how.
    private func captureTextCloud() -> (model: CloudModel, read: @Sendable (CGImage, Bool) async throws -> CloudReading)? {
        let store = shownCloudModels
        guard let model = store.captureTextModel else { return nil }
        let reader = CloudReader(secrets: store.secrets)
        return (model, { image, joinsLines in
            #if DEBUG
            if let stub = DebugCloudDemo.stub(for: model) { return try await stub { _ in } }
            #endif
            return try await reader.read(image, with: model, joinsLines: joinsLines)
        })
    }
    lazy var annotations = AnnotationCoordinator(history: history)
    /// Turns, flips, and scales pictures from their Quick Access cards.
    lazy var pictureChanges = PictureChangeCoordinator(
        history: history,
        isBeingEdited: { [weak self] in self?.annotations.openCaptureIDs.contains($0) ?? false },
        displayScale: { [weak self] item in Double(self?.displays.layout.display(id: item.displayID)?.pixelsPerPoint ?? 1) },
        changed: { [weak self] entry, data in self?.pictureChanged(entry, data: data, savedCopyIsStale: true) }
    )
    /// The cards' and History's showing of changed pictures, in the order the pictures changed.
    var pictureUpdates: Task<Void, Never>?
    /// Reads the text in the history's screenshots for its search, in the text reader beside the app.
    lazy var textReader: HistoryTextReader = {
        let reader = HistoryTextReader(store: history, helper: readerPacks.helper) { [weak self] in self?.readerPacks.secondReading }
        reader.onRead = { [weak self] id in self?.historyWindow?.textRead(id) }
        return reader
    }()
    lazy var pins = PinController(settings: settings, actions: makePinActions())
    /// The model packs the text reader reads with beside Vision, and the text reader itself.
    lazy var readerPacks: TextReaderPacks = {
        let packs = TextReaderPacks()
        packs.secondReadingWarmed = { [weak self] in
            guard let self, settings.historyRetention != .never else { return }
            textReader.readSoon()
        }
        return packs
    }()
    lazy var colorPicker = ColorPickerCoordinator(settings: settings, overlay: overlay)
    lazy var measurer = MeasureCoordinator(settings: settings, overlay: overlay, colorPicker: colorPicker)
    lazy var recordings = RecordingCoordinator(
        settings: settings, displays: displays, capturer: capturer, overlay: overlay, history: history, permissions: permissions, files: files
    )
    lazy var scrolling = ScrollingCaptureCoordinator(displays: displays, capturer: capturer, overlay: overlay, permissions: permissions, captures: captures)
    /// Hide Desktop Icons: nothing exists unless the icons are hidden.
    lazy var desktopIcons: DesktopCover = {
        let cover = DesktopCover(topology: displays, capturer: capturer)
        cover.onChange = { [weak self] in self?.shareableContent.refresh() }
        cover.canReadScreen = { [weak self] in self?.permissions.status(of: .screenRecording) == .granted }
        return cover
    }()
    /// The replay (macOS 27), kept as any object: a stored property can't be of a type this macOS may lack.
    private(set) var replayStorage: AnyObject?
    private let hotkeys: HotkeyCenter
    let urlScheme: String
    private var statusItem: StatusItemController?
    /// Release builds' updates; nil in builds without a feed, until a debug hook starts one against a feed of its own.
    var updates: UpdateController?
    private var automation: AutomationController?
    private(set) var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    /// The invitation to MMFoundation's Discord: counted as captures are kept, shown once, at a later launch.
    private let communityInvite = CommunityInvite()
    private var communityInviteWindow: CommunityInviteWindowController?
    var historyWindow: HistoryWindowController?
    private var observations: [Task<Void, Never>] = []
    /// How long captures stay: as Keep Captures says, and with history off, as long as something holds them.
    lazy var retention = CaptureRetention(
        settings: settings, history: history,
        cards: { [weak self] in self?.quickAccess.itemIDs ?? [] },
        editors: { [weak self] in self?.annotations.openCaptureIDs ?? [] },
        recordingWindows: { [weak self] in self?.recordings.openRecordingIDs ?? [] },
        uploads: { [weak self] in self?.uploads.uploadingIDs ?? [] },
        historyChanged: { [weak self] in self?.historyWindow?.reload() }
    )
    /// What the Shortcuts actions run.
    private(set) lazy var shortcuts = ShortcutActions(
        permissions: permissions, uploads: uploads, captures: captures, textCapture: textCapture, files: files, packs: readerPacks,
        pins: pins, displays: displays,
        showOnboarding: { [weak self] in self?.showOnboarding() },
        run: { [weak self] command, done in
            guard let self else { done?(nil); return }
            perform(command, done: done)
        },
        openInEditor: { [weak self] loaded, name in await self?.annotate(loaded, name: name) }
    )

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
        // The Share extension can write only inside this folder, so it has to be there for the extension.
        ShareInbox.standard().prepare()
        ShareInbox.standard().removeStaleBatches()
        // A capture's text, read on this Mac for the annotation tools.
        AnnotationSession.readText = { AnnotationReadings.reading(of: $0) }
        // Where the blocks of text on a frozen screen lie, found quickly and never read, for a selection's edges
        // to snap to when Settings say so.
        overlay.textBlocks = TextBlockFinder(isOn: { [settings = self.settings] in settings.snapSelectionToText }, find: { await TextBlocks.find(in: $0) })
        overlay.captureLoupeStyle = settings.captureLoupeStyle
        overlay.captureLoupeSize = settings.captureLoupeSize
        if #available(macOS 27, *) {
            replayStorage = ReplayCoordinator(settings: settings, displays: displays, capturer: capturer, permissions: permissions, recordings: recordings)
        }
        let statusItem = makeStatusItem()
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
        observations.append(Task { [weak self] in
            for await size in Observations({ settings.captureLoupeSize }) {
                self?.overlay.captureLoupeSize = size
            }
        })
        observations.append(Task { [weak self] in
            for await style in Observations({ settings.captureLoupeStyle }) {
                self?.overlay.captureLoupeStyle = style
            }
        })
        observations.append(Task { [weak self] in
            for await shows in Observations({ settings.screenshotShowsCursor }) {
                self?.overlay.showsPointer = shows
            }
        })
        observations.append(Task { [weak self] in
            for await shape in Observations({ settings.areaShape }) {
                self?.overlay.keptShape = AspectRatio(label: shape)
            }
        })
        // A shape chosen on Capture Area's size control is the one Shift keeps from now on; a square is the empty one.
        overlay.onKeptShapeChange = { shape in settings.areaShape = shape == .square ? "" : shape.label }
        observations.append(Task { [weak statusItem] in
            for await visible in Observations({ settings.showMenuBarIcon }) {
                statusItem?.setVisible(visible)
            }
        })
        if let updates = UpdateController.make(), updates.start() {
            self.updates = updates
            observeUpdateSetting()
        }
        // Also runs once now, which is the launch-time cleanup.
        observations.append(Task { [weak self] in
            for await _ in Observations({ settings.historyRetention }) {
                self?.retention.removeExpired()
            }
        })
        // The converted copies made for dragging out and uploading, from days ago.
        Task.detached(priority: .background) { ExportedFiles.removeOld() }
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
        // Card or not, a screenshot or a recording kept counts toward the invitation to the Discord.
        captures.onKept = { [weak self] _ in self?.communityInvite.captureKept() }
        recordings.onKept = { [weak self] _ in self?.communityInvite.captureKept() }
        recordings.copiedToClipboard = { [weak self] id in self?.retention.recordingCopied(id) }
        // A recording copied from its card, History, or its window goes to the clipboard as a reference to its file too.
        files.recordingCopied = { [weak self] id in self?.retention.recordingCopied(id) }
        // A recording's window holds the recording while it is open, and lets go of it when it closes.
        recordings.windowClosed = { [weak self] id in self?.retention.releaseIfUnheld(id) }
        captures.uploadKept = { [weak self] entry in self?.uploadKept(entry) }
        recordings.uploadKept = { [weak self] entry in self?.uploadKept(entry) }
        recordings.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .recording(let time, let paused):
                self.statusItem?.showRecording(elapsed: time, paused: paused) { [weak self] in self?.recordings.stop() }
            case .makingGIF(let progress):
                self.statusItem?.showProgress(.makingGIF(progress))
            case .exportingStudio(let progress):
                self.statusItem?.showProgress(.exportingStudio(progress))
            case .idle:
                self.statusItem?.endRecording()
            }
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
            guard let self else { return }
            let joinLines = !self.settings.textRecognitionKeepsLineBreaks
            Task { await self.textCapture.recognize(region: area, frozen: frozen, joinLines: joinLines) }
        }
        captures.allInOneScroll = { [weak self] area in self?.scrolling.begin(area: area, starts: true) }
        captures.onRecord = { [weak self] target, display, choices, app in
            self?.recordings.record(target, on: display, choices: choices, appName: app)
        }
        captures.recordingSetupCancelled = { [weak self] in self?.recordings.recordingSetupCancelled() }
        captures.canUpload = { [weak self] in self?.uploads.canUpload ?? false }
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
        // A card is not closed by itself under the editor that has its capture open.
        annotations.onEditing = { [weak self] id, editing in self?.quickAccess.setEditing(editing, for: id) }
        annotations.saveCopy = { [weak self] entry, file in
            guard let self, let saved = await files.saveScreenshot(fileAt: file, entry: entry, asks: true) else { return nil }
            quickAccess.markSaved(entry.id, at: saved)
            return saved
        }
        annotations.saveAs = { [weak self] file, entry, scale in
            guard let self, let saved = await files.saveScreenshotAs(fileAt: file, entry: entry, scale: scale) else { return nil }
            if let entry { quickAccess.markSaved(entry.id, at: saved) }
            return saved
        }
        annotations.saveFile = { [weak self] file, scale in
            await self?.files.saveScreenshot(fileAt: file, scale: scale, asks: true)
        }
        annotations.fileToHandOver = { [weak self] file, scale in
            self?.files.fileToHandOver(file, scale: scale) ?? file
        }
        annotations.copyPicture = { [weak self] image, png, name, scale in
            await self?.files.copy(.init(image), png: png, name: name, scale: scale)
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
        communityInvite.launched()
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
            // Once, after the permission (often a relaunch later): while macOS answers its screenshot keys, the
            // shortcuts that have them never fire.
            if !OnboardingWindowController.hasShownShortcuts,
               SystemScreenshotKeys.clashes(hotKeys: SystemScreenshotKeys.readHotKeys(), bindings: SystemScreenshotKeys.currentBindings())
                .contains(where: \.takenByMacOS) {
                showOnboarding(at: .shortcuts)
            }
        } else {
            showOnboarding()
        }
        // On the next turn, once what launched the app (a URL, a file to annotate) has begun.
        Task { @MainActor [weak self] in self?.offerCommunityInvite() }
    }

    /// Keeps edits still open in the editor before the app quits.
    func prepareForTermination() {
        annotations.keepAll()
        // A card waiting under Undo goes to the Trash as it would have a moment later.
        quickAccess.finishTrashingNow()
        textReader.stop()
    }

    /// Stops a recording and keeps it before the app quits, and the replay's buffers once the clips being
    /// saved are kept; `done` runs once all of it is. False when nothing needed waiting for.
    func finishRecordingBeforeQuitting(_ done: @escaping (Bool) -> Void) -> Bool {
        var waiting = 1
        var mayQuit = true
        let finished = {
            waiting -= 1
            if waiting == 0 { done(mayQuit) }
        }
        if recordings.finishBeforeQuitting({ saved in
            mayQuit = mayQuit && saved
            finished()
        }) { waiting += 1 }
        // An upload still going is cancelled, and quitting waits until its transfer has stopped and cleaned up.
        if uploads.cancelAll(then: finished) { waiting += 1 }
        if #available(macOS 27, *), replay?.finishBeforeQuitting(finished) == true { waiting += 1 }
        // The count's own share: what still waits calls `done` when it ends.
        waiting -= 1
        return waiting > 0
    }

    @available(macOS 27, *)
    var replay: ReplayCoordinator? {
        replayStorage as? ReplayCoordinator
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

    /// An open onboarding window is brought forward as it is. Scripted checks pass `keys`, macOS's hot keys and
    /// OhMyShot's shortcuts to show in place of the Mac's, which replaces an open window.
    func showOnboarding(
        at step: OnboardingWindowController.Step = .permission,
        keys: (hotKeys: () -> [String: Any]?, bindings: @MainActor () -> [SystemScreenshotKeys.Binding])? = nil
    ) {
        if keys != nil, let open = onboardingWindow {
            open.close()
            onboardingWindow = nil
        }
        let controller = onboardingWindow ?? OnboardingWindowController(
            permissions: permissions,
            startingAt: step,
            readHotKeys: keys?.hotKeys ?? SystemScreenshotKeys.readHotKeys,
            bindings: keys?.bindings ?? SystemScreenshotKeys.currentBindings,
            relaunch: { Relauncher.relaunch() }
        )
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self, weak controller] in
            if self?.onboardingWindow === controller { self?.onboardingWindow = nil }
        }
        onboardingWindow = controller
        controller.show()
    }

    /// At launch, the invitation to MMFoundation's Discord, once, when `CommunityInvite` says it may appear. Never as a
    /// capture is kept, though that is when it becomes due: the capture is on the clipboard on its way somewhere, and a
    /// window coming forward would take the keys it is pasted with.
    private func offerCommunityInvite() {
        guard communityInvite.mayAppear(busy: isBusyForCommunityInvite) else { return }
        communityInvite.shown()
        Log.app.notice("Showing the invitation to the Discord")
        let controller = CommunityInviteWindowController()
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self, weak controller] in
            if self?.communityInviteWindow === controller { self?.communityInviteWindow = nil }
        }
        communityInviteWindow = controller
        controller.show()
    }

    /// Whatever the invitation must not come in front of: a capture's overlay or countdown, a recording, a scrolling
    /// capture, an editor (a recording's or Studio's too), onboarding, a window asking for an answer, or a window of the
    /// app's in use.
    private var isBusyForCommunityInvite: Bool {
        overlay.isActive || captures.isSelfTimerRunning || recordings.isRecording || recordings.isCountingDown
            || scrolling.isCapturing || annotations.isEditing || !recordings.openRecordingIDs.isEmpty
            || onboardingWindow != nil || communityInviteWindow != nil
            || NSApp.modalWindow != nil || NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
            || NSApp.keyWindow != nil
    }

    /// Schedules the updater's daily look while Settings › General says so; runs once now.
    private func observeUpdateSetting() {
        observations.append(Task { [weak self, settings] in
            for await on in Observations({ settings.checksForUpdates }) {
                self?.updates?.setChecksAutomatically(on)
            }
        })
    }

    // MARK: - Wiring

    func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController(dependencies: SettingsDependencies(
            settings: settings,
            permissions: permissions,
            urlScheme: urlScheme,
            relaunch: { Relauncher.relaunch() },
            openHistory: { [weak self] in self?.showHistory() },
            expiredCount: { [weak self] in self?.retention.expiredCount(for: $0) ?? 0 },
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
            ),
            modelPacks: readerPacks.center,
            cloudModels: shownCloudModels,
            updates: updates?.status,
            acknowledgments: Bundle.main.url(forResource: "Acknowledgments", withExtension: "md")
        ))
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in self?.settingsWindow = nil }
        return controller
    }

    private func logStartup() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        Log.app.notice("Started \(Log.subsystem, privacy: .public) \(version, privacy: .public) (\(build, privacy: .public)), \(self.displays.layout.displays.count, privacy: .public) display(s), URL scheme \(self.urlScheme, privacy: .public)")
    }
}
