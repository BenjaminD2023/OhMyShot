import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import ImageIO
import OSLog

/// How long captures stay in the history.
public enum HistoryRetention: String, CaseIterable, Sendable {
    case never
    case oneDay
    case threeDays
    case oneWeek
    case oneMonth

    /// How long an item is kept, or nil for "never": items are removed once their Quick Access card
    /// closes.
    public var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .oneDay: 86_400
        case .threeDays: 3 * 86_400
        case .oneWeek: 7 * 86_400
        case .oneMonth: 30 * 86_400
        }
    }
}

/// One capture kept in the history.
public struct HistoryItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case screenshot
        case recording
    }

    public let id: UUID
    public let kind: Kind
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The app that was in front when the capture was taken.
    public let appName: String?
    /// The file's name inside the history folder.
    public let fileName: String
    /// A recording's length.
    public let duration: TimeInterval?
    /// The pixels per point of the display the capture was made on: which sizes a GIF made of a recording as
    /// things were on screen, and says how large a screenshot was, so it can be saved at 1×. Nil for captures and
    /// recordings from before it was kept. A screenshot scaled to 1× in its card has 1.
    public let pixelsPerPoint: Double?
    /// The title of the window captured, or of the front window when an area was; nil when there was none or it is
    /// unknown. A saved copy's name can hold it.
    public let windowTitle: String?
    /// Whether the file is named from the file name template, so a copy saved later is named from it too (with the
    /// next number, if it counts). Nil for pictures that came with names of their own.
    public let isTemplateNamed: Bool?
    /// True for a capture added to Favorites in Capture History, which Keep captures doesn't take away (History off
    /// keeps nothing). Nil for one that isn't, as for every record from before favorites.
    public let favorite: Bool?

    /// Whether the capture is in Favorites.
    public var isFavorite: Bool { favorite == true }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = .now,
        pixelWidth: Int,
        pixelHeight: Int,
        appName: String?,
        fileName: String,
        duration: TimeInterval? = nil,
        pixelsPerPoint: Double? = nil,
        windowTitle: String? = nil,
        isTemplateNamed: Bool? = nil,
        favorite: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.appName = appName
        self.fileName = fileName
        self.duration = duration
        self.pixelsPerPoint = pixelsPerPoint
        self.windowTitle = windowTitle
        self.isTemplateNamed = isTemplateNamed
        self.favorite = favorite
    }

    /// The record added to Favorites, or taken out of them.
    public func favoriting(_ favorite: Bool) -> HistoryItem {
        HistoryItem(
            id: id, kind: kind, createdAt: createdAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight, appName: appName, fileName: fileName,
            duration: duration, pixelsPerPoint: pixelsPerPoint, windowTitle: windowTitle, isTemplateNamed: isTemplateNamed,
            favorite: favorite ? true : nil
        )
    }
}

/// Keeps every capture in an app-owned folder, so nothing lands on the Desktop unless the user saves it,
/// and a closed Quick Access card can always be brought back.
///
/// Each capture is a file plus a small JSON sidecar; the folder itself is the index, so there is no
/// database to keep in sync. Cleanup runs at launch and after each capture, never on a timer.
public final class HistoryStore: Sendable {
    public let directory: URL
    /// Each capture's file name by its id, as records are written and read: `item(id:)` reads one sidecar, not the
    /// whole history. A name it holds is checked against the record before it is trusted.
    private let fileNames = Mutex<[UUID: String]>([:])

    public init(directory: URL) {
        self.directory = directory
    }

    /// The standard location: Application Support, under this build's bundle identifier.
    public static func standard() -> HistoryStore {
        HistoryStore(directory: AppFolders.support.appending(path: "History", directoryHint: .isDirectory))
    }

    public func fileURL(for item: HistoryItem) -> URL {
        directory.appending(path: item.fileName)
    }

    /// The capture as it was taken, kept beside it once it has been marked up. No `.json` suffix, so
    /// listing the history never mistakes it for a record.
    public func originalURL(for item: HistoryItem) -> URL {
        directory.appending(path: "\(item.fileName).original")
    }

