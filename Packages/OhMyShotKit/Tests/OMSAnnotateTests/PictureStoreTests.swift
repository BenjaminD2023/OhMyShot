import Foundation
import Testing
@testable import OMSAnnotate

/// The pictures the app makes itself go again once nothing uses them; the user's own never do.
struct PictureStoreTests {
    private let folder = URL.temporaryDirectory.appending(path: "OhMyShotKit Pictures \(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func unusedPicturesTheAppMadeGoAndTheUsersStay() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PictureStore(directory: folder)
        let own = try store.add(Data("the user's".utf8), fileExtension: "png")
        let used = try store.add(Data("in a capture".utf8), fileExtension: "jpg", prefix: "wallpaper-")
        let unused = try store.add(Data("in nothing".utf8), fileExtension: "jpg", prefix: "wallpaper-")
        #expect(used.hasPrefix("wallpaper-") && !own.hasPrefix("wallpaper-"))

        // Just made: kept, as it may not be in use yet.
        #expect(store.removeUnused(prefix: "wallpaper-", used: [used], olderThan: 600) == 0)
        let later = Date.now.addingTimeInterval(601)
        #expect(store.removeUnused(prefix: "wallpaper-", used: [used], olderThan: 600, now: later) == 1)
        #expect(store.contains(own) && store.contains(used) && !store.contains(unused))
        // No prefix sweeps nothing.
        #expect(store.removeUnused(prefix: "", used: [], olderThan: 0, now: later) == 0)
        #expect(store.contains(own))
    }

    /// Kept again, a picture counts as just made.
    @Test func aPictureAddedAgainIsNewAgain() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PictureStore(directory: folder)
        let name = try store.add(Data("piece".utf8), fileExtension: "jpg", prefix: "wallpaper-")
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: store.url(named: name).path(percentEncoded: false)
        )
        #expect(try store.add(Data("piece".utf8), fileExtension: "jpg", prefix: "wallpaper-") == name)
        #expect(store.removeUnused(prefix: "wallpaper-", used: [], olderThan: 600) == 0)
    }
}
