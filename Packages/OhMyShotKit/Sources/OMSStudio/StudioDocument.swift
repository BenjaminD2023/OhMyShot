import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Observation
import OMSCore
import OSLog

/// A Studio recording open in the Studio window: the recording, what the pointer did, and the project being
/// set, with the composition the preview plays, made again shortly after each change.
@Observable
public final class StudioDocument {
    public enum SaveState: Equatable, Sendable {
        case saved, pending, saving
        case failed(String)
    }

    public enum PreviewState: Equatable, Sendable {
        case preparing, ready, updating
        case failed(String)
    }

    public let source: URL
    public let telemetry: StudioTelemetry
    /// The recording's length in seconds, and its size in pixels.
    public let duration: Double
    public let recordingSize: CGSize
    /// The recording's file size in bytes; 0 when it can't be read.
    public let sourceByteCount: Int
    /// Where the project is kept: its settings are saved here after each change.
    public let folder: URL
    /// The camera's movie, recorded beside the recording; nil when none was.
    public let cameraMovie: URL?
    /// The recording's sounds kept apart, each in a file of its own; empty when they weren't, and the recording's own
    /// sound plays as one.
    let soundFiles: [(sound: StudioSound, url: URL)]

    public var project: StudioProject {
        didSet {
            guard project != oldValue else { return }
            registerUndo(back: oldValue)
            projectChanged(from: oldValue)
        }
    }

    /// Gives the undo manager every change to the project is registered with: the window's, asked each
    /// time, since a hosted window's can be put in place after the window is made.
    @ObservationIgnored public var undoManagerProvider: (() -> UndoManager?)?

    var undoManager: UndoManager? {
        undoManagerProvider?()
    }

    /// What is chosen on the timeline. One thing is chosen at a time, a zoom, a cut, a stretch of the camera's
    /// layout, or a stretch to cut: choosing one lets go of the others, so Delete takes away what is shown as
    /// chosen. The properties below only read it: written through them, letting go of a zoom (nil) right after
    /// choosing a cut did nothing, which read as though it did.
    public var selection: StudioSelection = .none

    /// The zoom chosen on the timeline, by its identifier.
    public var selectedZoom: UUID? {
        if case .zoom(let id) = selection { id } else { nil }
    }
    /// The cut chosen on the timeline, by its start.
    public var selectedCut: Double? {
        if case .cut(let start) = selection { start } else { nil }
    }
    /// The stretch of the camera's layout chosen on the timeline, by its identifier.
    public var selectedSegment: UUID? {
        if case .cameraSegment(let id) = selection { id } else { nil }
    }
    /// The stretch of the recording chosen to cut.
    public var selectedRange: ClosedRange<Double>? {
        if case .range(let range) = selection { range } else { nil }
    }
    /// The stretch played faster or slower chosen on the timeline, by its start.
    public var selectedSpeed: Double? {
        if case .speed(let start) = selection { start } else { nil }
    }
    /// The movie the preview plays now; nil until it is first made.
    public private(set) var composition: StudioComposition?
    /// The newest composition couldn't be made (the recording couldn't be read).
    public private(set) var previewState: PreviewState = .preparing
    public var compositionFailed: Bool {
        if case .failed = previewState { true } else { false }
    }
    public private(set) var saveState: SaveState = .saved
    public var hasPendingSave: Bool { savedRevision < projectRevision }
    /// Counts the compositions made, so the window knows to play the newest.
    public private(set) var compositionGeneration = 0
    /// Normalized peak amplitude bins (`0...1`) for the timeline audio waveform silhouette.
    public private(set) var waveform: [Float] = []
    /// Where the preview is, in the recording's seconds.
    public var time: Double = 0
    public var isPlaying = false
    /// Whether the project changed since it was last exported.
    public private(set) var hasUnexportedChanges = true
    /// The picture last chosen for the background, while the project is open: offered again after another
    /// background was chosen.
    public private(set) var lastPicture: String?

    @ObservationIgnored private let background: @Sendable (String, CGSize) -> CGImage?
    @ObservationIgnored private var rebuild: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    /// How many times the composition was made, so a slower, older one never replaces a newer one.
    @ObservationIgnored private var generation = 0
    /// While a slider or a zoom is dragged (non-nil), its changes are taken back as one: only the first
    /// registers, and this says whether it has.
    @ObservationIgnored private var continuousRegistered: Bool?
    /// When a change without a name was last registered: quick ones in a row (a color picked in the
    /// picker, a slider nudged with the keyboard) are taken back together.
    @ObservationIgnored private var lastUnnamedChange: Date?
    @ObservationIgnored private var namingChange = false
    /// The preview's size in pixels, once it is known, and the longest side the newest preview was asked to
    /// be filmed at.
    @ObservationIgnored private var previewPixels: CGSize?
    @ObservationIgnored private var previewSide: Double?
    @ObservationIgnored private var projectWriter = StudioProjectWriter()
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var projectRevision = 0
    @ObservationIgnored private var savedRevision = -1
    @ObservationIgnored private var previewBuild: Task<StudioComposition, Error>?
    @ObservationIgnored private var cachedMotion: (key: StudioMotionKey, track: StudioTrack)?
    /// Where the person is in the camera's frames, for the preview's Blur and Cutout backgrounds: one for every
    /// composition the preview makes, as it depends only on the camera's frames; made when first needed.
    @ObservationIgnored private var previewMatte: StudioCameraMatte?
    /// The background pictures' tiles for the inspector, read once each, and the Blurred recording's.
    @ObservationIgnored private var pictureThumbnails: [String: CGImage] = [:]
    @ObservationIgnored private var blurredThumbnail: CGImage?
    @ObservationIgnored private(set) var motionBuildCount = 0
    /// Tests can control completion order without requiring a media decoder or wall-clock delays.
    @ObservationIgnored var compositionLoader: (@Sendable (StudioProject, Double) async throws -> StudioComposition)?

