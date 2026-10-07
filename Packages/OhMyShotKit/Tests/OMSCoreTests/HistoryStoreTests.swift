import Foundation
import Testing
@testable import OMSCore

struct HistoryStoreTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)"))
    }

    @Test func addedItemsAreListedNewestFirst() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let older = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: "Safari", date: .now.addingTimeInterval(-60))
        let newer = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 30, pixelHeight: 40, appName: nil)
        #expect(store.items().map(\.id) == [newer.id, older.id])
        #expect(FileManager.default.contents(atPath: store.fileURL(for: older).path(percentEncoded: false)) == Data([1]))
    }

    @Test func deletingRemovesTheFileAndTheRecord() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        store.delete(item)
        #expect(store.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: item).path(percentEncoded: false)))
    }

    @Test func expiredItemsAreRemovedByRetention() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        let old = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-2 * 86_400))
        let fresh = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-3_600))
        #expect(store.removeExpired(retention: .oneDay, now: now) == 1)
        #expect(store.items().map(\.id) == [fresh.id])
        #expect(store.item(id: old.id) == nil)
    }

    @Test func neverRetentionKeepsOnlyCapturesStillOnScreen() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        _ = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: .now.addingTimeInterval(-60))
        let onScreen = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        #expect(store.removeExpired(retention: .never, keeping: [onScreen.id]) == 1)
        #expect(store.items().map(\.id) == [onScreen.id])
    }

    @Test func expiredItemsCanBeCountedBeforeRemoving() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        _ = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-2 * 86_400))
        _ = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-60))
        #expect(store.expired(retention: .oneDay, now: now).count == 1)
        #expect(store.items().count == 2)
    }

    @Test func recordingsKeepTheirDuration() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 1920, pixelHeight: 1080, appName: nil, duration: 12.5)
        #expect(store.item(id: item.id)?.duration == 12.5)
        #expect(store.item(id: item.id)?.kind == .recording)
    }

    @Test func expiryNeverRemovesCapturesStillOnScreen() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        let old = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-2 * 86_400))
        #expect(store.removeExpired(retention: .oneDay, keeping: [old.id], now: now) == 0)
        #expect(store.item(id: old.id) != nil)
    }
}
