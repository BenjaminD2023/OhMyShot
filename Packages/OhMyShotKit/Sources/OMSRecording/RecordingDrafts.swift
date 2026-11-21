import AVFoundation
import Foundation
import OMSCore

/// Where recordings are written while they run, and what a crash left there.
///
/// Each recording in progress is a movie written in fragments plus a small record of when it began and what
/// was in front. A finished recording leaves nothing here; anything found at launch was cut short, and is
/// readable up to its last fragment, so it can still be finished and kept.
public struct RecordingDrafts: Sendable {
    /// What is known about a recording before it is finished.
    public struct Info: Codable, Equatable, Sendable {
        /// Size and modification time of the History movie when it was kept, so recovery can detect if
        /// the movie was replaced (for example, trimmed in the recording editor) before relaunching.
        public struct KeptMovie: Codable, Equatable, Sendable {
            public var byteCount: Int64
            /// `Date.timeIntervalSince1970` of the kept movie's modification date, preserving sub-second precision.
            public var modifiedAt: TimeInterval

            public init(byteCount: Int64, modifiedAt: TimeInterval) {
                self.byteCount = byteCount
                self.modifiedAt = modifiedAt
            }

            public static func measure(at url: URL) -> KeptMovie? {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize,
                      let modified = values.contentModificationDate
                else { return nil }
                return KeptMovie(byteCount: Int64(size), modifiedAt: modified.timeIntervalSince1970)
            }
        }

        public var startedAt: Date
        /// The app that was in front when recording began, for the file's name.
        public var appName: String?
        /// What it is kept as; nil (a draft from before GIFs) is a movie.
        public var output: RecordingOutput?
        /// The recorded display's pixels per point, which sizes a GIF as things were on screen.
        public var pixelsPerPoint: Double?
        /// The history entry already created for this draft's movie while Studio sidecar assets still
        /// remain to be copied or written into it.
        public var keptHistoryID: UUID?
        /// Fingerprint of the History movie at the time `keptHistoryID` was recorded.
        public var keptMovie: KeptMovie?

        public init(
            startedAt: Date, appName: String?, output: RecordingOutput = .video,
            pixelsPerPoint: Double? = nil, keptHistoryID: UUID? = nil, keptMovie: KeptMovie? = nil
        ) {
            self.startedAt = startedAt
            self.appName = appName
            self.output = output
            self.pixelsPerPoint = pixelsPerPoint
            self.keptHistoryID = keptHistoryID
            self.keptMovie = keptMovie
        }
    }

    /// Minimum free space required on the draft volume before starting a recording (500 MiB).
    public static let minimumFreeBytesToStart: Int64 = 500 * 1_024 * 1_024
    /// Minimum free space kept while recording; dropping below this stops early so finishing still has room (250 MiB).
    public static let minimumFreeBytesWhileRecording: Int64 = 250 * 1_024 * 1_024
    /// How long an unreadable leftover movie draft stays on disk before launch recovery discards it (7 days).
    public static let unreadableDraftRetention: TimeInterval = 7 * 86_400

    public enum DiskSpaceStatus: Equatable, Sendable {
        case sufficient(availableBytes: Int64?)
        case insufficient(availableBytes: Int64, requiredBytes: Int64)
    }

    public enum RestartDecision: Equatable, Sendable {
        /// Enough free space exists to start a replacement recording: discard the current session and restart.
        case restart
        /// Free space is below `minimumFreeBytesToStart`: keep the current session recording so it can be stopped and kept.
        case keepCurrent(availableBytes: Int64, requiredBytes: Int64)
    }

    /// One recording in progress, or left behind.
    public struct Draft: Equatable, Sendable {
        public let id: UUID
        public let movieURL: URL
        public let info: Info?

        /// Where a Studio recording's camera is written beside it, in a movie of its own.
        public var cameraURL: URL {
            movieURL.deletingPathExtension().appendingPathExtension("camera.mov")
        }

        /// Where a Studio recording's telemetry checkpoint is written beside it.
        public var telemetryURL: URL {
            movieURL.deletingPathExtension().appendingPathExtension("telemetry.json")
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The standard location: Application Support, under this build's bundle identifier.
    public static func standard() -> RecordingDrafts {
        RecordingDrafts(directory: AppFolders.support.appending(path: "Recordings in Progress", directoryHint: .isDirectory))
    }

    /// Checks free space on the volume hosting the drafts folder. Uses the nearest existing ancestor when
    /// the drafts folder has not been created yet.
    public func checkDiskSpace(
        requiring minimumBytes: Int64,
        measure: (URL) -> Int64? = Self.volumeAvailableBytes(at:)
    ) -> DiskSpaceStatus {
        let probe = Self.existingAncestor(of: directory)
        guard let available = measure(probe) else { return .sufficient(availableBytes: nil) }
        if available < minimumBytes {
            return .insufficient(availableBytes: available, requiredBytes: minimumBytes)
        }
        return .sufficient(availableBytes: available)
    }

    /// Decides whether a running recording can safely restart without discarding the current recording only
    /// to have its replacement refused by the startup disk-space gate.
    public func restartDecision(
        measure: (URL) -> Int64? = Self.volumeAvailableBytes(at:)
    ) -> RestartDecision {
        switch checkDiskSpace(requiring: Self.minimumFreeBytesToStart, measure: measure) {
        case .sufficient:
            return .restart
        case .insufficient(let available, let required):
            return .keepCurrent(availableBytes: available, requiredBytes: required)
        }
    }

    public static func volumeAvailableBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        return values.volumeAvailableCapacity.map { Int64($0) }
    }

