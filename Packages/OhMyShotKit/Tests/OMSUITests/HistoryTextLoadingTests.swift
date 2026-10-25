import Foundation
import OMSCore
import Testing
@testable import OMSUI

@MainActor
struct HistoryTextLoadingTests {
    private final class Loader {
        struct Request {
            var ids: Set<UUID>
            var continuation: CheckedContinuation<[UUID: HistorySearch.Entry], Never>?
        }
        var requests: [Request] = []
        var cancellations = 0
        private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func waitForRequests(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { requestWaiters.append((count, $0)) }
        }

        func waitForCancellations(_ count: Int) async {
            if cancellations >= count { return }
            await withCheckedContinuation { cancellationWaiters.append((count, $0)) }
        }

        private func wakeWaiters() {
            let readyRequests = requestWaiters.filter { requests.count >= $0.0 }
            requestWaiters.removeAll { requests.count >= $0.0 }
            readyRequests.forEach { $0.1.resume() }
            let readyCancellations = cancellationWaiters.filter { cancellations >= $0.0 }
            cancellationWaiters.removeAll { cancellations >= $0.0 }
            readyCancellations.forEach { $0.1.resume() }
        }

        func load(_ items: [HistoryItem], _: HistoryStore) async -> [UUID: HistorySearch.Entry] {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    requests.append(Request(ids: Set(items.map(\.id)), continuation: continuation))
                    wakeWaiters()
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancellations += 1; self?.wakeWaiters() }
            }
        }

        func finish(_ index: Int, text: String?) {
            guard requests.indices.contains(index), let continuation = requests[index].continuation else { return }
            requests[index].continuation = nil
            var folding = HistorySearch.Folding()
            let entries = text.map { text in
                Dictionary(uniqueKeysWithValues: requests[index].ids.map { ($0, HistorySearch.Entry(text: text, appName: nil, folding: &folding)) })
            } ?? [:]
            continuation.resume(returning: entries)
        }

        func finishAll() {
            for index in requests.indices { finish(index, text: nil) }
        }
    }

    private func model(_ loader: Loader) -> (HistoryModel, HistoryItem) {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryTextLoadingTests-\(UUID().uuidString)"))
        let actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        let model = HistoryModel(
            store: store, settings: SettingsStore(defaults: UserDefaults()), actions: actions, expiredCount: { _ in 0 },
            textLoader: { items, store in await loader.load(items, store) }
        )
        let item = HistoryItem(kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, fileName: "capture.png")
        model.items = [item]
        return (model, item)
    }

    @Test func aReadNotificationDuringLoadingIsRetriedAndCoalesced() async {
        let loader = Loader()
        let (model, item) = model(loader)
        defer { model.release(); loader.finishAll() }
        model.query = "new"
        model.loadText(of: [item.id])
        await loader.waitForRequests(1)
        model.loadText(of: [item.id])
        model.loadText(of: [item.id])
        #expect(loader.requests.count == 1)
        loader.finish(0, text: nil)
        await loader.waitForRequests(2)
        loader.finish(1, text: "new")
        await model.waitForTextLoads()
        await model.waitForSearch()
        #expect(model.matches?[item.id] != nil)
        #expect(loader.requests.count == 2)
    }

    @Test func returnWaitsForTheInitialIndexInsteadOfAcceptingAnEmptySearch() async {
        let loader = Loader()
        let (model, item) = model(loader)
        defer { model.release(); loader.finishAll() }
        model.loadText(of: [item.id])
        await loader.waitForRequests(1)
        model.query = "new"
        // Membership lookup has completed against an empty index, while its first text read is pending.
        await model.waitForSearch()
        #expect(model.matches?.isEmpty == true && model.isIndexing && model.isUpdatingSearch)
        let state = ReturnState()
        let submitted = Task {
            state.enter()
            let allowed = await model.waitForCurrentResults()
            state.finished = true
            return allowed
        }
        // Both run on MainActor: this resumes only when the Return task has entered and yielded.
        await state.waitUntilEntered()
        #expect(!state.finished, "Return must not accept the transient empty result")
        loader.finish(0, text: "new")
        #expect(await submitted.value)
        #expect(state.finished && model.matches?[item.id] != nil)
        #expect(!model.isIndexing && !model.isUpdatingSearch)
    }

    @Test func typingAnotherQueryWhileReturnWaitsCancelsThatSubmission() async {
        let loader = Loader()
        let (model, item) = model(loader)
        defer { model.release(); loader.finishAll() }
        model.loadText(of: [item.id])
        await loader.waitForRequests(1)
        model.query = "old"
        await model.waitForSearch()
        let state = ReturnState()
        let submitted = Task {
            state.enter()
            return await model.waitForCurrentResults()
        }
        await state.waitUntilEntered()
        model.query = "new"
        loader.finish(0, text: "new")
        #expect(await submitted.value == false)
        await model.waitForSearch()
        #expect(model.matches?[item.id] != nil && model.query == "new")
    }

    @Test func replacingThePictureInvalidatesThePendingOldResult() async {
        let loader = Loader()
        let (model, item) = model(loader)
        defer { model.release(); loader.finishAll() }
        model.query = "old"
        model.loadText(of: [item.id])
        await loader.waitForRequests(1)
        model.forgetText(of: [item.id])
        loader.finish(0, text: "old")
        await loader.waitForRequests(2)
        #expect(model.matches?[item.id] == nil)
        loader.finish(1, text: "new")
        model.query = "new"
        await model.waitForTextLoads()
        await model.waitForSearch()
        #expect(model.matches?[item.id] != nil)
    }

    @Test func refreshingOneCaptureDoesNotInvalidateAnotherCapturesLoad() async {
        let loader = Loader()
        let (model, first) = model(loader)
        let second = HistoryItem(kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, fileName: "second.png")
        model.items.append(second)
        defer { model.release(); loader.finishAll() }
        model.query = "new"
        model.loadText(of: [first.id, second.id])
        await loader.waitForRequests(1)
        model.forgetText(of: [first.id])
        model.loadText(of: [first.id])
        loader.finish(0, text: "new")
        await loader.waitForRequests(2)
        await model.waitForSearch()
        #expect(model.matches?[second.id] != nil)
        #expect(model.matches?[first.id] == nil)
        await loader.waitForRequests(2)
        if loader.requests.count == 2 { #expect(loader.requests[1].ids == [first.id]) }
        loader.finish(1, text: "new")
        await model.waitForTextLoads()
        await model.waitForSearch()
        #expect(model.matches?[first.id] != nil)
    }

    @Test func deletingACaptureRejectsTheResultAndItsQueuedRefresh() async {
        let loader = Loader()
        let (model, item) = model(loader)
        defer { model.release(); loader.finishAll() }
        model.query = "old"
        model.loadText(of: [item.id])
        await loader.waitForRequests(1)
        model.loadText(of: [item.id])
        model.items = []
        loader.finish(0, text: "old")
        await model.waitForTextLoads()
        await model.waitForSearch()
        #expect(model.matches?[item.id] == nil)
        #expect(loader.requests.count == 1)
    }

    @Test func closingCancelsTheLoadAndRejectsEvenAnUncooperativeLoader() async {
        let loader = Loader()
        let (model, item) = model(loader)
        defer { loader.finishAll() }
        model.query = "old"
        model.loadText(of: [item.id])
        await loader.waitForRequests(1)
        model.loadText(of: [item.id])
        let pending = model.pendingWork()
        model.release()
        await loader.waitForCancellations(1)
        loader.finish(0, text: "old")
        await pending.value
        #expect(model.matches?[item.id] == nil)
        #expect(await model.waitForCurrentResults() == false)
        model.loadText(of: [item.id])
        #expect(loader.requests.count == 1)
    }

    private final class ReturnState {
        var finished = false
        private var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func enter() { entered = true; continuation?.resume(); continuation = nil }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { continuation = $0 }
        }
    }
}
