import Foundation

/// The centered screenshot and annotation picker's approximate device-pixel magnification.
public enum CaptureLoupeMagnification: String, CaseIterable, Sendable {
    case one
    case two
    case four
    case eight

    public var factor: CGFloat {
        switch self {
        case .one: 1
        case .two: 2
        case .four: 4
        case .eight: 8
        }
    }

    public var title: String {
        switch self {
        case .one: "1×"
        case .two: "2×"
        case .four: "4×"
        case .eight: "8×"
        }
    }
}

/// The centered color picker used before a screenshot or annotation area is selected.
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

    /// An odd count keeps one exact center cell, with the chosen rendered device pixels per source pixel.
    public func pixelsAcross(backingScale: CGFloat, magnification: CaptureLoupeMagnification = .four) -> Int {
        let half = Int((diameter * backingScale / magnification.factor / 2).rounded(.down))
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
