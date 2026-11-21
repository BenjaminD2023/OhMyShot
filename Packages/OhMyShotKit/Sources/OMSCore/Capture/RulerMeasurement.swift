import CoreGraphics

/// What Measure's ruler shows, to be drawn on a capture of the frame it measured: the lines from the pointer, or a
/// box, in that frame's pixels from its top left, and the unit its readings are in.
public struct RulerMeasurement: Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        /// The lines through the pixel at `x`, `y`: across, over the pixels `across` of row `y`; down, over the pixels
        /// `down` of column `x`.
        case lines(x: Int, y: Int, across: ClosedRange<Int>, down: ClosedRange<Int>)
        /// A box on whole pixels.
        case box(CGRect)
    }

    public var shape: Shape
    public var unit: MeasureUnit
    /// The frame's pixels per point, which readings in points are measured by.
    public var pixelsPerPoint: CGFloat

    public init(shape: Shape, unit: MeasureUnit, pixelsPerPoint: CGFloat) {
        self.shape = shape
        self.unit = unit
        self.pixelsPerPoint = pixelsPerPoint
    }
}
