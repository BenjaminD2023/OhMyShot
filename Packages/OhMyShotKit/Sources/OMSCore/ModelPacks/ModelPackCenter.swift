import Foundation
import Observation
import OSLog

/// The model packs this build offers, what is on this Mac of each, and the downloads under way.
///
/// The center reads nothing until it is asked to (`refresh`, when Settings shows the packs, or a reader looking
/// for a pack), so it costs the app nothing at launch. A download runs as one task, holding the downloader's
/// lease while it transfers; pausing or cancelling it ends the task, so nothing runs between downloads.
@MainActor
@Observable
public final class ModelPackCenter {
    public enum State: Equatable, Sendable {
        /// Nothing of it on this Mac.
        case available
        /// Part of it downloaded, nothing running: `done` of its bytes.
        case paused(done: Int64)
        case downloading(done: Int64)
        case installed(ModelPackStore.Receipt)
        /// The last download failed, `done` of its bytes kept.
        case failed(message: String, done: Int64)
    }

    public private(set) var packs: [ModelPack]
    public private(set) var states: [String: State] = [:]

    /// Told once a pack is installed, with its folder: where step 2 compiles and warms a model, in the reader.
    @ObservationIgnored public var onInstalled: ((ModelPack, URL) -> Void)?
    /// Told when a download fails (not when it is paused or cancelled), with why.
    @ObservationIgnored public var onFailed: ((ModelPack, String) -> Void)?
    /// Told once installed files are gone: a pack removed, an old version or a pack no longer offered cleared away.
    /// What was made from them elsewhere (Core ML's cache in the reader) can go too.
    @ObservationIgnored public var onRemoved: (() -> Void)?

    @ObservationIgnored private let store: ModelPackStore
    @ObservationIgnored private let downloader: ModelPackDownloader
    @ObservationIgnored private var downloads: [String: Download] = [:]

    private final class Download {
        var task: Task<Void, Never>?
        /// How the task was asked to end, if it was.
        var ending: Ending?

        enum Ending {
            case pause, cancel, remove
        }
    }

    /// - Parameter packs: what the build offers; packs whose listing has a problem are left out.
    public init(packs: [ModelPack] = ModelPackCatalog.packs, store: ModelPackStore, downloader: ModelPackDownloader) {
        self.packs = packs.filter { pack in
            guard let problem = pack.problem else { return true }
            Log.modelPacks.error("Model pack \(pack.id, privacy: .public) left out: \(problem, privacy: .public)")
            return false
        }
        self.store = store
        self.downloader = downloader
    }

    /// Whether the build offers any pack; with none, the app says nothing about them.
    public var isEmpty: Bool { packs.isEmpty }

    public func state(of pack: ModelPack) -> State {
        states[pack.id] ?? .available
    }

    /// Reads what is on this Mac of each pack, and removes what no listed pack uses (old versions, packs no longer
    /// offered), off the main actor. Downloads under way keep the state they have, and a failed one its reason.
    public func refresh() async {
        let store = store, packs = packs
        let (found, removed) = await Self.read(packs, in: store)
        if removed { onRemoved?() }
        for pack in packs where downloads[pack.id] == nil {
            let state = found[pack.id] ?? .available
            if case .failed(let message, _) = states[pack.id], case .paused(let done) = state {
                states[pack.id] = .failed(message: message, done: done)
            } else {
                states[pack.id] = state
            }
        }
    }

    /// What is on this Mac of each pack, and whether anything installed was removed as unused.
    @concurrent
    private static func read(_ packs: [ModelPack], in store: ModelPackStore) async -> (states: [String: State], removed: Bool) {
        let removed = await removedUnused(keeping: packs, in: store)
        var states: [String: State] = [:]
        for pack in packs {
            if let receipt = store.receipt(of: pack) {
                states[pack.id] = .installed(receipt)
            } else if store.downloadStarted(pack) {
                states[pack.id] = .paused(done: store.downloaded(pack))
            } else {
                // At most the license, read before agreeing to the download: not started.
                states[pack.id] = .available
            }
        }
        return (states, removed)
    }

    /// The installed pack's folder, or nil when this version isn't installed.
    public func installedFolder(of pack: ModelPack) -> URL? {
        if case .installed = state(of: pack) { return store.folder(of: pack) }
        return store.receipt(of: pack) == nil ? nil : store.folder(of: pack)
    }

    /// The license of an installed pack, read from its folder, or nil when the pack isn't installed.
    public func installedLicense(of pack: ModelPack) async -> String? {
        guard let folder = installedFolder(of: pack) else { return nil }
        return await Self.text(at: ModelPackStore.place(pack.license.file, under: folder))
    }

