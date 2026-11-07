import Foundation
import OMSCore
import OSLog

/// Keeps Vision's text models compiled for the Neural Engine while the app runs, so that no reading has to compile
/// them (about 37 s, Docs/perf.md › OCR — Vision's first reading after its cache is emptied).
///
/// If this build's compilation isn't on disk, both models are warmed in the background. That is checked at launch
/// and again whenever something changes the app's Caches folder, such as a cleaner or a person emptying it. Some
/// warmups can't run when asked: a reading may hold the models, or other apps' compiling may make one time out. Those
/// are tried again a little later. Nothing runs while the folder stays as it is.
final class TextModelWarmup {
    private let models: CompiledTextModels
    private let warm: () async -> Bool
    private var watch: FolderWatch?
    private var pending: Task<Void, Never>?
    private var failures = 0

    /// After launch, and after the folder last changed: launch settles, and a cleaner finishes.
    private static let delay = Duration.seconds(10)
    /// Retries after a warmup that couldn't run: 1, 2, 4, 8 and 16 minutes later, then not until the folder changes.
    private static let retries = 5

    init(models: CompiledTextModels, warm: @escaping () async -> Bool) {
        self.models = models
        self.warm = warm
    }

    func start() {
        check(after: Self.delay)
    }

    private func check(after delay: Duration) {
        pending?.cancel()
        pending = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.checkNow()
        }
    }

    private func checkNow() async {
        guard !models.isCompiled else {
            failures = 0
            watchFolder()
            return
        }
        // The warmup writes into the folder; that isn't a change to answer.
        watch = nil
        Log.capture.notice("Vision's text models aren't compiled for macOS \(self.models.build, privacy: .public); warming them in the background")
        let started = ContinuousClock.now
        let warmed = await warm()
        // A newer check took over (the folder changed meanwhile) and runs shortly.
        guard !Task.isCancelled else { return }
        guard warmed else {
            failures += 1
            guard failures <= Self.retries else {
                Log.capture.error("Warming Vision's text models failed \(Self.retries + 1, privacy: .public) times; waiting for the Caches folder to change")
                watchFolder()
                return
            }
            let wait = Duration.seconds(60 << (failures - 1))
            Log.capture.notice("Warming Vision's text models couldn't finish; trying again in \(String(describing: wait), privacy: .public)")
            check(after: wait)
            return
        }
        do {
            try models.markCompiled()
        } catch {
            Log.capture.error("Noting Vision's compiled text models failed: \(error.localizedDescription, privacy: .public)")
        }
        failures = 0
        Log.capture.notice("Warmed Vision's text models in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        watchFolder()
    }

    /// Watches the Caches folder, made first if it isn't there, so that its next change is seen.
    private func watchFolder() {
        try? FileManager.default.createDirectory(at: models.folder, withIntermediateDirectories: true)
        watch = FolderWatch(folder: models.folder) { [weak self] gone in
            Task { @MainActor in self?.folderChanged(gone: gone) }
        }
    }

    private func folderChanged(gone: Bool) {
        if gone { watch = nil }
        failures = 0
        check(after: Self.delay)
    }
}
