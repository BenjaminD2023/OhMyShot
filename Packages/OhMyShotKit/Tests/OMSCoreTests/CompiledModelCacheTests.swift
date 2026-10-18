import Foundation
import Testing
@testable import OMSCore

/// What of Core ML's cache goes once the models it was made from are gone.
struct CompiledModelCacheTests {
    /// A description as Core ML writes it, the parts this reads: strings as FlatBuffers keeps them.
    private static func description(naming paths: [String]) -> Data {
        var data = Data([0x0C, 0x00, 0x00, 0x00, 0x08, 0x00])
        for path in paths + ["input-file-path", "10.203.3"] {
            var length = UInt32(path.utf8.count).littleEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(Data(path.utf8))
            data.append(0)
            data.append(contentsOf: [0x00, 0x00, 0x00])
        }
        return data
    }

    /// An entry as Core ML lays it out: <cache>/<build>/<entry>/<model>.bundle/H15C.bundle/H15C.e5 and its weights.
    @discardableResult
    private static func entry(_ name: String, in cache: URL, naming paths: [String]?) throws -> URL {
        let entry = cache.appending(path: "26B5101f/\(name)", directoryHint: .isDirectory)
        let bundle = entry.appending(path: "E787.bundle/H15C.bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle.appending(path: "main/main_bnns"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: bundle.appending(path: "main/main_bnns/weights.bin"))
        if let paths { try description(naming: paths).write(to: bundle.appending(path: "H15C.e5")) }
        return entry
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CompiledModelCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theModelFileADescriptionNamesIsRead() {
        let path = "/Users/me/Library/Application Support/OhMyShot/Model Packs/pp-formulanet-plus-l/1/Compiled/encoder.mlmodelc/model.mil"
        #expect(CompiledModelCache.sources(in: Self.description(naming: [path])) == [path])
        // Only paths to a model: the keys, versions, and other files are not.
        #expect(CompiledModelCache.sources(in: Self.description(naming: ["/tmp/weights.bin"])).isEmpty)
        // A string without its NUL is no string.
        var cut = Data([UInt8(20), 0, 0, 0])
        cut.append(Data("/a/b/c/model.mil.xyz".utf8))
        cut.append(1)
        #expect(CompiledModelCache.sources(in: cut).isEmpty)
    }

    @Test func entriesOfModelsThatAreGoneAreRemovedAndTheRestStay() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
        let packs = root.appending(path: "Model Packs/pp-formulanet-plus-l", directoryHint: .isDirectory)
        let kept = packs.appending(path: "2/Compiled/encoder.mlmodelc/model.mil")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mil".utf8).write(to: kept)
        let gone = packs.appending(path: "1/Compiled/encoder.mlmodelc/model.mil").path(percentEncoded: false)

        let old = try Self.entry("OLD", in: cache, naming: [gone])
        let current = try Self.entry("CURRENT", in: cache, naming: [kept.path(percentEncoded: false)])
        // Made from a copy Core ML keeps in the cache itself (the Neural Engine's): which model it was isn't known.
        let copy = try Self.entry("COPY", in: cache, naming: [cache.path(percentEncoded: false) + "26B5101f/ABCD/model.mil"])
        let unnamed = try Self.entry("UNNAMED", in: cache, naming: nil)
        // Vision's own models, read by the reader too, stand for any model still where it was.
        let systemModel = "/System/Library/PrivateFrameworks/TextRecognition.framework/cr_td_model_v3_e5.mlmodelc.bundle/model.mil"
        let system = try Self.entry("SYSTEM", in: cache, naming: [systemModel])
        let fileExists = { (path: String) in path == systemModel || FileManager.default.fileExists(atPath: path) }

        let removed = CompiledModelCache.removeStale(in: cache, fileExists: fileExists)
        #expect(removed.map(\.lastPathComponent) == ["OLD"])
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        #expect(!exists(old))
        #expect(exists(current) && exists(copy) && exists(unnamed) && exists(system))
        // Again, nothing more goes.
        #expect(CompiledModelCache.removeStale(in: cache, fileExists: fileExists).isEmpty)
    }

    @Test func aCacheThatIsntThereRemovesNothing() {
        #expect(CompiledModelCache.removeStale(in: URL(filePath: "/nonexistent/com.apple.e5rt.e5bundlecache")).isEmpty)
    }

    @Test func theCacheIsTheProcesssOwn() {
        let folder = CompiledModelCache.folder(forBundleIdentifier: "io.example.text-reader")
        #expect(folder.path(percentEncoded: false).hasSuffix("/Caches/io.example.text-reader/com.apple.e5rt.e5bundlecache/"))
    }
}
