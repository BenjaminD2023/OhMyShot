import Foundation
import CoreGraphics
import OMSCore
import Testing
@testable import OMSUI

@MainActor
struct HistoryAsyncTests {
    private func model(
        items: [HistoryItem] = [], itemsLoader: HistoryModel.ItemsLoader? = nil,
        searcher: HistoryModel.Searcher? = nil, thumbnailLoader: HistoryModel.ThumbnailLoader? = nil
    ) -> HistoryModel {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryAsync-\(UUID())"))
        let actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        let model = HistoryModel(
            store: store, settings: SettingsStore(defaults: UserDefaults()), actions: actions, expiredCount: { _ in 0 },
            textLoader: { items, _ in
                var folding = HistorySearch.Folding()
                return Dictionary(uniqueKeysWithValues: items.map {
                    ($0.id, HistorySearch.Entry(text: "searchable text for \($0.fileName)", appName: $0.appName, folding: &folding))
                })
            }, itemsLoader: itemsLoader, searcher: searcher, searchDelay: .zero, thumbnailLoader: thumbnailLoader
        )
        model.items = items
        return model
    }

    private func item(_ name: String) -> HistoryItem {
        HistoryItem(kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: "Safari", fileName: name)
    }

    @Test func directoryChangesCoalesceAndOnlyTheNewestListingCanPublish() async {
        let loader = DirectoryLoader()
        let existing = item("existing"), newest = item("newest")
        let model = model(items: [existing], itemsLoader: { _ in await loader.read() })
        defer { model.release() }
        model.selection = [existing.id]
        model.focus = existing.id
        model.reload()
        await loader.waitForCount(1)
        #expect(model.isReloading && model.items == [existing])
        // Main-actor interaction continues while file IO is outstanding.
        model.filter = .screenshots
        model.reload()
        model.reload()
        #expect(loader.requests.count == 1)
        loader.finish(0, items: [])
        await loader.waitForCount(2)
        #expect(model.items == [existing], "A superseded listing must not blank the window")
        loader.finish(1, items: [newest])
        await model.waitForReload()
        await model.waitForTextLoads()
        #expect(model.items == [newest] && !model.isReloading)
        #expect(model.selection.isEmpty && model.focus == nil)
        #expect(loader.requests.count == 2)
    }

    @Test func closingRejectsAnUncooperativeDirectoryLoader() async {
        let loader = DirectoryLoader()
        let model = model(itemsLoader: { _ in await loader.read() })
        model.reload()
        await loader.waitForCount(1)
        let pending = model.pendingWork()
        model.release()
        loader.finish(0, items: [item("late")])
        await pending.value
        #expect(model.items.isEmpty && !model.isReloading)
        model.reload()
        #expect(loader.requests.count == 1)
    }

    @Test func changedPicturesUseTheReloadedFileNameAndRejectLateOldThumbnails() async throws {
        let directory = DirectoryLoader(), thumbnails = ThumbnailLoader()
        let old = item("old.png")
        let newer = HistoryItem(id: old.id, kind: .screenshot, pixelWidth: 2, pixelHeight: 1, appName: "Safari", fileName: "new.png")
        let model = model(
            items: [old], itemsLoader: { _ in await directory.read() }, thumbnailLoader: { url in await thumbnails.read(url) }
        )
        defer { model.release() }
        let oldRead = Task { await model.loadThumbnail(for: old) }
        await thumbnails.waitForCount(1)
        model.reload(changed: [old.id])
        await directory.waitForCount(1)
        #expect(thumbnails.requests.count == 1, "Wait for the new sidecar before choosing the thumbnail URL")
        directory.finish(0, items: [newer])
        await model.waitForReload()
        await thumbnails.waitForCount(2)
        #expect(thumbnails.requests[1].0.lastPathComponent == "new.png")
        let space = CGColorSpaceCreateDeviceRGB()
        let newImage = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let oldImage = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        thumbnails.finish(1, image: newImage)
        await model.pendingWork().value
        #expect(model.thumbnails[old.id]?.width == 2)
        thumbnails.finish(0, image: oldImage)
        await oldRead.value
        #expect(model.thumbnails[old.id]?.width == 2)
    }

    @Test func oldSearchResultsCannotReplaceANewerQueryOrAClearedQuery() async throws {
        let searcher = Searcher()
        let first = item("first"), second = item("second")
        let model = model(items: [first, second], searcher: { query, _, _ in try await searcher.read(query) })
        defer { model.release() }
        model.query = "first"
        await searcher.waitForCount(1)
        let firstPending = model.pendingWork()
        model.query = "second"
        await searcher.waitForCount(2)
        searcher.finish(1, ids: [second.id])
        await model.waitForSearch()
        #expect(model.visibleItems.map(\.id) == [second.id] && !model.isSearchPending)
        searcher.finish(0, ids: [first.id])
        await firstPending.value
        #expect(model.visibleItems.map(\.id) == [second.id])
        model.query = "third"
        await searcher.waitForCount(3)
        let thirdPending = model.pendingWork()
        #expect(model.isSearchPending && model.visibleItems.map(\.id) == [second.id])
        model.query = ""
        #expect(model.matches == nil && !model.isSearchPending)
        searcher.finish(2, ids: [first.id])
        await thirdPending.value
        #expect(model.matches == nil && model.visibleItems.count == 2)
    }

