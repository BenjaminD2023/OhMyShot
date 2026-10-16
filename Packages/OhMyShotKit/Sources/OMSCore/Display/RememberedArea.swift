import CoreGraphics
import Foundation

/// An area kept for next time (All-In-One's last selection), with the display it was on as it was then. It is
/// offered again only on that display, arranged as it was: after a display goes, moves, or changes resolution, the
/// same points would land somewhere else.
public struct RememberedArea: Codable, Equatable, Sendable {
    /// In AppKit's global space.
    public var area: CGRect
    public var displayID: CGDirectDisplayID
    public var displayFrame: CGRect

    public init(area: CGRect, on display: DisplayInfo) {
        self.area = area
        displayID = display.id
        displayFrame = display.frame
    }

    /// The area, while its display is still there and where it was; nil after the arrangement changed.
    public func area(in layout: DisplayLayout) -> CGRect? {
        guard let display = layout.display(id: displayID), display.frame == displayFrame else { return nil }
        let kept = area.intersection(display.frame)
        guard !kept.isNull, kept.width >= 1, kept.height >= 1 else { return nil }
        return kept
    }
}
