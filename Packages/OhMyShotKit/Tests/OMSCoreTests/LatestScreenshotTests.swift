import Foundation
import Testing
@testable import OMSCore

struct LatestScreenshotTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "LatestScreenshotTests-\(UUID().uuidString)"))
    }

    @Test func aStoreWithNothingInItHasNoLatestScreenshot() {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.latestScreenshot() == nil)
    }

    @Test func aRecordingNewerThanTheLastScreenshotIsPassedOver() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let older = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil, date: .now.addingTimeInterval(-120))
        let newer = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil, date: .now.addingTimeInterval(-60))
        _ = try store.add(data: Data([3]), fileExtension: "mp4", kind: .recording, pixelWidth: 10, pixelHeight: 20, appName: nil, duration: 3, date: .now)
        #expect(store.latestScreenshot()?.id == newer.id)
        store.delete(newer)
        #expect(store.latestScreenshot()?.id == older.id)
        store.delete(older)
        #expect(store.latestScreenshot() == nil)
    }
}
