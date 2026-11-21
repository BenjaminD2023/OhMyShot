import Foundation
import Testing
@testable import OMSCore

@MainActor
struct UploadRecordTests {
    private func destination(_ configuration: UploadDestination.Configuration? = nil) -> UploadDestination {
        UploadDestination(name: "Mine", configuration: configuration ?? .s3(S3Settings(endpoint: URL(string: "https://s3.test")!, bucket: "bk")))
    }

    private func record(
        capture: UUID? = UUID(), date: Date = .now, expires: Date? = nil, key: String? = "a/b.png", deletion: URL? = nil,
        link: String = "https://x.test/b.png", to destination: UploadDestination? = nil
    ) -> UploadRecord {
        UploadRecord(
            captureID: capture, date: date, fileName: "b.png", destination: destination ?? self.destination(),
            result: UploadResult(link: URL(string: link)!, deletionURL: deletion, fileName: "b.png", expiresAt: expires, remoteKey: key)
        )
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "OMSRecords-\(UUID().uuidString)/Uploads.json")
    }

    @Test func recordsSurviveARelaunchNewestFirst() {
        let file = scratch()
        let store = UploadRecordStore(fileURL: file)
        let first = record(date: .now.addingTimeInterval(-60))
        let second = record()
        store.add(first)
        store.add(second)
        let again = UploadRecordStore(fileURL: file)
        #expect(again.records.map(\.id) == [second.id, first.id])
        #expect(again.records[0].link == second.link)
        #expect(again.records[0].remoteKey == "a/b.png")
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func aDamagedFileIsAnEmptyList() throws {
        let file = scratch()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(UploadRecordStore(fileURL: file).records.isEmpty)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func aCaptureFindsItsNewestWorkingLink() {
        let store = UploadRecordStore(fileURL: nil)
        let capture = UUID()
        let old = record(capture: capture, expires: nil)
        let expired = record(capture: capture, expires: .now.addingTimeInterval(-10))
        store.add(old)
        store.add(expired)
        // The newest upload's link has expired, so the older one that still works is offered.
        #expect(store.link(for: capture) == old.link)
        #expect(store.link(for: UUID()) == nil)
        #expect(expired.isExpired())
        #expect(!old.isExpired())
    }

    @Test func aLinkThatHasExpiredIsNotOffered() {
        let store = UploadRecordStore(fileURL: nil)
        let capture = UUID()
        store.add(record(capture: capture, expires: .now.addingTimeInterval(60)))
        #expect(store.link(for: capture) != nil)
        #expect(store.link(for: capture, at: .now.addingTimeInterval(120)) == nil)
    }

    @Test func deletingTheNewestUploadOffersTheOneBeforeUntilItExpires() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = UploadRecordStore(fileURL: nil)
        let capture = UUID()
        let older = record(capture: capture, date: now.addingTimeInterval(-120), expires: now.addingTimeInterval(3600), link: "https://x.test/older.png")
        let newest = record(capture: capture, date: now.addingTimeInterval(-60), link: "https://x.test/newest.png")
        store.add(older)
        store.add(newest)
        #expect(store.link(for: capture, at: now) == newest.link)
        store.forget(id: newest.id)
        #expect(store.link(for: capture, at: now) == older.link)
        #expect(store.link(for: capture, at: now.addingTimeInterval(3599)) == older.link)
        #expect(store.link(for: capture, at: now.addingTimeInterval(3600)) == nil)
    }

    @Test func deletingAFileForgetsEveryUploadOfIt() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = UploadRecordStore(fileURL: nil)
        let capture = UUID(), storage = destination()
        // Sent twice under its own name to the same storage, so the second replaced the first there; and once elsewhere.
        let first = record(capture: capture, date: now.addingTimeInterval(-180), key: "b.png", link: "https://x.test/1/b.png", to: storage)
        let elsewhere = record(capture: capture, date: now.addingTimeInterval(-120), key: "b.png", link: "https://y.test/b.png")
        let second = record(capture: capture, date: now.addingTimeInterval(-60), key: "b.png", link: "https://x.test/2/b.png", to: storage)
        store.add(first)
        store.add(elsewhere)
        store.add(second)
        let forgotten = store.forgetDeleted(second)
        #expect(Set(forgotten.map(\.id)) == [first.id, second.id])
        #expect(store.records.map(\.id) == [elsewhere.id])
        #expect(store.link(for: capture, at: now) == elsewhere.link)
    }

    @Test func aDeletedFileWithoutAKeyTakesOnlyItsOwnRecord() {
        let store = UploadRecordStore(fileURL: nil)
        let capture = UUID(), storage = destination()
        let older = record(capture: capture, date: .now.addingTimeInterval(-60), key: nil, deletion: URL(string: "https://x.test/delete/1"), to: storage)
        let newer = record(capture: capture, key: nil, deletion: URL(string: "https://x.test/delete/2"), to: storage)
        store.add(older)
        store.add(newer)
        #expect(store.forgetDeleted(newer).map(\.id) == [newer.id])
        #expect(store.records.map(\.id) == [older.id])
    }

    @Test func removalIsASignedRequestOrTheServersAddress() {
        #expect(record(key: "k").removal == .request)
        let address = URL(string: "https://x.test/delete/1")!
        #expect(record(key: nil, deletion: address).removal == .openAddress(address))
        #expect(record(key: nil).removal == nil)
        let store = UploadRecordStore(fileURL: nil)
        let capture = UUID()
        store.add(record(capture: capture, key: nil))
        #expect(store.removable(for: capture) == nil)
        let deletable = record(capture: capture)
        store.add(deletable)
        #expect(store.removable(for: capture)?.id == deletable.id)
    }

    @Test func forgettingTakesARecordOffTheListAndTheFile() {
        let file = scratch()
        let store = UploadRecordStore(fileURL: file)
        let kept = record(), gone = record()
        store.add(kept)
        store.add(gone)
        store.forget(id: gone.id)
        #expect(UploadRecordStore(fileURL: file).records.map(\.id) == [kept.id])
        store.forgetAll()
        #expect(UploadRecordStore(fileURL: file).records.isEmpty)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func theListIsCapped() {
        let store = UploadRecordStore(fileURL: nil)
        for _ in 0..<(UploadRecordStore.limit + 20) { store.add(record()) }
        #expect(store.records.count == UploadRecordStore.limit)
    }
}
