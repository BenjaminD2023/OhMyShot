import Foundation
import Testing
@testable import OMSCore

/// Finding one capture, and the expired ones, without listing the history on the main actor after every capture.
struct HistoryLookupTests {
    private func makeStore(_ directory: URL? = nil) -> HistoryStore {
        HistoryStore(directory: directory ?? FileManager.default.temporaryDirectory.appending(path: "HistoryLookupTests-\(UUID().uuidString)"))
    }

    private func add(_ store: HistoryStore, _ byte: UInt8, ago seconds: TimeInterval = 0) throws -> HistoryItem {
        try store.add(data: Data([byte]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: .now.addingTimeInterval(-seconds))
    }

    @Test func aCaptureIsFoundByItsIdAndIsGoneOnceDeleted() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let one = try add(store, 1), two = try add(store, 2)
        #expect(store.item(id: one.id)?.fileName == one.fileName)
        #expect(store.item(id: two.id)?.fileName == two.fileName)
        store.delete(one)
        #expect(store.item(id: one.id) == nil)
        #expect(store.item(id: two.id)?.fileName == two.fileName)
    }

    @Test func aCaptureWrittenBeforeLaunchIsFoundToo() throws {
        let first = makeStore()
        defer { try? FileManager.default.removeItem(at: first.directory) }
        let item = try add(first, 1)
        // Read back from its record: a record keeps its date to the millisecond, so compare what identifies it.
        // The app's next run: a store that has written and listed nothing yet.
        let next = makeStore(first.directory)
        #expect(next.item(id: item.id)?.fileName == item.fileName)
    }

    @Test func aChangedRecordIsTheOneFound() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try add(store, 1)
        let changed = try store.updated(item, pixelWidth: 640, pixelHeight: 480, duration: nil)
        #expect(store.item(id: item.id)?.pixelWidth == 640)
        #expect(store.item(id: item.id)?.pixelHeight == changed.pixelHeight)
    }

    @Test func theExpiredAreListedOffTheMainActorAsOnIt() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let old = try add(store, 1, ago: 2 * 86_400), held = try add(store, 2, ago: 3 * 86_400), recent = try add(store, 3)
        let now = Date.now
        let listed = await store.loadExpired(retention: .oneDay, keeping: [held.id], now: now)
        #expect(listed.map(\.id) == [old.id])
        #expect(listed.map(\.id) == store.expired(retention: .oneDay, keeping: [held.id], now: now).map(\.id))
        // History off: everything not held.
        #expect(Set(await store.loadExpired(retention: .never, keeping: [held.id], now: now).map(\.id)) == [old.id, recent.id])
    }

    @Test func historyOffNeverTakesACaptureTakenOrPutBackWhileTheListingRan() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let closed = try add(store, 1, ago: 60), restored = try add(store, 2, ago: 120)
        let checkedAt = Date.now
        // History off: everything not held when the check began is expired.
        let expired = await store.loadExpired(retention: .never, keeping: [], now: checkedAt)
        // Meanwhile a capture is taken (its card holds it, but it was not held when the check began), and an old one
        // is put back on a card.
        let taken = try add(store, 3)
        let listedLate = expired + [taken]
        let removable = HistoryStore.removable(listedLate, held: [restored.id], checkedAt: checkedAt)
        #expect(removable.map(\.id) == [closed.id])
    }
}
