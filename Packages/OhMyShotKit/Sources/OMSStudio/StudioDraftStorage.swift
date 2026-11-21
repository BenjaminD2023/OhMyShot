import AVFoundation
import Foundation
import OMSCore
import OSLog

/// What a Studio recording keeps beside its draft movie so a crash, forced quit, or partial save failure
/// can recover the recording into Studio with its cursor, clicks, keys, and camera aligned to the movie.
nonisolated public struct StudioDraftTelemetry: Codable, Equatable, Sendable {
    public struct Pause: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double?

        public init(start: Double, end: Double? = nil) {
            self.start = start
            self.end = end
        }
    }

    public struct CameraFillChange: Codable, Equatable, Sendable {
        public var time: Double
        public var fills: Bool

        public init(time: Double, fills: Bool) {
            self.time = time
            self.fills = fills
        }
    }

    /// Raw host-clock telemetry while recording (`isRetimed == false`), or movie-timeline telemetry once
    /// stopped (`isRetimed == true`).
    public var telemetry: StudioTelemetry
    public var isRetimed: Bool
    /// Host-clock seconds of the screen movie's first frame.
    public var movieStart: Double?
    /// Pause intervals in host-clock seconds (an open pause has `end == nil`).
    public var pauses: [Pause]
    /// Host-clock seconds of the camera movie's first frame, when a camera movie is recorded.
    public var cameraStart: Double?
    public var cameraFills: [CameraFillChange]
    public var cameraBubble: StudioProject.Camera?
    public var cameraWanted: Bool
    public var showsClicks: Bool
    public var showsKeystrokes: Bool

    public init(
        telemetry: StudioTelemetry,
        isRetimed: Bool,
        movieStart: Double? = nil,
        pauses: [Pause] = [],
        cameraStart: Double? = nil,
        cameraFills: [CameraFillChange] = [],
        cameraBubble: StudioProject.Camera? = nil,
        cameraWanted: Bool = false,
        showsClicks: Bool = true,
        showsKeystrokes: Bool = true
    ) {
        self.telemetry = telemetry
        self.isRetimed = isRetimed
        self.movieStart = movieStart
        self.pauses = pauses
        self.cameraStart = cameraStart
        self.cameraFills = cameraFills
        self.cameraBubble = cameraBubble
        self.cameraWanted = cameraWanted
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
    }

    /// Resolves this draft telemetry onto the finished movie's timeline (`0...movieDuration`).
    public func resolvedTelemetry(movieDuration: Double, hasCameraFile: Bool) -> StudioTelemetry {
        if isRetimed {
            var resolved = telemetry
            if resolved.camera != nil, !hasCameraFile {
                resolved.camera = nil
                resolved.cameraFailed = true
            }
            return resolved
        }
        var raw = TelemetryRecorder.ordered(telemetry)
        let start = movieStart ?? Self.earliestHostTime(in: raw) ?? 0
        var ranges: [ClosedRange<Double>] = pauses.compactMap { pause in
            guard let end = pause.end, end > pause.start else { return nil }
            return pause.start...end
        }
        let completedPaused = ranges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let openPauseStart = pauses.last.flatMap { $0.end == nil ? $0.start : nil }
        if let openPauseStart {
            ranges.append(openPauseStart...Double.greatestFiniteMagnitude)
        }
        let endHost = openPauseStart ?? (start + max(0, movieDuration) + completedPaused)
        if hasCameraFile {
            var fills: [ClosedRange<Double>] = []
            var since: Double?
            for change in cameraFills {
                if change.fills, since == nil { since = change.time }
                if !change.fills, let began = since {
                    if change.time > began { fills.append(began...change.time) }
                    since = nil
                }
            }
            if let began = since, endHost > began { fills.append(began...endHost) }
            raw.camera = StudioTelemetry.Camera(
                start: cameraStart ?? start, fills: fills, bubble: cameraBubble ?? StudioProject.Camera()
            )
        } else if cameraWanted {
            raw.cameraFailed = true
        }
        return raw.retimed(start: start, pauses: ranges)
    }

    private static func earliestHostTime(in telemetry: StudioTelemetry) -> Double? {
        [telemetry.samples.first?.time, telemetry.clicks.first?.time, telemetry.keys.first?.time]
            .compactMap(\.self)
            .min()
    }
}

