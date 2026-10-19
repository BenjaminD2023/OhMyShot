import Foundation

/// How the capture overlay's magnifier shows the pixels at the pointer before an area is chosen, in screenshots and
/// Annotate Area. Pick Color, Capture Text, recording, and scrolling keep the magnified lens.
public enum CaptureLoupeStyle: String, CaseIterable, Sendable {
    /// The lens below and right of the pointer, 15 captured pixels across at 8 pt each, with a grid and the crosshair:
    /// for placing an edge on the exact pixel.
    case magnified
    /// A lens centered on the pointer, the screen in it at its own scale and undimmed, its center cell the target; gone
    /// from the first press until a click with no drag, the crosshair staying.
    case actualSize

    public var title: String {
        switch self {
        case .magnified: String(localized: "Magnified", bundle: .module)
        case .actualSize: String(localized: "Actual Size", bundle: .module)
        }
    }
}

/// The size of the actual-size lens (`CaptureLoupeStyle.actualSize`).
public enum CaptureLoupeSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    /// The picker diameter in points; the screen itself stays at its original scale.
    public var diameter: CGFloat {
        switch self {
        case .small: 75
        case .medium: 90
        case .large: 120
        }
    }

    public var title: String {
        switch self {
        case .small: String(localized: "Small", bundle: .module)
        case .medium: String(localized: "Medium", bundle: .module)
        case .large: String(localized: "Large", bundle: .module)
        }
    }
}
