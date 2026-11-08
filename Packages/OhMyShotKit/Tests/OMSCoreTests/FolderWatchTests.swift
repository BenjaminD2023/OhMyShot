import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// What a folder's watch is told: its entries changing, and the folder going.
struct FolderWatchTests {
    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FolderWatchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func aMissingFolderCantBeWatched() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FolderWatchTests-missing-\(UUID().uuidString)")
        #expect(FolderWatch(folder: folder, queue: DispatchQueue(label: "test")) { _ in } == nil)
    }

    @Test func aNewEntryIsAChange() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let told = Mutex<[Bool]>([])
        let watch = try #require(FolderWatch(folder: folder, queue: DispatchQueue(label: "test")) { gone in told.withLock { $0.append(gone) } })
        try Data("x".utf8).write(to: folder.appending(path: "entry"))
        try await settle { !told.withLock { $0 }.isEmpty }
        #expect(told.withLock { $0 }.allSatisfy { !$0 })
        watch.stop()
    }

    @Test func removingTheFolderEndsTheWatch() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "com.apple.e5rt.e5bundlecache/26B118"), withIntermediateDirectories: true)
        let told = Mutex<[Bool]>([])
        let watch = try #require(FolderWatch(folder: folder, queue: DispatchQueue(label: "test")) { gone in told.withLock { $0.append(gone) } })
        try FileManager.default.removeItem(at: folder)
        try await settle { told.withLock { $0 }.contains(true) }
        // Nothing after the folder went: the watch ended there.
        #expect(told.withLock { $0 }.last == true)
        _ = watch
    }
}
