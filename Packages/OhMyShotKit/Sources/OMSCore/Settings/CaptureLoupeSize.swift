import Foundation

/// How the capture overlay's magnifier shows the pixels at the pointer before an area is chosen, in screenshots and
/// Annotate Area. Pick Color, Capture Text, recording, and scrolling keep the magnified lens.
public enum CaptureLoupeStyle: String, CaseIterable, Sendable {
    /// The lens below and right of the pointer, 15 captured pixels across at 8 pt each, with a grid and the crosshair:
    /// for placing an edge on the exact pixel.
    case magnified
    /// A compact, translucent pixel grid centered on the pointer, with modest magnification. Hidden after the first
    /// press until a click with no drag. The stored case name preserves existing preferences.
    case actualSize

    public var title: String {
        switch self {
        case .magnified: String(localized: "Magnified", bundle: .module)
        case .actualSize: String(localized: "Centered", bundle: .module)
        }
    }
}

/// The size of the centered pixel picker (`CaptureLoupeStyle.actualSize`).
public enum CaptureLoupeSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    /// The picker diameter in points; the surrounding screen stays at its original scale.
    public var diameter: CGFloat {
        switch self {
        case .small: 75
        case .medium: 90
        case .large: 120
        }
    }

    /// About four rendered device pixels per source pixel. An odd count keeps one exact center cell.
    public func pixelsAcross(backingScale: CGFloat) -> Int {
        let half = Int((diameter * backingScale / 4 / 2).rounded(.down))
        return max(3, half * 2 + 1)
    }

    public var title: String {
        switch self {
        case .small: String(localized: "Small", bundle: .module)
        case .medium: String(localized: "Medium", bundle: .module)
        case .large: String(localized: "Large", bundle: .module)
        }
    }
}
