import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// Favorites in Capture History: kept in the capture's record, and past Keep captures (but not with History off).
struct HistoryFavoritesTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryFavoritesTests-\(UUID().uuidString)"))
    }

    private func add(_ store: HistoryStore, age: TimeInterval, now: Date) throws -> HistoryItem {
        try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-age))
    }

    @Test func aFavoriteIsKeptInItsRecordAndTakenOutAgain() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try add(store, age: 0, now: .now)
        #expect(!item.isFavorite)
        let starred = try store.setFavorite(true, of: item)
        #expect(starred.isFavorite)
        #expect(store.item(id: item.id)?.isFavorite == true)
        #expect(store.items().first?.isFavorite == true)
        let unstarred = try store.setFavorite(false, of: item)
        #expect(!unstarred.isFavorite)
        #expect(store.item(id: item.id)?.favorite == nil)
    }

    /// A record written before favorites has no such field, and reads as no favorite.
    @Test func aRecordFromBeforeFavoritesIsNoFavorite() throws {
        let json = #"{"id":"6F1A2C9E-7D7B-4C1E-9A65-2B1C0E4F8A11","kind":"screenshot","createdAt":0,"pixelWidth":4,"pixelHeight":4,"fileName":"a.png"}"#
        let item = try JSONDecoder().decode(HistoryItem.self, from: Data(json.utf8))
        #expect(item.favorite == nil && !item.isFavorite)
    }

    @Test(arguments: [HistoryRetention.oneDay, .threeDays, .oneWeek, .oneMonth])
    func keepCapturesLeavesFavorites(retention: HistoryRetention) throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        let age = try #require(retention.interval) + 60
        let favorite = try store.setFavorite(true, of: try add(store, age: age, now: now))
        let old = try add(store, age: age, now: now)
        #expect(store.expired(retention: retention, now: now).map(\.id) == [old.id])
        #expect(store.removeExpired(retention: retention, now: now) == 1)
        #expect(store.items().map(\.id) == [favorite.id])
    }

    /// A capture added to Favorites after expiry listed it, while the listing ran off the main actor, isn't deleted.
    @Test func aCaptureAddedToFavoritesAfterTheListingStays() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        let starred = try add(store, age: 2 * 86_400, now: now), old = try add(store, age: 2 * 86_400, now: now)
        let listed = await store.loadExpired(retention: .oneDay, now: now)
        #expect(Set(listed.map(\.id)) == [starred.id, old.id])
        try store.setFavorite(true, of: starred)
        #expect(store.stillExpired(listed, retention: .oneDay, now: now).map(\.id) == [old.id])
        store.delete(old)
        #expect(store.stillExpired(listed, retention: .oneDay, now: now).isEmpty)
        #expect(store.stillExpired(listed, retention: .never, now: now).map(\.id) == [starred.id])
    }

    /// With History off nothing is kept past its card, a favorite included.
    @Test func historyOffKeepsNoFavorite() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let favorite = try store.setFavorite(true, of: try add(store, age: 60, now: .now))
        #expect(store.expired(retention: .never).map(\.id) == [favorite.id])
    }

    @MainActor @Test func retentionPreviewCountsFromOneBackgroundListingPerChoice() async throws {
        let directory = makeStore().directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainThreadListings = Mutex<[Bool]>([])
        let store = HistoryStore(directory: directory, listingDirectory: { path in
            mainThreadListings.withLock { $0.append(Thread.isMainThread) }
            return try FileManager.default.contentsOfDirectory(atPath: path)
        }, writingRecords: { try $0.write(to: $1, options: .atomic) })
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let held = try add(store, age: 90_000, now: now)
        let heldFavorite = try store.setFavorite(true, of: try add(store, age: 90_000, now: now))
        let keeping: Set = [held.id, heldFavorite.id]
        _ = try add(store, age: 86_401, now: now)
        _ = try add(store, age: 86_400, now: now)
        _ = try add(store, age: 0, now: now)
        try store.setFavorite(true, of: try add(store, age: 90_000, now: now))
        let timed = await store.loadRetentionPreview(retention: .oneDay, keeping: { keeping }, now: now)
        let off = await store.loadRetentionPreview(retention: .never, keeping: { keeping }, now: now)
        #expect(timed == RetentionPreviewCounts(count: 1, favorites: 0))
        #expect(off == RetentionPreviewCounts(count: 4, favorites: 1))
        #expect(mainThreadListings.withLock { $0 } == [false, false])
    }

    @MainActor @Test func aReleasedHoldInvalidatesAnOtherwiseEmptyRetentionPreview() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let favorite = try store.setFavorite(true, of: try add(store, age: 0, now: .now))
        var held: Set = [favorite.id]
        let counts = await store.loadRetentionPreview(retention: .never, keeping: {
            defer { held = [] }
            return held
        })
        #expect(counts == nil)
        let retried = await store.loadRetentionPreview(retention: .never)
        #expect(retried == RetentionPreviewCounts(count: 1, favorites: 1))
    }

    @MainActor @Test(arguments: [true, false])
    func aNewCaptureOrUnfavoriteInvalidatesAZeroBeforeItCanApply(addCapture: Bool) async throws {
        let store = makeStore(), now = Date()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let favorite = try store.setFavorite(true, of: try add(store, age: 90_000, now: now))
        var snapshots = 0
        let counts = await store.loadRetentionPreview(retention: .oneDay, keeping: {
            snapshots += 1
            if snapshots == 2 {
                do {
                    if addCapture {
                        _ = try add(store, age: 90_000, now: now)
                    } else {
                        try store.setFavorite(false, of: favorite)
                    }
                } catch { Issue.record(error) }
            }
            return []
        }, now: now)
        #expect(counts == nil)
        let retried = await store.loadRetentionPreview(retention: .oneDay, now: now)
        #expect(retried == RetentionPreviewCounts(count: 1, favorites: 0))
    }

    @MainActor @Test func anUnreadableOrCancelledListingIsNotAnEmptyRetentionPreview() async {
        let directory = makeStore().directory
        let fresh = await HistoryStore(directory: directory).loadRetentionPreview(retention: .never)
        #expect(fresh == RetentionPreviewCounts(count: 0, favorites: 0))
        let unreadable = HistoryStore(directory: directory, listingDirectory: { _ in throw CocoaError(.fileReadNoPermission) },
                                      writingRecords: { try $0.write(to: $1) })
        let failed = await unreadable.loadRetentionPreview(retention: .never)
        #expect(failed == nil)
        let cancelled = HistoryStore(directory: directory, listingDirectory: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return []
        }, writingRecords: { try $0.write(to: $1) })
        let result = await Task { await cancelled.loadRetentionPreview(retention: .never) }.value
        #expect(result == nil)
    }

    /// A record from before the capture was added to Favorites (as an open editor's is) doesn't take it out of them
    /// when the picture changes.
    @Test func aChangedPictureStaysAFavorite() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try add(store, age: 0, now: .now)
        try store.setFavorite(true, of: item)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 2, pixelHeight: 2, annotations: Data([9]))
        #expect(marked.isFavorite)
        #expect(store.item(id: item.id)?.isFavorite == true)
        #expect(store.item(id: item.id)?.pixelWidth == 2)
    }

    /// Starring reads the record as it is now: a size written since stays, and a capture gone stays gone.
    @Test func starringKeepsTheRecordAsItIsNowAndBringsNothingBack() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try add(store, age: 0, now: .now)
        _ = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 2, pixelHeight: 2, annotations: Data([9]))
        let starred = try store.setFavorite(true, of: item)
        #expect(starred.pixelWidth == 2)
        store.delete(item)
        #expect(throws: CocoaError.self) { try store.setFavorite(false, of: item) }
        #expect(store.item(id: item.id) == nil)
    }
}