    /// The marks on a marked-up capture, so they stay editable.
    public func annotationsURL(for item: HistoryItem) -> URL {
        directory.appending(path: "\(item.fileName).annotations")
    }

    /// Whether the capture has been marked up and its original kept.
    public func hasOriginal(_ item: HistoryItem) -> Bool {
        FileManager.default.fileExists(atPath: originalURL(for: item).path(percentEncoded: false))
    }

    /// Shows a marked-up picture in place of the capture, keeping the original (the first time) and the
    /// marks beside it. `pixelsPerPoint` is kept as the capture's scale when given: the editor's resize scales
    /// it with the picture, and every reader of the record (saving at 1×, dragging out, pins, printing) goes
    /// by it. Returns the record with the new size.
    @discardableResult
    public func replaceImage(
        of item: HistoryItem, with data: Data, pixelWidth: Int, pixelHeight: Int, annotations: Data, pixelsPerPoint: Double? = nil
    ) throws -> HistoryItem {
        if !hasOriginal(item) {
            try FileManager.default.copyItem(at: fileURL(for: item), to: originalURL(for: item))
        }
        try data.write(to: fileURL(for: item), options: .atomic)
        try annotations.write(to: annotationsURL(for: item), options: .atomic)
        return try updated(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: item.duration, pixelsPerPoint: pixelsPerPoint)
    }

    /// Puts a turned, flipped, or scaled picture in place of a capture that has never been edited. Unlike
    /// `replaceImage` it keeps no original and no marks: the new picture is the capture, so the editor, a
    /// restore, and Revert all see it, and the change is undone by changing it back. A capture that has an
    /// original (marked up, cropped, or put on a background) is refused, since its original and its marks
    /// would go on showing the picture as it was. `pixelsPerPoint` is kept as the capture's scale when given
    /// (1 after scaling to one pixel per point). Returns the record with the new size.
    @discardableResult
    public func replacePicture(of item: HistoryItem, with data: Data, pixelWidth: Int, pixelHeight: Int, pixelsPerPoint: Double? = nil) throws -> HistoryItem {
        guard !hasOriginal(item) else { throw PictureError.hasOriginal }
        try data.write(to: fileURL(for: item), options: .atomic)
        return try updated(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: item.duration, pixelsPerPoint: pixelsPerPoint)
    }

    public enum PictureError: Error, Equatable, Sendable {
        /// The capture was edited, and its original and marks are kept beside it.
        case hasOriginal
    }