    @concurrent
    private static func text(at file: URL) async -> String? {
        (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The text of the pack's license, fetched on its own (a few kilobytes) to be read before the download starts.
    public func license(of pack: ModelPack) async throws -> String {
        try await downloader.license(of: pack)
    }

    /// Downloads the pack, or goes on with a download paused or failed. Asking for one under way does nothing.
    public func download(_ pack: ModelPack) {
        guard packs.contains(pack), downloads[pack.id] == nil else { return }
        if case .installed = state(of: pack) { return }
        let download = Download()
        downloads[pack.id] = download
        states[pack.id] = .downloading(done: done(of: pack))
        let downloader = downloader, id = pack.id
        download.task = Task { [weak self] in
            let outcome: Result<ModelPackStore.Receipt, Error>
            do {
                let receipt = try await downloader.download(pack) { done in
                    Task { @MainActor in self?.moved(id, to: done) }
                }
                outcome = .success(receipt)
            } catch {
                outcome = .failure(error)
            }
            await self?.ended(pack, download, outcome)
        }
    }

    /// Stops the download and keeps what came, to go on later.
    public func pause(_ pack: ModelPack) {
        stop(pack, .pause)
    }

    /// Stops the download and throws away what came.
    public func cancel(_ pack: ModelPack) {
        if downloads[pack.id] != nil {
            stop(pack, .cancel)
        } else {
            let store = store
            Task {
                await Self.removing { try store.removeDownload(of: pack) }
                states[pack.id] = .available
            }
        }
    }

    /// Removes the pack from this Mac, a download under way included.
    public func remove(_ pack: ModelPack) {
        if downloads[pack.id] != nil {
            stop(pack, .remove)
        } else {
            let store = store
            Task {
                await Self.removing { try store.remove(pack) }
                states[pack.id] = .available
                onRemoved?()
            }
        }
    }

    private func stop(_ pack: ModelPack, _ ending: Download.Ending) {
        guard let download = downloads[pack.id] else { return }
        download.ending = ending
        download.task?.cancel()
    }

    private func done(of pack: ModelPack) -> Int64 {
        switch state(of: pack) {
        case .paused(let done), .downloading(let done), .failed(_, let done): done
        case .available, .installed: 0
        }
    }

    private func moved(_ id: String, to done: Int64) {
        guard downloads[id] != nil, case .downloading = states[id] else { return }
        states[id] = .downloading(done: done)
    }

    private func ended(_ pack: ModelPack, _ download: Download, _ outcome: Result<ModelPackStore.Receipt, Error>) async {
        guard downloads[pack.id] === download else { return }
        let store = store
        switch outcome {
        case .success(let receipt):
            downloads[pack.id] = nil
            states[pack.id] = .installed(receipt)
            onInstalled?(pack, store.folder(of: pack))
            let packs = packs
            let removed = await Self.removedUnused(keeping: packs, in: store)
            if removed { onRemoved?() }
        case .failure(let error):
            switch download.ending {
            case .cancel:
                await Self.removing { try store.removeDownload(of: pack) }
                states[pack.id] = .available
            case .remove:
                await Self.removing { try store.remove(pack) }
                states[pack.id] = .available
                onRemoved?()
            case .pause, nil:
                let (started, done) = await Self.downloaded(pack, in: store)
                if error is CancellationError || download.ending == .pause {
                    states[pack.id] = started ? .paused(done: done) : .available
                } else {
                    states[pack.id] = .failed(message: error.localizedDescription, done: done)
                    onFailed?(pack, error.localizedDescription)
                }
            }
            downloads[pack.id] = nil
        }
    }

    @concurrent
    private static func downloaded(_ pack: ModelPack, in store: ModelPackStore) async -> (started: Bool, done: Int64) {
        (store.downloadStarted(pack), store.downloaded(pack))
    }

    /// Clears away what no listed pack uses; whether anything installed went (not only downloads under way).
    @concurrent
    private static func removedUnused(keeping packs: [ModelPack], in store: ModelPackStore) async -> Bool {
        store.removeUnused(keeping: packs).contains { !$0.hasSuffix(".download") }
    }

    @concurrent
    private static func removing(_ work: @Sendable () throws -> Void) async {
        do {
            try work()
        } catch {
            Log.modelPacks.error("Removing model pack files failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Offers a pack the build doesn't list, for scripted checks against a server on this Mac.
    public func debugOffer(_ pack: ModelPack) {
        guard pack.problem == nil else {
            Log.modelPacks.error("debug pack \(pack.id, privacy: .public) left out: \(pack.problem ?? "", privacy: .public)")
            return
        }
        packs.removeAll { $0.id == pack.id }
        packs.append(pack)
    }

    public func debugWithdraw(id: String) {
        packs.removeAll { $0.id == id }
        states[id] = nil
    }
    #endif
}