/// Serializes incremental Studio telemetry checkpoints off the main actor so recording stays responsive
/// and a crash or forced quit still leaves usable pointer/zoom/camera metadata in the drafts folder.
public actor StudioDraftCheckpointer {
    private struct Version: Equatable {
        let samples: Int
        let clicks: Int
        let releasedClicks: Int
        let keys: Int
        let cursors: Int
        let movieStart: Double?
        let pauses: Int
        let openPause: Bool
        let cameraStart: Double?
        let cameraFills: Int

        /// Whether the movie's timeline (its start, pauses, and camera) is as in `other`, so only new pointer
        /// readings, clicks, or keys are left to write.
        func hasTimeline(of other: Version) -> Bool {
            movieStart == other.movieStart && pauses == other.pauses && openPause == other.openPause
                && cameraStart == other.cameraStart && cameraFills == other.cameraFills
        }
    }

    private var lastVersion: Version?
    private var isStopped = false
    private let minimumInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var nextWrite: ContinuousClock.Instant?

    /// Each checkpoint writes everything recorded so far, so one that only adds readings waits at least
    /// `minimumInterval`, and fifty times as long as the last write took, keeping a long recording's
    /// checkpoints to a small share of a core.
    public init(minimumInterval: Duration = .seconds(10)) {
        self.minimumInterval = minimumInterval
        self.now = { ContinuousClock.now }
    }

    init(minimumInterval: Duration = .seconds(10), now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// Writes an incremental checkpoint atomically to `url` when the recording's telemetry state changed.
    public func checkpoint(_ draft: StudioDraftTelemetry, to url: URL) {
        guard !isStopped else { return }
        let releasedClicks = draft.telemetry.clicks.reduce(into: 0) { count, click in
            if click.releaseTime != nil { count += 1 }
        }
        let version = Version(
            samples: draft.telemetry.samples.count,
            clicks: draft.telemetry.clicks.count,
            releasedClicks: releasedClicks,
            keys: draft.telemetry.keys.count,
            cursors: draft.telemetry.cursors.count,
            movieStart: draft.movieStart,
            pauses: draft.pauses.count,
            openPause: draft.pauses.last?.end == nil && !draft.pauses.isEmpty,
            cameraStart: draft.cameraStart,
            cameraFills: draft.cameraFills.count
        )
        guard version != lastVersion else { return }
        let current = now()
        if let lastVersion, version.hasTimeline(of: lastVersion), let nextWrite, current < nextWrite { return }
        let began = ContinuousClock.now
        var normalized = draft
        if !normalized.isRetimed {
            normalized.telemetry = TelemetryRecorder.ordered(normalized.telemetry)
        }
        do {
            try JSONEncoder().encode(normalized).write(to: url, options: .atomic)
            lastVersion = version
            let elapsed = began.duration(to: ContinuousClock.now)
            nextWrite = now() + max(minimumInterval, elapsed * 50)
        } catch {
            Log.studio.error("Writing Studio telemetry checkpoint failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
        }
    }

    /// Writes the finalized draft telemetry and suppresses any further periodic checkpoints.
    public func saveFinal(_ draft: StudioDraftTelemetry, to url: URL) throws {
        isStopped = true
        var normalized = draft
        if !normalized.isRetimed {
            normalized.telemetry = TelemetryRecorder.ordered(normalized.telemetry)
        }
        try JSONEncoder().encode(normalized).write(to: url, options: .atomic)
    }

    /// Stops any queued checkpoints from writing after a recording is discarded.
    public func cancel() {
        isStopped = true
    }
}

/// Outcome of persisting a Studio project's sidecar assets beside the kept screen recording.
nonisolated public struct StudioProjectSaveResult: Equatable, Sendable {
    public var savedTelemetry: Bool
    public var savedProject: Bool
    public var expectedCamera: Bool
    public var savedCamera: Bool
    /// Whether this call actually copied `camera.mov` onto disk (as opposed to finding it already present).
    public var wroteCamera: Bool
    /// Whether this call actually wrote or updated `telemetry.json` on disk.
    public var wroteTelemetry: Bool
    public var errorDescription: String?

    public var isComplete: Bool {
        savedTelemetry && savedProject && (!expectedCamera || savedCamera)
    }

    /// Whether this save added or updated Studio media (`camera.mov` or `telemetry.json`).
    public var addedMedia: Bool {
        wroteCamera || wroteTelemetry
    }

    public init(
        savedTelemetry: Bool,
        savedProject: Bool,
        expectedCamera: Bool,
        savedCamera: Bool,
        wroteCamera: Bool = false,
        wroteTelemetry: Bool = false,
        errorDescription: String? = nil
    ) {
        self.savedTelemetry = savedTelemetry
        self.savedProject = savedProject
        self.expectedCamera = expectedCamera
        self.savedCamera = savedCamera
        self.wroteCamera = wroteCamera
        self.wroteTelemetry = wroteTelemetry
        self.errorDescription = errorDescription
    }
}

/// Outcome of retrying missing Studio sidecar assets for a draft whose movie is already in History.
nonisolated public enum StudioRecoveryOutcome: Equatable, Sendable {
    /// Every expected Studio asset is now present in the history entry's Studio folder; the draft can be removed.
    case completed(StudioProjectSaveResult)
    /// At least one Studio asset still could not be saved; keep the draft for a later retry.
    case incomplete(StudioProjectSaveResult)
    /// The linked history entry's movie was replaced after it was kept (e.g. trimmed in the recording editor),
    /// so recovered telemetry and camera no longer match it and the draft should be discarded.
    case movieReplaced
    /// The linked history entry is gone; safe to discard the draft.
    case discarded
}

/// Persists Studio sidecar assets (`camera.mov`, `telemetry.json`, `project.json`) non-destructively so
/// the caller only deletes the source draft when every expected asset landed cleanly.
nonisolated public enum StudioProjectStorage {
    public static func save(
        telemetry: StudioTelemetry,
        project: StudioProject,
        cameraURL: URL?,
        to folder: URL,
        preservingExisting: Bool = false,
        existingCameraReady: Bool? = nil,
        copyCamera: (URL, URL) throws -> Void = { source, destination in
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        },
        writeData: (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    ) -> StudioProjectSaveResult {
        let cameraDestination = folder.appending(path: StudioFiles.camera)
        let cameraAlreadyPresent: Bool = {
            guard preservingExisting else { return false }
            if let existingCameraReady { return existingCameraReady }
            let size = (try? cameraDestination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 0
        }()
        let expectsCamera = telemetry.camera != nil && (cameraURL != nil || cameraAlreadyPresent)
        var result = StudioProjectSaveResult(
            savedTelemetry: false, savedProject: false, expectedCamera: expectsCamera, savedCamera: false
        )
        var errors: [String] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            result.errorDescription = error.localizedDescription
            return result
        }

        var writtenTelemetry = telemetry
        if expectsCamera {
            if cameraAlreadyPresent {
                result.savedCamera = true
            } else if let cameraURL {
                do {
                    try copyCamera(cameraURL, cameraDestination)
                    result.savedCamera = true
                    result.wroteCamera = true
                } catch {
                    errors.append(error.localizedDescription)
                    writtenTelemetry.camera = nil
                    writtenTelemetry.cameraFailed = true
                }
            }
        }

        let telemetryDestination = folder.appending(path: StudioFiles.telemetry)
        let existingTelemetryReady: Bool = {
            guard preservingExisting,
                  let data = try? Data(contentsOf: telemetryDestination),
                  let existing = try? JSONDecoder().decode(StudioTelemetry.self, from: data)
            else { return false }
            if expectsCamera && result.savedCamera && existing.camera == nil {
                return false
            }
            return true
        }()
        if existingTelemetryReady {
            result.savedTelemetry = true
        } else {
            do {
                let data = try JSONEncoder().encode(writtenTelemetry)
                try writeData(data, telemetryDestination)
                result.savedTelemetry = true
                result.wroteTelemetry = true
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        let projectDestination = folder.appending(path: StudioFiles.project)
        let existingProjectReady: Bool = {
            guard preservingExisting,
                  let data = try? Data(contentsOf: projectDestination),
                  (try? JSONDecoder().decode(StudioProject.self, from: data)) != nil
            else { return false }
            return true
        }()
        if existingProjectReady {
            result.savedProject = true
        } else {
            do {
                let data = try JSONEncoder().encode(project)
                try writeData(data, projectDestination)
                result.savedProject = true
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if !errors.isEmpty {
            result.errorDescription = errors.joined(separator: "; ")
        }
        return result
    }

    /// Retries only the missing Studio sidecar assets for an existing history entry without creating a new
    /// history item or overwriting valid assets that already saved.
    public static func recoverMissingAssets(
        forHistoryID historyID: UUID,
        telemetryURL: URL,
        cameraURL: URL,
        in history: HistoryStore,
        expectedMovieByteCount: Int64? = nil,
        expectedMovieModifiedAt: TimeInterval? = nil,
        hasReadableVideo: (URL) async -> Bool,
        copyCamera: (URL, URL) throws -> Void = { source, destination in
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        },
        writeData: (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    ) async -> StudioRecoveryOutcome {
        guard let entry = history.item(id: historyID) else { return .discarded }
        let folder = history.studioURL(for: entry)
        let studioSource = history.studioSourceURL(for: entry)
        let hasStudioSource = FileManager.default.fileExists(atPath: studioSource.path(percentEncoded: false))

        func cleanupIncompleteStudioFolderIfSafe() {
            guard !hasStudioSource, !history.hasStudioMovie(entry),
                  !FileManager.default.fileExists(atPath: folder.appending(path: StudioFiles.telemetry).path(percentEncoded: false))
            else { return }
            try? FileManager.default.removeItem(at: folder)
        }

        if history.hasOriginal(entry) {
            cleanupIncompleteStudioFolderIfSafe()
            return .movieReplaced
        }
        if history.hasStudioMovie(entry), !hasStudioSource {
            return .movieReplaced
        }
        let sourceMovieURL = hasStudioSource ? studioSource : history.fileURL(for: entry)
        if expectedMovieByteCount != nil || expectedMovieModifiedAt != nil {
            guard let values = try? sourceMovieURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else {
                cleanupIncompleteStudioFolderIfSafe()
                return .movieReplaced
            }
            if let expectedMovieByteCount, Int64(size) != expectedMovieByteCount {
                cleanupIncompleteStudioFolderIfSafe()
                return .movieReplaced
            }
            if let expectedMovieModifiedAt, abs(modified.timeIntervalSince1970 - expectedMovieModifiedAt) > 0.001 {
                cleanupIncompleteStudioFolderIfSafe()
                return .movieReplaced
            }
        }

        let existingCameraURL = folder.appending(path: StudioFiles.camera)
        let hasExistingCamera = await hasReadableVideo(existingCameraURL)
        let draftCameraExists = FileManager.default.fileExists(atPath: cameraURL.path(percentEncoded: false))

        let savedDraft: StudioDraftTelemetry
        do {
            let data = try Data(contentsOf: telemetryURL)
            savedDraft = try JSONDecoder().decode(StudioDraftTelemetry.self, from: data)
        } catch {
            let hasExistingProject = FileManager.default.fileExists(atPath: folder.appending(path: StudioFiles.project).path(percentEncoded: false))
            let result = StudioProjectSaveResult(
                savedTelemetry: false,
                savedProject: hasExistingProject,
                expectedCamera: hasExistingCamera || draftCameraExists,
                savedCamera: hasExistingCamera,
                errorDescription: error.localizedDescription
            )
            return .incomplete(result)
        }

        let hasDraftCamera = draftCameraExists ? await hasReadableVideo(cameraURL) : false
        let unreadableDraftCamera = !hasExistingCamera && draftCameraExists && !hasDraftCamera
        let hasCamera = hasExistingCamera || hasDraftCamera
        let duration: Double
        if !savedDraft.isRetimed, hasStudioSource,
           let sourceDuration = try? await AVURLAsset(url: studioSource).load(.duration).seconds,
           sourceDuration.isFinite, sourceDuration > 0 {
            duration = sourceDuration
        } else {
            duration = entry.duration ?? 0
        }
        let resolvedTelemetry = savedDraft.resolvedTelemetry(movieDuration: duration, hasCameraFile: hasCamera)

        var project = StudioProject(zooms: AutoZoom.zooms(for: resolvedTelemetry, duration: duration))
        project.cursor.showsClicks = savedDraft.showsClicks
        project.showsKeys = savedDraft.showsKeystrokes
        project.keystrokeMode = resolvedTelemetry.keystrokeMode ?? .all
        project.camera = resolvedTelemetry.camera?.bubble ?? savedDraft.telemetry.camera?.bubble ?? savedDraft.cameraBubble ?? StudioProject.Camera()

        var result = save(
            telemetry: resolvedTelemetry,
            project: project,
            cameraURL: hasDraftCamera ? cameraURL : nil,
            to: folder,
            preservingExisting: true,
            existingCameraReady: hasExistingCamera,
            copyCamera: copyCamera,
            writeData: writeData
        )
        if unreadableDraftCamera {
            result.expectedCamera = true
            result.savedCamera = false
            let message = "Draft camera file could not be read"
            result.errorDescription = result.errorDescription.map { "\($0); \(message)" } ?? message
        }
        if result.addedMedia {
            history.invalidateStudioMovieExport(of: entry)
        }
        return result.isComplete ? .completed(result) : .incomplete(result)
    }
}
