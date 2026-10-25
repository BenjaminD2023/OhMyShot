import AppKit
import AVFoundation
import CoreGraphics
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

    /// The zoom chosen on the timeline, by its identifier. One thing is chosen at a time, a zoom, a cut, or a
    /// stretch of the camera's layout: choosing one lets go of the others, so Delete takes away what is shown as chosen.
    public var selection: StudioSelection = .none

    public var selectedZoom: UUID? {
        get { if case .zoom(let id) = selection { id } else { nil } }
        set {
            if let newValue { selection = .zoom(newValue) }
            else if case .zoom = selection { selection = .none }
        }
    }
    /// The cut chosen on the timeline, by its start.
    public var selectedCut: Double? {
        get { if case .cut(let start) = selection { start } else { nil } }
        set {
            if let newValue { selection = .cut(newValue) }
            else if case .cut = selection { selection = .none }
        }
    }
    /// The stretch of the camera's layout chosen on the timeline, by its identifier.
    public var selectedSegment: UUID? {
        get { if case .cameraSegment(let id) = selection { id } else { nil } }
        set {
            if let newValue { selection = .cameraSegment(newValue) }
            else if case .cameraSegment = selection { selection = .none }
        }
    }
    public var selectedRange: ClosedRange<Double>? {
        get { if case .range(let range) = selection { range } else { nil } }
        set {
            if let newValue { selection = .range(newValue) }
            else if case .range = selection { selection = .none }
        }
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
    /// Where the preview is, in the recording's seconds.
    public var time: Double = 0
    public var isPlaying = false
    /// Whether the project changed since it was last exported.
    public private(set) var hasUnexportedChanges = true

    @ObservationIgnored private let background: @Sendable (String, CGSize) -> CGImage?
    @ObservationIgnored private var rebuild: Task<Void, Never>?
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
        self.project = project.opened(for: telemetry, duration: duration)
        self.duration = duration
        self.recordingSize = recordingSize
        sourceByteCount = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.folder = folder
        self.background = background
        let camera = folder.appending(path: StudioFiles.camera)
        cameraMovie = telemetry.camera != nil && FileManager.default.fileExists(atPath: camera.path(percentEncoded: false)) ? camera : nil
        hasUnexportedChanges = !hasBeenExported
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

    /// Where everything goes in the movie as the project is now, no larger than `largestSide`.
    func movieLayout(largestSide: Double = StudioRenderer.largestSide) -> StudioRenderer.Layout {
        StudioRenderer.layout(recordingSize: recordingSize, project: project, hasCamera: hasCamera, largestSide: largestSide)
    }

    /// Whether the camera showed while recording but couldn't be recorded, or its movie is gone since.
    public var cameraFailed: Bool {
        !hasCamera && (telemetry.cameraFailed == true || telemetry.camera != nil)
    }

    /// Whether keys were written down while recording, so they can be shown.
    public var hasKeys: Bool {
        !telemetry.keys.isEmpty
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
        let task = Task { try await composition(project: snapshot, largestSide: side) }
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
            Log.studio.error("Making the Studio composition failed: \(String(describing: error), privacy: .public)")
            previewState = .failed(error.localizedDescription)
        }
        if mine == generation { previewBuild = nil }
    }

    /// The composition the export writes: the project as it is now, at the movie's full size.
    public func makeExportComposition(project snapshot: StudioProject? = nil) async throws -> StudioComposition {
        try Task.checkCancellation()
        return try await composition(project: snapshot ?? project, largestSide: StudioRenderer.largestSide)
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
        rebuild = nil
        previewBuild = nil
        composition = nil
        cachedMotion = nil
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

    private func composition(project: StudioProject, largestSide: Double) async throws -> StudioComposition {
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
            largestSide: largestSide, track: track, source: source, cameraMovie: cameraMovie, background: background, ringColor: ringColor
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
        largestSide: Double, track: StudioTrack, source: URL, cameraMovie: URL?,
        background: @Sendable (String, CGSize) -> CGImage?, ringColor: StudioRenderer.RingColor
    ) async throws -> StudioComposition {
        try Task.checkCancellation()
        let layout = StudioRenderer.layout(recordingSize: recordingSize, project: project, hasCamera: cameraMovie != nil, largestSide: largestSide)
        let picture: CGImage?
        if case .gradient(let name) = project.background { picture = background(name, layout.canvas) } else { picture = nil }
        try Task.checkCancellation()
        let renderer = StudioRenderer(
            telemetry: telemetry, project: project, duration: duration, recordingSize: recordingSize, background: picture,
            largestSide: largestSide, ringColor: ringColor, preparedTrack: track
        )
        try Task.checkCancellation()
        let camera = cameraMovie.map { StudioComposition.CameraSource(asset: AVURLAsset(url: $0), start: telemetry.camera?.start ?? 0) }
        return try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: project.cuts, camera: camera)
    }

    /// The longest side the preview needs: the movie fitted in the preview's pixels, in steps of 128 so a
    /// small change of the window's size films nothing again, between 640 and the export's.
    private func previewLargestSide() -> Double {
        guard let pixels = previewPixels else { return 1920 }
        let full = movieLayout().canvas
        guard full.width > 0, full.height > 0 else { return 1920 }
        let fit = min(pixels.width / full.width, pixels.height / full.height)
        let side = max(full.width, full.height) * fit
        return min(max((side / 128).rounded(.up) * 128, 640), StudioRenderer.largestSide)
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

    /// Sets how closely the movie is encoded, as one step that Undo names.
    public func setQuality(_ quality: StudioProject.Quality) {
        change(named: String(localized: "Change Quality", bundle: .module)) {
            project.quality = quality
        }
    }

    /// About how many bytes the movie will be as the project is now: its canvas at the export's size, the
    /// recording's cuts left out. Nil when the recording's size isn't known.
    public var estimatedMovieByteCount: Int? {
        let kept = StudioComposition.keptSegments(duration: duration, cuts: project.cuts).reduce(0) { $0 + $1.duration }
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
        selectedZoom = zoom.id
    }

    public func updateZoom(_ id: UUID, _ change: (inout StudioProject.Zoom) -> Void) {
        guard let index = project.zooms.firstIndex(where: { $0.id == id }) else { return }
        var zoom = project.zooms[index]
        change(&zoom)
        // Changed by hand, it is no longer placed again with the automatic ones.
        zoom.isAutomatic = false
        zoom.start = max(0, min(zoom.start, duration - 0.3))
        zoom.end = min(duration, max(zoom.end, zoom.start + 0.3))
        project.zooms[index] = zoom
    }

    /// Removes the chosen zoom or camera layout, or takes back the chosen cut.
    public func deleteSelection() {
        if let id = selectedZoom {
            removeZoom(id)
        } else if let id = selectedSegment {
            removeCameraSegment(id)
        } else if let start = selectedCut {
            restoreCut(at: start)
        } else if let range = selectedRange {
            cut(range)
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
        selectedSegment = segment.id
        selectedZoom = nil
        selectedCut = nil
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
        if selectedSegment == id { selectedSegment = nil }
    }

    public func removeZoom(_ id: UUID) {
        change(named: String(localized: "Remove Zoom", bundle: .module)) {
            project.zooms.removeAll { $0.id == id }
        }
        if selectedZoom == id { selectedZoom = nil }
    }

    /// Takes back the cut that starts at `start`: that stretch is in the movie again.
    public func restoreCut(at start: Double) {
        change(named: String(localized: "Restore Cut", bundle: .module)) {
            project.cuts.removeAll { $0.lowerBound == start }
        }
        if selectedCut == start { selectedCut = nil }
    }

    /// Leaves `range` (the recording's seconds) out of the movie, joined with cuts it meets.
    public func cut(_ range: ClosedRange<Double>) {
        let lower = max(0, range.lowerBound), upper = min(duration, range.upperBound)
        guard upper - lower >= 0.05 else { return }
        let clamped = lower...upper
        var merged = clamped
        var kept: [ClosedRange<Double>] = []
        for cut in project.cuts {
            if cut.overlaps(merged) || cut.upperBound == merged.lowerBound || cut.lowerBound == merged.upperBound {
                merged = min(cut.lowerBound, merged.lowerBound)...max(cut.upperBound, merged.upperBound)
            } else {
                kept.append(cut)
            }
        }
        change(named: String(localized: "Cut", bundle: .module)) {
            project.cuts = (kept + [merged]).sorted { $0.lowerBound < $1.lowerBound }
        }
        selectedCut = merged.lowerBound
        selectedZoom = nil
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

    /// The movie's time for the recording's `time`: the end of a cut for a time inside one.
    public func movieTime(_ time: Double) -> Double {
        var removed = 0.0
        for cut in project.cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if time <= cut.lowerBound { break }
            if time < cut.upperBound { return cut.lowerBound - removed }
            removed += cut.upperBound - cut.lowerBound
        }
        return time - removed
    }

    /// The recording's time for the movie's `time`.
    public func recordingTime(_ time: Double) -> Double {
        var result = time
        for cut in project.cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if result < cut.lowerBound { break }
            result += cut.upperBound - cut.lowerBound
        }
        return min(result, duration)
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
                Log.studio.error("Saving the Studio project failed: \(String(describing: error), privacy: .public)")
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
        if let id = selectedZoom, !project.zooms.contains(where: { $0.id == id }) { selectedZoom = nil }
        if let start = selectedCut, !project.cuts.contains(where: { $0.lowerBound == start }) { selectedCut = nil }
        // A layout chosen on the timeline that is gone (taken back, or the layout made side by side) is no longer chosen.
        if let id = selectedSegment, !canChangeLayoutAlongTheTimeline || !project.cameraSegments.contains(where: { $0.id == id }) {
            selectedSegment = nil
        }
        // The preview isn't encoded, so the movie's quality is no reason to film it again.
        var seen = project
        seen.quality = old.quality
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
}
