import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Several selected marks resized together by a corner of the box around them. Nothing is shown.
@MainActor
struct GroupResizeTests {
    private let scratch = ScratchDefaults()

    private func makeCanvas() throws -> (AnnotationCanvasView, AnnotationSession, NSWindow) {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let session = AnnotationSession(image: try #require(context.makeImage()), scale: 1, tool: .select, defaults: scratch.make())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, session, window)
    }

    /// A press, a drag and a release, at points in the capture's pixels, as one undo group as an event makes it.
    private func drag(_ canvas: AnnotationCanvasView, in window: NSWindow, session: AnnotationSession, from start: CGPoint, to end: CGPoint, shift: Bool = false) throws {
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: canvas.windowPoint(forDocument: point), modifierFlags: shift ? .shift : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        session.undoManager.beginUndoGrouping()
        defer { session.undoManager.endUndoGrouping() }
        canvas.mouseDown(with: try event(.leftMouseDown, at: start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: end))
        canvas.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    private func add(_ marks: [Annotation], to session: AnnotationSession) {
        session.undoManager.beginUndoGrouping()
        var document = session.document
        document.items = marks
        session.commit(document, actionName: "Add")
        session.undoManager.endUndoGrouping()
    }

    private func rect(of id: Annotation.ID, in session: AnnotationSession) -> CGRect? {
        switch session.document.item(id)?.shape {
        case .rectangle(let box), .ellipse(let box): box.rect
        default: nil
        }
    }

    @Test func draggingACornerOfSeveralMarksStretchesThemFromTheOppositeCornerAsOneUndoStep() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        session.undoManager.groupsByEvent = false
        let box = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 40, width: 60, height: 40))), style: Style(lineWidth: 4))
        let oval = Annotation(shape: .ellipse(Box(rect: CGRect(x: 120, y: 80, width: 40, height: 40))), style: Style(lineWidth: 4))
        add([box, oval], to: session)
        session.select([box.id, oval.id])
        // The two lie in one box from (38, 38) to (162, 122), drawn line and all; its bottom right corner is dragged
        // 62 pt right and 42 down, doubling it from its top left.
        let group = try #require([box, oval].map { $0.bounds(scale: 1) }.reduce(CGRect.null) { $0.union($1) } as CGRect?)
        let corner = CGPoint(x: group.maxX, y: group.maxY)
        try drag(canvas, in: window, session: session, from: corner, to: CGPoint(x: group.maxX + group.width, y: group.maxY + group.height))

        let grown = try #require(rect(of: box.id, in: session))
        let grownOval = try #require(rect(of: oval.id, in: session))
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        func doubled(_ r: CGRect) -> CGRect {
            CGRect(x: group.minX + (r.minX - group.minX) * 2, y: group.minY + (r.minY - group.minY) * 2, width: r.width * 2, height: r.height * 2)
        }
        #expect(near(grown, doubled(CGRect(x: 40, y: 40, width: 60, height: 40))))
        #expect(near(grownOval, doubled(CGRect(x: 120, y: 80, width: 40, height: 40))))
        // Lines keep their width.
        #expect(session.document.item(box.id)?.style.lineWidth == 4)
        #expect(Set(session.selection) == [box.id, oval.id])
        #expect(session.undoManager.undoActionName == "Resize Marks")

        canvas.undo(nil)
        #expect(rect(of: box.id, in: session) == CGRect(x: 40, y: 40, width: 60, height: 40))
        #expect(rect(of: oval.id, in: session) == CGRect(x: 120, y: 80, width: 40, height: 40))
    }

    @Test func textAndCountersKeepTheirSizeAndMoveWithTheRest() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        let block = TextBlock(origin: CGPoint(x: 40, y: 40), string: "Look here", fontSize: 20, look: .label, width: 90)
        let text = Annotation(shape: .text(block), style: Style())
        let counter = Annotation(shape: .counter(Counter(center: CGPoint(x: 200, y: 140), value: 3)), style: Style())
        add([text, counter], to: session)
        session.select([text.id, counter.id])
        let before = text.bounds(scale: 1)
        let group = [text, counter].map { $0.bounds(scale: 1) }.reduce(CGRect.null) { $0.union($1) }
        // The top left corner dragged up and left, so the box grows away from its bottom right.
        try drag(canvas, in: window, session: session, from: CGPoint(x: group.minX, y: group.minY), to: CGPoint(x: group.minX - 20, y: group.minY - 20))

        guard case .text(let moved) = session.document.item(text.id)?.shape else { Issue.record("Not text"); return }
        #expect(moved.fontSize == 20)
        #expect(moved.width == 90)
        let after = try #require(session.document.item(text.id)).bounds(scale: 1)
        #expect(abs(after.width - before.width) < 0.5 && abs(after.height - before.height) < 0.5)
        // Its middle moved away from the anchor, as the box grew.
        #expect(after.midX < before.midX && after.midY < before.midY)
        guard case .counter(let step) = session.document.item(counter.id)?.shape else { Issue.record("Not a counter"); return }
        #expect(step.value == 3)
        #expect(step.center.x < 200 + 0.5 && step.center.x > 190 && step.center.y < 140 + 0.5)
    }

    @Test func shiftKeepsTheBoxsShape() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        let one = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 40, width: 40, height: 20))), style: Style(lineWidth: 2))
        let two = Annotation(shape: .rectangle(Box(rect: CGRect(x: 100, y: 60, width: 40, height: 20))), style: Style(lineWidth: 2))
        add([one, two], to: session)
        session.select([one.id, two.id])
        let group = [one, two].map { $0.bounds(scale: 1) }.reduce(CGRect.null) { $0.union($1) }
        // Dragged far to the right but hardly down: with Shift the box keeps its proportions.
        try drag(canvas, in: window, session: session, from: CGPoint(x: group.maxX, y: group.maxY), to: CGPoint(x: group.maxX + group.width, y: group.maxY + 4), shift: true)
        let scaled = [one, two].compactMap { session.document.item($0.id)?.bounds(scale: 1) }.reduce(CGRect.null) { $0.union($1) }
        #expect(abs(scaled.width / scaled.height - group.width / group.height) < 0.05)
    }

    @Test func aCornerDraggedPastTheOppositeOneStopsShortOfIt() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        let one = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 40, width: 40, height: 20))), style: Style(lineWidth: 2))
        let two = Annotation(shape: .rectangle(Box(rect: CGRect(x: 100, y: 60, width: 40, height: 20))), style: Style(lineWidth: 2))
        add([one, two], to: session)
        session.select([one.id, two.id])
        let group = [one, two].map { $0.bounds(scale: 1) }.reduce(CGRect.null) { $0.union($1) }
        try drag(canvas, in: window, session: session, from: CGPoint(x: group.maxX, y: group.maxY), to: CGPoint(x: 10, y: 10))
        // Squeezed against the top left corner, still in order: the first mark left of and above the second.
        let first = try #require(rect(of: one.id, in: session)), second = try #require(rect(of: two.id, in: session))
        #expect(first.minX >= group.minX - 0.5 && first.minY >= group.minY - 0.5)
        #expect(first.minX < second.minX && first.minY < second.minY)
        #expect(second.maxX <= group.minX + 5 && second.maxY <= group.minY + 5)
    }

    @Test func aSingleMarkKeepsItsOwnHandles() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        let one = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 40, width: 60, height: 40))), style: Style(lineWidth: 4))
        add([one], to: session)
        session.select([one.id])
        // The rectangle's own corner handle reshapes it: its rect, not its drawn box, follows the pointer.
        try drag(canvas, in: window, session: session, from: CGPoint(x: 100, y: 80), to: CGPoint(x: 140, y: 100))
        #expect(rect(of: one.id, in: session) == CGRect(x: 40, y: 40, width: 100, height: 60))
        #expect(session.undoManager.undoActionName != "Resize Marks")
    }

    @Test func tailsStillPointOffTheirMarksWhenTheGroupShrinks() {
        let bubble = Annotation(shape: .text(TextBlock(origin: CGPoint(x: 100, y: 100), string: "Here", fontSize: 20, look: .bubble)), style: Style())
        let pointed = Annotation(shape: .counter(Counter(center: CGPoint(x: 300, y: 300), value: 1, tail: CGPoint(x: 330, y: 330))), style: Style())
        let far = Annotation(shape: .counter(Counter(center: CGPoint(x: 400, y: 100), value: 2, tail: CGPoint(x: 500, y: 300))), style: Style())
        let box = CGRect(x: 80, y: 80, width: 440, height: 240)
        let target = CGRect(x: 80, y: 80, width: box.width * 0.4, height: box.height * 0.4)
        let scaled = AnnotationCanvasView.scaled([bubble, pointed, far], from: box, to: target, scale: 1)

        // A bubble left to point its own way still does, beside its plate.
        guard case .text(let block) = scaled[0].shape else { Issue.record("Not text"); return }
        #expect(block.tail == nil)
        // A tip that would land on the disc keeps its place beside it.
        guard case .counter(let near) = scaled[1].shape, let nearTip = near.tail else { Issue.record("No tail"); return }
        #expect(abs((nearTip.x - near.center.x) - 30) < 0.01 && abs((nearTip.y - near.center.y) - 30) < 0.01)
        #expect(!scaled[1].bounds(scale: 1).contains(nearTip))
        // One pointed well away goes where the map takes the place it pointed at.
        guard case .counter(let away) = scaled[2].shape else { Issue.record("Not a counter"); return }
        #expect(away.tail == CGPoint(x: 80 + (500 - 80) * 0.4, y: 80 + (300 - 80) * 0.4))
    }

    @Test func theMapIsTheSameForEveryMark() {
        let marks = [
            Annotation(shape: .line(Line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10))), style: Style()),
            Annotation(shape: .pen(Stroke(points: [CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 20)])), style: Style()),
        ]
        let scaled = AnnotationCanvasView.scaled(
            marks, from: CGRect(x: 0, y: 0, width: 20, height: 20), to: CGRect(x: 10, y: 10, width: 40, height: 10), scale: 1
        )
        guard case .line(let line) = scaled[0].shape, case .pen(let stroke) = scaled[1].shape else { Issue.record("Shapes changed"); return }
        #expect(line.start == CGPoint(x: 10, y: 10) && line.end == CGPoint(x: 30, y: 15))
        #expect(stroke.points == [CGPoint(x: 30, y: 10), CGPoint(x: 50, y: 20)])
    }
}
