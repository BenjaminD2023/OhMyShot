import Foundation

/// How much adjacent pixels may differ before Measure treats them as an edge.
public enum MeasureTolerance: String, CaseIterable, Codable, Sendable {
    case zero
    case low
    case medium
    case high

    /// The largest allowed difference in an 8-bit color channel.
    public var threshold: Int {
        switch self {
        case .zero: 0
        case .low: 7
        case .medium: 13
        case .high: 26
        }
    }

    public var title: String {
        switch self {
        case .zero: String(localized: "Zero", bundle: .module)
        case .low: String(localized: "Low", bundle: .module)
        case .medium: String(localized: "Medium", bundle: .module)
        case .high: String(localized: "High", bundle: .module)
        }
    }

    /// T cycles through every tolerance and returns to Zero after High.
    public var next: MeasureTolerance {
        switch self {
        case .zero: .low
        case .low: .medium
        case .medium: .high
        case .high: .zero
        }
    }

    public var increased: MeasureTolerance {
        self == .high ? .high : next
    }

    public var decreased: MeasureTolerance {
        switch self {
        case .zero, .low: .zero
        case .medium: .low
        case .high: .medium
        }
    }
}
