import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog
import Sparkle

/// Updates, with Sparkle, in builds that have a feed (release builds: `SUFeedURL` from Config/Release.xcconfig). The
/// feed and the archives it lists are signed with the key in `SUPublicEDKey`, and Sparkle checks both (Info.plist).
///
/// Sparkle's own schedule stays off (`SUEnableAutomaticChecks` is NO): it would keep a timer of its own in the app.
/// The daily look is a background activity instead, which the system runs when it suits it, so the app holds nothing
/// while idle. A version found that way waits in the menu bar menu (Sparkle's gentle reminders), unless Sparkle would
/// show it in full focus anyway (the app just launched, or the Mac was left idle).
@MainActor
final class UpdateController: NSObject {
    let status = UpdateStatus()

    private var controller: SPUStandardUpdaterController!
    private var activity: NSBackgroundActivityScheduler?
    private var canCheckObservation: NSKeyValueObservation?
    /// The feed a debug hook points the updater at, in place of the build's.
    private let feedOverride: URL?
    /// Never put a found version in front of the person, for debug runs: the menu says so instead.
    private let alwaysGentle: Bool

    /// About once a day; a look sooner than most of that since the last one is skipped, as after a relaunch.
    private static let interval: TimeInterval = 24 * 60 * 60

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

    /// Looks by itself about once a day while `on`, through the system's background activity scheduler.
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
        } else if !on, let activity {
            activity.invalidate()
            self.activity = nil
        }
    }

    /// The person asked: Sparkle's windows say what it found, or bring back the version waiting in the menu.
    func checkNow() {
        status.waiting = nil
        updater.checkForUpdates()
    }

    /// A look of the app's own: nothing shows unless a newer version is found. `skippingRecent` leaves it when the
    /// last look, by whoever, was less than most of a day ago.
    func checkInBackground(skippingRecent: Bool) {
        if skippingRecent, let last = updater.lastUpdateCheckDate, Date.now.timeIntervalSince(last) < Self.interval * 0.75 {
            Log.updates.notice("updates.background skipped: looked \(Int(Date.now.timeIntervalSince(last)), privacy: .public) s ago")
            return
        }
        guard !updater.sessionInProgress else {
            Log.updates.notice("updates.background skipped: a session is in progress")
            return
        }
        Log.updates.notice("updates.background checking")
        updater.checkForUpdatesInBackground()
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
        feedOverride?.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status.lastCheck = updater.lastUpdateCheckDate
        Log.updates.notice("updates.found \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status.lastCheck = updater.lastUpdateCheckDate
        Log.updates.notice("updates.none newer")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        status.lastCheck = updater.lastUpdateCheckDate
        if let error = error as NSError?, error.domain != SUSparkleErrorDomain || error.code != Int(SUError.noUpdateError.rawValue) {
            Log.updates.error("updates.cycle ended: \(error.domain, privacy: .public) \(error.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus && !alwaysGentle
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        status.waiting = update.displayVersionString
        Log.updates.notice("updates.waiting \(update.displayVersionString, privacy: .public) in the menu")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        status.waiting = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        status.waiting = nil
    }
}