    /// - Parameter background: paints a built-in gradient, by name, at a size in pixels.
    public init(
        source: URL, telemetry: StudioTelemetry, project: StudioProject, duration: Double, recordingSize: CGSize, folder: URL,
        hasBeenExported: Bool, background: @escaping @Sendable (String, CGSize) -> CGImage?
    ) {
        self.source = source
        self.telemetry = telemetry
        // The times the camera filled what was recorded become stretches on the timeline; the movie is the same.
        var opened = project.opened(for: telemetry, duration: duration)
        // A background picture gone from the folder gives way to the default gradient in the project itself, so the
        // movie made with the picture is made again, and choosing the picture again is a change.
        var pictureGone = false
        if case .picture(let name) = opened.background,
           !FileManager.default.fileExists(atPath: StudioBackgroundPicture.url(named: name, in: folder).path(percentEncoded: false)) {
            opened.background = .gradient(Self.missingPictureGradient)
            pictureGone = true
        }
        self.project = opened
        self.duration = duration
        self.recordingSize = recordingSize
        sourceByteCount = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.folder = folder
        self.background = background
        let camera = folder.appending(path: StudioFiles.camera)
        cameraMovie = telemetry.camera != nil && FileManager.default.fileExists(atPath: camera.path(percentEncoded: false)) ? camera : nil
        soundFiles = StudioSound.files(in: folder)
        hasUnexportedChanges = !hasBeenExported || pictureGone
        // Pictures chosen for the background the last time it was open and since put aside can't be taken back
        // with Undo any more: only the one in use stays, with any the project as saved names, in a form this
        // version may not read. Opened on defaults because the project couldn't be read, every picture stays.
        if case .picture(let name) = self.project.background { lastPicture = name }
        if let saved = try? Data(contentsOf: folder.appending(path: StudioFiles.project)) {
            let text = String(decoding: saved, as: UTF8.self)
            let kept = lastPicture
            StudioBackgroundPicture.removeUnused(in: folder) { $0 == kept || text.contains($0) }
        }
        if self.project == project, FileManager.default.fileExists(atPath: folder.appending(path: StudioFiles.project).path) {
            savedRevision = 0
        } else {
            saveState = .pending
        }
    }

    deinit {
        pendingSave?.cancel()
        rebuild?.cancel()
        previewBuild?.cancel()
        waveformTask?.cancel()
    }

    /// Extracts normalized peak amplitude bins for the timeline waveform silhouette off the main actor.
    public func loadWaveform() {
        waveformTask?.cancel()
        let urls = soundFiles.isEmpty ? [source] : soundFiles.map(\.url)
        waveformTask = Task { [weak self] in
            let peaks = await StudioWaveform.extract(from: urls, binCount: 200)
            guard !Task.isCancelled, let self else { return }
            self.waveform = peaks
        }
    }

    /// Whether a camera was recorded beside the recording, so it can be shown.
    public var hasCamera: Bool {
        cameraMovie != nil
    }

    /// The telemetry the movie is drawn from: the camera's too, only while its movie is there. Without it the
    /// movie holds the recording alone, however the project lays the camera out (a Side by side movie
    /// wouldn't leave an empty picture beside the recording). The telemetry itself keeps the camera, for
    /// `cameraFailed` to say so.
    var drawnTelemetry: StudioTelemetry {
        var drawn = telemetry
        if cameraMovie == nil { drawn.camera = nil }
        return drawn
    }

    /// Where everything goes in the movie as the project is now, no larger than `largestSide` (or the project's
    /// export limit when nil).
    func movieLayout(largestSide: Double? = nil) -> StudioRenderer.Layout {
        StudioRenderer.layout(
            recordingSize: recordingSize, project: project, hasCamera: hasCamera,
            largestSide: largestSide ?? project.resolvedOutputMaxSide
        )
    }

    /// Whether the camera showed while recording but couldn't be recorded, or its movie is gone since.
    public var cameraFailed: Bool {
        !hasCamera && (telemetry.cameraFailed == true || telemetry.camera != nil)
    }

    /// The sounds the movie can play, each set on its own; empty for a recording without sound, or before the
    /// preview is first made.
    public var sounds: [StudioSound] {
        composition?.sounds ?? []
    }

    /// Mutes `sound`, or plays it again, as one step that Undo names.
    public func setMuted(_ muted: Bool, _ sound: StudioSound) {
        change(named: muted ? String(localized: "Mute", bundle: .module) : String(localized: "Unmute", bundle: .module)) {
            project.audio[sound].isMuted = muted
        }
    }

    /// Mutes or unmutes all audio via the master level as one named Undo step.
    public func setMasterMuted(_ muted: Bool) {
        guard project.audio.master.isMuted != muted else { return }
        change(named: muted ? String(localized: "Mute Audio", bundle: .module) : String(localized: "Unmute Audio", bundle: .module)) {
            project.audio.master.isMuted = muted
        }
    }

    public func setAudioFadeIn(_ seconds: Double) {
        let clamped = StudioProject.Audio.clampedFade(seconds)
        guard project.audio.fadeIn != clamped else { return }
        project.audio.fadeIn = clamped
    }

    public func setAudioFadeOut(_ seconds: Double) {
        let clamped = StudioProject.Audio.clampedFade(seconds)
        guard project.audio.fadeOut != clamped else { return }
        project.audio.fadeOut = clamped
    }

    /// Whether displayable keys (excluding unrecorded typing placeholders under Shortcuts only) were written down
    /// while recording, so they can be shown.
    public var hasKeys: Bool {
        telemetry.keys.contains { $0.keyCode != StudioTelemetry.Key.unrecordedKeyCode }
    }

    /// Makes the preview's composition again from the project as it is now; the newest one asked for wins.
    /// The preview is filmed no larger than it shows, which keeps the frames played ahead small: at the
    /// export's 4K, a full-screen recording held some 400 MB of them while it played.
    public func makeComposition() async {
        rebuild?.cancel()
        rebuild = nil
        await buildPreview()
    }

