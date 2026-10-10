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

    /// The frontmost window under a point in AppKit's global space.
    public static func target(at point: CGPoint, in windows: [WindowTarget]) -> WindowTarget? {
        windows.first { $0.frame.contains(point) }
    }
}
