import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// The wheel over a selected counter steps its number, one undo step a gesture. Nothing is shown.
@MainActor
struct CounterWheelTests {
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

    /// A mouse wheel's notch (`lines`, no phases) over `point` in the capture's pixels.
    private func notch(_ lines: Int32, at point: CGPoint, on canvas: AnnotationCanvasView, command: Bool = false) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        let screen = try #require(canvas.window).convertPoint(toScreen: canvas.windowPoint(forDocument: point))
        let height = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: screen.x, y: height - screen.y)
        if command { event.flags = .maskCommand }
        return try #require(NSEvent(cgEvent: event))
    }

    private func value(of id: Annotation.ID, in session: AnnotationSession) -> Int? {
        guard case .counter(let counter) = session.document.item(id)?.shape else { return nil }
        return counter.value
    }

    /// `change` as one undo group, as an event would make it.
    private func step(_ session: AnnotationSession, _ change: () throws -> Void) rethrows {
        session.undoManager.beginUndoGrouping()
        defer { session.undoManager.endUndoGrouping() }
        try change()
    }

    @Test func notchesOverASelectedCounterStepItsNumberAsOneUndoStep() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        session.undoManager.groupsByEvent = false
        let center = CGPoint(x: 200, y: 100)
        let mark = Annotation(shape: .counter(Counter(center: center, value: 5)), style: Style())
        step(session) {
            var document = session.document
            document.items = [mark]
            session.commit(document, actionName: "Add")
        }

        // Not selected: the wheel leaves it alone.
        canvas.scrollWheel(with: try notch(1, at: center, on: canvas))
        #expect(value(of: mark.id, in: session) == 5)

        session.select([mark.id])
        let first = try notch(1, at: center, on: canvas)
        let travel = first.isDirectionInvertedFromDevice ? -first.scrollingDeltaY : first.scrollingDeltaY
        let step = travel > 0 ? 1 : -1
        try self.step(session) {
            canvas.scrollWheel(with: first)
            canvas.scrollWheel(with: try notch(1, at: center, on: canvas))
            canvas.scrollWheel(with: try notch(1, at: center, on: canvas))
            #expect(value(of: mark.id, in: session) == 5 + 3 * step)
            // With Command the wheel zooms instead, which also ends the gesture.
            canvas.scrollWheel(with: try notch(1, at: center, on: canvas, command: true))
            #expect(value(of: mark.id, in: session) == 5 + 3 * step)
        }
        #expect(session.undoManager.undoActionName == "Renumber Counter")

        // The three notches are one step back.
        canvas.undo(nil)
        #expect(value(of: mark.id, in: session) == 5)
        #expect(session.document.items.count == 1)
    }

    /// Another change between notches (a color chosen in the capsule) is its own undo step: the notches after it start
    /// another, so each Undo puts back exactly what it should.
    @Test func aChangeBetweenNotchesKeepsTheUndoStepsInOrder() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        session.undoManager.groupsByEvent = false
        let center = CGPoint(x: 200, y: 100)
        let mark = Annotation(shape: .counter(Counter(center: center, value: 5)), style: Style(color: .red))
        step(session) {
            var document = session.document
            document.items = [mark]
            session.commit(document, actionName: "Add")
        }
        session.select([mark.id])
        let probe = try notch(1, at: center, on: canvas)
        let step = (probe.isDirectionInvertedFromDevice ? -probe.scrollingDeltaY : probe.scrollingDeltaY) > 0 ? 1 : -1
        func color() -> RGBA? { session.document.item(mark.id)?.style.color }

        try self.step(session) { canvas.scrollWheel(with: probe) }
        self.step(session) {
            var document = session.document
            document.items[0].style.color = .blue
            session.commit(document, actionName: "Color")
        }
        try self.step(session) { canvas.scrollWheel(with: try notch(1, at: center, on: canvas)) }
        #expect(value(of: mark.id, in: session) == 5 + 2 * step && color() == .blue)

        canvas.undo(nil)
        #expect(value(of: mark.id, in: session) == 5 + step && color() == .blue)
        canvas.undo(nil)
        #expect(value(of: mark.id, in: session) == 5 + step && color() == .red)
        canvas.undo(nil)
        #expect(value(of: mark.id, in: session) == 5 && color() == .red)
        canvas.redo(nil)
        #expect(value(of: mark.id, in: session) == 5 + step && color() == .red)
    }

    @Test func aCounterNeverStepsBelowTheFirst() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        let center = CGPoint(x: 200, y: 100)
        let mark = Annotation(shape: .counter(Counter(center: center, value: 2)), style: Style())
        var document = session.document
        document.items = [mark]
        session.commit(document, actionName: "Add")
        session.select([mark.id])
        let probe = try notch(1, at: center, on: canvas)
        let up: Int32 = (probe.isDirectionInvertedFromDevice ? -probe.scrollingDeltaY : probe.scrollingDeltaY) > 0 ? 1 : -1
        for _ in 0..<4 { canvas.scrollWheel(with: try notch(-up, at: center, on: canvas)) }
        #expect(value(of: mark.id, in: session) == 1)
    }
}
