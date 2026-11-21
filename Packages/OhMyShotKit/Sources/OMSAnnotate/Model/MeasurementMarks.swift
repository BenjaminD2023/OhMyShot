import CoreGraphics
import Foundation
import OMSCore

nonisolated extension AnnotationDocument {
    /// A capture of `pixelSize` pixels with what Measure's ruler showed on it, as marks to edit: each line a
    /// double-headed arrow with its length on a label beside it, where the ruler shows its readings, or the box as a
    /// rectangle with its size on a label under it. The readings are in the ruler's unit, and the marks in the
    /// editor's first ink at its thinnest line and smallest text, kept 6 pt inside the picture.
    public init(pixelSize: CGSize, measurement: RulerMeasurement) {
        let scale = measurement.pixelsPerPoint
        self.init(pixelSize: pixelSize, scale: scale)
        let unit = measurement.unit
        let ink = Style(color: .red, lineWidth: 2)
        let margin = 6 * scale
        func clamped(_ frame: CGRect) -> CGRect {
            var frame = frame
            frame.origin.x = min(max(frame.minX, margin), pixelSize.width - frame.width - margin)
            frame.origin.y = min(max(frame.minY, margin), pixelSize.height - frame.height - margin)
            return frame
        }
        // A label laid out anywhere, to be moved into `frame`, the size of its plate.
        func label(_ reading: String) -> (mark: Annotation, frame: CGRect) {
            let mark = Annotation(shape: .text(TextBlock(origin: .zero, string: reading, fontSize: 14, look: .label)), style: ink)
            return (mark, mark.bounds(scale: scale))
        }
        func placed(_ label: (mark: Annotation, frame: CGRect), in frame: CGRect) -> Annotation {
            label.mark.translated(by: CGSize(width: frame.minX - label.frame.minX, height: frame.minY - label.frame.minY))
        }
        switch measurement.shape {
        case .lines(let x, let y, let across, let down):
            // Through the middle of the pointer's pixel, from the first pixel's edge to past the last.
            let row = CGFloat(y) + 0.5, column = CGFloat(x) + 0.5
            let left = CGFloat(across.lowerBound), right = CGFloat(across.upperBound + 1)
            let top = CGFloat(down.lowerBound), bottom = CGFloat(down.upperBound + 1)
            let gap = 8 * scale
            let width = label(unit.reading(across.count, pixelsPerPoint: scale))
            let height = label(unit.reading(down.count, pixelsPerPoint: scale))
            // The length across above the middle of its line (below it near the top), the length down right of the
            // middle of its line (left of it near the right edge), as the ruler shows them.
            var widthFrame = CGRect(origin: CGPoint(x: (left + right - width.frame.width) / 2, y: row - gap - width.frame.height), size: width.frame.size)
            if widthFrame.minY < margin { widthFrame.origin.y = row + gap }
            var heightFrame = CGRect(origin: CGPoint(x: column + gap, y: (top + bottom - height.frame.height) / 2), size: height.frame.size)
            if heightFrame.maxX > pixelSize.width - margin { heightFrame.origin.x = column - gap - height.frame.width }
            widthFrame = clamped(widthFrame)
            heightFrame = clamped(heightFrame)
            // On something small both middles are near the pointer: the length down steps below the line across, and
            // below the length across too when that is under its line.
            if widthFrame.insetBy(dx: -2 * scale, dy: -2 * scale).intersects(heightFrame) {
                heightFrame.origin.y = max(row + gap, widthFrame.maxY + 4 * scale)
                heightFrame = clamped(heightFrame)
            }
            // Against the bottom edge there is no room under it, so the length down sits beside the length across, right
            // of it or left of it near the right edge.
            if widthFrame.insetBy(dx: -2 * scale, dy: -2 * scale).intersects(heightFrame) {
                heightFrame.origin = CGPoint(x: widthFrame.maxX + 4 * scale, y: widthFrame.minY)
                if heightFrame.maxX > pixelSize.width - margin { heightFrame.origin.x = widthFrame.minX - 4 * scale - heightFrame.width }
                heightFrame = clamped(heightFrame)
            }
            items = [
                Annotation(shape: .arrow(Arrow(start: CGPoint(x: left, y: row), end: CGPoint(x: right, y: row), head: .double)), style: ink),
                Annotation(shape: .arrow(Arrow(start: CGPoint(x: column, y: top), end: CGPoint(x: column, y: bottom), head: .double)), style: ink),
                placed(width, in: widthFrame),
                placed(height, in: heightFrame),
            ]
        case .box(let box):
            let size = label(unit.reading(width: Int(box.width), height: Int(box.height), pixelsPerPoint: scale))
            // Under the box, or over it near the bottom.
            let gap = 10 * scale
            var frame = CGRect(origin: CGPoint(x: box.midX - size.frame.width / 2, y: box.maxY + gap), size: size.frame.size)
            if frame.maxY > pixelSize.height - margin { frame.origin.y = box.minY - gap - frame.height }
            items = [Annotation(shape: .rectangle(Box(rect: box)), style: ink), placed(size, in: clamped(frame))]
        }
    }
}
