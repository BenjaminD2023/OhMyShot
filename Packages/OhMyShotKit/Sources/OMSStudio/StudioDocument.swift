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

    /// The zoom chosen on the timeline, by its identifier.
    public var selectedZoom: UUID?
    /// The cut chosen on the timeline, by its start.
    public var selectedCut: Double?
    /// The movie the preview plays now; nil until it is first made.
    public private(set) var composition: StudioComposition?
    /// The newest composition couldn't be made (the recording couldn't be read).
    public private(set) var compositionFailed = false
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

    /// - Parameter background: paints a built-in gradient, by name, at a size in pixels.
    public init(
        source: URL, telemetry: StudioTelemetry, project: StudioProject, duration: Double, recordingSize: CGSize, folder: URL,
        hasBeenExported: Bool, background: @escaping @Sendable (String, CGSize) -> CGImage?
    ) {
        self.source = source
        self.telemetry = telemetry
        self.project = project
        self.duration = duration
        self.recordingSize = recordingSize
        sourceByteCount = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.folder = folder
        self.background = background
        let camera = folder.appending(path: StudioFiles.camera)
        cameraMovie = telemetry.camera != nil && FileManager.default.fileExists(atPath: camera.path(percentEncoded: false)) ? camera : nil
        hasUnexportedChanges = !hasBeenExported
    }

    /// Whether a camera was recorded beside the recording, so it can be shown.
    public var hasCamera: Bool {
        cameraMovie != nil
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
        generation += 1
        let mine = generation
        let side = previewLargestSide()
        previewSide = side
        do {
            let made = try await composition(largestSide: side)
            guard mine == generation else { return }
            composition = made
            compositionFailed = false
            compositionGeneration += 1
        } catch {
            Log.studio.error("Making the Studio composition failed: \(String(describing: error), privacy: .public)")
            guard mine == generation else { return }
            compositionFailed = true
        }
    }

    /// The composition the export writes: the project as it is now, at the movie's full size.
    public func makeExportComposition() async throws -> StudioComposition {
        try await composition(largestSide: StudioRenderer.largestSide)
    }

    /// Tells the document how large the preview is, in pixels; the preview is filmed again when that asks
    /// for a different size.
    public func setPreviewSize(_ pixels: CGSize) {
        guard pixels.width > 0, pixels.height > 0, pixels != previewPixels else { return }
        previewPixels = pixels
        // Before the first composition is asked for, it is made at this size anyway.
        guard let previewSide, previewLargestSide() != previewSide else { return }
        scheduleComposition()
    }

    private func composition(largestSide: Double) async throws -> StudioComposition {
        let project = project
        let telemetry = telemetry
        let duration = duration
        let size = recordingSize
        let layout = StudioRenderer.layout(recordingSize: size, project: project, largestSide: largestSide)
        var backdrop: CGImage?
        if case .gradient(let name) = project.background {
            backdrop = background(name, layout.canvas)
        }
        let picture = backdrop
        let source = source
        let cameraMovie = cameraMovie
        let cameraStart = telemetry.camera?.start ?? 0
        // The user's accent, as the rings shown while recording take it.
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let ringColor = accent.map { StudioRenderer.RingColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) } ?? .systemBlue
        return try await Task.detached(priority: .userInitiated) {
            let renderer = StudioRenderer(
                telemetry: telemetry, project: project, duration: duration, recordingSize: size, background: picture, largestSide: largestSide,
                ringColor: ringColor
            )
            let camera = cameraMovie.map { StudioComposition.CameraSource(asset: AVURLAsset(url: $0), start: cameraStart) }
            return try await StudioComposition.make(source: AVURLAsset(url: source), renderer: renderer, cuts: project.cuts, camera: camera)
        }.value
    }

    /// The longest side the preview needs: the movie fitted in the preview's pixels, in steps of 128 so a
    /// small change of the window's size films nothing again, between 640 and the export's.
    private func previewLargestSide() -> Double {
        guard let pixels = previewPixels else { return 1920 }
        let full = StudioRenderer.layout(recordingSize: recordingSize, project: project).canvas
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
            canvas: StudioRenderer.layout(recordingSize: recordingSize, project: project).canvas, keptDuration: kept, quality: project.quality
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
    public func addZoom() {
        let length = 2.0
        var start = min(max(time, 0), max(duration - 0.5, 0))
        if let blocking = project.zooms.first(where: { $0.start <= start && start < $0.end }) { start = blocking.end }
        let next = project.zooms.filter { $0.start > start }.map(\.start).min() ?? duration
        let end = min(start + length, next, duration)
        guard end - start >= 0.5 else { return }
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

    /// Removes the chosen zoom, or takes back the chosen cut.
    public func deleteSelection() {
        if let id = selectedZoom {
            removeZoom(id)
        } else if let start = selectedCut {
            restoreCut(at: start)
        }
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
        let clamped = max(0, range.lowerBound)...min(duration, range.upperBound)
        guard clamped.upperBound - clamped.lowerBound >= 0.05 else { return }
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

    /// The project saved in its folder, so the Studio window opens it as it was left.
    public func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(project).write(to: folder.appending(path: StudioFiles.project), options: .atomic)
        } catch {
            Log.studio.error("Saving the Studio project failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func markExported() {
        hasUnexportedChanges = false
    }

    private func projectChanged(from old: StudioProject) {
        hasUnexportedChanges = true
        save()
        // The preview isn't encoded, so the movie's quality is no reason to film it again.
        var seen = project
        seen.quality = old.quality
        if seen != old { scheduleComposition() }
    }

    private func scheduleComposition() {
        rebuild?.cancel()
        rebuild = Task { [weak self] in
            // Shortly after the last change, so a slider being dragged doesn't make a movie per step.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.makeComposition()
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
