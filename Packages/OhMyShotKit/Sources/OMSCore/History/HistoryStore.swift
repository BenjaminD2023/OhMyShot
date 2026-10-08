import CoreGraphics
import Foundation
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

    public init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = .now,
        pixelWidth: Int,
        pixelHeight: Int,
        appName: String?,
        fileName: String,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.appName = appName
        self.fileName = fileName
        self.duration = duration
    }
}

/// Keeps every capture in an app-owned folder, so nothing lands on the Desktop unless the user saves it,
/// and a closed Quick Access card can always be brought back.
///
/// Each capture is a file plus a small JSON sidecar; the folder itself is the index, so there is no
/// database to keep in sync. Cleanup runs at launch and after each capture, never on a timer.
public final class HistoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The standard location: Application Support, under this build's bundle identifier.
    public static func standard() -> HistoryStore {
        let base = URL.applicationSupportDirectory.appending(path: Log.subsystem, directoryHint: .isDirectory)
        return HistoryStore(directory: base.appending(path: "History", directoryHint: .isDirectory))
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
    /// marks beside it. Returns the record with the new size.
    @discardableResult
    public func replaceImage(of item: HistoryItem, with data: Data, pixelWidth: Int, pixelHeight: Int, annotations: Data) throws -> HistoryItem {
        if !hasOriginal(item) {
            try FileManager.default.copyItem(at: fileURL(for: item), to: originalURL(for: item))
        }
        try data.write(to: fileURL(for: item), options: .atomic)
        try annotations.write(to: annotationsURL(for: item), options: .atomic)
        return try resized(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// Puts the capture back as it was taken and forgets its marks. Returns the record with the
    /// original's size; unchanged when it was never marked up.
    @discardableResult
    public func restoreOriginal(of item: HistoryItem) throws -> HistoryItem {
        guard hasOriginal(item) else { return item }
        let original = originalURL(for: item)
        let size = Self.pixelSize(of: original)
        _ = try FileManager.default.replaceItemAt(fileURL(for: item), withItemAt: original)
        try? FileManager.default.removeItem(at: annotationsURL(for: item))
        return try resized(item, pixelWidth: size?.width ?? item.pixelWidth, pixelHeight: size?.height ?? item.pixelHeight)
    }

    /// Keeps the marked-up picture as the capture and lets the original and the marks go: the marks can
    /// no longer be changed.
    public func flatten(_ item: HistoryItem) {
        removeExtras(of: item)
    }

    private func resized(_ item: HistoryItem, pixelWidth: Int, pixelHeight: Int) throws -> HistoryItem {
        let updated = HistoryItem(
            id: item.id, kind: item.kind, createdAt: item.createdAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            appName: item.appName, fileName: item.fileName, duration: item.duration
        )
        if updated != item {
            try JSONEncoder.history.encode(updated).write(to: sidecarURL(for: item.id, fileName: item.fileName), options: .atomic)
        }
        return updated
    }

    private func removeExtras(of item: HistoryItem) {
        try? FileManager.default.removeItem(at: originalURL(for: item))
        try? FileManager.default.removeItem(at: annotationsURL(for: item))
    }

    private static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
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
        date: Date = .now
    ) throws -> HistoryItem {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        var fileName = "\(name).\(fileExtension)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: fileName).path(percentEncoded: false)) {
            fileName = "\(name) (\(counter)).\(fileExtension)"
            counter += 1
        }
        let item = HistoryItem(
            id: id,
            kind: kind,
            createdAt: date,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            appName: appName,
            fileName: fileName,
            duration: duration
        )
        try data.write(to: fileURL(for: item), options: .atomic)
        try JSONEncoder.history.encode(item).write(to: sidecarURL(for: item.id, fileName: fileName), options: .atomic)
        return item
    }

    /// Every item, newest first.
    public func items() -> [HistoryItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                guard let data = FileManager.default.contents(atPath: directory.appending(path: name).path(percentEncoded: false)) else { return nil }
                return try? JSONDecoder.history.decode(HistoryItem.self, from: data)
            }
            .filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path(percentEncoded: false)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func item(id: UUID) -> HistoryItem? {
        items().first { $0.id == id }
    }

    public func delete(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: fileURL(for: item))
        try? FileManager.default.removeItem(at: sidecarURL(for: item.id, fileName: item.fileName))
        removeExtras(of: item)
    }

    /// Moves the capture to the Trash, where it can still be recovered, and forgets it.
    public func moveToTrash(_ item: HistoryItem) {
        do {
            try FileManager.default.trashItem(at: fileURL(for: item), resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: fileURL(for: item))
        }
        try? FileManager.default.removeItem(at: sidecarURL(for: item.id, fileName: item.fileName))
        // The Trash keeps the picture as it was last shown; the original and the marks go with the record.
        removeExtras(of: item)
    }

    public func deleteAll() {
        items().forEach(delete)
    }

    /// The items older than the retention allows, except those in `keeping` (captures still on screen as
    /// Quick Access cards). With history off, that is everything else.
    public func expired(retention: HistoryRetention, keeping: Set<UUID> = [], now: Date = .now) -> [HistoryItem] {
        items().filter { item in
            guard !keeping.contains(item.id) else { return false }
            guard let interval = retention.interval else { return true }
            return now.timeIntervalSince(item.createdAt) > interval
        }
    }

    /// Deletes the expired items. Returns how many were removed.
    @discardableResult
    public func removeExpired(retention: HistoryRetention, keeping: Set<UUID> = [], now: Date = .now) -> Int {
        let expired = expired(retention: retention, keeping: keeping, now: now)
        expired.forEach(delete)
        return expired.count
    }

    private func sidecarURL(for id: UUID, fileName: String) -> URL {
        directory.appending(path: "\(fileName).json")
    }

    /// A thumbnail at most `maxPixels` on its long side, decoded without loading the full image.
    @concurrent
    public static func thumbnail(of url: URL, maxPixels: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// The same, from encoded data already in memory.
    @concurrent
    public static func thumbnail(of data: Data, maxPixels: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
