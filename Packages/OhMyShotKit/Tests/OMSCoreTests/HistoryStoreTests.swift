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

    @Test func markingUpKeepsTheOriginalAndTheMarksBesideTheCapture() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 8, pixelHeight: 6, annotations: Data([9]))
        #expect(marked.pixelWidth == 8 && marked.pixelHeight == 6)
        #expect(store.item(id: item.id)?.pixelWidth == 8)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([2]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        // Marking up again keeps the first original.
        try store.replaceImage(of: marked, with: Data([3]), pixelWidth: 8, pixelHeight: 6, annotations: Data([9]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        // The extra files are never listed as captures.
        #expect(store.items().count == 1)
    }

    @Test func deletingAMarkedUpCaptureLeavesNothingBehind() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil)
        try store.replaceImage(of: item, with: Data([2]), pixelWidth: 10, pixelHeight: 20, annotations: Data([9]))
        store.delete(item)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    @Test func restoringTheOriginalForgetsTheMarks() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 10, pixelHeight: 20, annotations: Data([9]))
        try store.restoreOriginal(of: marked)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([1]))
        #expect(!store.hasOriginal(item))
        #expect(!FileManager.default.fileExists(atPath: store.annotationsURL(for: item).path(percentEncoded: false)))
    }

    @Test func anEditedRecordingKeepsTheRecordingAsItWasMade() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 1920, pixelHeight: 1080, appName: nil, duration: 12)
        let edited = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).mp4")
        try Data([2]).write(to: edited)
        let trimmed = try store.replaceRecording(of: item, withFileAt: edited, pixelWidth: 960, pixelHeight: 540, duration: 5)
        #expect((trimmed.pixelWidth, trimmed.pixelHeight, trimmed.duration) == (960, 540, 5))
        #expect(store.item(id: item.id)?.duration == 5)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([2]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: edited.path(percentEncoded: false)))
        // Editing again keeps the first original.
        let again = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).mp4")
        try Data([3]).write(to: again)
        try store.replaceRecording(of: trimmed, withFileAt: again, pixelWidth: 960, pixelHeight: 540, duration: 4)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([3]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        #expect(store.items().count == 1)
    }
}
