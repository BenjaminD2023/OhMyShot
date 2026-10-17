import Foundation
import OSLog

/// Loggers and the signposter shared by every module.
///
/// Lifecycle events and debug-hook results log at `notice`, which macOS persists, so scripts can read
/// them back with `log show --predicate 'subsystem == "<bundle id>"'`.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.fzlzjerry.ohmyshot"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let automation = Logger(subsystem: subsystem, category: "automation")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let modelPacks = Logger(subsystem: subsystem, category: "modelPacks")
    public static let performance = Logger(subsystem: subsystem, category: "performance")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let recording = Logger(subsystem: subsystem, category: "recording")
    public static let resources = Logger(subsystem: subsystem, category: "resources")
    public static let studio = Logger(subsystem: subsystem, category: "studio")
    public static let upload = Logger(subsystem: subsystem, category: "upload")

    /// Points of interest for latency measurement (`Scripts/latency.sh`).
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
