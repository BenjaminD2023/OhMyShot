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
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let performance = Logger(subsystem: subsystem, category: "performance")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let resources = Logger(subsystem: subsystem, category: "resources")

    /// Points of interest for latency measurement (`Scripts/latency.sh`).
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
