import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Making a mark on the canvas: the field a text mark is typed in, and the tool being put down once its
/// mark is made. Nothing is shown.
@MainActor
struct MarkMakingTests {
    private let scratch = ScratchDefaults()

    /// A canvas of 400 × 200 pt on a capture of `pixels`, which a larger capture is zoomed out to fit.
    private func makeCanvas(pixels: CGSize = CGSize(width: 400, height: 200), scale: CGFloat = 1, tool: AnnotationTool? = nil) throws -> (AnnotationCanvasView, AnnotationSession, NSWindow, UserDefaults) {
        let context = try #require(CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixels))
        let defaults = scratch.make()
        let session = AnnotationSession(image: try #require(context.makeImage()), scale: scale, tool: tool, defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, session, window, defaults)
    }

    /// A press, a drag when `end` differs, and a release, at points in the capture's pixels.
    private func press(_ canvas: AnnotationCanvasView, in window: NSWindow, from start: CGPoint, to end: CGPoint? = nil) throws {
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: canvas.windowPoint(forDocument: point), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, at: start))
        if let end { canvas.mouseDragged(with: try event(.leftMouseDragged, at: end)) }
        canvas.mouseUp(with: try event(.leftMouseUp, at: end ?? start))
    }

    private func field(in canvas: AnnotationCanvasView) throws -> NSTextView {
        try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
    }

    /// The system font spaces its letters by their size, so a field typeset at the zoomed size would be
    /// wider than the mark's own layout scaled down, and cut its last words off.
    @Test func theFieldShowsEveryWordOfAZoomedOutCapture() throws {
        let (canvas, session, window, _) = try makeCanvas(pixels: CGSize(width: 1600, height: 800), scale: 2, tool: .select)
        defer { window.close() }
        #expect(canvas.zoom == 0.25)
        let block = TextBlock(origin: CGPoint(x: 40, y: 40), string: "A heart\nyou might need to change the color of the text, or add a border", fontSize: 20, look: .label)
        let mark = Annotation(shape: .text(block), style: Style(color: .white))
        var document = session.document
        document.items = [mark]
        session.commit(document, actionName: "Add")
        canvas.beginEditing(mark.id, isNew: false)
        defer { canvas.endEditing() }

        let field = try field(in: canvas)
        let manager = try #require(field.layoutManager)
        let container = try #require(field.textContainer)
        let font = try #require(field.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        manager.ensureLayout(for: container)
        // Where the last letter of the long line ends, in the canvas.
        let last = manager.numberOfGlyphs - 1
        let line = manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
        let letter = NSAttributedString(string: "r", attributes: [.font: font]).size().width
        let end = CGPoint(x: field.textContainerOrigin.x + line.minX + manager.location(forGlyphAt: last).x + letter, y: field.textContainerOrigin.y + line.maxY)
        let shown = field.convert(end, to: canvas)
        #expect(shown.x <= field.frame.maxX && shown.y <= field.frame.maxY)
        // The field is the mark's own size, so the text does not move when editing ends.
        let markSize = mark.bounds(scale: 2).size
        #expect(abs(field.frame.width - markSize.width * canvas.zoom) < 0.01)
        #expect(abs(field.frame.height - markSize.height * canvas.zoom) < 0.01)
    }

    @Test func aDraggedShapePutsItsToolDownAndStaysTheNextEditorsTool() throws {
        let (canvas, session, window, defaults) = try makeCanvas()
        defer { window.close() }
        session.tool = .rectangle
        try press(canvas, in: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 100))
        let shape = try #require(session.document.items.first)
        #expect(session.tool == .select)
        #expect(session.selection == [shape.id])
        #expect(defaults.string(forKey: "annotation.tool") == AnnotationTool.rectangle.rawValue)
    }

    @Test func thePenStaysInHandStrokeAfterStroke() throws {
        let (canvas, session, window, _) = try makeCanvas(tool: .pen)
        defer { window.close() }
        try press(canvas, in: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 100))
        try press(canvas, in: window, from: CGPoint(x: 200, y: 40), to: CGPoint(x: 280, y: 100))
        #expect(session.tool == .pen)
        #expect(session.document.items.count == 2)
    }

    @Test func theRedactToolStaysInHandMarkAfterMark() throws {
        #expect(!AnnotationTool.redact.isPutDownAfterMark)
        #expect(AnnotationTool.rectangle.isPutDownAfterMark)
        #expect(AnnotationTool.arrow.isPutDownAfterMark)
        #expect(AnnotationTool.text.isPutDownAfterMark)
        let (canvas, session, window, _) = try makeCanvas(tool: .redact)
        defer { window.close() }
        try press(canvas, in: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 100))
        #expect(session.tool == .redact)
        #expect(session.selection.count == 1)
        try press(canvas, in: window, from: CGPoint(x: 200, y: 40), to: CGPoint(x: 280, y: 100))
        #expect(session.tool == .redact)
        #expect(session.document.items.count == 2)
    }

    @Test func aClickAwayFromWrittenTextPutsTheTextToolDownInsteadOfStartingAnother() throws {
        let (canvas, session, window, _) = try makeCanvas(tool: .text)
        defer { window.close() }
        try press(canvas, in: window, from: CGPoint(x: 60, y: 60))
        #expect(canvas.isEditingText)
        try field(in: canvas).insertText("Hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        try press(canvas, in: window, from: CGPoint(x: 300, y: 160))
        #expect(!canvas.isEditingText)
        #expect(session.tool == .select)
        #expect(session.document.items.count == 1)
    }

    /// Nothing was written, so nothing was made: the click away moves the text to where it lands.
    @Test func aClickAwayFromAnEmptyTextKeepsTheTextTool() throws {
        let (canvas, session, window, _) = try makeCanvas(tool: .text)
        defer { window.close() }
        try press(canvas, in: window, from: CGPoint(x: 60, y: 60))
        try press(canvas, in: window, from: CGPoint(x: 300, y: 160))
        defer { canvas.endEditing() }
        #expect(session.tool == .text)
        #expect(canvas.isEditingText)
        #expect(session.document.items.count == 1)
    }

    @Test func drawingToolCreatesNewMarkNearExistingMarkAndCommandGrabsExisting() throws {
        let (canvas, session, window, _) = try makeCanvas(tool: .arrow)
        defer { window.close() }
        let existing = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 40, width: 100, height: 80))), style: Style())
        var document = session.document
        document.items = [existing]
        session.commit(document, actionName: "Setup")

        // Pressing right on the existing rectangle's edge while holding `.arrow` starts a new arrow instead of dragging the rectangle.
        try press(canvas, in: window, from: CGPoint(x: 40, y: 110), to: CGPoint(x: 200, y: 180))
        #expect(session.document.items.count == 2)
        #expect(session.document.item(existing.id) == existing)

        // Holding ⌘ while holding `.rectangle` temporarily grabs and moves the existing rectangle instead of drawing a new mark.
        session.tool = .rectangle
        func cmdEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: canvas.windowPoint(forDocument: point), modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        canvas.mouseDown(with: try cmdEvent(.leftMouseDown, at: CGPoint(x: 90, y: 40)))
        canvas.mouseDragged(with: try cmdEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 50)))
        canvas.mouseUp(with: try cmdEvent(.leftMouseUp, at: CGPoint(x: 110, y: 50)))
        #expect(session.document.items.count == 2)
        guard case .rectangle(let moved) = session.document.item(existing.id)?.shape else {
            Issue.record("Expected rectangle")
            return
        }
        #expect(moved.rect.origin == CGPoint(x: 60, y: 50))
    }

    @Test func lockedToolStaysActiveAcrossConsecutiveMarksUntilSwitched() throws {
        let (canvas, session, window, _) = try makeCanvas(tool: .select)
        defer { window.close() }
        session.lockTool(.rectangle)
        #expect(session.tool == .rectangle && session.isToolLocked)
        try press(canvas, in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 70))
        #expect(session.tool == .rectangle && session.isToolLocked)
        try press(canvas, in: window, from: CGPoint(x: 120, y: 20), to: CGPoint(x: 180, y: 70))
        #expect(session.tool == .rectangle && session.isToolLocked)
        #expect(session.document.items.count == 2)

        // Switching tools clears the lock.
        session.tool = .arrow
        #expect(!session.isToolLocked)

        // Locking a non-single-shot tool leaves `isToolLocked` false.
        session.lockTool(.pen)
        #expect(session.tool == .pen && !session.isToolLocked)
    }

    @Test func commandOneZoomsToActualSizeAndCommandReturnCommitsTextEditing() throws {
        let (canvas, session, window, _) = try makeCanvas(pixels: CGSize(width: 1600, height: 800), scale: 2, tool: .text)
        defer { window.close() }
        #expect(canvas.zoom == 0.25)
        window.makeFirstResponder(canvas)

        // ⌘1 zooms to actual size (1 / scale == 0.5).
        let cmd1 = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        #expect(canvas.performKeyEquivalent(with: cmd1))
        #expect(canvas.zoom == 0.5)

        // Start editing a text mark; ⌘0 zooms while editing, and ⌘Return commits text editing cleanly.
        try press(canvas, in: window, from: CGPoint(x: 100, y: 100))
        #expect(canvas.isEditingText)
        let textField = try field(in: canvas)
        textField.insertText("Committed", replacementRange: NSRange(location: NSNotFound, length: 0))

        let cmd0 = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29
        ))
        #expect(canvas.performKeyEquivalent(with: cmd0))
        #expect(canvas.zoom == 0.25)
        #expect(canvas.isEditingText)

        let cmdReturn = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        #expect(canvas.performKeyEquivalent(with: cmdReturn))
        #expect(!canvas.isEditingText)
        guard case .text(let block) = session.document.items.first?.shape else {
            Issue.record("Expected committed text mark")
            return
        }
        #expect(block.string == "Committed")

        // Context menu displays standard macOS shortcut equivalents for selected mark actions.
        let rightClick = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(canvas.menu(for: rightClick))
        let duplicate = try #require(menu.items.first { $0.action == #selector(AnnotationCanvasView.duplicateSelection(_:)) })
        #expect(duplicate.keyEquivalent == "d" && duplicate.keyEquivalentModifierMask == .command)
        let front = try #require(menu.items.first { $0.action == #selector(AnnotationCanvasView.bringToFront(_:)) })
        #expect(front.keyEquivalent == "]" && front.keyEquivalentModifierMask == [.command, .shift])
        let back = try #require(menu.items.first { $0.action == #selector(AnnotationCanvasView.sendToBack(_:)) })
        #expect(back.keyEquivalent == "[" && back.keyEquivalentModifierMask == [.command, .shift])
        let del = try #require(menu.items.first { $0.action == #selector(AnnotationCanvasView.delete(_:)) })
        #expect(del.keyEquivalent == "\u{8}" && del.keyEquivalentModifierMask == [])
    }
}