    private func buildPreview() async {
        generation += 1
        let mine = generation
        previewBuild?.cancel()
        let side = previewLargestSide()
        previewSide = side
        previewState = composition == nil ? .preparing : .updating
        let snapshot = project
        if snapshot.camera.background != .original, previewMatte == nil { previewMatte = StudioCameraMatte(quality: .preview) }
        let matte = snapshot.camera.background == .original ? nil : previewMatte
        let task = Task { try await composition(project: snapshot, largestSide: side, cameraMatte: matte) }
        previewBuild = task
        do {
            let made = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard mine == generation, !Task.isCancelled else { return }
            composition = made
            previewState = .ready
            compositionGeneration += 1
        } catch {
            guard mine == generation, !(error is CancellationError), !Task.isCancelled else { return }
            Log.studio.error("Making the Studio composition failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            previewState = .failed(error.localizedDescription)
        }
        if mine == generation { previewBuild = nil }
    }

    /// The composition the export writes: the project as it is now, at the movie's export resolution, the person in the
    /// camera found with Vision's accurate matte.
    public func makeExportComposition(project snapshot: StudioProject? = nil) async throws -> StudioComposition {
        try Task.checkCancellation()
        let exported = snapshot ?? project
        let matte = exported.camera.background == .original ? nil : StudioCameraMatte(quality: .export)
        return try await composition(project: exported, largestSide: exported.resolvedOutputMaxSide, cameraMatte: matte)
    }

    func previewFailed(_ message: String) {
        isPlaying = false
        previewState = .failed(message)
    }

    /// Releases preview work on close. An export has its own snapshot and task and is not cancelled here.
    func releasePreview() {
        generation += 1
        rebuild?.cancel()
        previewBuild?.cancel()
        waveformTask?.cancel()
        rebuild = nil
        previewBuild = nil
        waveformTask = nil
        composition = nil
        cachedMotion = nil
        previewMatte = nil
    }

    #if DEBUG
    public func releaseDiagnosticPreview() { releasePreview() }
    #endif

    /// Tells the document how large the preview is, in pixels; the preview is filmed again when that asks
    /// for a different size.
    public func setPreviewSize(_ pixels: CGSize) {
        guard pixels.width > 0, pixels.height > 0, pixels != previewPixels else { return }
        previewPixels = pixels
        // Before the first composition is asked for, it is made at this size anyway.
        guard let previewSide, previewLargestSide() != previewSide else { return }
        scheduleComposition()
    }

    private func composition(project: StudioProject, largestSide: Double, cameraMatte: StudioCameraMatte?) async throws -> StudioComposition {
        try Task.checkCancellation()
        if let compositionLoader { return try await compositionLoader(project, largestSide) }
        let telemetry = drawnTelemetry
        let track = try await preparedMotion(for: project)
        try Task.checkCancellation()
        // The user's accent, as the rings shown while recording take it.
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let ringColor = accent.map { StudioRenderer.RingColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) } ?? .systemBlue
        return try await Self.assemble(
            project: project, telemetry: telemetry, duration: duration, recordingSize: recordingSize,
            largestSide: largestSide, track: track, source: source, cameraMovie: cameraMovie, folder: folder, soundFiles: soundFiles,
            background: background, ringColor: ringColor, cameraMatte: cameraMatte
        )
    }

    /// A single completed motion track per document. Export and preview share its immutable frame storage;
    /// a cancelled preview never owns or cancels the export's work.
    func preparedMotion(for project: StudioProject) async throws -> StudioTrack {
        try Task.checkCancellation()
        let key = StudioMotionKey(project)
        if let cachedMotion, cachedMotion.key == key { return cachedMotion.track }
        let track = try await StudioTrack.make(telemetry: telemetry, project: project, duration: duration)
        try Task.checkCancellation()
        motionBuildCount += 1
        if key == StudioMotionKey(self.project) { cachedMotion = (key, track) }
        return track
    }

    @concurrent
    private static func assemble(
        project: StudioProject, telemetry: StudioTelemetry, duration: Double, recordingSize: CGSize,
        largestSide: Double, track: StudioTrack, source: URL, cameraMovie: URL?, folder: URL, soundFiles: [(sound: StudioSound, url: URL)],
        background: @Sendable (String, CGSize) -> CGImage?, ringColor: StudioRenderer.RingColor, cameraMatte: StudioCameraMatte?
    ) async throws -> StudioComposition {
        try Task.checkCancellation()
        // Worked out once, for the background painted at the movie's size and for the renderer. `telemetry` is the
        // drawn one, with a camera exactly where there is a camera's movie, as the layout has to agree.
        let layout = StudioRenderer.layout(recordingSize: recordingSize, project: project, hasCamera: cameraMovie != nil, largestSide: largestSide)
        let picture: CGImage? = switch project.background {
        case .gradient(let name): background(name, layout.canvas)
        // Read no larger than the movie shows it; gone from the folder, the default gradient stands in.
        case .picture(let name):
            StudioBackgroundPicture.image(named: name, in: folder, covering: layout.canvas) ?? background(Self.missingPictureGradient, layout.canvas)
        case .color, .blur: nil
        }
        try Task.checkCancellation()
        let renderer = StudioRenderer(
            telemetry: telemetry, project: project, duration: duration, recordingSize: recordingSize, background: picture,
            layout: layout, ringColor: ringColor, preparedTrack: track, cameraMatte: cameraMatte
        )
        try Task.checkCancellation()
        let camera = cameraMovie.map { StudioComposition.CameraSource(asset: AVURLAsset(url: $0), start: telemetry.camera?.start ?? 0) }
        let sounds = soundFiles.map { StudioComposition.SoundSource(sound: $0.sound, asset: AVURLAsset(url: $0.url)) }
        return try await StudioComposition.make(
            source: AVURLAsset(url: source), renderer: renderer, cuts: project.cuts, speeds: project.speeds, camera: camera, sounds: sounds
        )
    }

    /// The gradient a background picture that has gone from the project's folder gives way to: the default one.
    nonisolated static let missingPictureGradient = "sky"

    /// The longest side the preview needs: the movie fitted in the preview's pixels, in steps of 128 so a
    /// small change of the window's size films nothing again, between 640 and the export's.
    private func previewLargestSide() -> Double {
        let cap = max(640, project.resolvedOutputMaxSide)
        guard let pixels = previewPixels else { return min(1920, cap) }
        let full = movieLayout().canvas
        guard full.width > 0, full.height > 0 else { return min(1920, cap) }
        let fit = min(pixels.width / full.width, pixels.height / full.height)
        let side = max(full.width, full.height) * fit
        return min(max((side / 128).rounded(.up) * 128, 640), cap)
    }

    // MARK: Editing

    /// Zooms on the clicks and the typing, or none of them: placed again from what happened, keeping the
    /// zooms placed or changed by hand.
    public func setAutomaticZooms(_ on: Bool) {
        var changed = project
        changed.automaticZooms = on
        var zooms = project.zooms.filter { !$0.isAutomatic }
        if on {
            // A zoom placed by hand wins where the two meet, and the automatic ones on either side of it stay apart.
            let hand = zooms
            zooms += AutoZoom.zooms(for: telemetry, duration: duration, around: hand)
                .filter { auto in !hand.contains { $0.start < auto.end && auto.start < $0.end } }
        }
        changed.zooms = zooms.sorted { $0.start < $1.start }
        change(named: on ? String(localized: "Zoom on Clicks", bundle: .module) : String(localized: "No Zoom on Clicks", bundle: .module)) {
            project = changed
        }
    }

    /// Whether the project's zooms already match the recording's automatic zooms.
    public var matchesAutomaticZooms: Bool {
        guard project.automaticZooms else { return false }
        let expected = automaticZooms
        guard project.zooms.count == expected.count else { return false }
        return zip(project.zooms, expected).allSatisfy { a, b in
            a.isAutomatic && a.start == b.start && a.end == b.end && a.scale == b.scale && a.target == b.target
        }
    }

    /// Replaces all zooms (manual and automatic) with the recording's automatic zooms in one undoable step.
    public func resetToAutomaticZooms() {
        var changed = project
        changed.automaticZooms = true
        changed.zooms = automaticZooms
        change(named: String(localized: "Reset to Automatic", bundle: .module)) {
            project = changed
        }
    }

