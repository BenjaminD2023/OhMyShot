import Foundation
import OSLog

/// What Core ML keeps of the models a process loaded, in that process's own Caches folder
/// (`com.apple.e5rt.e5bundlecache`). For a model run on the CPU it is the model again, its weights at 16 bits: about
/// 350 MB for the Math Formulas pack, one copy for each path the model was loaded from, never removed when that path
/// goes away (Docs/perf.md › M6 — Formulas in the panel). Without this, every pack removed or replaced by a new version
/// would leave its copy behind for good.
public enum CompiledModelCache {
    /// Core ML's cache in the Caches folder of the process with `bundleIdentifier`.
    public static func folder(forBundleIdentifier bundleIdentifier: String) -> URL {
        URL.cachesDirectory
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
    }

    /// Removes the entries made from model files that are all gone. An entry that names no model file outside the
    /// cache (one made from a copy Core ML keeps in the cache itself, as for the Neural Engine) is left alone.
    ///
    /// The cache holds a folder for each system build, and in it a folder for each entry; an entry's `.e5` files, a
    /// few folders down, name the model it was made from.
    /// - Returns: the entries removed.
    @discardableResult
    public static func removeStale(in folder: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        let manager = FileManager.default
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        var removed: [URL] = []
        for build in subfolders(of: folder) {
            for entry in subfolders(of: build) {
                let sources = descriptions(in: entry).flatMap(sources(in:)).filter { !$0.hasPrefix(base) }
                guard !sources.isEmpty, !sources.contains(where: fileExists) else { continue }
                if (try? manager.removeItem(at: entry)) != nil { removed.append(entry) }
            }
        }
        if !removed.isEmpty {
            Log.modelPacks.notice("Removed \(removed.count, privacy: .public) entries of Core ML's cache whose models are gone")
        }
        return removed
    }

    /// The model files a `.e5` description names: its strings (FlatBuffers: a 32-bit little-endian length, the
    /// bytes, a NUL) that are absolute paths to a `.mil` file.
    static func sources(in description: Data) -> [String] {
        let bytes = [UInt8](description)
        var found: [String] = []
        var index = 0
        while index + 5 < bytes.count {
            defer { index += 1 }
            guard bytes[index + 4] == UInt8(ascii: "/") else { continue }
            let length = Int(bytes[index]) | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24
            let end = index + 4 + length
            guard (8...4096).contains(length), end < bytes.count, bytes[end] == 0 else { continue }
            let text = bytes[(index + 4)..<end]
            guard !text.contains(where: { $0 < 0x20 }), let path = String(bytes: text, encoding: .utf8), path.hasSuffix(".mil") else { continue }
            found.append(path)
            index = end
        }
        return found
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// The `.e5` files in an entry, read; each is a few kilobytes.
    private static func descriptions(in entry: URL) -> [Data] {
        guard let files = FileManager.default.enumerator(at: entry, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "e5" }.compactMap { try? Data(contentsOf: $0) }
    }
}
