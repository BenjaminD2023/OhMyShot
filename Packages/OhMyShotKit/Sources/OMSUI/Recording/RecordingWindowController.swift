import AppKit
import AVFoundation
import AVKit
import Observation
import OMSCore
import SwiftUI
import UniformTypeIdentifiers

/// What the recording window changes in a recording before it is kept again.
public struct RecordingEdit: Equatable, Sendable {
    /// The part kept, in the movie's time; nil keeps all of it.
    public var timeRange: CMTimeRange?
    /// Whether the sound stays.
    public var keepsAudio: Bool
    /// The size against the recording's own, at most 1.
    public var scale: Double

    public init(timeRange: CMTimeRange? = nil, keepsAudio: Bool = true, scale: Double = 1) {
        self.timeRange = timeRange
        self.keepsAudio = keepsAudio
        self.scale = scale
    }

    public var isNone: Bool {
        timeRange == nil && keepsAudio && scale >= 1
    }
}

/// The recording window: plays a kept recording and makes the few edits a recording needs before it goes
/// out. Trim takes QuickTime's trimming bar; the toolbar leaves the sound out, makes the movie smaller,
/// makes a GIF of it, and saves or copies it. A GIF only plays here.
///
/// Edits are kept in the recording itself when it leaves the window (copied, saved) and when the window
/// closes, as the annotation editor keeps marks; the recording as it was made stays beside it, and Revert to
/// Original in Save's menu brings it back.
public final class RecordingWindowController: NSWindowController, NSWindowDelegate {
    public struct Actions {
        /// Makes the recording with `edit` and keeps it in place of the recording, the recording as it was made
        /// kept beside it; returns the file that now holds it.
        public var keep: (RecordingEdit) async throws -> URL
        /// Puts the recording back as it was made; returns its file.
        public var revert: () async throws -> URL
        /// Makes a GIF of the recording with `edit`, kept as a capture of its own, with a card.
        public var makeGIF: (RecordingEdit) async throws -> Void
        /// Saves a copy of the file to the export location; returns where it went.
        public var save: (URL) -> URL?
        /// Puts the file on the clipboard.
        public var copy: (URL) -> Void

        public init(
            keep: @escaping (RecordingEdit) async throws -> URL, revert: @escaping () async throws -> URL,
            makeGIF: @escaping (RecordingEdit) async throws -> Void, save: @escaping (URL) -> URL?, copy: @escaping (URL) -> Void
        ) {
            self.keep = keep
            self.revert = revert
            self.makeGIF = makeGIF
            self.save = save
            self.copy = copy
        }
    }

    public var onClose: (() -> Void)?
    /// The recording's file in the history.
    public private(set) var fileURL: URL

    private let model = RecordingWindowModel()
    private let actions: Actions
    private let playerView = AVPlayerView()
    private let gifView = NSImageView()
    private var windowLease: ActiveResources.Lease?
    /// Runs once the window has closed and its edits are kept.
    private var closed: (() -> Void)?
    /// The edits being kept now, which a second keep waits for.
    private var keeping: Task<URL?, Never>?

    /// - Parameters:
    ///   - fileURL: the recording's file in the history: a movie, or a GIF.
    ///   - pixelsPerPoint: the recorded display's, so the window shows the recording as large as it was on
    ///     screen; nil for a Retina display's.
    ///   - hasOriginal: whether it was edited before, so Revert to Original has something to bring back.
    public init(fileURL: URL, title: String, pixelWidth: Int, pixelHeight: Int, pixelsPerPoint: Double?, hasOriginal: Bool, actions: Actions) {
        self.fileURL = fileURL
        self.actions = actions
        let isGIF = fileURL.pathExtension.lowercased() == "gif"
        // A GIF is made as large as things were on screen already.
        let scale = isGIF ? 1 : max(pixelsPerPoint ?? 2, 1)
        let size = Self.preferredSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = title
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 560, height: 360)
        super.init(window: window)
        model.controller = self
        model.isGIF = isGIF
        model.pixelWidth = pixelWidth
        model.pixelHeight = pixelHeight
        model.canRevert = hasOriginal

