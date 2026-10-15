import AVFoundation
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
    /// A recording's pixels per point on the display it was made on, which sizes a GIF made of it as
    /// things were on screen; nil for captures and recordings from before it was kept.
    public let pixelsPerPoint: Double?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = .now,
        pixelWidth: Int,
        pixelHeight: Int,
        appName: String?,
        fileName: String,
        duration: TimeInterval? = nil,
        pixelsPerPoint: Double? = nil
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

    /// A Studio recording's project, a folder beside it: what the pointer did while recording, the source
    /// movie once an export has taken its place, and the Studio window's settings.
    public func studioURL(for item: HistoryItem) -> URL {
        directory.appending(path: "\(item.fileName).studio", directoryHint: .isDirectory)
    }

    public func hasStudioProject(_ item: HistoryItem) -> Bool {
        FileManager.default.fileExists(atPath: studioURL(for: item).path(percentEncoded: false))
    }

    /// The Studio recording as it was made, kept in its project for Studio to film again.
    public func studioSourceURL(for item: HistoryItem) -> URL {
        studioURL(for: item).appending(path: "source.mp4")
    }

    /// The Studio recording as it was made, copied into its project (a clone, which takes no room) the first
    /// time it is asked for, while the history still holds it. Studio films that copy, which never moves, so
    /// a movie exported into the history while the Studio window is open never becomes what it films.
    public func studioSource(for item: HistoryItem) throws -> URL {
        let source = studioSourceURL(for: item)
        guard !FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return source }
        // Once a movie has taken its place, the history no longer holds the recording as it was made.
        guard !hasStudioMovie(item) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: studioURL(for: item), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fileURL(for: item), to: source)
        return source
    }

    /// Whether a movie exported from Studio has taken the recording's place in the history.
    public func hasStudioMovie(_ item: HistoryItem) -> Bool {
        FileManager.default.fileExists(atPath: studioMovieMarkerURL(for: item).path(percentEncoded: false))
    }

    /// Keeps a movie exported from Studio, the file at `exported` (moved in), in place of the recording, which
    /// stays in its project (see `studioSource(for:)`), and `project`, the settings it was made with, beside
    /// it. Returns the record with the movie's size and length.
    @discardableResult
    public func replaceStudioMovie(
        of item: HistoryItem, withFileAt exported: URL, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval, project: Data
    ) throws -> HistoryItem {
        _ = try studioSource(for: item)
        try FileManager.default.removeItem(at: fileURL(for: item))
        try FileManager.default.moveItem(at: exported, to: fileURL(for: item))
        try project.write(to: studioMovieMarkerURL(for: item), options: .atomic)
        return try updated(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration)
    }

    /// The settings the movie in the history was made with, when one exported from Studio is there: the
    /// Studio window compares them with the project's to know whether the movie is still its own.
    public func studioMovieProject(of item: HistoryItem) -> Data? {
        try? Data(contentsOf: studioMovieMarkerURL(for: item))
    }

    /// In the project, there once a movie exported from Studio has taken the recording's place: the settings
    /// that movie was made with.
    private func studioMovieMarkerURL(for item: HistoryItem) -> URL {
        studioURL(for: item).appending(path: "exported.json")
    }

    /// The text read in the capture, for searching the history (`HistoryText`). Not `.json`, so listing the
    /// history never takes it for a record.
    public func textURL(for item: HistoryItem) -> URL {
        directory.appending(path: "\(item.fileName).text")
    }

    /// The capture's file as it is now, to tell later whether text read from it still belongs to it; nil
    /// when the file is gone.
    public func stamp(of item: HistoryItem) -> HistoryText.Stamp? {
        let values = try? fileURL(for: item).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate else { return nil }
        return HistoryText.Stamp(size: size, modified: modified.timeIntervalSinceReferenceDate)
    }

    /// The text read in the capture as it is now; nil when none was read, or it was read from a picture
    /// since replaced (marked up, or put back as taken).
    public func text(of item: HistoryItem) -> String? {
        guard let data = try? Data(contentsOf: textURL(for: item)),
              let kept = try? JSONDecoder().decode(HistoryText.self, from: data),
              kept.version == HistoryText.version, kept.stamp == stamp(of: item)
        else { return nil }
        return kept.text
    }

    /// Keeps `text`, read from the capture's file when it was `stamp`; if the file has changed since, the text
    /// is kept but counts as not read.
    public func setText(_ text: String, of item: HistoryItem, readFrom stamp: HistoryText.Stamp) throws {
        let kept = HistoryText(version: HistoryText.version, stamp: stamp, text: text)
        try JSONEncoder().encode(kept).write(to: textURL(for: item), options: .atomic)
    }

    /// The screenshots among `items` whose text has not been read from their picture as it is now. Recordings
    /// have no text to read.
    public func needingText(_ items: [HistoryItem]) -> [HistoryItem] {
        items.filter { $0.kind == .screenshot && text(of: $0) == nil }
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

    /// Keeps an edited recording, the file at `edited` (moved in), in place of the recording, keeping the
    /// recording as it was made beside it the first time. Returns the record with the new size and length.
    @discardableResult
    public func replaceRecording(of item: HistoryItem, withFileAt edited: URL, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval) throws -> HistoryItem {
        if hasOriginal(item) {
            try FileManager.default.removeItem(at: fileURL(for: item))
        } else {
            try FileManager.default.moveItem(at: fileURL(for: item), to: originalURL(for: item))
        }
        try FileManager.default.moveItem(at: edited, to: fileURL(for: item))
        return try updated(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration)
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
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        return try updated(
            item, pixelWidth: size.map { Int($0.width.rounded()) } ?? item.pixelWidth,
            pixelHeight: size.map { Int($0.height.rounded()) } ?? item.pixelHeight, duration: duration
        )
    }

    /// Keeps the marked-up picture as the capture and lets the original and the marks go: the marks can
    /// no longer be changed.
    public func flatten(_ item: HistoryItem) {
        removeExtras(of: item)
    }

    private func resized(_ item: HistoryItem, pixelWidth: Int, pixelHeight: Int) throws -> HistoryItem {
        try updated(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: item.duration)
    }

    private func updated(_ item: HistoryItem, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval?) throws -> HistoryItem {
        let updated = HistoryItem(
            id: item.id, kind: item.kind, createdAt: item.createdAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            appName: item.appName, fileName: item.fileName, duration: duration, pixelsPerPoint: item.pixelsPerPoint
        )
        if updated != item {
            try JSONEncoder.history.encode(updated).write(to: sidecarURL(for: item.id, fileName: item.fileName), options: .atomic)
        }
        return updated
    }

    private func removeExtras(of item: HistoryItem) {
        try? FileManager.default.removeItem(at: originalURL(for: item))
        try? FileManager.default.removeItem(at: annotationsURL(for: item))
        try? FileManager.default.removeItem(at: studioURL(for: item))
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
        date: Date = .now
    ) throws -> HistoryItem {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = HistoryItem(
            kind: kind, createdAt: date, pixelWidth: pixelWidth, pixelHeight: pixelHeight, appName: appName,
            fileName: availableFileName(name, fileExtension: source.pathExtension), duration: duration, pixelsPerPoint: pixelsPerPoint
        )
        try FileManager.default.moveItem(at: source, to: fileURL(for: item))
        try JSONEncoder.history.encode(item).write(to: sidecarURL(for: item.id, fileName: item.fileName), options: .atomic)
        return item
    }

    /// `name.fileExtension`, or `name (2).fileExtension` and so on when that is taken.
    private func availableFileName(_ name: String, fileExtension: String) -> String {
        var fileName = "\(name).\(fileExtension)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: fileName).path(percentEncoded: false)) {
            fileName = "\(name) (\(counter)).\(fileExtension)"
            counter += 1
        }
        return fileName
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
        let fileName = availableFileName(name, fileExtension: fileExtension)
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
        try? FileManager.default.removeItem(at: textURL(for: item))
    }

    /// Moves the capture to the Trash, where it can still be recovered, and forgets it.
    public func moveToTrash(_ item: HistoryItem) {
        do {
            try FileManager.default.trashItem(at: fileURL(for: item), resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: fileURL(for: item))
        }
        try? FileManager.default.removeItem(at: sidecarURL(for: item.id, fileName: item.fileName))
        // The Trash keeps the picture as it was last shown; the original, the marks, and its text go with the record.
        removeExtras(of: item)
        try? FileManager.default.removeItem(at: textURL(for: item))
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

    /// A thumbnail at most `maxPixels` on its long side, decoded without loading the full image; for a
    /// recording, its first frame.
    @concurrent
    public static func thumbnail(of url: URL, maxPixels: Int) async -> CGImage? {
        if isMovie(url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return try? await generator.image(at: .zero).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// Whether a history file is a movie, by its extension.
    public static func isMovie(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// Whether a history file is a recording, kept as a movie or a GIF, by its extension.
    public static func isRecording(_ url: URL) -> Bool {
        isMovie(url) || url.pathExtension.lowercased() == "gif"
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

    /// A card's thumbnail of a picture, at most `maxPixels` on its longer side: the part the card shows
    /// (`CardPicture`), drawn from the picture itself, so the top of a long scrolling capture stays sharp
    /// however long it is.
    @concurrent
    public static func cardThumbnail(of image: CGImage, maxPixels: Int) async -> CGImage? {
        scaled(CardPicture.shownPart(of: image), maxPixels: maxPixels)
    }

    /// The same, from a capture's file; a movie's first frame as `thumbnail(of:maxPixels:)` makes it.
    @concurrent
    public static func cardThumbnail(of url: URL, maxPixels: Int) async -> CGImage? {
        if isMovie(url) { return await thumbnail(of: url, maxPixels: maxPixels) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return cardThumbnail(of: source, maxPixels: maxPixels)
    }

    /// The same, from encoded data already in memory.
    @concurrent
    public static func cardThumbnail(of data: Data, maxPixels: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return cardThumbnail(of: source, maxPixels: maxPixels)
    }

    /// The card's part of what `source` holds: decoded only as large as that part needs, then drawn on its own,
    /// so the larger decoding is let go.
    private static func cardThumbnail(of source: CGImageSource, maxPixels: Int) -> CGImage? {
        func decoded(_ longest: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longest,
            ] as CFDictionary)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return decoded(maxPixels) }
        let part = CardPicture.shownRect(width: width, height: height)
        guard part.width < CGFloat(width) || part.height < CGFloat(height) else { return decoded(maxPixels) }
        // The whole at the size that makes the part `maxPixels` on its longer side, but no more than about 64 MB of
        // pixels: a narrow picture tens of thousands of pixels long decodes long enough for a sharp part.
        let scale = Double(maxPixels) / Double(max(part.width, part.height))
        let longest = Int((16_777_216 * Double(max(width, height)) / Double(min(width, height))).squareRoot())
        guard let whole = decoded(min(max(16_384, longest), Int((Double(max(width, height)) * scale).rounded(.up)))) else { return nil }
        let across = Double(whole.width) / Double(width), along = Double(whole.height) / Double(height)
        let shown = CGRect(x: 0, y: 0, width: (part.width * across).rounded(), height: (part.height * along).rounded())
        return whole.cropping(to: shown).flatMap { scaled($0, maxPixels: maxPixels) }
    }

    /// `image` drawn at most `maxPixels` on its longer side, in a bitmap of its own.
    private static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
