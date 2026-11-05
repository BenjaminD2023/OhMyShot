import Foundation

/// Selection belongs to the document rather than to separate controls. Choosing a range also lets go of
/// any zoom, cut or camera layout, whichever input method made the choice.
nonisolated public enum StudioSelection: Equatable, Sendable {
    case none
    case range(ClosedRange<Double>)
    case zoom(UUID)
    case cut(Double)
    case cameraSegment(UUID)
}
