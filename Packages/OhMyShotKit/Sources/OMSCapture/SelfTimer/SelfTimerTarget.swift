import AppKit
import CoreGraphics

/// What Self-Timer captures at zero, as the same choice is captured without it: an area as the screen shows it then, a
/// window on its own, or Shift-clicked windows each on its own and put together, never the screen between or behind
/// them.
public enum SelfTimerTarget: Equatable {
    case area(CGRect)
    /// With the keys held as it was clicked: Option turns its background the other way round.
    case window(WindowTarget, NSEvent.ModifierFlags)
    case windows([WindowTarget], NSEvent.ModifierFlags)

    /// What the overlay's choice has Self-Timer capture; nil for a choice that captures nothing at zero (a color, no
    /// windows, nothing).
    public init?(_ outcome: OverlayController.Outcome) {
        switch outcome {
        case .region(let rect, _, _, _): self = .area(rect)
        case .window(let target, let modifiers): self = .window(target, modifiers)
        case .windows(let targets, let modifiers):
            guard !targets.isEmpty else { return nil }
            self = .windows(targets, modifiers)
        case .annotated, .color, .record, .scroll, .allInOne, .allInOneWindows, .cancelled: return nil
        }
    }

    /// What the countdown outlines, in global points: the area, the window's frame, or the frame around all the windows.
    public var outline: CGRect {
        switch self {
        case .area(let rect): rect
        case .window(let target, _): target.frame
        case .windows(let targets, _): targets.combinedFrame ?? .null
        }
    }
}

extension [WindowTarget] {
    /// The frame around all of the windows, in global points; nil for none.
    public var combinedFrame: CGRect? {
        guard let first else { return nil }
        return dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }
}
