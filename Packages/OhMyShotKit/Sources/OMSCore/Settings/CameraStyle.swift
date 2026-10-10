import CoreGraphics

/// How the camera's bubble looks in a recording: its shape, its size, and whether it shows the picture as
/// a mirror does.
public struct CameraStyle: Equatable, Sendable {
    public enum Shape: String, CaseIterable, Sendable {
        case circle
        case roundedSquare
    }

    public enum Size: String, CaseIterable, Sendable {
        case small
        case medium
        case large

        /// The bubble's width and height in points.
        public var points: CGFloat {
            switch self {
            case .small: 120
            case .medium: 180
            case .large: 260
            }
        }
    }

    public var shape: Shape
    public var size: Size
    /// Shown as a mirror shows it, as people expect to see themselves; recorded the same way.
    public var mirrored: Bool

    public init(shape: Shape = .circle, size: Size = .medium, mirrored: Bool = true) {
        self.shape = shape
        self.size = size
        self.mirrored = mirrored
    }
}
