import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Speech bubbles and counters with a pointer: their tails reach past the frame that selects them, catch the pointer,
/// follow the picture, and are drawn as one shape with their plate.
struct CalloutTests {
    private func bubble(tail: CGPoint? = nil) -> Annotation {
        Annotation(shape: .text(TextBlock(origin: CGPoint(x: 100, y: 100), string: "Look here", fontSize: 20, look: .bubble, tail: tail)), style: Style(shadow: false))
    }

    @Test func bubblesAndPointersRoundTripThroughJSON() throws {
        let marks = [
            bubble(tail: CGPoint(x: 40, y: 260)),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 9, y: 9), value: 2, tail: CGPoint(x: 80, y: 40))), style: Style()),
        ]
        let document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300), scale: 1, items: marks)
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
        // Without a tail nothing new is written, so an earlier version reads it as before.
        let plain = try JSONEncoder().encode(TextBlock(origin: .zero, string: "a"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("tail"))
    }

    /// The tail reaches past the frame that selects the bubble, which stays the plate's own.
    @Test func aBubblesTailIsDrawnAndCaughtButNotFramed() throws {
        let mark = bubble(tail: CGPoint(x: 60, y: 220))
        let frame = mark.bounds(scale: 1)
        #expect(!frame.contains(CGPoint(x: 60, y: 220)))
        #expect(mark.drawingBounds(scale: 1).contains(CGPoint(x: 60, y: 220)))
        // On the tail, near its tip, and off it.
        #expect(mark.contains(CGPoint(x: 62, y: 216), tolerance: 2, scale: 1))
        #expect(!mark.contains(CGPoint(x: 300, y: 260), tolerance: 2, scale: 1))
        // A handle for the width and one for the tip.
        #expect(mark.handles(scale: 1).map(\.handle) == [.right, .tail])
        let moved = mark.moving(.tail, to: CGPoint(x: 400, y: 40), constrained: false, scale: 1)
        guard case .text(let block) = moved.shape else { Issue.record(Comment(rawValue: "not text")); return }
        #expect(block.tail == CGPoint(x: 400, y: 40))
        // Moved whole, the tip goes along.
        guard case .text(let shifted) = mark.translated(by: CGSize(width: 10, height: 5)).shape else { Issue.record(Comment(rawValue: "not text")); return }
        #expect(shifted.tail == CGPoint(x: 70, y: 225))
    }

    /// A counter's pointer is pulled out of its disc's edge and pushed back in to go.
    @Test func aCountersPointerIsPulledOutAndPushedBack() throws {
        let counter = Annotation(shape: .counter(Counter(center: CGPoint(x: 100, y: 100), value: 1)), style: Style(lineWidth: 4))
        let handles = counter.handles(scale: 1)
        let resting = try #require(handles.first)
        #expect(resting.handle == .tail)
        // On the disc's edge (28 px across at width 4), down and to the left.
        #expect(abs(hypot(resting.point.x - 100, resting.point.y - 100) - 14) < 0.5 && resting.point.x < 100 && resting.point.y > 100)
        let pointing = counter.moving(.tail, to: CGPoint(x: 40, y: 180), constrained: false, scale: 1)
        guard case .counter(let out) = pointing.shape else { Issue.record(Comment(rawValue: "not a counter")); return }
        #expect(out.tail == CGPoint(x: 40, y: 180))
        #expect(pointing.contains(CGPoint(x: 45, y: 173), tolerance: 2, scale: 1))
        #expect(pointing.bounds(scale: 1) == counter.bounds(scale: 1))
        let back = pointing.moving(.tail, to: CGPoint(x: 104, y: 103), constrained: false, scale: 1)
        guard case .counter(let gone) = back.shape else { Issue.record(Comment(rawValue: "not a counter")); return }
        #expect(gone.tail == nil)
    }

    /// Turned with the picture, a bubble stays upright and its tip still points where it did, even one left to point
    /// down and to the left.
    @Test func aTurnCarriesTheTipWithThePicture() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300), scale: 1)
        document.items = [bubble()]
        let tip = try #require(document.items[0].tip(scale: 1))
        let turned = try #require(document.applying(.rotateRight))
        guard case .text(let block) = turned.items[0].shape else { Issue.record(Comment(rawValue: "not text")); return }
        // A quarter turn right of a 400 × 300 picture: (x, y) goes to (300 − y, x).
        let expected = CGPoint(x: 300 - tip.y, y: tip.x)
        let moved = try #require(block.tail)
        #expect(abs(moved.x - expected.x) < 0.01 && abs(moved.y - expected.y) < 0.01)
    }

    /// The tail is filled with its plate: pixels along it take the bubble's color.
    @Test func theTailIsDrawnWithItsPlate() throws {
        let mark = bubble(tail: CGPoint(x: 40, y: 260))
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // y down, as the canvas and exports draw.
        context.translateBy(x: 0, y: 300)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(mark, in: context, scale: 1)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * context.bytesPerRow + x * 4 + 3] }
        // A point on the line from the plate's middle to the tip, outside the plate, and one well off it.
        let frame = mark.bounds(scale: 1)
        let along = CGPoint(x: frame.midX + (40 - frame.midX) * 0.8, y: frame.midY + (260 - frame.midY) * 0.8)
        #expect(!frame.contains(along))
        #expect(alpha(Int(along.x), Int(along.y)) > 200)
        #expect(alpha(390, 20) == 0)
    }
}