        let content: NSView
        if isGIF {
            gifView.imageScaling = .scaleProportionallyDown
            gifView.animates = true
            gifView.image = NSImage(contentsOf: fileURL)
            gifView.setAccessibilityLabel(String(localized: "GIF", bundle: .module))
            content = gifView
        } else {
            playerView.controlsStyle = .inline
            playerView.showsFullScreenToggleButton = true
            playerView.player = AVPlayer(url: fileURL)
            content = playerView
        }
        let hosting = NSHostingController(rootView: RecordingWindowView(model: model, content: content))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        window.delegate = self
        if !isGIF { loadAudio() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The window's toolbar, over the top of its content.
    private static let toolbarHeight: CGFloat = 52

    /// The recording as large as it was on screen under the toolbar (the player's controls float over the
    /// movie), within most of the screen; no smaller than the toolbar needs.
    private static func preferredSize(pixelWidth: Int, pixelHeight: Int, scale: Double) -> CGSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let movie = CGSize(width: CGFloat(Double(pixelWidth) / scale), height: CGFloat(Double(pixelHeight) / scale))
        let fit = min(1, visible.width * 0.85 / movie.width, (visible.height * 0.85 - toolbarHeight) / movie.height)
        return CGSize(width: max((movie.width * fit).rounded(), 560), height: max((movie.height * fit).rounded(), 300) + toolbarHeight)
    }

    public func show() {
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        showWindow(nil)
        AppActivation.bringForward(window)
        window?.makeFirstResponder(model.isGIF ? gifView : playerView)
    }

    private func loadAudio() {
        let asset = AVURLAsset(url: fileURL)
        Task { [weak self] in
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            self?.model.hasAudio = !tracks.isEmpty
        }
    }

    // MARK: Window

    /// Whether closing would keep edits: something is trimmed, silenced, or made smaller.
    public var hasUnkeptEdits: Bool {
        !model.isGIF && !edit.isNone
    }

    /// Closes the window, keeping its edits; `done` runs once they are kept.
    public func close(then done: @escaping () -> Void) {
        closed = done
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        if hasUnkeptEdits {
            // Kept after the window has gone; this task holds the controller until then.
            Task {
                _ = await self.keepEdits()
                self.finishClosing()
            }
        } else {
            finishClosing()
        }
    }

    private func finishClosing() {
        playerView.player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        gifView.image = nil
        windowLease?.end()
        windowLease = nil
        onClose?()
        closed?()
        closed = nil
    }

    // MARK: Edits

    /// The edits made so far: the part kept (QuickTime's trim sets the item's playback ends), the sound,
    /// the size.
    var edit: RecordingEdit {
        RecordingEdit(timeRange: trimRange, keepsAudio: !model.hasAudio || model.keepsAudio, scale: model.scale)
    }

    private var trimRange: CMTimeRange? {
        guard let item = playerView.player?.currentItem, item.duration.isNumeric else { return nil }
        let duration = item.duration
        let start = item.reversePlaybackEndTime.isNumeric ? max(item.reversePlaybackEndTime, .zero) : .zero
        let end = item.forwardPlaybackEndTime.isNumeric ? min(item.forwardPlaybackEndTime, duration) : duration
        // Within a hundredth of a second of both ends is no trim.
        let slack = CMTime(value: 1, timescale: 100)
        guard start > slack || end < duration - slack, end > start else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    func beginTrimming() {
        guard playerView.canBeginTrimming else { return NSSound.beep() }
        model.isTrimming = true
        playerView.beginTrimming { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.isTrimming = false
                self.model.isTrimmed = self.trimRange != nil
            }
        }
    }

    func toggleAudio() {
        model.keepsAudio.toggle()
        playerView.player?.isMuted = !model.keepsAudio
        announce(model.keepsAudio ? String(localized: "Sound kept", bundle: .module) : String(localized: "Sound left out", bundle: .module))
    }

    func setScale(_ scale: Double) {
        model.scale = scale
    }

    /// Makes the edits and keeps them in the recording, once; returns the file that holds it, or nil when
    /// it failed (said with a beep and an alert).
    private func keepEdits() async -> URL? {
        // Edits being kept already (Copy, then the window closed): wait for them rather than make them twice.
        if let keeping { return await keeping.value }
        let edit = edit
        guard !edit.isNone else { return fileURL }
        model.busy = String(localized: "Saving the recording…", bundle: .module)
        let task = Task { () -> URL? in
            do {
                let url = try await actions.keep(edit)
                reload(url)
                model.canRevert = true
                return url
            } catch {
                fail(error)
                return nil
            }
        }
        keeping = task
        let url = await task.value
        keeping = nil
        model.busy = nil
        return url
    }

