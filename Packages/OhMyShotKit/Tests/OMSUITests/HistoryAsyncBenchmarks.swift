import Foundation
import OMSCore
import Testing
@testable import OMSUI

/// Reproducible synthetic history; opt in because creating thousands of sidecars is not a unit test.
@MainActor
struct HistoryAsyncBenchmarks {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_HISTORY_ASYNC_BENCHMARK"] == "1"))
    func directoryAndSearchLeaveTheMainActorFree() async throws {
        for count in [300, 1_000, 3_000] { try await measure(count) }
    }

    private func measure(_ count: Int) async throws {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryAsyncBench-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var entries: [UUID: HistorySearch.Entry] = [:]
        var folding = HistorySearch.Folding()
        let page = (0..<100).map { "第\($0)行 The quick brown fox jumps over the lazy dog 敏捷的棕色狐狸跳过了懒狗" }.joined(separator: "\n")
        var last: UUID?
        for index in 0..<count {
            let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: "Safari")
            entries[item.id] = HistorySearch.Entry(text: page + " zebra\(index)", appName: item.appName, folding: &folding)
            last = item.id
        }
        let frozen = entries
        let actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        let model = HistoryModel(
            store: store, settings: SettingsStore(defaults: UserDefaults()), actions: actions, expiredCount: { _ in 0 },
            textLoader: { _, _ in frozen }, searchDelay: .zero
        )
        defer { model.release() }
        let synchronousStart = ContinuousClock.now
        let listing = store.items()
        let synchronousListing = milliseconds(since: synchronousStart)
        #expect(listing.count == count)
        let queued = ContinuousClock.now
        model.reload()
        let reloadMain = milliseconds(since: queued)
        await model.waitForReload()
        let reloadTotal = milliseconds(since: queued)
        await model.waitForTextLoads()
        var submissions: [Double] = [], completions: [Double] = []
        for iteration in 0..<5 {
            let start = ContinuousClock.now
            model.query = "懒狗 lazy zebra\(count - 1)" + String(repeating: " ", count: iteration)
            submissions.append(milliseconds(since: start))
            await model.waitForSearch()
            if let last { await model.loadExcerpt(for: last) }
            completions.append(milliseconds(since: start))
            #expect(model.matches?.count == 1 && model.matches?[last!]?.excerpt?.found == "懒狗")
        }
        print("HISTORY_ASYNC count=\(count) synchronous_listing_ms=\(synchronousListing) reload_main_ms=\(reloadMain) reload_total_ms=\(reloadTotal) query_main_median_ms=\(submissions.sorted()[2]) query_publish_and_visible_excerpt_median_ms=\(completions.sorted()[2])")
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
