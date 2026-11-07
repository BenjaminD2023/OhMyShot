import AppKit
import CoreGraphics
import OMSCore
import ScreenCaptureKit

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

    /// The display holding most of this window, independent of the pointer or the selector's host.
    public func display(in layout: DisplayLayout) -> DisplayInfo? {
        layout.displays.filter { frame.intersects($0.frame) }.max {
            let a = frame.intersection($0.frame), b = frame.intersection($1.frame)
            return a.width * a.height < b.width * b.height
        } ?? layout.primary
    }
}

/// The on-screen windows, front to back, read once when window selection starts. Hit-testing the
/// pointer against this snapshot is plain arithmetic, so hovering costs nothing per event.
///
/// Standard windows only (layer 0), this app's own among them (Settings, Capture History, the editor, the
/// OCR panel); its panels over the screen (the overlay, cards, pins, readings) sit on higher layers.
public enum WindowCatalog {
    /// A shareable window from any display or Space. Kept separate from the visible hit-test catalog:
    /// windows on different Spaces may occupy exactly the same coordinates.
    struct Choice: Equatable {
        let target: WindowTarget
        let processID: pid_t
        let isOnScreen: Bool

        func matches(_ query: String) -> Bool {
            query.split(whereSeparator: \.isWhitespace).allSatisfy {
                "\(target.ownerName) \(target.title ?? "")".localizedStandardContains(String($0))
            }
        }
    }

    static func choices(from windows: [SCWindow], layout: DisplayLayout) -> [Choice] {
        let order = Dictionary(uniqueKeysWithValues: snapshot(layout: layout, excludingPID: getpid()).enumerated().map { ($0.element.id, $0.offset) })
        return windows.compactMap { window -> Choice? in
            guard let app = window.owningApplication, app.processID != getpid(),
                  let running = NSRunningApplication(processIdentifier: app.processID),
                  running.activationPolicy == .regular,
                  window.frame.width >= 100, window.frame.height >= 80,
                  window.windowLayer >= 0 else { return nil }
            // Some games use an elevated full-screen window. Ordinary app windows and these full-screen
            // surfaces are selectable; menu extras, tooltips, desktops and our own panels are not.
            let fillsDisplay = layout.displays.contains {
                let screen = layout.flipped($0.frame)
                return window.frame.insetBy(dx: -1, dy: -1).contains(screen)
            }
            guard window.windowLayer == 0 || fillsDisplay else { return nil }
            return Choice(
                target: WindowTarget(id: window.windowID, frame: layout.flipped(window.frame), ownerName: app.applicationName, title: window.title),
                processID: app.processID, isOnScreen: window.isOnScreen
            )
        }.sorted {
            let lhs = order[$0.target.id] ?? Int.max, rhs = order[$1.target.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.target.frame.width * $0.target.frame.height > $1.target.frame.width * $1.target.frame.height
        }
    }

    public static func snapshot(layout: DisplayLayout, excludingPID: pid_t? = nil) -> [WindowTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard
                isStandard(info),
                let pid = info[kCGWindowOwnerPID as String] as? pid_t, excludingPID.map({ pid != $0 }) ?? true,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let cgFrame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
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

    /// The same from a window list, front to back: the first standard window of the process that has a title.
    static func frontWindowTitle(ofProcess pid: pid_t, in list: [[String: Any]]) -> String? {
        for info in list {
            guard
                isStandard(info), (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                let title = info[kCGWindowName as String] as? String, !title.isEmpty
            else { continue }
            return title
        }
        return nil
    }

    /// Whether a window list's entry is a standard window: on layer 0 (panels over the screen, the menu bar, and the
    /// Dock sit higher), not see-through, and more than a sliver. The windows to choose from and the window an area is
    /// named after are both these, so a window that can be chosen names what is taken in it.
    static func isStandard(_ info: [String: Any]) -> Bool {
        guard
            (info[kCGWindowLayer as String] as? Int) == 0,
            (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { return false }
        return (bounds["Width"] ?? 0) >= 20 && (bounds["Height"] ?? 0) >= 20
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
