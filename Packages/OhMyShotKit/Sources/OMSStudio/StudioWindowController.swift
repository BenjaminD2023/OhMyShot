import AppKit
import AVFoundation
import AVKit
import Observation
import OMSCore
import OSLog
import SwiftUI
#if DEBUG
import ApplicationServices
#endif

/// The Studio window: the recording filmed again in the preview, its timeline along the bottom, and the
/// inspector on the right, as the user chose on 2026-10-11.
///
/// The preview plays the composition the export writes, so what plays is what is kept. The movie is
/// exported into the recording's place in the history when it is copied or saved and when the window closes,
/// as the annotation editor keeps marks; the recording as it was made stays in the project, and the Studio
/// window can always open it again.
public final class StudioWindowController: NSWindowController, NSWindowDelegate {
    public struct Actions {
        /// Keeps the exported movie (a file in a temporary place) in place of the recording, the recording as it
        /// was made kept in the project, with the settings it was made with; returns the file that now holds
        /// the movie.
        public var keep: (StudioExporter.Movie, StudioProject) throws -> URL
        /// Puts the file on the clipboard.
        public var copy: (URL) -> Void
        /// Saves a copy to the export location; returns where it went.
        public var save: (URL) -> URL?
        /// How far along an export is, from 0 to 1, or nil once it is done: shown in the menu bar while the
        /// window is gone.
        public var progress: (Double?) -> Void

        public init(
            keep: @escaping (StudioExporter.Movie, StudioProject) throws -> URL, copy: @escaping (URL) -> Void, save: @escaping (URL) -> URL?,
            progress: @escaping (Double?) -> Void
        ) {
            self.keep = keep
            self.copy = copy
            self.save = save
            self.progress = progress
        }
    }

    /// One of the built-in backgrounds, for the inspector.
    public struct Swatch: Identifiable {
        public let name: String
        public let title: String
        public let picture: CGImage
        public var id: String { name }

        public init(name: String, title: String, picture: CGImage) {
            self.name = name
            self.title = title
            self.picture = picture
        }
    }

    public var onClose: (() -> Void)?
    public let studio: StudioDocument
    let model = StudioWindowModel()
    private let actions: Actions
    private let player: AVPlayer
    private let playerView: PlayerLayerView
    private var timeObserver: Any?
    private var itemStatus: NSKeyValueObservation?
    private var observation: Task<Void, Never>?
    private var windowLease: ActiveResources.Lease?
    /// The newest exported movie in the history, while the project hasn't changed since.
    private var exported: URL?
    private var exporting: Task<URL?, Never>?
    /// Set by Cancel: exporting stops, including the export after it that a change made meanwhile asks for.
    private var cancelled = false
    /// Runs once the window has closed and its movie is kept.
    private var closeCompletions: [(Bool) -> Void] = []
    private var preparingToClose: Task<Void, Never>?
    private var didClose = false
    private var finishedClosing = false

