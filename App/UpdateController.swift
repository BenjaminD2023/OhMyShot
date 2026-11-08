import AppKit
import Observation
import OMSCore
import OMSUI
import OSLog
import Sparkle

/// Sparkle owns scheduling, saved preferences, signature verification, and installation.
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, NSMenuItemValidation, SPUStandardUserDriverDelegate {
    let status = UpdateStatus()
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private var releaseWindow: ReleaseNotesWindowController?
    private var reminder: NSAlert?
    var canPresentReminder: () -> Bool = { true }
    private static let pendingKey = "updates.pending"
    private static let seenBuildKey = "updates.seenBuild"
    private var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
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
        if let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
           let build = pending["build"] as? String, let version = pending["version"] as? String,
           build.compare(currentBuild, options: .numeric) == .orderedDescending {
            status.waiting = version
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
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

    func showReleaseNotes(preview: Bool = false) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let changelog = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let localized = Bundle.main.preferredLocalizations.first
            .flatMap { Bundle.main.url(forResource: "ReleaseNotes-" + $0, withExtension: "md") }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let notes = ReleaseNotes.localizedSection(localized, fallback: changelog, version: preview ? "Unreleased" : version)
            ?? String(localized: "This update includes improvements and fixes.")
        releaseWindow = ReleaseNotesWindowController(version: preview ? "0.2.0" : version, markdown: notes, banner: NSImage(named: "ReleaseBanner"))
        releaseWindow?.present()
    }

    func showReleaseNotesAfterUpdate() {
        let previous = UserDefaults.standard.string(forKey: Self.seenBuildKey)
        if ReleaseNotes.shouldShow(previousBuild: previous, currentBuild: currentBuild) { showReleaseNotes() }
        UserDefaults.standard.set(currentBuild, forKey: Self.seenBuildKey)
    }

    /// Called when an update arrives and when the person returns to the app. Snooze for a day, never forget it.
    func presentReminderIfNeeded(preview: Bool = false) {
        guard !isCapturing(), let version = status.waiting, reminder == nil, canPresentReminder() else { return }
        let key = "updates.reminded." + version
        if !preview, let last = UserDefaults.standard.object(forKey: key) as? Date, Date.now.timeIntervalSince(last) < 86400 { return }
        if !preview { UserDefaults.standard.set(Date.now, forKey: key) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Update to Version \(version)…")
        alert.informativeText = String(localized: "A newer OhMyShot is ready. Update now for the latest improvements and fixes. Your captures will stay safe.")
        alert.addButton(withTitle: String(localized: "Update Now"))
        alert.addButton(withTitle: String(localized: "Remind Me Tomorrow"))
        reminder = alert
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        reminder = nil
        if answer == .alertFirstButtonReturn { checkForUpdates() }
    }

    var menuTitle: String {
        if let waiting = status.waiting {
            String(localized: "Update to Version \(waiting)…")
        } else {
            String(localized: "Check for Updates…")
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status.lastCheck = updater.lastUpdateCheckDate
        status.waiting = item.displayVersionString
        UserDefaults.standard.set(["build": item.versionString, "version": item.displayVersionString], forKey: Self.pendingKey)
        Log.updates.notice("updates.found \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        status.lastCheck = updater.lastUpdateCheckDate
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // The persistent reminder waits until capture and recording finish.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        status.waiting = update.displayVersionString
        if !state.userInitiated { presentReminderIfNeeded() }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    }

    func standardUserDriverWillFinishUpdateSession() {
    }

    private func requireIdleCapture() throws {
        guard !isCapturing() else {
            throw NSError(domain: "OhMyShot.Updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Finish the current capture or recording before checking for updates."),
            ])
        }
    }
}
