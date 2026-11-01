import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Return in the annotation editor copies and closes, unless it has something of its own to finish. Nothing is shown.
@MainActor
struct EditorReturnTests {
    private func makeCanvas(tool: AnnotationTool) throws -> (AnnotationCanvasView, AnnotationSession, NSWindow) {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let session = AnnotationSession(image: try #require(context.makeImage()), scale: 1, tool: tool)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, session, window)
    }

    private func returnKey(code: UInt16 = 36) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code
        ))
    }

    @Test func returnCopiesAndClosesWithNothingToFinish() throws {
        let (canvas, _, window) = try makeCanvas(tool: .arrow)
        defer { window.close() }
        var returned = 0
        canvas.onReturn = { returned += 1 }
        canvas.keyDown(with: try returnKey())
        canvas.keyDown(with: try returnKey(code: 76))
        #expect(returned == 2)
    }

    /// Crop's Return applies the frame and leaves Crop mode, as Done does: the window stays.
    @Test func cropKeepsItsReturn() throws {
        let (canvas, session, window) = try makeCanvas(tool: .crop)
        defer { window.close() }
        var returned = 0
        canvas.onReturn = { returned += 1 }
        canvas.keyDown(with: try returnKey())
        #expect(returned == 0)
        #expect(session.tool != .crop && !session.tool.isPictureMode)
    }

    @Test func spaceDragPansAZoomedCanvasWithoutDrawingMarks() throws {
        let (canvas, session, window) = try makeCanvas(tool: .arrow)
        defer { window.close() }
        canvas.zoomIn()
        let initialFocus = try #require(canvas.viewportFocus)
        let spaceDown = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        canvas.keyDown(with: spaceDown)
        #expect(canvas.isSpaceHeld)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 200, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let dragged = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 150, y: 80), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 150, y: 80), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: dragged)
        canvas.mouseUp(with: up)
        #expect(session.document.items.isEmpty)
        let updatedFocus = try #require(canvas.viewportFocus)
        #expect(updatedFocus.x > initialFocus.x)
        let spaceUp = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        canvas.keyUp(with: spaceUp)
        #expect(!canvas.isSpaceHeld)
    }

    @Test func marqueeSelectionSelectsEnclosedMarksAndSupportsShiftAdditiveSelection() throws {
        let (canvas, session, window) = try makeCanvas(tool: .select)
        defer { window.close() }
        let first = Annotation(shape: .rectangle(Box(rect: CGRect(x: 20, y: 20, width: 30, height: 30))), style: Style())
        let second = Annotation(shape: .rectangle(Box(rect: CGRect(x: 200, y: 100, width: 40, height: 40))), style: Style())
        var document = session.document
        document.items = [first, second]
        session.commit(document, actionName: "Add")

        func drag(from start: CGPoint, to end: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws {
            let down = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvas.convert(start, to: nil), modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let move = try #require(NSEvent.mouseEvent(
                with: .leftMouseDragged, location: canvas.convert(end, to: nil), modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let up = try #require(NSEvent.mouseEvent(
                with: .leftMouseUp, location: canvas.convert(end, to: nil), modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            canvas.mouseDown(with: down)
            canvas.mouseDragged(with: move)
            #expect(canvas.marqueeRect != nil)
            canvas.mouseUp(with: up)
            #expect(canvas.marqueeRect == nil)
        }

        try drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        #expect(session.selection == [first.id])

        try drag(from: CGPoint(x: 190, y: 90), to: CGPoint(x: 250, y: 150), modifiers: .shift)
        #expect(session.selection == [first.id, second.id])
    }

    @Test func doubleClickTextEditCommandClickSelectionEyedropperAndSmartGuides() throws {
        let (canvas, session, window) = try makeCanvas(tool: .arrow)
        defer { window.close() }

        // 1. Canvas color eyedropper (I key) samples capture pixel color and sets current tool color.
        let iDown = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34
        ))
        canvas.keyDown(with: iDown)
        #expect(canvas.isPickingColor)
        let sampled = try #require(canvas.sampleColor(at: CGPoint(x: 10, y: 10)))
        let clickPick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: canvas.convert(CGPoint(x: 50, y: 50), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        canvas.mouseDown(with: clickPick)
        #expect(!canvas.isPickingColor)
        #expect(session.settings(for: .arrow).color == sampled)

        // 2. Command-click selects an unselected area mark (filled rectangle) even while holding .arrow.
        let filledBox = Annotation(
            shape: .rectangle(Box(rect: CGRect(x: 40, y: 40, width: 100, height: 80), filled: true)),
            style: Style()
        )
        let targetBox = Annotation(
            shape: .rectangle(Box(rect: CGRect(x: 200, y: 40, width: 60, height: 60))),
            style: Style()
        )
        let textMark = Annotation(
            shape: .text(TextBlock(origin: CGPoint(x: 300, y: 120), string: "Hello", fontSize: 20, look: .plain)),
            style: Style()
        )
        var doc = session.document
        doc.items = [filledBox, targetBox, textMark]
        session.commit(doc, actionName: "Setup")
        session.select([])

        let interiorViewPt = CGPoint(x: canvas.bounds.minX + 90 * (canvas.bounds.width / 800), y: canvas.bounds.minY + 80 * (canvas.bounds.height / 400))
        let cmdDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: canvas.convert(interiorViewPt, to: nil), modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let cmdUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: canvas.convert(interiorViewPt, to: nil), modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        canvas.mouseDown(with: cmdDown)
        canvas.mouseUp(with: cmdUp)
        #expect(session.selection == [filledBox.id])

        // 3. Moving `targetBox` near `filledBox`'s top edge (y = 40) activates smart alignment guides when Command is not held.
        // Click on the top edge at x = 215 (between the topLeft handle at 200 and top handle at 230) so it moves rather than reshapes.
        session.select([targetBox.id])
        let edgePt = canvas.windowPoint(forDocument: CGPoint(x: 215, y: 40))
        let nearTopPt = canvas.windowPoint(forDocument: CGPoint(x: 215, y: 41))
        let moveDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: edgePt, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let moveDrag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: nearTopPt, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let moveUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: nearTopPt, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        canvas.mouseDown(with: moveDown)
        canvas.mouseDragged(with: moveDrag)
        #expect(!canvas.alignmentGuides.isEmpty)
        canvas.mouseUp(with: moveUp)
        #expect(canvas.alignmentGuides.isEmpty)

        // 4. Double-clicking `textMark` while `.pen` is selected enters inline text editing directly.
        session.tool = .pen
        let textPt = canvas.windowPoint(forDocument: CGPoint(x: 310, y: 130))
        let doubleClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: textPt, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
        ))
        canvas.mouseDown(with: doubleClick)
        #expect(canvas.isEditingText)
    }
}
