import AppKit
import AVFoundation
import AVKit
import Observation
import OMSCore
import SwiftUI

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
    private var observation: Task<Void, Never>?
    private var windowLease: ActiveResources.Lease?
    /// The newest exported movie in the history, while the project hasn't changed since.
    private var exported: URL?
    private var exporting: Task<URL?, Never>?
    /// Set by Cancel: exporting stops, including the export after it that a change made meanwhile asks for.
    private var cancelled = false
    /// Runs once the window has closed and its movie is kept.
    private var closed: (() -> Void)?

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
        Task { [weak self] in
            guard let source = self?.studio.source else { return }
            for await pictures in Filmstrip.pictures(of: source, count: 24, pixelHeight: 80) {
                self?.model.filmstrip = pictures
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show() {
        if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    // MARK: Playing

    func togglePlay() {
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
            if let exported, !studio.hasUnexportedChanges { return exported }
            guard !cancelled else { return nil }
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
                let composition = try await studio.makeExportComposition()
                let movie = try await StudioExporter.export(composition, to: temporary) { fraction in
                    // The export holds the window controller until it ends, so this may too.
                    Task { @MainActor in
                        self.model.progress = fraction
                        if self.window?.isVisible != true { self.actions.progress(fraction) }
                    }
                }
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
                if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
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
        closed = done
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        player.pause()
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
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observation?.cancel()
        player.replaceCurrentItem(with: nil)
        windowLease = nil
        onClose?()
        closed?()
        closed = nil
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
        model.selectedRange = range
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
    /// A stretch chosen on the timeline's clip, for Cut.
    var selectedRange: ClosedRange<Double>?
    /// Pictures along the recording for the timeline's clip, evenly spaced; empty until they are read.
    var filmstrip: [CGImage] = []
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

/// Pictures along a recording, for the timeline's clip.
nonisolated enum Filmstrip {
    /// `count` pictures `pixelHeight` pixels high, one for each equal stretch of the recording: first the
    /// key frames nearest them, which come at once, then, where those repeat, a frame from each stretch.
    /// Read exactly from the start, a short full-screen recording took seconds, decoding up to two seconds
    /// of frames for each picture. Any that can't be read are left out; the reading stops when the stream's
    /// listener goes.
    static func pictures(of url: URL, count: Int, pixelHeight: Int) -> AsyncStream<[CGImage]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: url)
                guard let duration = try? await asset.load(.duration).seconds, duration > 0, count > 0 else { return continuation.finish() }
                let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
                let quick = await read(asset, at: times, pixelHeight: pixelHeight, tolerance: .positiveInfinity)
                continuation.yield(quick.pictures)
                if quick.distinct < count, !Task.isCancelled {
                    let tolerance = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
                    let exact = await read(asset, at: times, pixelHeight: pixelHeight, tolerance: tolerance)
                    if !Task.isCancelled { continuation.yield(exact.pictures) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The pictures nearest `times` within `tolerance`, and how many different frames they are.
    @concurrent private static func read(_ asset: AVAsset, at times: [CMTime], pixelHeight: Int, tolerance: CMTime) async -> (pictures: [CGImage], distinct: Int) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: pixelHeight * 4, height: pixelHeight)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var pictures: [CGImage] = []
        var frames = Set<Double>()
        for time in times {
            guard !Task.isCancelled else { break }
            if let picture = try? await generator.image(at: time) {
                pictures.append(picture.image)
                frames.insert(picture.actualTime.seconds)
            }
        }
        return (pictures, frames.count)
    }
}
