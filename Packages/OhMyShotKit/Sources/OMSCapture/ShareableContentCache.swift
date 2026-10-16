import CoreGraphics
import Foundation
import OMSCore
import OSLog
import ScreenCaptureKit

/// The list of capturable displays and this app's own entry, fetched off the hotkey path.
///
/// Every fetch is a round trip through the privacy daemon, and fetching per capture has been seen to
/// exhaust it (macOS 26.6.2). The cache refreshes at launch, when displays change, and on a miss.
public final class ShareableContentCache {
    private var content: SCShareableContent?

    public init() {}

    /// Drops the cached copy and fetches a fresh one in the background.
    public func refresh() {
        content = nil
        Task { _ = try? await current() }
    }

    /// Content fetched now, in one round trip, for what changes without telling the cache: the wallpaper's windows.
    public func fresh() async throws -> SCShareableContent {
        content = nil
        return try await current()
    }

    /// The cached content, fetching it if there is none yet.
    public func current() async throws -> SCShareableContent {
        if let content { return content }
        let probe = LatencyProbe("capture.content")
        // Off-screen windows are included so this app is listed even while its overlay panels are
        // hidden; captures exclude it by application.
        let fetched = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        probe.end()
        content = fetched
        return fetched
    }

    /// This app, so captures can exclude its own windows. An app is listed only once it has a window,
    /// so a miss refetches once in case the overlay panels were created after the last fetch.
    public func ownApplication() async throws -> SCRunningApplication? {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let own = try await current().applications.first(where: { $0.processID == pid }) {
            return own
        }
        content = nil
        let own = try await current().applications.first { $0.processID == pid }
        if own == nil {
            Log.capture.error("This app is missing from the shareable content; its windows cannot be excluded")
        }
        return own
    }

    /// The windows among `ids`, fetching once more when one is missing: a pin opened since the last fetch.
    public func windows(withIDs ids: Set<CGWindowID>) async throws -> [SCWindow] {
        let found = try await current().windows.filter { ids.contains($0.windowID) }
        guard found.count < ids.count else { return found }
        content = nil
        return try await current().windows.filter { ids.contains($0.windowID) }
    }

    public func display(id: CGDirectDisplayID) async throws -> SCDisplay {
        if let display = try await current().displays.first(where: { $0.displayID == id }) {
            return display
        }
        // A display attached since the last fetch: fetch once more.
        content = nil
        guard let display = try await current().displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound(id)
        }
        return display
    }
}