    /// Plays the recording now in `url`, with no edits made yet.
    private func reload(_ url: URL) {
        fileURL = url
        model.keepsAudio = true
        model.scale = 1
        model.isTrimmed = false
        playerView.player?.isMuted = false
        playerView.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            if let size = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) {
                self?.model.pixelWidth = Int(size.width.rounded())
                self?.model.pixelHeight = Int(size.height.rounded())
            }
        }
        loadAudio()
    }

    // MARK: Actions

    func copyRecording() {
        Task {
            guard let url = await keepEdits() else { return }
            actions.copy(url)
            model.flashCopied()
            announce(String(localized: "Copied", bundle: .module))
        }
    }

    func saveRecording() {
        Task {
            guard let url = await keepEdits() else { return }
            guard actions.save(url) != nil else { return NSSound.beep() }
            model.flashSaved()
            announce(String(localized: "Saved", bundle: .module))
        }
    }

    func saveAs() {
        guard let window else { return }
        Task {
            guard let url = await keepEdits() else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .mpeg4Movie]
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let destination = panel.url else { return }
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

    func makeGIF() {
        let edit = edit
        Task {
            model.busy = String(localized: "Making the GIF…", bundle: .module)
            defer { model.busy = nil }
            do {
                try await actions.makeGIF(edit)
                announce(String(localized: "GIF made", bundle: .module))
            } catch {
                fail(error)
            }
        }
    }

    /// Forgets the edits not kept yet and puts the recording back as it was made.
    func revert() {
        Task {
            guard model.canRevert else { return reload(fileURL) }
            model.busy = String(localized: "Reverting…", bundle: .module)
            defer { model.busy = nil }
            do {
                let url = try await actions.revert()
                reload(url)
                model.canRevert = false
            } catch {
                fail(error)
            }
        }
    }

    func openInDefaultApp() {
        Task {
            guard let url = await keepEdits() else { return }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu commands

    @objc func copy(_ sender: Any?) {
        copyRecording()
    }

    @objc func save(_ sender: Any?) {
        saveRecording()
    }

    // MARK: Private

    private func fail(_ error: any Error) {
        NSSound.beep()
        let alert = NSAlert(error: error)
        guard let window, window.isVisible else {
            // Edits kept as the window closed: said in an alert of its own, so they are not lost without a word.
            alert.messageText = String(localized: "The edited recording couldn’t be kept", bundle: .module)
            NSApp.activate()
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: window as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    #if DEBUG
    /// For scripted screenshots that show nothing: the window behind the wallpaper in the middle of the
    /// main display, ordered in without making the app active.
    public func showBehindWallpaper() {
        guard let window else { return }
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
        }
        window.orderFront(nil)
    }

    /// Edits as the toolbar would make them, for scripted checks: a trim to `range`, the sound, the size.
    public func debugEdit(trim range: CMTimeRange?, keepsAudio: Bool, scale: Double) {
        if let range, let item = playerView.player?.currentItem {
            item.reversePlaybackEndTime = range.start
            item.forwardPlaybackEndTime = range.end
            model.isTrimmed = true
        }
        if keepsAudio != model.keepsAudio { toggleAudio() }
        setScale(scale)
    }

    /// Forgets the edits and closes, for cleaning up after scripted checks.
    public func debugDiscardAndClose() {
        model.keepsAudio = true
        model.scale = 1
        if let item = playerView.player?.currentItem {
            item.reversePlaybackEndTime = .invalid
            item.forwardPlaybackEndTime = .invalid
        }
        window?.close()
    }

    /// Copies, saves, or makes a GIF as the toolbar would, for scripted checks.
    public func debugPerform(_ action: String) {
        switch action {
        case "copy": copyRecording()
        case "save": saveRecording()
        case "gif": makeGIF()
        case "revert": revert()
        case "close": window?.performClose(nil)
        default: break
        }
    }
    #endif
}

@MainActor
@Observable
final class RecordingWindowModel {
    weak var controller: RecordingWindowController?
    var isGIF = false
    var hasAudio = false
    var keepsAudio = true
    var scale = 1.0
    var pixelWidth = 0
    var pixelHeight = 0
    var isTrimmed = false
    var isTrimming = false
    /// What the window is doing that takes a moment, shown over the recording; nil when nothing is.
    var busy: String?
    var canRevert = false
    var copied = false
    var saved = false
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var savedReset: Task<Void, Never>?

    /// The sizes Size offers: the recording's own, then smaller.
    static let scales = [1.0, 0.75, 0.5, 0.25]

    /// The recording's size at `scale`, in pixels, both sides even: "1000 × 640".
    func dimensions(_ scale: Double) -> String {
        let width = Int((Double(pixelWidth) * scale).rounded()), height = Int((Double(pixelHeight) * scale).rounded())
        return "\(width - width % 2) × \(height - height % 2)"
    }

    /// A size's name with what it makes: "Half Size (1000 × 640)".
    func sizeTitle(_ scale: Double) -> String {
        let dimensions = dimensions(scale)
        return switch scale {
        case 1: String(localized: "Full Size (\(dimensions))", bundle: .module)
        case 0.75: String(localized: "Three Quarters (\(dimensions))", bundle: .module)
        case 0.5: String(localized: "Half Size (\(dimensions))", bundle: .module)
        default: String(localized: "Quarter Size (\(dimensions))", bundle: .module)
        }
    }

    var isEdited: Bool {
        isTrimmed || !keepsAudio || scale < 1
    }

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

struct RecordingWindowView: View {
    @Bindable var model: RecordingWindowModel
    let content: NSView

    var body: some View {
        PlayerArea(view: content)
            .overlay {
                if let busy = model.busy {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(busy)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    // Opaque behind its text, over whatever frame the movie shows.
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(.black)
            .toolbar { toolbar }
            .disabled(model.busy != nil)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !model.isGIF {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.controller?.beginTrimming()
                } label: {
                    Label { Text("Trim", bundle: .module) } icon: { Image(systemName: "timeline.selection") }
                }
                .disabled(model.isTrimming)
                .help(Text("Trim the start and end", bundle: .module))
                if model.hasAudio {
                    Button {
                        model.controller?.toggleAudio()
                    } label: {
                        Label {
                            model.keepsAudio ? Text("Sound", bundle: .module) : Text("No Sound", bundle: .module)
                        } icon: {
                            Image(systemName: model.keepsAudio ? "speaker.wave.2" : "speaker.slash")
                        }
                    }
                    .help(model.keepsAudio ? Text("Leave the sound out", bundle: .module) : Text("Keep the sound", bundle: .module))
                    .accessibilityValue(model.keepsAudio ? Text("On", bundle: .module) : Text("Off", bundle: .module))
                }
                // The size the recording will have, as the editor's zoom shows its scale.
                Menu {
                    ForEach(RecordingWindowModel.scales, id: \.self) { scale in
                        Toggle(isOn: Binding(get: { model.scale == scale }, set: { if $0 { model.controller?.setScale(scale) } })) {
                            Text(verbatim: model.sizeTitle(scale))
                        }
                    }
                } label: {
                    Text(verbatim: model.dimensions(model.scale)).monospacedDigit()
                }
                .fixedSize()
                .help(Text("Make the recording smaller", bundle: .module))
                .accessibilityLabel(Text("Size", bundle: .module))
                .accessibilityValue(Text(verbatim: model.sizeTitle(model.scale)))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.controller?.makeGIF()
                } label: {
                    Label { Text("Make GIF", bundle: .module) } icon: { Image(systemName: "photo.stack") }
                }
                .help(Text("Make a GIF of the recording, without sound, as large as it was on screen or smaller as Size says", bundle: .module))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.controller?.saveAs() } label: { Text("Save As…", bundle: .module) }
                Button { model.controller?.openInDefaultApp() } label: {
                    model.isGIF ? Text("Open in Preview", bundle: .module) : Text("Open in QuickTime Player", bundle: .module)
                }
                if !model.isGIF {
                    Divider()
                    Button { model.controller?.revert() } label: { Text("Revert to Original", bundle: .module) }
                        .disabled(!model.canRevert && !model.isEdited)
                }
            } label: {
                Label {
                    model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module)
                } icon: {
                    Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                }
            } primaryAction: {
                model.controller?.saveRecording()
            }
            .help(Text("Save a Copy (⌘S)", bundle: .module))
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.controller?.copyRecording()
            } label: {
                Label {
                    model.copied ? Text("Copied", bundle: .module) : Text("Copy", bundle: .module)
                } icon: {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help(Text("Copy the recording (⌘C)", bundle: .module))
        }
    }
}

/// Hosts the player (or the GIF) in the SwiftUI window.
struct PlayerArea: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
