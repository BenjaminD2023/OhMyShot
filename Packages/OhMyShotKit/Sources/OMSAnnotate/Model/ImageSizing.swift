import CoreGraphics
import Foundation

/// The size the Image Size sheet is asking for: a width and a height in pixels, which a percent of the
/// picture's current size sets too. Proportions are kept by default, so changing one side moves the other.
nonisolated public struct ImageSizing: Equatable, Sendable {
    /// The picture's size now: the canvas, in pixels.
    public let current: CGSize
    public private(set) var width: Int
    public private(set) var height: Int
    public var keepsProportions = true

    public init(current: CGSize) {
        self.current = CGSize(width: max(current.width.rounded(), 1), height: max(current.height.rounded(), 1))
        width = Int(self.current.width)
        height = Int(self.current.height)
    }

    /// The size asked for, in pixels.
    public var size: CGSize { CGSize(width: width, height: height) }

    /// How large the width is against the current width, as a percent.
    public var percent: Double { Double(width) / Double(current.width) * 100 }

    /// Whether this asks for a different size than the picture has.
    public var changesSize: Bool { size != current }

    public mutating func setWidth(_ value: Int) {
        width = Self.clamped(value)
        if keepsProportions { height = Self.clamped(Int((Double(width) * Double(current.height) / Double(current.width)).rounded())) }
    }

    public mutating func setHeight(_ value: Int) {
        height = Self.clamped(value)
        if keepsProportions { width = Self.clamped(Int((Double(height) * Double(current.width) / Double(current.height)).rounded())) }
    }

    /// Both sides at `value` percent of the current size, whatever the proportions setting.
    public mutating func setPercent(_ value: Double) {
        let factor = max(value, 0) / 100
        width = Self.clamped(Int((Double(current.width) * factor).rounded()))
        height = Self.clamped(Int((Double(current.height) * factor).rounded()))
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, 1), AnnotationDocument.maxPictureSide)
    }
}

nonisolated extension AnnotationDocument {
    /// Whether the picture can have a canvas of `size` pixels: the picture it makes stays within what can
    /// be drawn and kept.
    public func allowsCanvas(of size: CGSize) -> Bool {
        resizedPictureSize(forCanvas: size) != nil
    }
}
