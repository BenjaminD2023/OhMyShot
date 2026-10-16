import CoreGraphics
import Foundation

/// The files screenshots are handed over as where nothing is saved: dragged out of a card or History, uploaded,
/// returned to a Shortcut. A capture in the history is a PNG as it was taken; when Settings ask for another
/// format, or for the picture to be changed, a converted copy is made in the caches and that is handed over. It
/// keeps the capture's name, so every way out names it alike.
public enum ExportedFiles {
    /// Where converted copies are kept.
    public static var standardFolder: URL {
        URL.cachesDirectory.appending(path: Log.subsystem, directoryHint: .isDirectory).appending(path: "Exports", directoryHint: .isDirectory)
    }

    /// How long a converted copy stays: an upload can be retried, and a drag's target may take the file later.
    public static let lifetime: TimeInterval = 3 * 24 * 3600

    /// Whether a file is a picture that `ScreenshotOutput` applies to: recordings, movies and GIFs alike, are not.
    public static func isPicture(_ url: URL) -> Bool {
        ImageLoader.canLoad(url) && !HistoryStore.isRecording(url)
    }

    /// The file to hand over for the capture at `source`: the capture itself when Settings leave it as it is (or
    /// it is no picture), else its converted copy, made now unless one made since the capture last changed is there.
    /// - Parameters:
    ///   - pixelsPerPoint: the capture's scale, which 1× needs.
    ///   - name: the file's name without its extension; the capture's own by default.
    public static func file(
        for source: URL, pixelsPerPoint: Double?, output: ScreenshotOutput, name: String? = nil, in folder: URL = standardFolder
    ) throws -> URL {
        guard !output.isUnchanged, isPicture(source) else { return source }
        let directory = folder
            .appending(path: "\(output.cacheKey)-\(pixelsPerPoint.map { String($0) } ?? "unknown")", directoryHint: .isDirectory)
            .appending(path: Self.tag(of: source), directoryHint: .isDirectory)
        let destination = directory.appending(path: "\(name ?? source.deletingPathExtension().lastPathComponent).\(output.format.fileExtension)")
        if let made = modificationDate(of: destination), let changed = modificationDate(of: source), made >= changed { return destination }
        let encoded = try PictureExport.encode(fileAt: source, pixelsPerPoint: pixelsPerPoint, output: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.data.write(to: destination, options: .atomic)
        return destination
    }

    /// The same off the main actor, for a capture too large to convert between two frames.
    @concurrent
    public static func fileOffMain(
        for source: URL, pixelsPerPoint: Double?, output: ScreenshotOutput, name: String? = nil, in folder: URL = standardFolder
    ) async throws -> URL {
        try file(for: source, pixelsPerPoint: pixelsPerPoint, output: output, name: name, in: folder)
    }

    /// A picture in memory made into a file named `name`, for an upload, which may be retried long after the capture's
    /// own file is gone: it is in a folder of its own, since a later picture of the same name must not replace it.
    public static func file(
        forPicture image: CGImage, hdr: CGImage? = nil, named name: String, pixelsPerPoint: Double?, output: ScreenshotOutput, in folder: URL = standardFolder
    ) throws -> URL {
        let encoded = try PictureExport.encode(image, pixelsPerPoint: pixelsPerPoint, hdr: hdr, output: output)
        let directory = folder
            .appending(path: "\(output.cacheKey)-picture", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(name).\(encoded.fileExtension)")
        try encoded.data.write(to: destination, options: .atomic)
        return destination
    }

    @concurrent
    public static func fileOffMain(
        forPicture image: CGImage, hdr: CGImage? = nil, named name: String, pixelsPerPoint: Double?, output: ScreenshotOutput, in folder: URL = standardFolder
    ) async throws -> URL {
        try file(forPicture: image, hdr: hdr, named: name, pixelsPerPoint: pixelsPerPoint, output: output, in: folder)
    }

    /// How many of the clipboard's files are kept: the last few copies, which an app slow to paste, or a clipboard
    /// manager, may still name. An older one goes as a new one is made, so copying again and again does not fill the
    /// caches.
    public static let clipboardFilesKept = 5

    /// A picture in memory made into a file named `name`, for the clipboard's file. Each is in a folder of its own
    /// under `Clipboard`, which holds only the last few, so uploads (see `file(forPicture:…)`) never lose theirs to it.
    public static func file(
        forClipboard image: CGImage, hdr: CGImage? = nil, named name: String, pixelsPerPoint: Double?, output: ScreenshotOutput, in folder: URL = standardFolder
    ) throws -> URL {
        let encoded = try PictureExport.encode(image, pixelsPerPoint: pixelsPerPoint, hdr: hdr, output: output)
        let clipboard = folder.appending(path: "Clipboard", directoryHint: .isDirectory)
        let directory = clipboard.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(name).\(encoded.fileExtension)")
        try encoded.data.write(to: destination, options: .atomic)
        removeAllButNewest(in: clipboard, keeping: clipboardFilesKept)
        return destination
    }

    @concurrent
    public static func fileOffMain(
        forClipboard image: CGImage, hdr: CGImage? = nil, named name: String, pixelsPerPoint: Double?, output: ScreenshotOutput, in folder: URL = standardFolder
    ) async throws -> URL {
        try file(forClipboard: image, hdr: hdr, named: name, pixelsPerPoint: pixelsPerPoint, output: output, in: folder)
    }

    /// Takes away the copies nobody can still want, and the folders they leave empty.
    public static func removeOld(in folder: URL = standardFolder, now: Date = .now) {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        var directories: [URL] = []
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            guard values.isRegularFile == true else {
                directories.append(url)
                continue
            }
            if let date = values.contentModificationDate, now.timeIntervalSince(date) > lifetime {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // The deepest first, so a folder whose only content was an empty folder goes too.
        for directory in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?.isEmpty == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Removes all but the `count` newest folders in `folder`.
    private static func removeAllButNewest(in folder: URL, keeping count: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let newestFirst = folders.sorted {
            let first = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return first > second
        }
        for old in newestFirst.dropFirst(count) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        // Not through the URL, which remembers the date it was first asked for.
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// A short name for a source file's place, so two captures with one name do not share a copy (FNV-1a).
    private static func tag(of url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.standardizedFileURL.path(percentEncoded: false).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
