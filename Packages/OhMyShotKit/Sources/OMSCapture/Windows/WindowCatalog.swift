import AppKit
import CoreGraphics
import OMSCore

/// A window that can be captured on its own.
public struct WindowTarget: Equatable, Sendable {
    public let id: CGWindowID
    /// The window's frame in AppKit's global space.
    public let frame: CGRect
    public let ownerName: String
    public let title: String?

    public init(id: CGWindowID, frame: CGRect, ownerName: String, title: String?) {
        self.id = id
        self.frame = frame
        self.ownerName = ownerName
        self.title = title
    }
}

/// The on-screen windows, front to back, read once when window selection starts. Hit-testing the
/// pointer against this snapshot is plain arithmetic, so hovering costs nothing per event.
///
/// Standard windows only (layer 0), this app's own among them (Settings, Capture History, the editor, the
/// OCR panel); its panels over the screen (the overlay, cards, pins, readings) sit on higher layers.
public enum WindowCatalog {
    public static func snapshot(layout: DisplayLayout, excludingPID: pid_t? = nil) -> [WindowTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard
                (info[kCGWindowLayer as String] as? Int) == 0,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t, excludingPID.map({ pid != $0 }) ?? true,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01
            else { return nil }
            let cgFrame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard cgFrame.width >= 20, cgFrame.height >= 20 else { return nil }
            return WindowTarget(
                id: id,
                frame: layout.flipped(cgFrame),
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String
            )
        }
    }

    /// The title of the front window of the app with process `pid`, read from the window list now: what an area
    /// taken in that app is named after. Nil when it has none on screen, or no title.
    public static func frontWindowTitle(ofProcess pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return frontWindowTitle(ofProcess: pid, in: CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    /// The same from a window list, front to back: the first standard window (layer 0) of the process that has a
    /// title and is more than a sliver.
    static func frontWindowTitle(ofProcess pid: pid_t, in list: [[String: Any]]) -> String? {
        for info in list {
            guard
                (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                (bounds["Width"] ?? 0) >= 20, (bounds["Height"] ?? 0) >= 20,
                let title = info[kCGWindowName as String] as? String, !title.isEmpty
            else { continue }
            return title
        }
        return nil
    }

    /// The process a window belongs to, read from the window list now; nil once the window is gone.
    public static func owner(of window: CGWindowID) -> pid_t? {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]]
        return list?.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    /// The frontmost window under a point in AppKit's global space.
    public static func target(at point: CGPoint, in windows: [WindowTarget]) -> WindowTarget? {
        windows.first { $0.frame.contains(point) }
    }

    /// All windows under a point in AppKit's global space, front to back.
    public static func targets(at point: CGPoint, in windows: [WindowTarget]) -> [WindowTarget] {
        windows.filter { $0.frame.contains(point) }
    }

    /// Cycles to the next (or previous) window: among the overlapping windows under `point` when there are two or more,
    /// otherwise across all `windows` on screen.
    public static func cycledTarget(
        from current: WindowTarget?, at point: CGPoint?, in windows: [WindowTarget], backward: Bool = false
    ) -> WindowTarget? {
        let under = point.map { targets(at: $0, in: windows) } ?? []
        let pool = under.count > 1 ? under : windows
        guard !pool.isEmpty else { return nil }
        if let current, let index = pool.firstIndex(of: current) {
            let step = backward ? -1 : 1
            return pool[(index + step + pool.count) % pool.count]
        }
        return backward ? pool.last : pool.first
    }
}