    /// Removes all zooms and turns automatic zooms off in one undoable step.
    public func clearAllZooms() {
        var changed = project
        changed.automaticZooms = false
        changed.zooms = []
        change(named: String(localized: "Clear All Zooms", bundle: .module)) {
            project = changed
        }
    }

    /// Sets the video crop rectangle (normalized `0...1`, top-left origin, or `nil` for full frame) as a named
    /// Undo step (coalescing when wrapped in `beginContinuousChange()` / `endContinuousChange()`).
    public func setCrop(_ rect: CGRect?) {
        let normalized = StudioProject.normalizedCrop(rect)
        guard project.crop != normalized else { return }
        change(named: String(localized: "Crop Video", bundle: .module)) {
            project.crop = normalized
        }
    }

    /// Clears any active video crop back to the full recording.
    public func resetCrop() {
        guard project.crop != nil else { return }
        change(named: String(localized: "Reset Crop", bundle: .module)) {
            project.crop = nil
        }
    }

    /// Makes the picture at `url` the background, kept in the project's folder (read and, when it is larger than
    /// a background needs, made smaller off the main actor). Throws when it isn't a picture that can be read.
    public func choosePicture(at url: URL) async throws {
        let folder = folder
        let name = try await Self.keepPicture(url, in: folder)
        lastPicture = name
        project.background = .picture(name)
    }

    @concurrent
    private static func keepPicture(_ url: URL, in folder: URL) async throws -> String {
        try StudioBackgroundPicture.keep(url, in: folder)
    }

    /// The tile of the background picture named `name`, for the inspector; nil when it can't be read.
    public func pictureThumbnail(_ name: String) -> CGImage? {
        if let cached = pictureThumbnails[name] { return cached }
        let made = StudioBackgroundPicture.thumbnail(named: name, in: folder, longest: Self.tileSide)
        if let made { pictureThumbnails[name] = made }
        return made
    }

    /// A frame from the middle of the recording, blurred as the Blurred recording background blurs it, for its
    /// tile in the inspector, read once; nil when the recording can't be read.
    public func blurredRecordingThumbnail() async -> CGImage? {
        if let blurredThumbnail { return blurredThumbnail }
        blurredThumbnail = await Self.blurredFrame(of: source, at: duration / 2)
        return blurredThumbnail
    }