    /// - Parameter movie: the movie in the history, when it was exported from the project as it is now.
    public init(document: StudioDocument, title: String, swatches: [Swatch], movie: URL?, actions: Actions) {
        studio = document
        self.actions = actions
        exported = movie
        let player = AVPlayer()
        self.player = player
        playerView = PlayerLayerView(player: player)
        playerView.onPixelSizeChange = { [weak document] size in document?.setPreviewSize(size) }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = title
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 900, height: 600)
        super.init(window: window)
        model.controller = self
        let hosting = NSHostingController(rootView: StudioView(document: studio, model: model, player: playerView, swatches: swatches))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 1180, height: 780))
        window.center()
        window.delegate = self
        // Laid out now, so the preview's size is known before its first composition is made.
        window.layoutIfNeeded()
        // The window's own undo manager (SwiftUI's, in a hosted window), which Edit › Undo and ⌘Z reach.
        studio.undoManagerProvider = { [weak window] in window?.undoManager }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(to: time.seconds) }
        }
        observation = Task { [weak self] in
            guard let studio = self?.studio else { return }
            for await _ in Observations({ studio.compositionGeneration }) {
                self?.reloadPlayer()
            }
        }
        Task { await studio.makeComposition() }
        studio.save()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show() {
        guard !finishedClosing else { return }
        if didClose {
            // History can reopen this window while its background export is still running. That export
            // may finish normally, but it must not tear down a window the user has returned to.
            didClose = false
            completeClose(saved: false)
        }
        if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    // MARK: Playing

    func togglePlay() {
        guard !studio.compositionFailed, studio.composition != nil else { return }
        if player.rate > 0 {
            player.pause()
            studio.isPlaying = false
        } else {
            // From the start again at the end.
            if let composition = studio.composition, studio.movieTime(studio.time) >= composition.duration - 0.05 {
                seek(toRecordingTime: 0)
            }
            player.play()
            studio.isPlaying = true
        }
    }

    /// Shows the recording at `time` (its seconds; a time inside a cut shows the cut's end).
    func seek(toRecordingTime time: Double) {
        let clamped = min(max(time, 0), studio.duration)
        studio.time = clamped
        player.seek(to: CMTime(seconds: studio.movieTime(clamped), preferredTimescale: 6_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func playerMoved(to movieTime: Double) {
        guard player.rate > 0 else { return }
        studio.time = studio.recordingTime(movieTime)
        if let composition = studio.composition, movieTime >= composition.duration - 0.02 {
            player.pause()
            studio.isPlaying = false
        }
    }

    /// Plays the newest composition from where the preview was.
    private func reloadPlayer() {
        guard let composition = studio.composition else { return }
        let item = AVPlayerItem(asset: composition.asset)
        item.videoComposition = composition.videoComposition
        let generation = studio.compositionGeneration
        itemStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Log.studio.error("The Studio preview couldn't play: \(String(describing: item.error), privacy: .public)")
            let message = item.error?.localizedDescription ?? String(localized: "The recording couldn’t be read", bundle: .module)
            Task { @MainActor [weak self] in
                guard let self, self.studio.compositionGeneration == generation else { return }
                self.player.pause()
                self.studio.previewFailed(message)
            }
        }
        let wasPlaying = player.rate > 0
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTime(seconds: studio.movieTime(studio.time), preferredTimescale: 6_000), toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    // MARK: Keeping

    /// Exports the movie into the history, once per change; returns its file, or nil when it failed (said
    /// with an alert). A change made while a movie is being made is exported after it, so what is kept, on
    /// closing above all, is the project as it was left.
    private func exportIfNeeded() async -> URL? {
        cancelled = false
        while true {
            guard !cancelled else { return nil }
            do { try await studio.flushSave() } catch { return nil }
            guard !cancelled, !Task.isCancelled else { return nil }
            if let exported, !studio.hasUnexportedChanges { return exported }
            if let exporting {
                guard await exporting.value != nil else { return nil }
                continue
            }
            let task = makeExport()
            exporting = task
            guard await task.value != nil else { return nil }
        }
    }

    /// One export of the project as it is now.
    private func makeExport() -> Task<URL?, Never> {
        Task { () -> URL? in
            // What the movie is made from: a change made while it is made waits for the next export.
            let project = studio.project
            model.progress = 0
            defer {
                model.progress = nil
                // Cleared here, before anyone waiting hears the result, so none of them finds it still running.
                exporting = nil
                actions.progress(nil)
            }
            let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
            do {
                try Task.checkCancellation()
                let composition = try await studio.makeExportComposition(project: project)
                try Task.checkCancellation()
                let movie = try await StudioExporter.export(composition, to: temporary) { fraction in
                    // The export holds the window controller until it ends, so this may too.
                    Task { @MainActor in
                        guard self.exporting != nil, !self.cancelled else { return }
                        self.model.progress = fraction
                        if self.window?.isVisible != true { self.actions.progress(fraction) }
                    }
                }
                try Task.checkCancellation()
                let url = try actions.keep(movie, project)
                if studio.project == project { studio.markExported() }
                exported = url
                return url
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                // Cancelled: nothing to say.
                if !(error is CancellationError), !Task.isCancelled { fail(error) }
                return nil
            }
        }
    }

    func copyMovie() {
        Task {
            guard let url = await exportIfNeeded() else { return }
            actions.copy(url)
            model.flashCopied()
        }
    }

    func saveMovie() {
        Task {
            guard let url = await exportIfNeeded() else { return }
            guard actions.save(url) != nil else { return NSSound.beep() }
            model.flashSaved()
        }
    }

    func saveMovieAs() {
        guard let window else { return }
        Task {
            guard let url = await exportIfNeeded() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            panel.allowedContentTypes = [.mpeg4Movie]
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
            do {
                try await AtomicFileCopy.copy(from: url, to: destination)
                model.flashSaved()
            } catch {
                fail(error)
            }
        }
    }

    // MARK: Window

    /// Whether closing would export: the project changed since the movie in the history was made.
    public var hasUnexportedChanges: Bool {
        studio.hasUnexportedChanges
    }

    public var hasPendingProjectSave: Bool { studio.hasPendingSave }

    /// Whether a movie is being exported after the window closed (the menu bar shows how far along).
    public var isExportingAfterClosing: Bool {
        exporting != nil && window?.isVisible != true
    }

    /// Stops the export under way, keeping nothing of it: the history keeps the movie it had, and the
    /// changes wait for the next export.
    public func cancelExport() {
        cancelled = true
        exporting?.cancel()
    }

    /// Closes the window, exporting its movie; `done` runs once it is kept.
    public func close(then done: @escaping () -> Void) {
        closeIfSaved { saved in if saved { done() } }
    }

    /// A failed project write cancels closing (and, for the app coordinator, quitting). The window stays
    /// open with its unsaved state and Retry action; exported movies never stand in for the editable project.
    public func closeIfSaved(then done: @escaping (Bool) -> Void) {
        guard !finishedClosing else { return done(true) }
        closeCompletions.append(done)
        if !didClose { prepareClose() }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        prepareClose()
        return false
    }

    private func prepareClose() {
        guard preparingToClose == nil, !didClose else { return }
        preparingToClose = Task {
            defer { preparingToClose = nil }
            do {
                try await studio.flushSave()
                window?.close()
            } catch {
                show()
                completeClose(saved: false)
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        didClose = true
        player.pause()
        studio.isPlaying = false
        if studio.hasUnexportedChanges {
            // Exported after the window has gone, as the editor keeps marks; the menu bar shows how far along.
            Task {
                _ = await self.exportIfNeeded()
                self.finishClosing()
            }
        } else {
            finishClosing()
        }
    }

    private func finishClosing() {
        guard didClose, !finishedClosing else { return }
        finishedClosing = true
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observation?.cancel()
        player.replaceCurrentItem(with: nil)
        itemStatus = nil
        studio.releasePreview()
        windowLease = nil
        onClose?()
        completeClose(saved: true)
    }

    private func completeClose(saved: Bool) {
        let completions = closeCompletions
        closeCompletions = []
        completions.forEach { $0(saved) }
    }

    private func fail(_ error: any Error) {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The movie couldn’t be exported", bundle: .module)
        alert.informativeText = error.localizedDescription
        guard let window, window.isVisible else {
            NSApp.activate()
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: Menu commands

    @objc func copy(_ sender: Any?) {
        copyMovie()
    }

    @objc func save(_ sender: Any?) {
        saveMovie()
    }

    #if DEBUG
    /// Runs against the synthetic demo's real responder chain and accessibility elements. It leaves
    /// the project as it found it and never posts a key to another app or to the global event stream.
    public func debugKeyboardChecks() async -> [String: Bool] {
        guard let window else { return ["window": false] }
        let original = studio.project
        let originalTime = studio.time
        let originalSelection = studio.selection
        defer {
            studio.project = original
            studio.selection = originalSelection
            seek(toRecordingTime: originalTime)
        }
        func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
            return result
        }
        func find(_ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let windows = value(app, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
            guard let target = windows.first(where: { value($0, kAXTitleAttribute as CFString) as? String == window.title }) else { return nil }
            var pending = [target]
            while let element = pending.popLast() {
                if predicate(element) { return element }
                pending += value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            }
            return nil
        }
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) else { return }
            window.sendEvent(event)
        }
        func until(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while !predicate(), ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            }
            return predicate()
        }
        guard let timeline = find({ value($0, kAXIdentifierAttribute as CFString) as? String == "studio-timeline" }) else {
            return ["timelineAccessible": false]
        }
        var checks: [String: Bool] = ["timelineAccessible": true]
        checks["timelineFocus"] = AXUIElementSetAttributeValue(timeline, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        studio.selection = .none
        seek(toRecordingTime: 0)
        key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .option)
        checks["optionArrowSelectsZoom"] = await until { studio.selectedZoom != nil }
        let count = studio.project.zooms.count
        if checks["optionArrowSelectsZoom"] == true {
            key(51, "\u{7F}")
            checks["deleteRemovesChosenZoom"] = await until { studio.project.zooms.count == count - 1 }
            _ = debugUndo()
            checks["undoRestoresZoom"] = await until { studio.project.zooms.count == count }
        }
        studio.selection = .none
        seek(toRecordingTime: min(0.5, studio.duration / 4))
        key(34, "i")
        checks["markIn"] = await until { studio.selectedRange != nil }
        let before = studio.time
        key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
        checks["arrowSeeks"] = await until { studio.time > before }
        key(31, "o")
        checks["markOut"] = await until { studio.selectedRange.map { abs($0.upperBound - studio.time) < 0.001 } ?? false }
        if checks["markOut"] == true {
            let oldCuts = studio.project.cuts
            key(51, "\u{7F}")
            checks["deleteCutsRange"] = await until { studio.project.cuts != oldCuts }
            _ = debugUndo()
            checks["undoRestoresRange"] = await until { studio.project.cuts == oldCuts }
        }
        if let id = studio.project.zooms.first?.id {
            studio.selectedZoom = id
            _ = await until { find { value($0, kAXIdentifierAttribute as CFString) as? String == "studio-start-time" } != nil }
            if let field = find({ value($0, kAXIdentifierAttribute as CFString) as? String == "studio-start-time" }) {
                checks["timeFieldFocus"] = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
                let start = min(studio.project.zooms[0].start + 0.1, studio.project.zooms[0].end - 0.3)
                checks["timeFieldSet"] = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, StudioTimeInput.format(start) as CFString) == .success
                key(36, "\r")
                checks["returnCommitsTime"] = await until { abs((studio.project.zooms.first { $0.id == id }?.start ?? -1) - start) < 0.002 }
            }
        }
        let playheadLabel = String(localized: "Playhead", bundle: .module)
        if let playhead = find({ value($0, kAXDescriptionAttribute as CFString) as? String == playheadLabel }) {
            let before = studio.time
            checks["playheadAXIncrement"] = AXUIElementPerformAction(playhead, kAXIncrementAction as CFString) == .success
            checks["playheadAXMoves"] = await until { studio.time > before }
        }
        return checks
    }

    /// Exercises the actual SwiftUI buttons through this process's own accessibility tree. No global
    /// input, external application or user capture is involved in the synthetic Studio checks.
    public func debugTimelineControl(_ action: String) -> Bool {
        let label: String
        switch action {
        case "zoom-in": label = String(localized: "Zoom In Timeline", bundle: .module)
        case "zoom-out": label = String(localized: "Zoom Out Timeline", bundle: .module)
        case "fit-selection": label = String(localized: "Fit Selection", bundle: .module)
        case "fit": label = String(localized: "Fit", bundle: .module)
        default: return false
        }
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
            return value
        }
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        guard let target = windows.first(where: { attribute($0, kAXTitleAttribute as CFString) as? String == window?.title }) else { return false }
        var pending = [target]
        while let element = pending.popLast() {
            let role = attribute(element, kAXRoleAttribute as CFString) as? String
            let title = attribute(element, kAXTitleAttribute as CFString) as? String
            let description = attribute(element, kAXDescriptionAttribute as CFString) as? String
            if role == kAXButtonRole as String, title == label || description == label {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            pending += attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        }
        return false
    }

    /// For scripted screenshots that show nothing: the window behind the wallpaper in the middle of the
    /// main display.
    public func showBehindWallpaper() {
        guard let window else { return }
        if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
        }
        window.orderFront(nil)
    }

    /// Moves the preview to `time` (the recording's seconds), for scripted renders.
    public func debugSeek(to time: Double) {
        seek(toRecordingTime: time)
    }

    /// Changes the padding, as its slider does, for scripted checks.
    public func debugSetPadding(_ padding: Double) {
        studio.project.padding = padding
    }

    /// Plays or pauses, as Space does, for scripted checks.
    public func debugTogglePlay() {
        togglePlay()
    }

    /// The preview's player, for scripted checks: its item's status, whether its layer has a frame to show,
    /// and where it is.
    public var debugPlayerState: String {
        let item = player.currentItem
        return "item \(item.map { "\($0.status.rawValue)" } ?? "none"), size \(item.map { "\(Int($0.presentationSize.width))x\(Int($0.presentationSize.height))" } ?? "-"), time \(String(format: "%.2f", player.currentTime().seconds)), rate \(player.rate), ready \(playerView.isReadyForDisplay)"
    }

    /// Chooses the first zoom, as a click on the timeline would, for scripted renders.
    public func debugSelectFirstZoom() {
        studio.selectedZoom = studio.project.zooms.first?.id
    }

    /// Exports as Copy would, without the clipboard: keeps the movie in the history.
    public func debugExport() async -> URL? {
        await exportIfNeeded()
    }

    /// Leaves `range` (the recording's seconds) out, as Cut does, for scripted renders.
    public func debugCut(_ range: ClosedRange<Double>) {
        studio.cut(range)
    }

    /// Chooses a stretch on the clip, as a drag along it does, for scripted renders.
    public func debugChoose(_ range: ClosedRange<Double>?) {
        studio.selectedRange = range
    }

    /// Sends Undo down the window's responder chain as Edit › Undo would, for scripted checks; returns who
    /// answered and whether the project's undo manager is the one used.
    public func debugUndo() -> String {
        let undo = Selector(("undo:"))
        var responder = window?.firstResponder
        var chain: [String] = []
        while let current = responder {
            chain.append("\(type(of: current))\(current.responds(to: undo) ? "*" : "")")
            if current.responds(to: undo), current.tryToPerform(undo, with: nil) {
                return "answered by \(type(of: current)); chain \(chain.joined(separator: " > ")); same manager \(current.undoManager === studio.undoManager)"
            }
            responder = current.nextResponder
        }
        return "nobody answered; chain \(chain.joined(separator: " > "))"
    }

    /// Exports and cancels it `after` seconds in, for scripted checks; returns what was left.
    public func debugExportAndCancel(after delay: Duration) async -> String {
        let export = Task { await exportIfNeeded() }
        try? await Task.sleep(for: delay)
        cancelExport()
        let url = await export.value
        return "result \(url?.lastPathComponent ?? "nil"), changes waiting \(studio.hasUnexportedChanges), progress \(model.progress.map { String($0) } ?? "nil"), sheet \(window?.attachedSheet != nil), exporting \(exporting != nil)"
    }

    /// Closes without exporting, for cleaning up after scripted checks.
    public func debugCloseWithoutExporting() {
        studio.markExported()
        window?.close()
    }
    #endif
}

/// What the window's toolbar and overlay show.
@Observable
final class StudioWindowModel {
    weak var controller: StudioWindowController?
    /// How far along an export is, from 0 to 1; nil while none runs.
    var progress: Double?
    var copied = false
    var saved = false
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var savedReset: Task<Void, Never>?

    func flashCopied() {
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func flashSaved() {
        saved = true
        savedReset?.cancel()
        savedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saved = false
        }
    }
}

/// The preview: the movie fitted in the view with nothing behind it, so the canvas sits on the window's
/// ground rather than between black bars.
final class PlayerLayerView: NSView {
    /// Hears the view's size in pixels when it settles: after a live resize rather than all through it.
    var onPixelSizeChange: ((CGSize) -> Void)?
    private let playerLayer = AVPlayerLayer()

    /// Whether the layer has a frame to show.
    var isReadyForDisplay: Bool {
        playerLayer.isReadyForDisplay
    }
    /// The picture border around the movie, so a pale background holds against the window's ground.
    private let edge = CALayer()
    private var reportedSize: CGSize?
    private var videoRectObservation: NSKeyValueObservation?

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        wantsLayer = true
        edge.borderWidth = 0.5
        edge.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        playerLayer.addSublayer(edge)
        videoRectObservation = playerLayer.observe(\.videoRect) { [weak self] _, _ in
            DispatchQueue.main.async { self?.placeEdge() }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Preview", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        playerLayer
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !inLiveResize { reportSize() }
        placeEdge()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        placeEdge()
    }

    /// The border on the movie's own rectangle, once there is one: the separator's hairline, the 1 pt
    /// contrast hairline under Increase Contrast.
    private func placeEdge() {
        let rect = playerLayer.videoRect
        edge.isHidden = rect.isEmpty
        edge.frame = rect
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        edge.borderWidth = contrast ? 1 : 0.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            edge.borderColor = contrast
                ? NSColor(white: dark ? 1 : 0, alpha: dark ? 0.5 : 0.35).cgColor
                : NSColor.separatorColor.cgColor
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
    }

    private func reportSize() {
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0, size != reportedSize else { return }
        reportedSize = size
        onPixelSizeChange?(size)
    }
}