    /// Puts the capture back as it was taken and forgets its marks. `pixelsPerPoint` is kept as the capture's
    /// scale when given: a resize that was undone in the editor has put it back. Returns the record with the
    /// original's size; unchanged when it was never marked up.
    @discardableResult
    public func restoreOriginal(of item: HistoryItem, pixelsPerPoint: Double? = nil) throws -> HistoryItem {
        guard hasOriginal(item) else { return item }
        let original = originalURL(for: item)
        let size = CGImageSourceCreateWithURL(original as CFURL, nil).flatMap(Self.pixelSize(of:))
        _ = try FileManager.default.replaceItemAt(fileURL(for: item), withItemAt: original)
        // The original carries the date it was taken: dated now, the file reads as changed to what judges by its date (a
        // converted copy made of the marked picture, a pin of it).
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: fileURL(for: item).path(percentEncoded: false))
        try? FileManager.default.removeItem(at: annotationsURL(for: item))
        return try updated(
            item, pixelWidth: size?.width ?? item.pixelWidth, pixelHeight: size?.height ?? item.pixelHeight, duration: item.duration,
            pixelsPerPoint: pixelsPerPoint
        )
    }

    /// Keeps an edited recording, the file at `edited` (moved in), in place of the recording, keeping the
    /// recording as it was made beside it the first time. Returns the record with the new size and length.
    @discardableResult
    public func replaceRecording(of item: HistoryItem, withFileAt edited: URL, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval) throws -> HistoryItem {
        try replaceMovie(of: item, with: edited, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, studioMarker: nil)
    }

    /// Stages the incoming movie on the history's volume, then prepares its sidecars. The final rename is the
    /// only operation that changes the visible movie, so even a failed commit leaves the previous movie in place.
    func replaceMovie(
        of item: HistoryItem, with movie: URL, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval,
        studioMarker: (url: URL, data: Data)?
    ) throws -> HistoryItem {
        let manager = FileManager.default, destination = fileURL(for: item)
        guard movie.standardizedFileURL != destination.standardizedFileURL,
              try movie.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw CocoaError(.fileReadUnknown) }
        var revised = item
        var undo: [(url: URL, prior: Data?)] = []
        do {
            try AtomicFileCopy.perform(from: movie, to: destination, copy: { source, staging in
                try manager.moveItem(at: source, to: staging)
                if let marker = studioMarker {
                    let prior = manager.fileExists(atPath: marker.url.path(percentEncoded: false)) ? try Data(contentsOf: marker.url) : nil
                    try marker.data.write(to: marker.url, options: .atomic)
                    undo.append((marker.url, prior))
                } else if !hasOriginal(item) {
                    let original = originalURL(for: item)
                    try manager.copyItem(at: destination, to: original)
                    undo.append((original, nil))
                }
                let record = sidecarURL(forFileName: item.fileName)
                let prior = try Data(contentsOf: record)
                revised = try updated(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration)
                if revised != item { undo.append((record, prior)) }
            })
        } catch {
            for (url, prior) in undo.reversed() {
                if let prior { try prior.write(to: url, options: .atomic) }
                else { try manager.removeItem(at: url) }
            }
            throw error
        }
        return revised
    }

    /// Puts a recording back as it was made. Returns the record with its size and length then; unchanged
    /// when it was never edited.
    @discardableResult
    public func restoreRecording(of item: HistoryItem) async throws -> HistoryItem {
        guard hasOriginal(item) else { return item }
        _ = try FileManager.default.replaceItemAt(fileURL(for: item), withItemAt: originalURL(for: item))
        // Read where it has its extension again: AVFoundation knows a movie by it.
        let asset = AVURLAsset(url: fileURL(for: item))
        let duration = try await asset.load(.duration).seconds
        // As it is shown: a movie from a phone held upright is encoded on its side.
        var shown: CGRect?
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            shown = CGRect(origin: .zero, size: natural).applying(transform)
        }
        return try updated(
            item, pixelWidth: shown.map { Int(abs($0.width).rounded()) } ?? item.pixelWidth,
            pixelHeight: shown.map { Int(abs($0.height).rounded()) } ?? item.pixelHeight, duration: duration
        )
    }

    /// Keeps the marked-up picture as the capture and lets the original and the marks go: the marks can
    /// no longer be changed.
    public func flatten(_ item: HistoryItem) {
        removeExtras(of: item)
    }

    /// The record with the new size, length, and scale, written beside the file when any of them changed. Whether it is
    /// a favorite is read from the record as it is now: `item` may be from before it was added or taken out, as an
    /// editor's is.
    func updated(_ item: HistoryItem, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval?, pixelsPerPoint: Double? = nil) throws -> HistoryItem {
        let updated = HistoryItem(
            id: item.id, kind: item.kind, createdAt: item.createdAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            appName: item.appName, fileName: item.fileName, duration: duration, pixelsPerPoint: pixelsPerPoint ?? item.pixelsPerPoint,
            windowTitle: item.windowTitle, isTemplateNamed: item.isTemplateNamed,
            favorite: record(at: sidecarURL(forFileName: item.fileName)).map(\.favorite) ?? item.favorite
        )
        if updated != item { try writeRecord(updated) }
        return updated
    }

    private func removeExtras(of item: HistoryItem) {
        try? FileManager.default.removeItem(at: originalURL(for: item))
        try? FileManager.default.removeItem(at: annotationsURL(for: item))
        try? FileManager.default.removeItem(at: studioURL(for: item))
    }

    /// Moves a file into the history under `name` (made unique, its extension kept) and returns its record:
    /// for recordings, which are written to disk while they run and are never loaded whole.
    public func add(
        movingFileAt source: URL,
        name: String = "OhMyShot",
        kind: HistoryItem.Kind,
        pixelWidth: Int,
        pixelHeight: Int,
        appName: String?,
        duration: TimeInterval? = nil,
        pixelsPerPoint: Double? = nil,
        windowTitle: String? = nil,
        isTemplateNamed: Bool? = nil,
        date: Date = .now
    ) throws -> HistoryItem {
        try add(
            name: name, fileExtension: source.pathExtension, kind: kind, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            appName: appName, duration: duration, pixelsPerPoint: pixelsPerPoint, windowTitle: windowTitle, isTemplateNamed: isTemplateNamed, date: date
        ) { try FileManager.default.moveItem(at: source, to: $0) }
    }

    /// Copies a picture or a recording of the user's into the history under its own name, leaving the file where it
    /// is: the URL API's `add-quick-access-overlay`. A movie or a GIF is kept as a recording, with its size and
    /// length; anything else must be a picture ImageIO reads. Runs off the caller's actor: a movie on another drive takes
    /// as long to copy as to read.
    @concurrent public func add(copyOf source: URL, date: Date = .now) async throws -> HistoryItem {
        let kind: HistoryItem.Kind
        let size: (width: Int, height: Int)
        var duration: TimeInterval?
        if Self.isMovie(source) {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = CGRect(origin: .zero, size: natural).applying(transform)
            kind = .recording
            size = (Int(abs(shown.width).rounded()), Int(abs(shown.height).rounded()))
            duration = try await asset.load(.duration).seconds
        } else {
            guard let picture = CGImageSourceCreateWithURL(source as CFURL, nil), let found = Self.pixelSize(of: picture) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            kind = source.pathExtension.lowercased() == "gif" ? .recording : .screenshot
            size = found
            if kind == .recording { duration = Self.gifDuration(of: picture) }
        }
        return try add(
            name: source.deletingPathExtension().lastPathComponent, fileExtension: source.pathExtension.lowercased(), kind: kind,
            pixelWidth: size.width, pixelHeight: size.height, appName: nil, duration: duration, date: date
        ) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    /// A picture's first image's size in pixels, turned upright as it is shown.
    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Orientations 5 to 8 turn the picture on its side.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// How long a GIF plays once: its frames' delays added up.
    private static func gifDuration(of source: CGImageSource) -> TimeInterval {
        (0..<CGImageSourceGetCount(source)).reduce(0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
            return total + delay
        }
    }

    /// Stores encoded image data under `name` (made unique) and returns its record. The file keeps a
    /// readable name, so dragging it out or revealing it shows the same name a saved copy would have.
    public func add(
        data: Data,
        name: String = "OhMyShot",
        fileExtension: String,
        kind: HistoryItem.Kind,
        pixelWidth: Int,
        pixelHeight: Int,
        appName: String?,
        duration: TimeInterval? = nil,
        pixelsPerPoint: Double? = nil,
        windowTitle: String? = nil,
        isTemplateNamed: Bool? = nil,
        date: Date = .now
    ) throws -> HistoryItem {
        try add(
            name: name, fileExtension: fileExtension, kind: kind, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            appName: appName, duration: duration, pixelsPerPoint: pixelsPerPoint, windowTitle: windowTitle, isTemplateNamed: isTemplateNamed, date: date
        ) { try data.write(to: $0, options: .atomic) }
    }

    /// An empty sidecar claims a name exclusively, but isn't a readable record until its capture has been written.
    private func add(
        name: String, fileExtension: String, kind: HistoryItem.Kind, pixelWidth: Int, pixelHeight: Int, appName: String?,
        duration: TimeInterval?, pixelsPerPoint: Double? = nil, windowTitle: String? = nil, isTemplateNamed: Bool? = nil,
        date: Date, writeFile: (URL) throws -> Void
    ) throws -> HistoryItem {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "-")
        let ext = fileExtension.replacingOccurrences(of: "/", with: "-")
        var number = 0
        while true {
            number += 1
            let stem = number == 1 ? base : "\(base) (\(number))"
            let fileName = "\(stem).\(ext)"
            let url = directory.appending(path: fileName)
            guard !manager.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            let record = sidecarURL(forFileName: fileName)
            do {
                try Data().write(to: record, options: .withoutOverwriting)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            let item = HistoryItem(
                kind: kind, createdAt: date, pixelWidth: pixelWidth, pixelHeight: pixelHeight, appName: appName, fileName: fileName,
                duration: duration, pixelsPerPoint: pixelsPerPoint, windowTitle: windowTitle, isTemplateNamed: isTemplateNamed
            )
            do {
                try writeFile(url)
                try writeRecord(item)
                return item
            } catch {
                try? manager.removeItem(at: record)
                throw error
            }
        }
    }

    /// Every item, newest first.
    public func items() -> [HistoryItem] {
        readItems(cancelled: { false })
    }

    /// Directory enumeration and sidecar decoding for an open history window. Work stays off its actor
    /// and cancellation stops before reading the next file; a cancelled listing is never a partial list.
    @concurrent public func loadItems() async -> [HistoryItem] {
        readItems(cancelled: { Task.isCancelled })
    }

    private func readItems(cancelled: () -> Bool) -> [HistoryItem] {
        guard !cancelled() else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return [] }
        var items: [HistoryItem] = []
        for name in names where name.hasSuffix(".json") {
            guard !cancelled() else { return [] }
            guard let item = record(at: directory.appending(path: name)),
                  FileManager.default.fileExists(atPath: fileURL(for: item).path(percentEncoded: false)) else { continue }
            items.append(item)
        }
        guard !cancelled() else { return [] }
        fileNames.withLock { names in
            for item in items { names[item.id] = item.fileName }
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    /// The capture with `id`: from its own sidecar when its file name is known, as it is for every capture written or
    /// listed since launch; otherwise from the whole history, which a listing takes tens of milliseconds over
    /// (Docs/perf.md › Main-thread work after a capture).
    public func item(id: UUID) -> HistoryItem? {
        if let name = fileNames.withLock({ $0[id] }), let item = item(fileName: name), item.id == id,
           FileManager.default.fileExists(atPath: fileURL(for: item).path(percentEncoded: false)) {
            return item
        }
        return items().first { $0.id == id }
    }

    /// The record whose file is `url`; nil for a file outside the history folder. Reads that record's sidecar alone, not
    /// the whole folder's, since it is asked at the moment a drag begins.
    public func item(forFileAt url: URL) -> HistoryItem? {
        func path(_ url: URL) -> String {
            var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let fileName = url.lastPathComponent
        guard
            path(url.deletingLastPathComponent()) == path(directory),
            let item = record(at: sidecarURL(forFileName: fileName)),
            item.fileName == fileName,
            FileManager.default.fileExists(atPath: fileURL(for: item).path(percentEncoded: false))
        else { return nil }
        return item
    }

    /// The newest screenshot, or nil when the history holds none: a recording is newer than it, perhaps, but is
    /// no picture to mark up.
    public func latestScreenshot() -> HistoryItem? {
        items().first { $0.kind == .screenshot }
    }

    /// The record of the capture whose file is `fileName`, read from its own sidecar: for what is asked often
    /// (a card's menu, VoiceOver's actions), which should not read the whole history.
    public func item(fileName: String) -> HistoryItem? {
        record(at: sidecarURL(forFileName: fileName))
    }

    public func delete(_ item: HistoryItem) {
        fileNames.withLock { $0[item.id] = nil }
        try? FileManager.default.removeItem(at: fileURL(for: item))
        try? FileManager.default.removeItem(at: sidecarURL(forFileName: item.fileName))
        removeExtras(of: item)
        try? FileManager.default.removeItem(at: textURL(for: item))
    }

    /// Moves the capture to the Trash, where it can still be recovered, and forgets it.
    public func moveToTrash(
        _ item: HistoryItem, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        try trash(fileURL(for: item))
        fileNames.withLock { $0[item.id] = nil }
        try? FileManager.default.removeItem(at: sidecarURL(forFileName: item.fileName))
        // The Trash keeps the picture as it was last shown; the original, the marks, and its text go with the record.
        removeExtras(of: item)
        try? FileManager.default.removeItem(at: textURL(for: item))
    }

    public func deleteAll() {
        items().forEach(delete)
    }

    /// Adds the capture to Favorites, which Keep captures doesn't take away, or takes it out of them; returns its record
    /// as written. The record is read as it is now, so nothing else in it goes back; a capture no longer in the history
    /// throws.
    @discardableResult
    public func setFavorite(_ favorite: Bool, of item: HistoryItem) throws -> HistoryItem {
        guard let current = record(at: sidecarURL(forFileName: item.fileName)) else { throw CocoaError(.fileNoSuchFile) }
        let updated = current.favoriting(favorite)
        if updated != current { try writeRecord(updated) }
        return updated
    }

    /// The items older than the retention allows, except those in `keeping` (captures still on screen as
    /// Quick Access cards) and favorites. With history off, that is everything else, favorites too.
    public func expired(retention: HistoryRetention, keeping: Set<UUID> = [], now: Date = .now) -> [HistoryItem] {
        Self.expired(items(), retention: retention, keeping: keeping, now: now)
    }

    /// `expired(retention:keeping:now:)`, listed off the caller's actor: after every capture, where a listing on the
    /// main actor took 17 ms with 300 captures and 280 ms with 5,000 (Docs/perf.md). The caller deletes; what it lists
    /// may have changed by then (see `CaptureRetention.removeExpired`).
    @concurrent public func loadExpired(retention: HistoryRetention, keeping: Set<UUID> = [], now: Date = .now) async -> [HistoryItem] {
        Self.expired(readItems(cancelled: { Task.isCancelled }), retention: retention, keeping: keeping, now: now)
    }

    /// Of `expired`, listed off the main actor for a check made at `checkedAt`, the captures to delete now: none that
    /// something holds now (`held`, asked again after the listing), and none newer than the check. With history off
    /// every capture not held is expired, so a capture taken, or put back on a card, while the listing ran must not go.
    public static func removable(_ expired: [HistoryItem], held: Set<UUID>, checkedAt: Date) -> [HistoryItem] {
        expired.filter { !held.contains($0.id) && $0.createdAt <= checkedAt }
    }

    /// Of the captures listed as expired at `now`, those still expired as their records are now: one deleted since, one
    /// whose file another capture has taken, and one added to Favorites since stay.
    public func stillExpired(_ listed: [HistoryItem], retention: HistoryRetention, now: Date) -> [HistoryItem] {
        let current = listed.compactMap { listed in item(forFileAt: fileURL(for: listed)).flatMap { $0.id == listed.id ? $0 : nil } }
        return Self.expired(current, retention: retention, keeping: [], now: now)
    }

    private static func expired(_ items: [HistoryItem], retention: HistoryRetention, keeping: Set<UUID>, now: Date) -> [HistoryItem] {
        items.filter { item in
            guard !keeping.contains(item.id) else { return false }
            guard let interval = retention.interval else { return true }
            return !item.isFavorite && now.timeIntervalSince(item.createdAt) > interval
        }
    }

    /// Deletes the expired items. Returns how many were removed.
    @discardableResult
    public func removeExpired(retention: HistoryRetention, keeping: Set<UUID> = [], now: Date = .now) -> Int {
        let expired = expired(retention: retention, keeping: keeping, now: now)
        expired.forEach(delete)
        return expired.count
    }

    /// The record of the capture whose file is `fileName`, beside it.
    private func sidecarURL(forFileName fileName: String) -> URL {
        directory.appending(path: "\(fileName).json")
    }

    /// Writes `item`'s record beside its file.
    private func writeRecord(_ item: HistoryItem) throws {
        try JSONEncoder.records.encode(item).write(to: sidecarURL(forFileName: item.fileName), options: .atomic)
        fileNames.withLock { $0[item.id] = item.fileName }
    }

    /// The record kept in the sidecar at `url`; nil when there is none, or it can't be read.
    private func record(at url: URL) -> HistoryItem? {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        return try? JSONDecoder.records.decode(HistoryItem.self, from: data)
    }

    /// Whether a history file is a movie, by its extension.
    public static func isMovie(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// Whether a history file is a recording, kept as a movie or a GIF, by its extension.
    public static func isRecording(_ url: URL) -> Bool {
        isMovie(url) || url.pathExtension.lowercased() == "gif"
    }
}
