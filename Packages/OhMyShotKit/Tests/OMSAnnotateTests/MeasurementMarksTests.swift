import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

/// Measure's F: what the ruler measured, drawn on the capture as marks to edit.
struct MeasurementMarksTests {
    private let picture = CGSize(width: 1600, height: 1000)

    private func arrows(_ document: AnnotationDocument) -> [Arrow] {
        document.items.compactMap { if case .arrow(let arrow) = $0.shape { arrow } else { nil } }
    }

    /// Each label's text and the frame of its plate, in pixels.
    private func labels(_ document: AnnotationDocument) -> [(text: String, frame: CGRect)] {
        document.items.compactMap { item in
            guard case .text(let block) = item.shape else { return nil }
            return (block.string, item.bounds(scale: document.scale))
        }
    }

    @Test func linesBecomeDoubleHeadedArrowsWithTheirLengthsInTheUnitShown() {
        let shape = RulerMeasurement.Shape.lines(x: 400, y: 300, across: 100...339, down: 250...311)
        let points = AnnotationDocument(pixelSize: picture, measurement: RulerMeasurement(shape: shape, unit: .points, pixelsPerPoint: 2))
        #expect(points.scale == 2 && points.pixelSize == picture)
        // Through the middle of the pointer's pixel, from the first pixel's edge to past the last.
        #expect(arrows(points) == [
            Arrow(start: CGPoint(x: 100, y: 300.5), end: CGPoint(x: 340, y: 300.5), head: .double),
            Arrow(start: CGPoint(x: 400.5, y: 250), end: CGPoint(x: 400.5, y: 312), head: .double),
        ])
        let read = labels(points)
        #expect(read.map(\.text) == ["120 pt", "31 pt"])
        // The length across above the middle of its line, the length down right of the middle of its line.
        #expect(read[0].frame.maxY < 300.5 && abs(read[0].frame.midX - 220) < 1)
        #expect(read[1].frame.minX > 400.5 && abs(read[1].frame.midY - 281) < 1)
        #expect(points.items.allSatisfy { $0.style.color == .red && !$0.isTurned })
        // Nothing an earlier version can't read.
        #expect(AnnotationProject.version(for: points) == 1)

        let pixels = AnnotationDocument(pixelSize: picture, measurement: RulerMeasurement(shape: shape, unit: .pixels, pixelsPerPoint: 2))
        #expect(labels(pixels).map(\.text) == ["240 px", "62 px"])
        // At 1× a point is a pixel.
        let single = AnnotationDocument(pixelSize: picture, measurement: RulerMeasurement(shape: shape, unit: .points, pixelsPerPoint: 1))
        #expect(labels(single).map(\.text) == ["240 pt", "62 pt"])
    }

    @Test func aBoxBecomesARectangleWithItsSizeUnderIt() {
        let box = CGRect(x: 200, y: 100, width: 96, height: 47)
        let document = AnnotationDocument(pixelSize: picture, measurement: RulerMeasurement(shape: .box(box), unit: .points, pixelsPerPoint: 2))
        #expect(document.items.first?.shape == .rectangle(Box(rect: box)))
        let read = labels(document)
        #expect(read.map(\.text) == ["48 × 23.5 pt"])
        #expect(abs(read[0].frame.minY - (box.maxY + 20)) < 0.5 && abs(read[0].frame.midX - box.midX) < 1)
        // Near the bottom it goes over the box.
        let low = CGRect(x: 200, y: 950, width: 96, height: 40)
        let over = labels(AnnotationDocument(pixelSize: picture, measurement: RulerMeasurement(shape: .box(low), unit: .pixels, pixelsPerPoint: 2)))
        #expect(over.map(\.text) == ["96 × 40 px"])
        #expect(abs(over[0].frame.maxY - (low.minY - 20)) < 0.5)
    }

    @Test func labelsStayOnThePictureAndClearOfEachOther() {
        let inside = CGRect(origin: .zero, size: picture).insetBy(dx: 11.5, dy: 11.5)
        // Short lines in the top left corner: the length across goes under its line, and the length down steps under
        // it rather than cover it.
        let corner = labels(AnnotationDocument(
            pixelSize: picture, measurement: RulerMeasurement(shape: .lines(x: 10, y: 6, across: 2...20, down: 0...14), unit: .points, pixelsPerPoint: 2)
        ))
        #expect(corner.allSatisfy { inside.contains($0.frame) })
        #expect(corner[0].frame.minY > 6.5)
        #expect(!corner[0].frame.intersects(corner[1].frame))
        // At the right edge the length down goes left of its line.
        let edge = labels(AnnotationDocument(
            pixelSize: picture, measurement: RulerMeasurement(shape: .lines(x: 1590, y: 500, across: 1500...1599, down: 400...599), unit: .pixels, pixelsPerPoint: 2)
        ))
        #expect(edge.allSatisfy { inside.contains($0.frame) })
        #expect(edge[1].frame.maxX < 1590.5)
    }

    /// Against the bottom edge there is no room under the length across, so the length down sits beside it rather than
    /// cover it.
    @Test func labelsAtTheBottomEdgeSitSideBySide() {
        let display = CGSize(width: 800, height: 600)
        let inside = CGRect(origin: .zero, size: display).insetBy(dx: 5.5, dy: 5.5)
        let read = labels(AnnotationDocument(
            pixelSize: display, measurement: RulerMeasurement(shape: .lines(x: 20, y: 599, across: 10...40, down: 560...599), unit: .points, pixelsPerPoint: 1)
        ))
        #expect(read.allSatisfy { inside.contains($0.frame) })
        #expect(!read[0].frame.intersects(read[1].frame), "\(read.map(\.frame))")
    }

    @Test func theMarksAreDrawnOnTheCapture() throws {
        let base = makeBase(width: 200, height: 100)
        let measured = AnnotationDocument(
            pixelSize: CGSize(width: 200, height: 100),
            measurement: RulerMeasurement(shape: .lines(x: 80, y: 20, across: 10...149, down: 0...39), unit: .points, pixelsPerPoint: 1)
        )
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(measured, base: base)))
        // On the line across, between its heads and clear of the line down.
        let ink = pixels[40, 20]
        #expect(ink.r > 180 && ink.g < 90 && ink.b < 90, "\(ink)")
    }
}
