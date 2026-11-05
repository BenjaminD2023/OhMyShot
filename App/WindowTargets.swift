import CoreGraphics
import OMSCapture

extension [WindowTarget] {
    /// The frame around all of the windows, in global points, as a capture of them together takes it in; nil for none.
    var combinedFrame: CGRect? {
        guard let first else { return nil }
        return dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }
}