    @Test func onlyVisibleCardsBuildExcerptsAndInvalidationHidesOldTextImmediately() async {
        let first = item("first"), second = item("second")
        let model = model(items: [first, second])
        defer { model.release() }
        model.query = "searchable"
        model.loadText(of: [first.id, second.id])
        await model.waitForTextLoads()
        await model.waitForSearch()
        #expect(model.matches?.count == 2)
        #expect(model.matches?[first.id]?.excerpt == nil && model.matches?[second.id]?.excerpt == nil)
        await model.loadExcerpt(for: first.id)
        #expect(model.matches?[first.id]?.excerpt?.found == "searchable")
        #expect(model.matches?[second.id]?.excerpt == nil)
        model.forgetText(of: [first.id])
        #expect(model.matches?[first.id] == nil)
        await model.waitForSearch()
        #expect(model.matches?[first.id] == nil && model.matches?[second.id] != nil)
    }

    @Test func theIndexRunsOffTheMainThreadAndRejectsOldUpdatesAndReleasedWork() async throws {
        let calls = SearchThreadProbe()
        let index = HistorySearchIndex(didBeginSearch: { calls.record() })
        let id = UUID()
        var folding = HistorySearch.Folding()
        let old = HistorySearch.Entry(text: "old", appName: nil, folding: &folding)
        let new = HistorySearch.Entry(text: "new", appName: nil, folding: &folding)
        await index.update([.init(id: id, generation: 2, entry: new)])
        await index.update([.init(id: id, generation: 1, entry: old)])
        #expect(try await index.search("new", generations: [id: 2]).matches[id] != nil)
        #expect(try await index.search("old", generations: [id: 2]).matches[id] == nil)
        #expect(try await index.search("new", generations: [id: 3]).matches[id] == nil)
        #expect(calls.count == 3 && !calls.wasMainThread)
        await index.release()
        await index.update([.init(id: id, generation: 3, entry: old)])
        #expect(try await index.search("old", generations: [id: 3]).matches.isEmpty)
    }

    @Test func closingCancelsAPendingSearchWithoutPublishingItsResult() async throws {
        let searcher = Searcher()
        let capture = item("capture")
        let model = model(items: [capture], searcher: { query, _, _ in try await searcher.read(query) })
        model.query = "late"
        await searcher.waitForCount(1)
        let pending = model.pendingWork()
        model.release()
        searcher.finish(0, ids: [capture.id])
        await pending.value
        #expect(model.matches == nil && !model.isSearchPending)
        model.query = "another"
        #expect(searcher.requests.count == 1)
    }

    private final class DirectoryLoader {
        var requests: [CheckedContinuation<[HistoryItem], Never>?] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func read() async -> [HistoryItem] {
            await withCheckedContinuation { continuation in
                requests.append(continuation)
                let ready = waiters.filter { requests.count >= $0.0 }
                waiters.removeAll { requests.count >= $0.0 }
                ready.forEach { $0.1.resume() }
            }
        }
        func waitForCount(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        func finish(_ index: Int, items: [HistoryItem]) {
            let continuation = requests[index]
            requests[index] = nil
            continuation?.resume(returning: items)
        }
    }

    private final class Searcher {
        var requests: [(String, CheckedContinuation<HistorySearchIndex.Result, Error>?)] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func read(_ query: String) async throws -> HistorySearchIndex.Result {
            try await withCheckedThrowingContinuation { continuation in
                requests.append((query, continuation))
                let ready = waiters.filter { requests.count >= $0.0 }
                waiters.removeAll { requests.count >= $0.0 }
                ready.forEach { $0.1.resume() }
            }
        }
        func waitForCount(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        func finish(_ index: Int, ids: [UUID]) {
            let (query, continuation) = requests[index]
            requests[index].1 = nil
            var folding = HistorySearch.Folding()
            let entry = HistorySearch.Entry(text: query, appName: nil, folding: &folding)
            let terms = HistorySearch.terms(in: query)
            let match = HistorySearch.match(terms, in: entry, includingExcerpt: false)!
            continuation?.resume(returning: .init(terms: terms, matches: Dictionary(uniqueKeysWithValues: ids.map { ($0, match) })))
        }
    }

    private final class ThumbnailLoader {
        var requests: [(URL, CheckedContinuation<CGImage?, Never>?)] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func read(_ url: URL) async -> CGImage? {
            await withCheckedContinuation { continuation in
                requests.append((url, continuation))
                let ready = waiters.filter { requests.count >= $0.0 }
                waiters.removeAll { requests.count >= $0.0 }
                ready.forEach { $0.1.resume() }
            }
        }
        func waitForCount(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        func finish(_ index: Int, image: CGImage?) {
            let continuation = requests[index].1
            requests[index].1 = nil
            continuation?.resume(returning: image)
        }
    }
}

nonisolated private final class SearchThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (count: 0, wasMainThread: false)
    var count: Int { lock.withLock { state.count } }
    var wasMainThread: Bool { lock.withLock { state.wasMainThread } }
    func record() {
        lock.withLock { state.count += 1; state.wasMainThread = state.wasMainThread || Thread.isMainThread }
    }
}