    @concurrent
    private static func blurredFrame(of source: URL, at time: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.maximumSize = CGSize(width: tileSide, height: tileSide)
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { return nil }
        let image = CIImage(cgImage: frame)
        let side = max(image.extent.width, image.extent.height)
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: side * StudioRenderer.blurStrength)
            .cropped(to: image.extent)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: image.extent)
    }

    /// The longer side of a background tile's picture, in pixels: the 44 pt tile at two pixels a point.
    nonisolated static let tileSide = 88

    /// Sets how closely the movie is encoded, as one step that Undo names.
    public func setQuality(_ quality: StudioProject.Quality) {
        change(named: String(localized: "Change Quality", bundle: .module)) {
            project.quality = quality
        }
    }

    /// Sets the export's maximum side in pixels (nil for Original up to 4K), as one step that Undo names.
    public func setOutputMaxSide(_ maxSide: Int?) {
        change(named: String(localized: "Change Resolution", bundle: .module)) {
            project.outputMaxSide = maxSide
        }
    }

    /// Sets the export's frame rate in frames per second (nil for 60 fps), as one step that Undo names.
    public func setFramesPerSecond(_ framesPerSecond: Int?) {
        change(named: String(localized: "Change Frame Rate", bundle: .module)) {
            project.framesPerSecond = framesPerSecond
        }
    }

    /// About how many bytes the movie will be as the project is now: its canvas at the export's size, the
    /// recording's cuts left out. Nil when the recording's size isn't known.
    public var estimatedMovieByteCount: Int? {
        let kept = keptSegments.reduce(0) { $0 + $1.duration }
        return StudioExporter.estimatedByteCount(
            sourceByteCount: sourceByteCount, sourceSize: recordingSize, sourceDuration: duration,
            canvas: movieLayout().canvas, keptDuration: kept, quality: project.quality
        )
    }

    /// The zooms the clicks and the typing place; empty when the recording holds no two clicks or keys close
    /// enough together to follow.
    public var automaticZooms: [StudioProject.Zoom] {
        AutoZoom.zooms(for: telemetry, duration: duration)
    }

    /// Whether the recording holds a click or a key to follow at all: when it places no zoom, it held too few, or
    /// too spread out.
    public var hasEventsToFollow: Bool {
        AutoZoom.hasEvents(in: telemetry)
    }

    /// Whether keys were written down, so typing can place zooms as clicks do.
    public var hasKeyPresses: Bool {
        telemetry.keystrokeMode != nil
    }

    /// A zoom at the playhead, two seconds long, at the standard scale, in the room the others leave.
    /// Where Add Zoom puts a zoom: at the playhead, past every zoom that holds its place, up to 2 seconds long and at
    /// least half a second; nil when there is no such room.
    private var roomForZoom: (start: Double, end: Double)? {
        let length = 2.0
        var start = min(max(time, 0), max(duration - 0.5, 0))
        // Past every zoom that holds the playhead's place, those that touch included.
        while let blocking = project.zooms.first(where: { $0.start <= start && start < $0.end }) { start = blocking.end }
        let next = project.zooms.filter { $0.start >= start }.map(\.start).min() ?? duration
        let end = min(start + length, next, duration)
        return end - start >= 0.5 ? (start, end) : nil
    }

    /// Whether Add Zoom has room at the playhead.
    public var canAddZoom: Bool { roomForZoom != nil }

    public func addZoom() {
        guard let (start, end) = roomForZoom else { return }
        let zoom = StudioProject.Zoom(start: start, end: end, scale: AutoZoom.standardScale, isAutomatic: false)
        change(named: String(localized: "Add Zoom", bundle: .module)) {
            project.zooms = (project.zooms + [zoom]).sorted { $0.start < $1.start }
        }
        selection = .zoom(zoom.id)
    }

    /// Changes a zoom, kept inside the recording and at least `StudioProject.shortestZoom` long: its start no later
    /// than that before the recording's end, its end pushed out to that past its start.
    public func updateZoom(_ id: UUID, _ change: (inout StudioProject.Zoom) -> Void) {
        guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
        var zoom = project.zooms[index]
        change(&zoom)
        // Changed by hand, it is no longer placed again with the automatic ones.
        zoom.isAutomatic = false
        zoom.start = max(0, min(zoom.start, duration - StudioProject.shortestZoom))
        zoom.end = min(duration, max(zoom.end, zoom.start + StudioProject.shortestZoom))
        project.zooms[index] = zoom
    }

    /// Moves one end of a zoom to `time`, the other staying where it is: an end taken past the other stops
    /// `StudioProject.shortestZoom` short of it. `updateZoom` alone pushes the end out from the start, which
    /// would move the end a start was dragged against. Returns where the zoom is then, for a field to show
    /// what the time typed became; nil when there is no such zoom.
    @discardableResult
    public func setZoomEdge(_ id: UUID, start: Bool, to time: Double) -> ClosedRange<Double>? {
        updateZoom(id) { zoom in
            if start { zoom.start = min(time, zoom.end - StudioProject.shortestZoom) } else { zoom.end = max(time, zoom.start + StudioProject.shortestZoom) }
        }
        return project.zooms.first { $0.id == id }.map { $0.start...$0.end }
    }

    /// Holds a zoom on `target`, kept inside the recording, or has it follow the pointer again (nil). Aimed by hand,
    /// an automatic zoom is no longer placed again with the others, as with any other change to it.
    public func setZoomTarget(_ id: UUID, _ target: StudioProject.Zoom.Spot?) {
        updateZoom(id) { $0.target = target?.clamped }
    }

    /// Where a zoom looks as the movie is now: its spot, or, following the pointer, where the camera looks in the
    /// frame the preview shows while the zoom is fully in there, else halfway through it, which is fully in; the
    /// middle of the recording until a movie is made.
    public func aim(of id: UUID) -> StudioProject.Zoom.Spot {
        let crop = project.effectiveCrop
        let fallback = StudioProject.Zoom.Spot(x: Double(crop.midX), y: Double(crop.midY))
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return fallback }
        if let target = zoom.target { return target }
        guard let track = composition?.renderer.track, track.width > 0, track.height > 0 else { return fallback }
        let frame = track.frame(at: isFullyIn(zoom) ? shownTime : (zoom.start + zoom.end) / 2)
        return StudioProject.Zoom.Spot(x: frame.centerX / track.width, y: frame.centerY / track.height).clamped
    }

    /// The recording's time of the frame the preview shows: the playhead's, or, inside a cut, the cut's end.
    public var shownTime: Double {
        recordingTime(movieTime(time))
    }

    /// Whether `zoom` is fully in in the frame the preview shows: there, done coming in, and not under a stronger one.
    func isFullyIn(_ zoom: StudioProject.Zoom) -> Bool {
        guard let track = composition?.renderer.track else { return false }
        let time = shownTime
        return time >= zoom.start && time <= zoom.end && abs(track.frame(at: time).zoom - zoom.scale) < 0.01
    }

    /// Removes the chosen zoom or camera layout, takes back the chosen cut, or cuts the chosen stretch.
    public func deleteSelection() {
        switch selection {
        case .zoom(let id): removeZoom(id)
        case .cameraSegment(let id): removeCameraSegment(id)
        case .cut(let start): restoreCut(at: start)
        case .speed(let start): removeSpeed(at: start)
        case .range(let range): cut(range)
        case .none: break
        }
    }

    // MARK: Speed

    /// Whether Speed has a stretch to set: one chosen on the clip, or a speed chosen on the timeline.
    public var canSetSpeed: Bool {
        selectedRange != nil || selectedSpeed != nil
    }

    /// The speed the chosen stretch plays at: the chosen speed's, or 1 for a stretch chosen on the clip.
    public var chosenRate: Double? {
        if let start = selectedSpeed { return project.speeds.first { $0.start == start }?.rate }
        return selectedRange == nil ? nil : 1
    }

    /// Plays what is chosen, a stretch of the clip or a speed on the timeline, at `rate` (1 as recorded), as one
    /// step that Undo names. A stretch takes the speeds it overlaps out of where it is; the speed it becomes is chosen.
    public func setSpeed(_ rate: Double) {
        let range: ClosedRange<Double>
        if let start = selectedSpeed, let speed = project.speeds.first(where: { $0.start == start }) {
            range = speed.start...speed.end
        } else if let chosen = selectedRange {
            range = chosen
        } else {
            return
        }
        let lower = max(0, range.lowerBound), upper = min(duration, range.upperBound)
        // A new stretch is at least a twentieth of a second; a speed already set changes, or goes, however short it was left.
        guard upper > lower, selectedSpeed != nil || upper - lower >= 0.05 else { return }
        // What the others keep outside the stretch, then the stretch itself.
        var speeds = project.speeds.flatMap { speed -> [StudioProject.Speed] in
            guard speed.end > lower, speed.start < upper else { return [speed] }
            return [
                StudioProject.Speed(start: speed.start, end: lower, rate: speed.rate),
                StudioProject.Speed(start: upper, end: speed.end, rate: speed.rate),
            ]
        }
        speeds.append(StudioProject.Speed(start: lower, end: upper, rate: rate))
        change(named: rate == 1 ? String(localized: "Remove Speed", bundle: .module) : String(localized: "Change Speed", bundle: .module)) {
            project.speeds = StudioProject.normalizedSpeeds(speeds, duration: duration)
        }
        selection = rate == 1 ? .none : .speed(lower)
    }

    /// Plays the stretch that starts at `start` as recorded again.
    public func removeSpeed(at start: Double) {
        change(named: String(localized: "Remove Speed", bundle: .module)) {
            project.speeds.removeAll { $0.start == start }
        }
        if selection == .speed(start) { selection = .none }
    }

    /// Where Add Speed places a speed stretch: at the playhead, past any speed occupying that place, up to
    /// 2 seconds long and at least 0.25 s; nil when there is no room.
    private var roomForSpeed: (start: Double, end: Double)? {
        let length = 2.0
        let shortest = 0.25
        var start = min(max(time, 0), max(duration - shortest, 0))
        while let blocking = project.speeds.first(where: { $0.start <= start && start < $0.end }) {
            start = blocking.end
        }
        let next = project.speeds.filter { $0.start >= start }.map(\.start).min() ?? duration
        let end = min(start + length, next, duration)
        return end - start >= shortest ? (start, end) : nil
    }

    /// Whether Add Speed has room at the playhead.
    public var canAddSpeed: Bool { roomForSpeed != nil }

    /// Adds a speed stretch at the playhead in the room adjacent speeds leave.
    public func addSpeed(rate: Double = 2) {
        guard let (start, end) = roomForSpeed else { return }
        let minRate = StudioProject.speedRates.min() ?? 0.5
        let maxRate = StudioProject.speedRates.max() ?? 4
        let clamped = rate.isFinite ? min(max(rate, minRate), maxRate) : 2
        let effectiveRate = abs(clamped - 1) > 0.01 ? clamped : 2
        let speed = StudioProject.Speed(start: start, end: end, rate: effectiveRate)
        let normalized = StudioProject.normalizedSpeeds(project.speeds + [speed], duration: duration)
        change(named: String(localized: "Add Speed", bundle: .module)) {
            project.speeds = normalized
        }
        if let placed = normalized.first(where: { $0.start <= start && start < $0.end }) {
            selection = .speed(placed.start)
        }
    }

    /// How far the speed stretch starting at `start` can reach before meeting an adjacent speed or the recording's ends.
    public func limits(ofSpeedAt start: Double) -> ClosedRange<Double> {
        guard let index = project.speeds.firstIndex(where: { $0.start == start }) else { return 0...max(0, duration) }
        let speed = project.speeds[index]
        let minBound = index > 0 ? min(speed.start, project.speeds[index - 1].end) : 0
        let maxBound = index + 1 < project.speeds.count ? max(speed.end, project.speeds[index + 1].start) : max(speed.end, duration)
        return minBound...max(minBound, maxBound)
    }

    /// Moves the speed stretch starting at `speedStart` to start at `newStart`, preserving its duration within its
    /// neighbor limits. Keeps the speed selected if it was selected before.
    @discardableResult
    public func moveSpeed(at speedStart: Double, to newStart: Double) -> ClosedRange<Double>? {
        guard let index = project.speeds.firstIndex(where: { $0.start == speedStart }) else { return nil }
        let speed = project.speeds[index]
        let length = speed.end - speed.start
        let bounds = limits(ofSpeedAt: speedStart)
        let clampedStart = min(max(newStart, bounds.lowerBound), max(bounds.lowerBound, bounds.upperBound - length))
        let clampedEnd = min(bounds.upperBound, clampedStart + length)
        let updated = StudioProject.Speed(start: clampedStart, end: clampedEnd, rate: speed.rate)
        guard updated != speed else { return speed.start...speed.end }
        let wasSelected = selection == .speed(speedStart)
        change(named: String(localized: "Move Speed", bundle: .module)) {
            project.speeds[index] = updated
        }
        if wasSelected { selection = .speed(updated.start) }
        return updated.start...updated.end
    }

    /// Resizes the speed stretch starting at `speedStart` to `newStart...newEnd`, clamped within its neighbor limits
    /// and at least `StudioProject.shortestSpeed` long. Keeps the speed selected if it was selected before.
    @discardableResult
    public func resizeSpeed(at speedStart: Double, start newStart: Double, end newEnd: Double) -> ClosedRange<Double>? {
        guard let index = project.speeds.firstIndex(where: { $0.start == speedStart }) else { return nil }
        let speed = project.speeds[index]
        let bounds = limits(ofSpeedAt: speedStart)
        let shortest = min(StudioProject.shortestSpeed, max(0, bounds.upperBound - bounds.lowerBound))
        let clampedStart = min(max(newStart, bounds.lowerBound), bounds.upperBound - shortest)
        let clampedEnd = min(max(newEnd, clampedStart + shortest), bounds.upperBound)
        let updated = StudioProject.Speed(start: clampedStart, end: clampedEnd, rate: speed.rate)
        guard updated != speed else { return speed.start...speed.end }
        let wasSelected = selection == .speed(speedStart)
        change(named: String(localized: "Resize Speed", bundle: .module)) {
            project.speeds[index] = updated
        }
        if wasSelected { selection = .speed(updated.start) }
        return updated.start...updated.end
    }

    /// Moves one end of the speed stretch starting at `speedStart` to `time`, keeping the other end fixed and
    /// enforcing minimum length and neighbor bounds. Returns the resulting range, or nil if no such speed exists.
    @discardableResult
    public func setSpeedEdge(at speedStart: Double, start: Bool, to time: Double) -> ClosedRange<Double>? {
        guard let speed = project.speeds.first(where: { $0.start == speedStart }) else { return nil }
        if start {
            let clamped = min(time, speed.end - StudioProject.shortestSpeed)
            return resizeSpeed(at: speedStart, start: clamped, end: speed.end)
        } else {
            let clamped = max(time, speed.start + StudioProject.shortestSpeed)
            return resizeSpeed(at: speedStart, start: speed.start, end: clamped)
        }
    }

    // MARK: Camera layout

    /// Whether stretches of the movie can show the camera another way than its layout does: a camera was
    /// recorded, and the layout isn't side by side, which widens the whole movie and so can't come and go.
    public var canChangeLayoutAlongTheTimeline: Bool {
        hasCamera && project.camera.layout != .sideBySide
    }

    /// When the camera shows, as the movie will have it: its layout, the stretches of the timeline, and where
    /// the camera filled what was recorded while the project hasn't taken those as stretches.
    private var cameraPlan: StudioCameraPlan {
        StudioCameraPlan(camera: project.camera, segments: project.cameraSegments, recordedFills: telemetry.camera?.fills ?? [])
    }

    /// Whether the camera shows anywhere in the movie: in its layout, or in a stretch of the timeline. Its
    /// mirror applies wherever it does.
    public var showsCamera: Bool {
        hasCamera && cameraPlan.usesCamera
    }

    /// Whether the camera's bubble shows anywhere in the movie: its layout is the bubble, or a stretch is. Its
    /// shape, size, and corner apply wherever it does.
    public var showsBubble: Bool {
        let plan = cameraPlan
        return hasCamera && (plan.base == .pictureInPicture || plan.stretches.contains { $0.layout == .pictureInPicture })
    }

    /// A stretch of the camera's layout at the playhead, three seconds long, in the room the others leave: camera
    /// only, or the bubble where the layout is camera only already.
    private var roomForCameraSegment: (start: Double, end: Double)? {
        guard canChangeLayoutAlongTheTimeline else { return nil }
        let length = 3.0
        var start = min(max(time, 0), max(duration - StudioProject.shortestSegment, 0))
        // Past every stretch that holds the playhead's place, those that touch included.
        while let blocking = project.cameraSegments.first(where: { $0.start <= start && start < $0.end }) { start = blocking.end }
        let next = project.cameraSegments.filter { $0.start >= start }.map(\.start).min() ?? duration
        let end = min(start + length, next, duration)
        return end - start >= StudioProject.shortestSegment ? (start, end) : nil
    }

    public var canAddCameraSegment: Bool { roomForCameraSegment != nil }

    public func addCameraSegment() {
        guard let (start, end) = roomForCameraSegment else { return }
        let segment = StudioProject.CameraSegment(
            start: start, end: end, layout: project.camera.layout == .cameraOnly ? .pictureInPicture : .cameraOnly
        )
        change(named: String(localized: "Add Layout", bundle: .module)) {
            project.cameraSegments = (project.cameraSegments + [segment]).sorted { $0.start < $1.start }
        }
        selection = .cameraSegment(segment.id)
    }

    /// How far a stretch can reach before it meets the one before it or the one after it, or the ends of the recording.
    public func limits(ofCameraSegment id: UUID) -> ClosedRange<Double> {
        guard let segment = project.cameraSegments.first(where: { $0.id == id }) else { return 0...duration }
        let before = project.cameraSegments.filter { $0.id != id && $0.end <= segment.start }.map(\.end).max() ?? 0
        let after = project.cameraSegments.filter { $0.id != id && $0.start >= segment.end }.map(\.start).min() ?? duration
        return before...max(before, after)
    }

    /// Changes a stretch, kept within its limits and at least `StudioProject.shortestSegment` long.
    public func updateCameraSegment(_ id: UUID, _ change: (inout StudioProject.CameraSegment) -> Void) {
        guard let index = project.cameraSegments.firstIndex(where: { $0.id == id }) else { return }
        let limits = limits(ofCameraSegment: id)
        var segment = project.cameraSegments[index]
        change(&segment)
        let shortest = StudioProject.shortestSegment
        segment.start = min(max(segment.start, limits.lowerBound), limits.upperBound - shortest)
        segment.end = min(max(segment.end, segment.start + shortest), limits.upperBound)
        project.cameraSegments[index] = segment
    }

    /// Moves one end of a stretch to `time`, the other staying where it is, as `setZoomEdge` does a zoom's: an end
    /// taken past the other stops `StudioProject.shortestSegment` short of it, and either stays within the
    /// stretch's limits. Returns where the stretch is then; nil when there is no such stretch.
    @discardableResult
    public func setCameraSegmentEdge(_ id: UUID, start: Bool, to time: Double) -> ClosedRange<Double>? {
        updateCameraSegment(id) { segment in
            if start { segment.start = min(time, segment.end - StudioProject.shortestSegment) }
            else { segment.end = max(time, segment.start + StudioProject.shortestSegment) }
        }
        return project.cameraSegments.first { $0.id == id }.map { $0.start...$0.end }
    }

    /// Shows the camera another way in the chosen stretch, as one step that Undo names.
    public func setCameraSegmentLayout(_ id: UUID, _ layout: StudioProject.Camera.Layout) {
        guard let index = project.cameraSegments.firstIndex(where: { $0.id == id }), layout != .sideBySide else { return }
        change(named: String(localized: "Change Layout", bundle: .module)) {
            project.cameraSegments[index].layout = layout
        }
    }

    public func removeCameraSegment(_ id: UUID) {
        change(named: String(localized: "Remove Layout", bundle: .module)) {
            project.cameraSegments.removeAll { $0.id == id }
        }
        if selection == .cameraSegment(id) { selection = .none }
    }

    public func removeZoom(_ id: UUID) {
        change(named: String(localized: "Remove Zoom", bundle: .module)) {
            project.zooms.removeAll { $0.id == id }
        }
        if selection == .zoom(id) { selection = .none }
    }

    /// The shortest cut, in seconds (matches `cut(_:)`).
    public static let shortestCut = 0.05
    /// Minimum gap kept between adjacent cuts while resizing so dragging an edge never merges a cut into its neighbor.
    public static let minimumCutGap = 0.05

    /// Takes back the cut that starts at `start`: that stretch is in the movie again.
    public func restoreCut(at start: Double) {
        change(named: String(localized: "Restore Cut", bundle: .module)) {
            project.cuts.removeAll { $0.lowerBound == start }
        }
        if selection == .cut(start) { selection = .none }
    }

    /// How far the cut starting at `start` can reach before it meets an adjacent cut or the recording's ends.
    public func limits(ofCutAt start: Double) -> ClosedRange<Double> {
        guard let index = project.cuts.firstIndex(where: { $0.lowerBound == start }) else { return 0...max(0, duration) }
        let cut = project.cuts[index]
        let minBound: Double = if index > 0 {
            min(cut.lowerBound, project.cuts[index - 1].upperBound + Self.minimumCutGap)
        } else {
            0
        }
        let maxBound: Double = if index + 1 < project.cuts.count {
            max(cut.upperBound, project.cuts[index + 1].lowerBound - Self.minimumCutGap)
        } else {
            max(cut.upperBound, duration)
        }
        return minBound...max(minBound, maxBound)
    }

    /// Resizes the cut starting at `cutStart` to `newStart...newEnd`, clamped within its neighbor limits and
    /// at least `shortestCut` long. Keeps the cut selected if it was selected before.
    @discardableResult
    public func resizeCut(at cutStart: Double, start newStart: Double, end newEnd: Double) -> ClosedRange<Double>? {
        guard let index = project.cuts.firstIndex(where: { $0.lowerBound == cutStart }) else { return nil }
        let cut = project.cuts[index]
        let bounds = limits(ofCutAt: cutStart)
        let shortest = min(Self.shortestCut, max(0, bounds.upperBound - bounds.lowerBound))
        let clampedStart = min(max(newStart, bounds.lowerBound), bounds.upperBound - shortest)
        let clampedEnd = min(max(newEnd, clampedStart + shortest), bounds.upperBound)
        guard clampedEnd >= clampedStart else { return cut }
        let updated = clampedStart...clampedEnd
        guard updated != cut else { return cut }
        let wasSelected = selection == .cut(cutStart)
        change(named: String(localized: "Resize Cut", bundle: .module)) {
            project.cuts[index] = updated
        }
        if wasSelected { selection = .cut(updated.lowerBound) }
        return updated
    }

    /// Moves one end of the cut starting at `cutStart` to `time`, keeping the other end fixed and the cut
    /// at least `shortestCut` long within its neighbor limits. Returns the resulting cut range, or nil when
    /// no cut starts at `cutStart`.
    @discardableResult
    public func setCutEdge(at cutStart: Double, start: Bool, to time: Double) -> ClosedRange<Double>? {
        guard let cut = project.cuts.first(where: { $0.lowerBound == cutStart }) else { return nil }
        if start {
            let clamped = min(time, cut.upperBound - Self.shortestCut)
            return resizeCut(at: cutStart, start: clamped, end: cut.upperBound)
        } else {
            let clamped = max(time, cut.lowerBound + Self.shortestCut)
            return resizeCut(at: cutStart, start: cut.lowerBound, end: clamped)
        }
    }

    /// Leaves `range` (the recording's seconds) out of the movie, joined with cuts it meets.
    public func cut(_ range: ClosedRange<Double>) {
        let lower = max(0, range.lowerBound), upper = min(duration, range.upperBound)
        guard upper - lower >= Self.shortestCut else { return }
        let cuts = StudioProject.normalizedCuts(project.cuts + [lower...upper], duration: duration)
        // The cut it became, with those it met: the cuts are apart, so only that one holds its start.
        guard let merged = cuts.first(where: { $0.contains(lower) }) else { return }
        change(named: String(localized: "Cut", bundle: .module)) {
            project.cuts = cuts
        }
        selection = .cut(merged.lowerBound)
    }

    /// Keeps only `range` (the recording's seconds) by cutting everything before and after it in one undoable step.
    public func keepOnly(_ range: ClosedRange<Double>) {
        let lower = max(0, min(range.lowerBound, duration))
        let upper = max(lower, min(range.upperBound, duration))
        guard upper - lower >= Self.shortestCut else { return }
        var additions: [ClosedRange<Double>] = []
        if lower >= Self.shortestCut { additions.append(0...lower) }
        if duration - upper >= Self.shortestCut { additions.append(upper...duration) }
        guard !additions.isEmpty else {
            if selection == .range(range) { selection = .none }
            return
        }
        let cuts = StudioProject.normalizedCuts(project.cuts + additions, duration: duration)
        guard cuts != project.cuts else {
            selection = .none
            return
        }
        change(named: String(localized: "Keep Only", bundle: .module)) {
            project.cuts = cuts
        }
        selection = .none
    }

    // MARK: Undo

    /// Changes made from here until `endContinuousChange()` (a slider or a zoom being dragged) are taken
    /// back as one.
    public func beginContinuousChange() {
        continuousRegistered = false
    }

    public func endContinuousChange() {
        continuousRegistered = nil
        scheduleSave(immediately: true)
    }

    /// Makes `body`'s change to the project as one step that Undo names `name`.
    private func change(named name: String, _ body: () -> Void) {
        namingChange = true
        body()
        namingChange = false
        undoManager?.setActionName(name)
    }

    private func registerUndo(back old: StudioProject) {
        guard let undoManager else { return }
        // Undoing and redoing register their way back as they are.
        if !undoManager.isUndoing, !undoManager.isRedoing {
            if let registered = continuousRegistered {
                guard !registered else { return }
                continuousRegistered = true
            } else if !namingChange {
                let now = Date()
                defer { lastUnnamedChange = now }
                if let last = lastUnnamedChange, now.timeIntervalSince(last) < 0.4 { return }
            }
        }
        if namingChange { lastUnnamedChange = nil }
        undoManager.registerUndo(withTarget: self) { document in
            document.project = old
        }
    }

    // MARK: Time

    /// The parts of the recording the movie keeps, as its composition lays them end to end: the playhead's
    /// time and the movie's are read through the same parts the compositor draws each frame from, so the
    /// playhead is never anywhere but on the frame shown.
    private var keptSegments: [StudioComposition.Segment] {
        StudioComposition.keptSegments(duration: duration, cuts: project.cuts, speeds: project.speeds)
    }

    /// The movie's time for the recording's `time`: the end of a cut for a time inside one.
    public func movieTime(_ time: Double) -> Double {
        StudioComposition.movieTime(forSource: time, in: keptSegments)
    }

    /// The recording's time for the movie's `time`.
    public func recordingTime(_ time: Double) -> Double {
        let segments = keptSegments
        // With all of it cut the movie is empty, and its one time is the recording's end, where the playhead stays.
        guard !segments.isEmpty else { return duration }
        return StudioComposition.sourceTime(time, in: segments)
    }

    // MARK: Keeping

    /// Requests an immediate asynchronous save. Call `flushSave` when the caller must wait for the file.
    public func save() {
        scheduleSave(immediately: true)
    }

    /// Waits for the newest revision, including edits made while an earlier snapshot was being written.
    /// Failed writes leave the document dirty and are surfaced to the window rather than merely logged.
    public func flushSave() async throws {
        pendingSave?.cancel()
        pendingSave = nil
        try await persistLatest()
    }

    private func persistLatest() async throws {
        while savedRevision < projectRevision {
            let revision = projectRevision
            let snapshot = project
            saveState = .saving
            do {
                try await projectWriter.save(snapshot, revision: revision, to: folder.appending(path: StudioFiles.project))
                savedRevision = max(savedRevision, revision)
                saveState = savedRevision == projectRevision ? .saved : .pending
            } catch {
                // A failed superseded snapshot does not override the state of a newer save.
                if revision != projectRevision || savedRevision >= revision { continue }
                saveState = .failed(error.localizedDescription)
                Log.studio.error("Saving the Studio project failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
                throw error
            }
        }
    }

    private func scheduleSave(immediately: Bool = false) {
        guard hasPendingSave else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            try? await persistLatest()
        }
    }

    /// Internal storage injection for deterministic failure and ordering tests.
    func setProjectWriter(_ writer: StudioProjectWriter) {
        projectWriter = writer
    }

    public func markExported() {
        hasUnexportedChanges = false
    }

    private func projectChanged(from old: StudioProject) {
        hasUnexportedChanges = true
        projectRevision += 1
        saveState = .pending
        scheduleSave()
        // What is chosen and gone is no longer chosen: a zoom or a cut taken back, or a layout taken back or made
        // side by side.
        let gone = switch selection {
        case .zoom(let id): !project.zooms.contains { $0.id == id }
        case .cut(let start): !project.cuts.contains { $0.lowerBound == start }
        case .speed(let start): !project.speeds.contains { $0.start == start }
        case .cameraSegment(let id): !canChangeLayoutAlongTheTimeline || !project.cameraSegments.contains { $0.id == id }
        case .range, .none: false
        }
        if gone { selection = .none }
        // The preview isn't encoded, so the movie's quality is no reason to film it again, and the player sets how
        // loud each sound plays as it plays.
        var seen = project
        seen.quality = old.quality
        seen.audio = old.audio
        if seen != old { scheduleComposition() }
    }

    private func scheduleComposition() {
        // Invalidate immediately, including during the debounce, so an older in-flight result cannot win.
        generation += 1
        rebuild?.cancel()
        previewBuild?.cancel()
        previewState = composition == nil ? .preparing : .updating
        rebuild = Task { [weak self] in
            // Shortly after the last change, so a slider being dragged doesn't make a movie per step.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.buildPreview()
        }
    }
}

/// The files of a Studio project folder that Studio writes; the history keeps the recording as it was made
/// (source.mp4) and the settings of the movie it holds (exported.json) beside them.
nonisolated public enum StudioFiles {
    public static let telemetry = "telemetry.json"
    public static let project = "project.json"
    /// The camera, recorded in a movie of its own while the screen was.
    public static let camera = "camera.mov"
    /// The system's sound and the microphone, each as recorded, in a file of its own (`StudioSound`).
    public static let systemAudio = "system audio.m4a"
    public static let microphone = "microphone.m4a"

    /// Verifies that an asset filename stored in `project.json` is a safe single path component (no slashes or traversal).
    public static func isValidAssetName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            return false
        }
        return (name as NSString).lastPathComponent == name
    }
}
