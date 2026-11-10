import Foundation
import Testing
@testable import OMSCore

/// How long the history's listing takes as it grows (Docs/perf.md › Main-thread work after a capture): every
/// capture's retention check lists the folder, reads every record, and checks every file. Opt-in, as it writes
/// thousands of files: OMS_HISTORY_SPEED=1.
struct HistoryScanSpeedTests {
    private func milliseconds(_ body: () -> Void) -> Double {
        var elapsed: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            body()
            let duration = ContinuousClock.now - start
            elapsed.append(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
        }
        return elapsed.sorted()[1]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_HISTORY_SPEED"] != nil))
    func listingTheHistory() throws {
        for count in [300, 1_000, 5_000] {
            let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryScanSpeed-\(UUID().uuidString)"))
            defer { try? FileManager.default.removeItem(at: store.directory) }
            var last: HistoryItem?
            for index in 0..<count {
                last = try store.add(
                    data: Data([UInt8(index % 256)]), fileExtension: "png", kind: .screenshot, pixelWidth: 3024, pixelHeight: 1964,
                    appName: "Safari", date: .now.addingTimeInterval(-Double(index) * 300)
                )
            }
            let oldest = try #require(last)
            let items = milliseconds { _ = store.items() }
            let expired = milliseconds { _ = store.expired(retention: .oneMonth) }
            let item = milliseconds { _ = store.item(id: oldest.id) }
            let needing = milliseconds { _ = store.needingText(store.items()) }
            print("HISTORY_SCAN_BENCH captures=\(count) items_ms=\(items) expired_ms=\(expired) item_id_ms=\(item) needingText_ms=\(needing)")
        }
    }
}
