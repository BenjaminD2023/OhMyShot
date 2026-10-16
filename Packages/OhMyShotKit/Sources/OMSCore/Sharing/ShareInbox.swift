import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The folder the Share extension hands pictures to the app through.
///
/// The extension is sandboxed and the app is not, and the signing is often ad-hoc or a personal team, which
/// has no App Group to share. So the extension may write one folder of the app's own Application Support
/// (a sandbox exception in its entitlements), the app reads from it, and neither needs the other's
/// container. Each hand-over is a batch: a folder named by a UUID holding the pictures, which the app is
/// told about by `ShareHandoff`'s URL and removes once it has read them.
///
/// Anything can open that URL, so the app takes nothing from it but a batch's name, looks for it only
/// directly inside the inbox, and accepts only the pictures it finds there.
public struct ShareInbox: Sendable {
    public static let folderName = "Share Inbox"
    /// A hand-over of more pictures than this has the rest left behind.
    public static let maximumPictures = 20
    /// Larger files are not taken; a picture of a few hundred megabytes is not a screenshot.
    public static let maximumFileSize = 512 * 1_024 * 1_024
    /// A batch the app never collected (it was not running, or quit first) is cleared after this long.
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    public enum Failure: Error, Equatable, Sendable {
        /// There is no such folder directly inside the inbox, or it is a link to somewhere else.
        case noSuchBatch
        /// The batch holds no picture the app can read.
        case noPictures
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's inbox: Application Support, under this build's bundle identifier, beside the history.
    public static func standard() -> ShareInbox {
        inbox(in: URL.applicationSupportDirectory, hostBundleIdentifier: Log.subsystem)
    }

    /// The inbox of the app with `hostBundleIdentifier`, as the extension finds it. A sandboxed process has a
    /// home folder of its own, so the real one is looked up; the extension's entitlements let it write here.
    public static func hosted(by hostBundleIdentifier: String) -> ShareInbox {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let support = URL(filePath: home, directoryHint: .isDirectory).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return inbox(in: support, hostBundleIdentifier: hostBundleIdentifier)
    }

    private static func inbox(in support: URL, hostBundleIdentifier: String) -> ShareInbox {
        ShareInbox(directory: support
            .appending(path: hostBundleIdentifier, directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory))
    }

    /// Makes the folder, so the extension, which can write only inside it, finds it there.
    public func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Writing (the extension)

    /// A new, empty batch. Batches nobody collected are cleared first.
    public func newBatch(now: Date = .now) throws -> Batch {
        removeStaleBatches(now: now)
        let id = UUID()
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Batch(id: id, directory: folder)
    }

    public struct Batch: Sendable {
        public let id: UUID
        public let directory: URL

        /// Copies a picture file into the batch. The name is made safe and kept unique; `type` supplies the
        /// extension when the name has none.
        @discardableResult
        public func store(copyOf file: URL, named suggestedName: String? = nil, type: UTType? = nil) throws -> URL {
            let destination = directory.appending(path: uniqueName(suggestedName ?? file.lastPathComponent, type: type ?? UTType(filenameExtension: file.pathExtension)))
            try FileManager.default.copyItem(at: file, to: destination)
            return destination
        }

        /// Writes a picture that exists only as data into the batch.
        @discardableResult
        public func store(_ data: Data, named suggestedName: String?, type: UTType) throws -> URL {
            let destination = directory.appending(path: uniqueName(suggestedName, type: type))
            try data.write(to: destination, options: .withoutOverwriting)
            return destination
        }

        private func uniqueName(_ suggested: String?, type: UTType?) -> String {
            ShareInbox.fileName(suggested: suggested, type: type) {
                FileManager.default.fileExists(atPath: directory.appending(path: $0).path(percentEncoded: false))
            }
        }
    }

    /// A name for a picture in a batch: the one suggested without folders or leading dots, with an image
    /// extension (`type`'s when the name has none), and numbered until `isTaken` says it is free.
    public static func fileName(suggested: String?, type: UTType?, isTaken: (String) -> Bool) -> String {
        var name = (suggested ?? "").split(separator: "/").last.map(String.init) ?? ""
        name = name.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        var base = (name as NSString).deletingPathExtension
        var fileExtension = (name as NSString).pathExtension
        if UTType(filenameExtension: fileExtension)?.conforms(to: .image) != true {
            // No extension, or not a picture's: the whole name is the base, and the type says what it is.
            base = name
            fileExtension = type?.preferredFilenameExtension ?? "png"
        }
        if base.isEmpty { base = "Picture" }
        base = String(base.prefix(120))
        var candidate = "\(base).\(fileExtension)"
        var number = 2
        while isTaken(candidate) {
            candidate = "\(base) \(number).\(fileExtension)"
            number += 1
        }
        return candidate
    }

    // MARK: Reading (the app)

    /// Whether `url` lies inside `folder`, judged by whole path components: `/x/Inbox-evil` is not inside
    /// `/x/Inbox`, and a path with `..` in it is taken where it leads.
    public static func isInside(_ url: URL, folder: URL) -> Bool {
        let inner = url.standardizedFileURL.pathComponents
        let outer = folder.standardizedFileURL.pathComponents
        return inner.count > outer.count && inner.starts(with: outer)
    }

    /// The pictures of a batch, in name order. The batch must be a folder directly inside the inbox, not a
    /// link out of it; in it, only regular files that are pictures count, and a link, a folder, a file of
    /// another kind, or one too large is passed over.
    public func pictures(inBatch id: UUID) throws -> [URL] {
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        guard
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true,
            Self.isInside(folder.resolvingSymlinksInPath(), folder: directory.resolvingSymlinksInPath())
        else { throw Failure.noSuchBatch }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        let pictures = files
            .filter { file in
                guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return false }
                guard values.isSymbolicLink != true, values.isRegularFile == true, let size = values.fileSize else { return false }
                return size > 0 && size <= Self.maximumFileSize && Self.isPicture(file)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !pictures.isEmpty else { throw Failure.noPictures }
        return Array(pictures.prefix(Self.maximumPictures))
    }

    /// Whether a file is a picture: named like one, and read as one by ImageIO, whatever its name says.
    public static func isPicture(_ file: URL) -> Bool {
        guard
            ImageLoader.canLoad(file),
            let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let identifier = CGImageSourceGetType(source)
        else { return false }
        return UTType(identifier as String)?.conforms(to: .image) == true
    }

    /// Removes a batch, once the app has read it.
    public func discard(batch id: UUID) {
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        // A link is removed as a link; what it pointed at is not touched.
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes the batches nobody collected within `staleAfter`.
    public func removeStaleBatches(now: Date = .now) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let batches = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        for batch in batches where UUID(uuidString: batch.lastPathComponent) != nil {
            guard let modified = try? batch.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > Self.staleAfter { try? FileManager.default.removeItem(at: batch) }
        }
    }
}
