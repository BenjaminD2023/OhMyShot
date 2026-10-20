import AppKit
import Observation
import OMSUI
import Sparkle

/// Sparkle owns scheduling, saved preferences, signature verification, and installation.
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, NSMenuItemValidation, SPUStandardUserDriverDelegate {
    let status = UpdateStatus()
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    var isCapturing: () -> Bool = { false }

    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func start() {
        // Development builds must never offer to replace themselves with a release.
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https" else { return }
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                    self?.status.canCheck = updater.canCheckForUpdates
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates }
            },
        ]
        status.checkNow = { [weak self] in self?.checkForUpdates() }
        controller.startUpdater()
        status.lastCheck = updater.lastUpdateCheckDate
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
        status.waiting = nil
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    // A scheduled check, or one that finished while a capture began, waits for the next cycle.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireIdleCapture()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try requireIdleCapture()
    }

    var menuTitle: String {
        if let waiting = status.waiting {
            String(localized: "Update to Version \(waiting)…")
        } else {
            String(localized: "Check for Updates…")
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        status.lastCheck = updater.lastUpdateCheckDate
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus && !isCapturing()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        status.waiting = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        status.waiting = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        status.waiting = nil
    }

    private func requireIdleCapture() throws {
        guard !isCapturing() else {
            throw NSError(domain: "OhMyShot.Updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Finish the current capture or recording before checking for updates."),
            ])
        }
    }
}
