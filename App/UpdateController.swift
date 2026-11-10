import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog
import Sparkle

/// Signed Sparkle updates through the website, with a direct GitHub fallback.
/// Discovery stays visible until the installed build catches up, including after dismissal or restart.
@MainActor
final class UpdateController: NSObject {
    let status = UpdateStatus()

    private var controller: SPUStandardUpdaterController!
    private var activity: NSBackgroundActivityScheduler?
    var canPresentReminder: () -> Bool = { true }
    private var releaseWindow: ReleaseNotesWindowController?
    private var reminder: NSAlert?
    private var usingFallback = false
    private var userInitiated = false
    private var fallbackTask: Task<Void, Never>?
    private static let pendingKey = "updates.pending"
    private static let seenBuildKey = "updates.seenBuild"
    private var canCheckObservation: NSKeyValueObservation?
    /// The feed a debug hook points the updater at, in place of the build's.
    private let feedOverride: URL?
    /// Never put a found version in front of the person, for debug runs: the menu says so instead.
    private let alwaysGentle: Bool

    /// About every six hours; a look sooner than most of that since the last one is skipped, as after a relaunch.
    private static let interval: TimeInterval = 6 * 60 * 60

    /// The build's updater, or nil when it has no feed (debug builds).
    static func make() -> UpdateController? {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, URL(string: feed)?.scheme == "https"
        else { return nil }
        return UpdateController(feedOverride: nil, alwaysGentle: false)
    }

    init(feedOverride: URL?, alwaysGentle: Bool) {
        self.feedOverride = feedOverride
        self.alwaysGentle = alwaysGentle
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        status.checkNow = { [weak self] in self?.checkNow() }
        if feedOverride == nil, let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
           let build = pending["build"] as? String, let version = pending["version"] as? String,
           build.compare(currentBuild, options: .numeric) == .orderedDescending {
            status.waiting = version
        } else if feedOverride == nil {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
    }

    private var updater: SPUUpdater { controller.updater }

    /// Starts the updater, without looking yet. Returns false, and logs why, when Sparkle finds the setup wrong.
    @discardableResult
    func start() -> Bool {
        do {
            try updater.start()
        } catch {
            Log.updates.error("updates.start failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        status.lastCheck = updater.lastUpdateCheckDate
        // Sparkle changes it on the main thread.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.status.canCheck = updater.canCheckForUpdates }
        }
        Log.updates.notice("updates.start feed \(self.updater.feedURL?.absoluteString ?? "none", privacy: .public), last check \(self.updater.lastUpdateCheckDate?.description ?? "never", privacy: .public)")
        return true
    }

    /// Looks by itself about every six hours while `on`, through the system's background activity scheduler.
    func setChecksAutomatically(_ on: Bool) {
        if on, activity == nil {
            let activity = NSBackgroundActivityScheduler(identifier: (Bundle.main.bundleIdentifier ?? "ohmyshot") + ".update-check")
            activity.repeats = true
            activity.interval = Self.interval
            activity.tolerance = Self.interval / 6
            activity.qualityOfService = .utility
            activity.schedule { [weak self] completion in
                Task { @MainActor in
                    self?.checkInBackground(skippingRecent: true)
                    completion(.finished)
                }
            }
            self.activity = activity
            checkInBackground(skippingRecent: true)
        } else if !on, let activity {
            activity.invalidate()
            self.activity = nil
        }
    }

    /// The person asked: Sparkle's windows say what it found, or bring back the version waiting in the menu.
    func checkNow() {
        userInitiated = true
        usingFallback = false
        updater.checkForUpdates()
    }

    /// A look of the app's own: nothing shows unless a newer version is found. `skippingRecent` leaves it when the
    /// last look, by whoever, was less than most of six hours ago.
    func checkInBackground(skippingRecent: Bool) {
        presentReminderIfNeeded()
        if skippingRecent, let last = updater.lastUpdateCheckDate, Date.now.timeIntervalSince(last) < Self.interval * 0.75 {
            Log.updates.notice("updates.background skipped: looked \(Int(Date.now.timeIntervalSince(last)), privacy: .public) s ago")
            return
        }
        guard !updater.sessionInProgress else {
            Log.updates.notice("updates.background skipped: a session is in progress")
            return
        }
        usingFallback = false
        userInitiated = false
        Log.updates.notice("updates.background checking")
        updater.checkForUpdatesInBackground()
    }

    private var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    func showReleaseNotes(preview: Bool = false) {
        releaseWindow = makeReleaseNotesWindow(preview: preview)
        releaseWindow?.present()
    }

    #if DEBUG
    /// The preview's window behind the desktop picture in the appearance asked for, for a scripted capture.
    func renderReleaseNotes(dark: Bool) -> NSWindow? {
        releaseWindow?.close()
        let controller = makeReleaseNotesWindow(preview: true)
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

    func showReleaseNotesAfterUpdate() {
        guard feedOverride == nil else { return }
        let previous = UserDefaults.standard.string(forKey: Self.seenBuildKey)
        if ReleaseNotes.shouldShow(previousBuild: previous, currentBuild: currentBuild) { showReleaseNotes() }
        UserDefaults.standard.set(currentBuild, forKey: Self.seenBuildKey)
    }

    /// Called when an update arrives and when the person returns to the app. Snooze for a day, never forget it.
    func presentReminderIfNeeded(preview: Bool = false) {
        guard (!alwaysGentle || preview), let version = status.waiting, reminder == nil, canPresentReminder() else { return }
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
        if answer == .alertFirstButtonReturn { checkNow() }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard feedOverride == nil, !usingFallback, let url = request.url,
              let mirror = UpdateTransport.mirroredDownload(url) else { return }
        request.url = mirror
    }

    /// The title for the menu bar menu's entry: a waiting version by name.
    var menuTitle: String {
        if let waiting = status.waiting {
            String(localized: "Update to Version \(waiting)…")
        } else {
            String(localized: "Check for Updates…")
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        feedOverride?.absoluteString ?? (usingFallback ? UpdateTransport.fallbackFeed : UpdateTransport.feed).absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status.lastCheck = updater.lastUpdateCheckDate
        status.waiting = item.displayVersionString
        if feedOverride == nil {
            UserDefaults.standard.set(["build": item.versionString, "version": item.displayVersionString], forKey: Self.pendingKey)
        }
        Log.updates.notice("updates.found \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status.lastCheck = updater.lastUpdateCheckDate
        Log.updates.notice("updates.none newer")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        status.lastCheck = updater.lastUpdateCheckDate
        if let error = error as NSError?, error.domain != SUSparkleErrorDomain || error.code != Int(SUError.noUpdateError.rawValue) {
            // Retry transport failures only. A bad signature must never turn into a different trust path.
            if feedOverride == nil, !usingFallback,
               error.domain == NSURLErrorDomain || (error.domain == SUSparkleErrorDomain && [Int(SUError.appcastError.rawValue), Int(SUError.downloadError.rawValue)].contains(error.code)) {
                usingFallback = true
                fallbackTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !Task.isCancelled else { return }
                    if self.userInitiated { self.updater.checkForUpdates() }
                    else { self.updater.checkForUpdatesInBackground() }
                }
            }
            Log.updates.error("updates.cycle ended: \(error.domain, privacy: .public) \(error.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // Our reminder waits until captures and recordings have finished.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        status.waiting = update.displayVersionString
        if !state.userInitiated { presentReminderIfNeeded() }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {}
    func standardUserDriverWillFinishUpdateSession() {}
}
