import CoreGraphics
import Foundation

/// Smart alignment while a single mark is moved: its edges and middle snap to the other marks' edges and
/// middles, and to the canvas's middle, once they come close, with a guide along each line it snapped to.
nonisolated enum AlignmentSnapping {
    /// A line a moving mark snapped to, reaching across both it and what it lines up with, in the
    /// document's pixels.
    struct Guide: Equatable {
        var start: CGPoint
        var end: CGPoint
    }

    /// Snaps `original`, moved by `rawDelta`, against the other marks of `document` and the canvas's middle
    /// within `threshold` pixels: the delta it moves by, and the guides to show. An axis Shift holds still
    /// does not snap.
    static func snap(
        _ original: Annotation, translatedBy rawDelta: CGSize, in document: AnnotationDocument, threshold: CGFloat,
        axisLockedX: Bool, axisLockedY: Bool
    ) -> (delta: CGSize, guides: [Guide]) {
        let scale = document.scale
        let movedBounds = original.translated(by: rawDelta).bounds(scale: scale)
        guard !movedBounds.isNull, movedBounds.width > 0 || movedBounds.height > 0 else {
            return (rawDelta, [])
        }
        let canvas = document.canvas.standardized

        var xTargets: [(x: CGFloat, minY: CGFloat, maxY: CGFloat)] = [
            (canvas.midX, canvas.minY, canvas.maxY),
        ]
        var yTargets: [(y: CGFloat, minX: CGFloat, maxX: CGFloat)] = [
            (canvas.midY, canvas.minX, canvas.maxX),
        ]
        for item in document.items where item.id != original.id {
            let b = item.bounds(scale: scale)
            guard !b.isNull else { continue }
            xTargets.append((b.minX, b.minY, b.maxY))
            xTargets.append((b.midX, b.minY, b.maxY))
            xTargets.append((b.maxX, b.minY, b.maxY))
            yTargets.append((b.minY, b.minX, b.maxX))
            yTargets.append((b.midY, b.minX, b.maxX))
            yTargets.append((b.maxY, b.minX, b.maxX))
        }

        var delta = rawDelta
        var guides: [Guide] = []

        if !axisLockedX {
            let xEdges = [movedBounds.minX, movedBounds.midX, movedBounds.maxX]
            var bestX: (offset: CGFloat, targetX: CGFloat, minY: CGFloat, maxY: CGFloat)?
            for edge in xEdges {
                for target in xTargets {
                    let diff = target.x - edge
                    guard abs(diff) <= threshold else { continue }
                    if bestX == nil || abs(diff) < abs(bestX!.offset) {
                        bestX = (diff, target.x, target.minY, target.maxY)
                    }
                }
            }
            if let bestX {
                delta.width += bestX.offset
                let snappedRect = movedBounds.offsetBy(dx: bestX.offset, dy: 0)
                guides.append(Guide(
                    start: CGPoint(x: bestX.targetX, y: min(snappedRect.minY, bestX.minY)),
                    end: CGPoint(x: bestX.targetX, y: max(snappedRect.maxY, bestX.maxY))
                ))
            }
        }

        if !axisLockedY {
            let yEdges = [movedBounds.minY, movedBounds.midY, movedBounds.maxY]
            var bestY: (offset: CGFloat, targetY: CGFloat, minX: CGFloat, maxX: CGFloat)?
            for edge in yEdges {
                for target in yTargets {
                    let diff = target.y - edge
                    guard abs(diff) <= threshold else { continue }
                    if bestY == nil || abs(diff) < abs(bestY!.offset) {
                        bestY = (diff, target.y, target.minX, target.maxX)
                    }
                }
            }
            if let bestY {
                delta.height += bestY.offset
                let snappedRect = movedBounds.offsetBy(dx: delta.width - rawDelta.width, dy: bestY.offset)
                guides.append(Guide(
                    start: CGPoint(x: min(snappedRect.minX, bestY.minX), y: bestY.targetY),
                    end: CGPoint(x: max(snappedRect.maxX, bestY.maxX), y: bestY.targetY)
                ))
            }
        }

        return (delta, guides)
    }
}
