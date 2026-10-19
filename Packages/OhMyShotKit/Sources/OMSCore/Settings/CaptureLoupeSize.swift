import Foundation

/// The centered color picker used before a screenshot or annotation area is selected.
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