    private static func existingAncestor(of url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path(percentEncoded: false)) {
            let parent = current.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == current.path(percentEncoded: false) { break }
            current = parent
        }
        return current
    }

    /// Makes room for a new recording and notes when it began. The movie is written at the draft's URL.
    public func create(_ info: Info, id: UUID = UUID()) throws -> Draft {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let draft = Draft(id: id, movieURL: directory.appending(path: "\(id.uuidString).mov"), info: info)
        try JSONEncoder.drafts.encode(info).write(to: infoURL(for: id), options: .atomic)
        return draft
    }

    /// Records that this draft's movie is already in History as `historyID` (plus its file fingerprint when
    /// provided) and removes the draft's screen movie only after that link is safely on disk. If writing the
    /// link fails, the draft movie stays on disk so launch recovery does not strand the draft's Studio assets.
    @discardableResult
    public func markKeptInHistory(
        _ draft: Draft,
        historyID: UUID,
        keptMovie: Info.KeptMovie? = nil,
        writeInfo: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) throws -> Draft {
        var info = draft.info ?? Info(startedAt: .now, appName: nil, output: .studio)
        info.keptHistoryID = historyID
        info.keptMovie = keptMovie
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.drafts.encode(info)
        try writeInfo(data, infoURL(for: draft.id))
        try? FileManager.default.removeItem(at: draft.movieURL)
        return Draft(id: draft.id, movieURL: draft.movieURL, info: info)
    }

    /// Whether `url` holds a video track with positive duration that AVFoundation can open for reading.
    public static func hasReadableVideo(at url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0
        else { return false }
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        reader.cancelReading()
        return true
    }

    /// Removes `draft` only when it is not a partial Studio draft linked to a History entry, its movie file
    /// still sits on disk older than `unreadableDraftRetention`, and that movie is verified unreadable.
    @discardableResult
    public func pruneIfExpiredAndUnreadable(
        _ draft: Draft,
        now: Date = .now,
        isReadable: (URL) async -> Bool = Self.hasReadableVideo(at:)
    ) async -> Bool {
        if draft.info?.keptHistoryID != nil { return false }
        if let latest = FileManager.default.contents(atPath: infoURL(for: draft.id).path(percentEncoded: false))
            .flatMap({ try? JSONDecoder.records.decode(Info.self, from: $0) }),
           latest.keptHistoryID != nil {
            return false
        }
        guard FileManager.default.fileExists(atPath: draft.movieURL.path(percentEncoded: false)),
              let modified = (try? draft.movieURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate),
              modified < now.addingTimeInterval(-Self.unreadableDraftRetention)
        else { return false }
        guard !(await isReadable(draft.movieURL)) else { return false }
        remove(draft)
        return true
    }

    /// Removes a draft, its movies, its telemetry checkpoint, and its record.
    public func remove(_ draft: Draft) {
        try? FileManager.default.removeItem(at: draft.movieURL)
        try? FileManager.default.removeItem(at: draft.cameraURL)
        try? FileManager.default.removeItem(at: draft.telemetryURL)
        try? FileManager.default.removeItem(at: infoURL(for: draft.id))
    }

    /// The drafts on disk except `excluding` (those still recording), oldest first. A record whose movie never
    /// got written is removed on the way, unless it already points to a kept History entry whose Studio assets
    /// still need recovery.
    public func leftovers(excluding: Set<UUID> = []) -> [Draft] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return [] }
        var drafts: [Draft] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), !excluding.contains(id) else { continue }
            let movie = directory.appending(path: "\(id.uuidString).mov")
            let info = FileManager.default.contents(atPath: infoURL(for: id).path(percentEncoded: false))
                .flatMap { try? JSONDecoder.records.decode(Info.self, from: $0) }
            guard FileManager.default.fileExists(atPath: movie.path(percentEncoded: false)) || info?.keptHistoryID != nil else {
                try? FileManager.default.removeItem(at: infoURL(for: id))
                continue
            }
            drafts.append(Draft(id: id, movieURL: movie, info: info))
        }
        for name in names where name.hasSuffix(".mov") {
            // A movie without its record still holds a recording.
            guard let id = UUID(uuidString: String(name.dropLast(4))), !excluding.contains(id), !drafts.contains(where: { $0.id == id }) else { continue }
            drafts.append(Draft(id: id, movieURL: directory.appending(path: name), info: nil))
        }
        return drafts.sorted { ($0.info?.startedAt ?? .distantPast) < ($1.info?.startedAt ?? .distantPast) }
    }

    private func infoURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}

/// A draft's notes are written compact, without the pretty printing of the records `JSONEncoder.records` writes; they
/// are read back as those are (`JSONDecoder.records`).
private extension JSONEncoder {
    static var drafts: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
