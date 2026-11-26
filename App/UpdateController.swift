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
    private static let skippedVersionKey = "updates.skippedVersion"
    private var userInitiated = false
    private let feedOverride: URL?
    private let alwaysGentle: Bool

    init(feedOverride: URL? = nil, alwaysGentle: Bool = false) {
        self.feedOverride = feedOverride
        self.alwaysGentle = alwaysGentle
        super.init()
    }

    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    @discardableResult
    func start() -> Bool {
        // Development builds must never offer to replace themselves with a release.
        guard feedOverride != nil || (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))?.scheme == "https" else { return false }
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
        do {
            try updater.start()
        } catch {
            Log.updates.error("updates.start failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        status.lastCheck = updater.lastUpdateCheckDate
        if feedOverride == nil, let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
           let build = pending["build"] as? String, let version = pending["version"] as? String,
           build.compare(currentBuild, options: .numeric) == .orderedDescending {
            if UserDefaults.standard.string(forKey: Self.skippedVersionKey) != version {
                status.waiting = version
            }
        } else if feedOverride == nil {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
        return true
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
        userInitiated = true
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

    func setChecksAutomatically(_ enabled: Bool) { setAutomaticallyChecksForUpdates(enabled) }

    func checkInBackground(skippingRecent: Bool) {
        guard canCheckForUpdates, !controller.updater.sessionInProgress else { return }
        if skippingRecent, let last = controller.updater.lastUpdateCheckDate,
           Date.now.timeIntervalSince(last) < 18 * 60 * 60 { return }
        userInitiated = false
        controller.updater.checkForUpdatesInBackground()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedOverride?.absoluteString
    }

    // A scheduled check, or one that finished while a capture began, waits for the next cycle.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireIdleCapture()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try requireIdleCapture()
    }

    var isShowingReleaseNotes: Bool { releaseWindow != nil }

    func showReleaseNotes(preview: Bool = false) {
        if let existing = releaseWindow, !preview {
            existing.present()
            return
        }
        releaseWindow?.close()
        let controller = makeReleaseNotesWindow(preview: preview)
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self, weak controller] in
            if self?.releaseWindow === controller { self?.releaseWindow = nil }
        }
        releaseWindow = controller
        controller.present()
    }

    #if DEBUG
    /// The preview's window behind the desktop picture in the appearance asked for, for a scripted capture.
    func renderReleaseNotes(dark: Bool) -> NSWindow? {
        releaseWindow?.close()
        let controller = makeReleaseNotesWindow(preview: true)
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self, weak controller] in
            if self?.releaseWindow === controller { self?.releaseWindow = nil }
        }
        releaseWindow = controller
        controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.showBehindWallpaper()
        return controller.window
    }

    func closeReleaseNotes() {
        releaseWindow?.close()
        releaseWindow = nil
    }
    #endif

    private func makeReleaseNotesWindow(preview: Bool) -> ReleaseNotesWindowController {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let changelog = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let localized = Bundle.main.preferredLocalizations.first
            .flatMap { Bundle.main.url(forResource: "ReleaseNotes-" + $0, withExtension: "md") }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let notes = ReleaseNotes.localizedSection(localized, fallback: changelog, version: preview ? "Unreleased" : version)
            ?? String(localized: "This update includes improvements and fixes.")
        return ReleaseNotesWindowController(version: preview ? "0.2.0" : version, markdown: notes, banner: NSImage(named: "ReleaseBanner"))
    }

    func showReleaseNotesAfterUpdate(onboardingPending: Bool = false) {
        guard feedOverride == nil else { return }
        let previous = UserDefaults.standard.string(forKey: Self.seenBuildKey)
        if ReleaseNotes.shouldShow(previousBuild: previous, currentBuild: currentBuild, onboardingPending: onboardingPending) {
            showReleaseNotes()
        }
        UserDefaults.standard.set(currentBuild, forKey: Self.seenBuildKey)
    }

    /// Called when an update arrives and when the person returns to the app. Snooze for a day, or skip this version.
    func presentReminderIfNeeded(preview: Bool = false) {
        guard !isCapturing(), (!alwaysGentle || preview), let version = status.waiting, reminder == nil, canPresentReminder() else { return }
        if !preview, UserDefaults.standard.string(forKey: Self.skippedVersionKey) == version { return }
        let key = "updates.reminded." + version
        if !preview, let last = UserDefaults.standard.object(forKey: key) as? Date, Date.now.timeIntervalSince(last) < 86400 { return }
        if !preview { UserDefaults.standard.set(Date.now, forKey: key) }
        let alert = NSAlert()
        // A statement, not the menu command's title: the alert asks nothing more after its buttons.
        alert.messageText = String(localized: "OhMyShot \(version) Is Available")
        alert.informativeText = String(localized: "A newer OhMyShot is ready. Update now for the latest improvements and fixes. Your captures will stay safe.")
        alert.addButton(withTitle: String(localized: "Update Now"))
        alert.addButton(withTitle: String(localized: "Remind Me Tomorrow"))
        alert.addButton(withTitle: String(localized: "Skip This Version"))
        reminder = alert
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        reminder = nil
        switch answer {
        case .alertFirstButtonReturn:
            checkForUpdates()
        case .alertThirdButtonReturn:
            if !preview {
                UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
                status.waiting = nil
                if feedOverride == nil { UserDefaults.standard.removeObject(forKey: Self.pendingKey) }
            }
        default:
            break
        }
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
        let skipped = UserDefaults.standard.string(forKey: Self.skippedVersionKey) == item.displayVersionString
        if userInitiated || !skipped {
            status.waiting = item.displayVersionString
            if feedOverride == nil, !skipped {
                UserDefaults.standard.set(["build": item.versionString, "version": item.displayVersionString], forKey: Self.pendingKey)
            }
        }
        Log.updates.notice("updates.found \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status.lastCheck = updater.lastUpdateCheckDate
        status.waiting = nil
        if feedOverride == nil {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
        Log.updates.notice("updates.none newer")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        status.lastCheck = updater.lastUpdateCheckDate
        userInitiated = false
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // The persistent reminder waits until capture and recording finish.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if state.userInitiated {
            status.waiting = update.displayVersionString
        } else if UserDefaults.standard.string(forKey: Self.skippedVersionKey) != update.displayVersionString {
            status.waiting = update.displayVersionString
            presentReminderIfNeeded()
        }
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
