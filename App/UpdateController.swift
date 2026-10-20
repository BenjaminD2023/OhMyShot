import AppKit
import Observation
import Sparkle

/// Sparkle owns scheduling, saved preferences, signature verification, and installation.
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    var isCapturing: () -> Bool = { false }

    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func start() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates }
            },
        ]
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
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

    private func requireIdleCapture() throws {
        guard !isCapturing() else {
            throw NSError(domain: "OhMyShot.Updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Finish the current capture or recording before checking for updates."),
            ])
        }
    }
}
