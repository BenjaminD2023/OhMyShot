import CoreGraphics
import Foundation

/// The canvas grows to hold what reaches past it, as Shottr's expandable canvas does: a mark drawn or
/// moved past the picture's edge takes the canvas with it, with room all around, and the canvas shrinks
/// back once it comes back in. Images combined beside the capture are held edge to edge, as one picture.
nonisolated extension AnnotationDocument {
    /// The room left on every side once a mark reaches past the canvas, in points.
    public static let canvasMargin: CGFloat = 20
    /// The most a side grows, in points, so a mark flung far off does not make a picture of nothing.
    static let canvasGrowthLimit: CGFloat = 6000

    /// The canvas as it was set: the whole capture or its crop, before any growing to hold marks.
    public var setCanvas: CGRect {
        (canvasBeforeGrowing ?? canvas).standardized
    }

    /// This document with its canvas fitted to what it holds: the set canvas grown to every image
    /// reaching past it, edge to edge, and then, when any other mark reaches past, by how far the furthest
    /// does on each side and `canvasMargin` more on every side, as far as `canvasGrowthLimit`.
    ///
    /// It holds the marks in `touched` (those just drawn, moved, or changed) and those the canvas holds
    /// whole already. A mark a crop cut through, which nothing has touched since, stays cut. Spots, which
    /// light part of the capture, take no canvas.
    public func fittingCanvas(holding touched: Set<Annotation.ID> = []) -> AnnotationDocument {
        let base = setCanvas.integral
        let current = canvas.standardized
        var images = CGRect.null
        var marks = CGRect.null
        for item in items {
            if case .spotlight = item.shape { continue }
            let bounds = item.bounds(scale: scale).standardized
            guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0 || bounds.height > 0 else { continue }
            guard touched.contains(item.id) || current.contains(bounds) else { continue }
            if case .image = item.shape {
                images = images.union(bounds)
            } else {
                marks = marks.union(bounds)
            }
        }
        var fitted = base.union(images)
        if !marks.isNull, !fitted.contains(marks) {
            let reach = fitted.union(marks)
            let margin = Self.canvasMargin * scale
            let limit = Self.canvasGrowthLimit * scale
            let left = min(fitted.minX - reach.minX + margin, limit)
            let top = min(fitted.minY - reach.minY + margin, limit)
            let right = min(reach.maxX - fitted.maxX + margin, limit)
            let bottom = min(reach.maxY - fitted.maxY + margin, limit)
            fitted = CGRect(
                x: fitted.minX - left, y: fitted.minY - top,
                width: fitted.width + left + right, height: fitted.height + top + bottom
            )
        }
        fitted = fitted.integral
        var result = self
        result.canvas = fitted
        result.canvasBeforeGrowing = fitted == base ? nil : base
        return result
    }
}
