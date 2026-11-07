import Foundation
import Testing
@testable import OMSCore

/// When Vision's text models count as compiled: a warmup's note for this build, and Core ML's cache beside it.
struct CompiledTextModelsTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CompiledTextModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func makeCache(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "com.apple.e5rt.e5bundlecache/26B118"), withIntermediateDirectories: true)
    }

    @Test func notCompiledUntilAWarmupNotesIt() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let models = CompiledTextModels(folder: folder, build: "26B118")
        #expect(!models.isCompiled)
        try Self.makeCache(in: folder)
        #expect(!models.isCompiled)
        try models.markCompiled()
        #expect(models.isCompiled)
    }

    @Test func goneWithTheCacheOrTheFolder() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let models = CompiledTextModels(folder: folder, build: "26B118")
        try Self.makeCache(in: folder)
        try models.markCompiled()
        // A cleaner that takes only Core ML's cache.
        try FileManager.default.removeItem(at: folder.appending(path: "com.apple.e5rt.e5bundlecache"))
        #expect(!models.isCompiled)
        try Self.makeCache(in: folder)
        try models.markCompiled()
        // One that empties the Caches folder.
        try FileManager.default.removeItem(at: folder)
        #expect(!models.isCompiled)
    }

    @Test func aNewBuildCompilesAgain() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.makeCache(in: folder)
        try CompiledTextModels(folder: folder, build: "26B118").markCompiled()
        #expect(!CompiledTextModels(folder: folder, build: "26C42").isCompiled)
    }

    @Test func withoutACacheToSeeTheBuildAloneDecides() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let models = CompiledTextModels(folder: folder, build: "26B118")
        try models.markCompiled()
        #expect(models.isCompiled)
        #expect(!CompiledTextModels(folder: folder, build: "26C42").isCompiled)
    }

    @Test func thisMacsBuildAndFolder() throws {
        let build = try #require(CompiledTextModels.osBuild())
        #expect(build.allSatisfy { $0.isLetter || $0.isNumber })
        let models = try #require(CompiledTextModels.current(bundleIdentifier: "io.example.app"))
        #expect(models.build == build)
        #expect(models.folder.lastPathComponent == "io.example.app")
        #expect(models.cache == CompiledModelCache.folder(forBundleIdentifier: "io.example.app"))
        #expect(CompiledTextModels.current(bundleIdentifier: nil) == nil)
    }
}
