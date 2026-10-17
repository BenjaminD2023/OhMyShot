import Foundation
import OSLog

/// Where model packs are kept: one folder per pack, in Application Support.
///
///     Model Packs/<id>/<version>/            an installed version: its files, and Receipt.json last
///     Model Packs/<id>/<version>.download/   a version on its way: files done, and <path>.partial for the rest
///
/// A version is installed once its folder holds its receipt. The receipt is written into the download's folder
/// after every file has been checked, and the folder is then renamed into place, so a version appears whole or
/// not at all. A download's folder outlives the app, so a download paused or cut off goes on where it stopped,
/// even after a relaunch. An installed version's folder never moves, so what is made from its files there (a
/// compiled Core ML model, whose Neural Engine compilation the system keeps by its path) stays valid.
///
/// Nothing here runs by itself: every method reads or changes the disk when called, off the main actor.
public struct ModelPackStore: Sendable {
    public let root: URL

    /// What a version's receipt records.
    public struct Receipt: Codable, Equatable, Sendable {
        public let id: String
        public let version: String
        public let size: Int64
        public let installed: Date
    }

    public init(root: URL) {
        self.root = root
    }

    /// `Model Packs` in the app's own folder in Application Support.
    public static func standard() -> ModelPackStore {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return ModelPackStore(root: support.appending(path: Log.subsystem).appending(path: "Model Packs"))
    }

    public func folder(of pack: ModelPack) -> URL {
        root.appending(path: pack.id).appending(path: pack.version, directoryHint: .isDirectory)
    }

    public func downloadFolder(of pack: ModelPack) -> URL {
        root.appending(path: pack.id).appending(path: "\(pack.version).download", directoryHint: .isDirectory)
    }

    static let receiptName = "Receipt.json"

    /// The receipt of the pack's version, when that version is installed.
    public func receipt(of pack: ModelPack) -> Receipt? {
        let url = folder(of: pack).appending(path: Self.receiptName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let receipt = try? decoder.decode(Receipt.self, from: data),
              receipt.id == pack.id, receipt.version == pack.version
        else { return nil }
        return receipt
    }

    /// Where one of the pack's files is, once the pack is installed.
    public func url(of file: ModelPack.File, in pack: ModelPack) -> URL {
        Self.place(file.path, under: folder(of: pack))
    }

    /// How much of the pack's version is already on this Mac, downloaded or partly downloaded, in bytes.
    public func downloaded(_ pack: ModelPack) -> Int64 {
        let staging = downloadFolder(of: pack)
        return pack.files.reduce(0) { total, file in
            let done = Self.place(file.path, under: staging)
            if Self.size(of: done) == file.size { return total + file.size }
            return total + min(Self.size(of: Self.partial(of: done)) ?? 0, file.size)
        }
    }

    /// Whether a download of the pack's version was started: any of its files but the license, which is fetched
    /// on its own to be read first, is there or partly there.
    public func downloadStarted(_ pack: ModelPack) -> Bool {
        let staging = downloadFolder(of: pack)
        return pack.files.contains { file in
            guard file.path != pack.license.file else { return false }
            let done = Self.place(file.path, under: staging)
            return (Self.size(of: done) ?? 0) > 0 || (Self.size(of: Self.partial(of: done)) ?? 0) > 0
        }
    }

    /// Makes the download's folder with every folder its files go in.
    func prepareDownload(of pack: ModelPack) throws -> URL {
        let staging = downloadFolder(of: pack)
        let manager = FileManager.default
        for file in pack.files {
            try manager.createDirectory(at: Self.place(file.path, under: staging).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return staging
    }

    /// Writes the receipt into the finished download's folder, then moves the folder into place. A folder
    /// already there without a receipt (left by a version cut off while it was being installed) is replaced.
    func install(_ pack: ModelPack, now: Date = .now) throws -> Receipt {
        let staging = downloadFolder(of: pack), target = folder(of: pack)
        // To the second, as the receipt keeps it.
        let installed = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let receipt = Receipt(id: pack.id, version: pack.version, size: pack.size, installed: installed)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: staging.appending(path: Self.receiptName), options: .atomic)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path(percentEncoded: false)) {
            try manager.removeItem(at: target)
        }
        try manager.moveItem(at: staging, to: target)
        return receipt
    }

    /// Removes the pack: every version, installed or on its way.
    public func remove(_ pack: ModelPack) throws {
        let folder = root.appending(path: pack.id, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Removes the pack's download in progress, and nothing installed.
    public func removeDownload(of pack: ModelPack) throws {
        let staging = downloadFolder(of: pack)
        guard FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: staging)
    }

    /// Removes what no pack of `catalog` uses: packs it no longer lists, and versions of its packs other than
    /// the listed one, installed or on their way. The listed version's download in progress stays, paused.
    ///
    /// - Returns: the folders removed, relative to the root.
    @discardableResult
    public func removeUnused(keeping catalog: [ModelPack]) -> [String] {
        let manager = FileManager.default
        let listed = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var removed: [String] = []
        for id in (try? manager.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? [] where !id.hasPrefix(".") {
            let folder = root.appending(path: id, directoryHint: .isDirectory)
            guard let pack = listed[id] else {
                if (try? manager.removeItem(at: folder)) != nil { removed.append(id) }
                continue
            }
            for entry in (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] where !entry.hasPrefix(".") {
                guard entry != pack.version, entry != "\(pack.version).download" else { continue }
                if (try? manager.removeItem(at: folder.appending(path: entry))) != nil { removed.append("\(id)/\(entry)") }
            }
        }
        if !removed.isEmpty { Log.modelPacks.notice("Removed model pack folders no pack uses: \(removed.joined(separator: ", "), privacy: .public)") }
        return removed
    }

    // MARK: Paths

    /// `path` under `folder`, folder by folder; the path is one `ModelPack.problem` has already checked.
    static func place(_ path: String, under folder: URL) -> URL {
        var url = folder
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            url.append(path: String(component), directoryHint: index == components.count - 1 ? .notDirectory : .isDirectory)
        }
        return url
    }

    /// Whether `file` lies inside `folder`, once both are standardized.
    static func contains(_ folder: URL, _ file: URL) -> Bool {
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let path = file.standardizedFileURL.path(percentEncoded: false)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func partial(of file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".partial")
    }

    static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
    }
}
