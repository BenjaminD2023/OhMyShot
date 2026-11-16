import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Marks turned about their middles: what they cover and catch, how they reshape, draw, and are kept, and the knob
/// that turns them. Nothing is shown.
@MainActor
struct RotationTests {
    private let scratch = ScratchDefaults()

    private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private func box(_ rect: CGRect, filled: Bool = false, angle: CGFloat? = nil) -> Annotation {
        Annotation(shape: .rectangle(Box(rect: rect, filled: filled)), style: Style(lineWidth: 4, shadow: false), rotation: angle)
    }

    @Test func aQuarterTurnCoversTheBoxStoodOnItsEnd() {
        let mark = box(CGRect(x: 0, y: 0, width: 100, height: 40), angle: .pi / 2)
        let upright = box(CGRect(x: 0, y: 0, width: 100, height: 40)).bounds(scale: 1)
        let turned = mark.bounds(scale: 1)
        #expect(abs(turned.width - upright.height) < 0.01 && abs(turned.height - upright.width) < 0.01)
        #expect(near(turned.middle, upright.middle))
    }

    @Test func aTurnedMarkIsCaughtWhereItIsDrawn() {
        // Filled, 100 × 20 about (50, 10), turned upright: it runs from y −40 to 60 at x 40…60.
        let mark = box(CGRect(x: 0, y: 0, width: 100, height: 20), filled: true, angle: .pi / 2)
        #expect(mark.contains(CGPoint(x: 50, y: 50), tolerance: 1, scale: 1))
        #expect(mark.contains(CGPoint(x: 50, y: -30), tolerance: 1, scale: 1))
        #expect(!mark.contains(CGPoint(x: 90, y: 10), tolerance: 1, scale: 1))
    }

    @Test func handlesTurnWithTheMark() {
        let mark = Annotation(shape: .rectangle(Box(rect: CGRect(x: 0, y: 0, width: 100, height: 40))), style: Style(lineWidth: 0, shadow: false), rotation: .pi / 2)
        let handles = Dictionary(uniqueKeysWithValues: mark.handles(scale: 1).map { ($0.handle, $0.point) })
        // The top left corner of the upright box, turned a quarter clockwise about (50, 20).
        #expect(near(handles[.topLeft]!, CGPoint(x: 70, y: -30)))
        #expect(near(handles[.bottomRight]!, CGPoint(x: 30, y: 70)))
    }

    @Test func reshapingATurnedBoxKeepsTheCornerAcrossWhereItWas() {
        let mark = box(CGRect(x: 100, y: 100, width: 80, height: 40), angle: .pi / 6)
        let before = Dictionary(uniqueKeysWithValues: mark.handles(scale: 1).map { ($0.handle, $0.point) })
        // 30 along its own width and 10 along its height, as they lie turned.
        let along = Annotation.turn(CGPoint(x: 30, y: 10), about: .zero, by: .pi / 6)
        let pulled = CGPoint(x: before[.bottomRight]!.x + along.x, y: before[.bottomRight]!.y + along.y)
        let moved = mark.moving(.bottomRight, to: pulled, constrained: false, scale: 1)
        let after = Dictionary(uniqueKeysWithValues: moved.handles(scale: 1).map { ($0.handle, $0.point) })
        #expect(near(after[.topLeft]!, before[.topLeft]!, 0.05))
        #expect(near(after[.bottomRight]!, pulled, 0.05))
        #expect(moved.rotation == .pi / 6)
        // It grew along its own sides.
        guard case .rectangle(let grown) = moved.shape else { Issue.record("Not a box"); return }
        #expect(abs(grown.rect.width - 110) < 0.05 && abs(grown.rect.height - 50) < 0.05)
    }

    @Test func aTurnedBubblesTipStaysWhereItPoints() {
        let tip = CGPoint(x: 40, y: 200)
        let block = TextBlock(origin: CGPoint(x: 100, y: 100), string: "Here", fontSize: 20, look: .bubble, tail: tip)
        let mark = Annotation(shape: .text(block), style: Style(), rotation: .pi / 5)
        #expect(near(mark.tip(scale: 1)!, tip, 0.01))
        // Widened by its handle, still turned, it points at the same place.
        let right = mark.handles(scale: 1).first { $0.handle == .right }!.point
        let wider = mark.moving(.right, to: CGPoint(x: right.x + 20, y: right.y), constrained: false, scale: 1)
        #expect(near(wider.tip(scale: 1)!, tip, 0.05))
    }

    @Test func aFlipTurnsItTheOtherWayAndATurnOfThePictureKeepsItsAngle() {
        let mark = box(CGRect(x: 10, y: 10, width: 60, height: 20), angle: 0.3)
        let flip = PictureMapping(affine: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 200, ty: 0), operation: .flipHorizontally, lengthFactor: 1)
        #expect(mark.mapped(by: flip, scale: 1).rotation == -0.3)
        let turn = PictureMapping(affine: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 100, ty: 0), operation: .rotateRight, lengthFactor: 1)
        let turned = mark.mapped(by: turn, scale: 1)
        #expect(turned.rotation == 0.3)
        // Its frame's sides swap, which is a quarter turn of the box: with its own turn, it is turned with the picture.
        guard case .rectangle(let frame) = turned.shape else { Issue.record("Not a box"); return }
        #expect(frame.rect.size == CGSize(width: 20, height: 60))
    }

    @Test func theTurnIsKeptInTheFileOnlyWhenThereIsOne() throws {
        let upright = try JSONEncoder().encode(box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(!(String(data: upright, encoding: .utf8) ?? "").contains("rotation"))
        let turned = box(CGRect(x: 0, y: 0, width: 10, height: 10), angle: 1.25)
        let decoded = try JSONDecoder().decode(Annotation.self, from: try JSONEncoder().encode(turned))
        #expect(decoded == turned)
        // A turn on a mark that never turns (a line) is ignored.
        let line = Annotation(shape: .line(Line(start: .zero, end: CGPoint(x: 10, y: 0))), style: Style(), rotation: 1)
        #expect(!line.isTurned && line.bounds(scale: 1) == Annotation(shape: line.shape, style: line.style).bounds(scale: 1))
    }

    @Test func aTurnedMarkIsDrawnTurned() throws {
        let context = try #require(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.translateBy(x: 0, y: 200)
        context.scaleBy(x: 1, y: -1)
        // 120 × 20 about (100, 100), stood on its end.
        let mark = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 90, width: 120, height: 20), filled: true)), style: Style(color: .red, lineWidth: 2, shadow: false), rotation: .pi / 2)
        AnnotationRenderer.draw(mark, in: context, scale: 1)
        let image = try #require(context.makeImage())
        let data = try #require(image.dataProvider?.data as Data?)
        func isWhite(_ x: Int, _ y: Int) -> Bool {
            let offset = y * image.bytesPerRow + x * 4
            return data[offset] > 240 && data[offset + 1] > 240 && data[offset + 2] > 240
        }
        #expect(!isWhite(100, 50) && !isWhite(100, 150))
        #expect(isWhite(40, 100) && isWhite(160, 100))
    }

    /// Text, a bubble, and a combined image export turned, the same every time.
    @Test func turnedTextAndImagesExportTurnedAndAlike() throws {
        func solid(_ width: Int, _ height: Int, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        let base = try solid(400, 300, 1, 1, 1)
        let name = try PictureStore.shared.add(try solid(120, 40, 0, 0, 1))
        var document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300), scale: 1)
        document.items = [
            // 120 × 40 about (300, 150), stood on its end.
            Annotation(shape: .image(PlacedImage(rect: CGRect(x: 240, y: 130, width: 120, height: 40), name: name)), style: Style(shadow: false), rotation: .pi / 2),
            Annotation(shape: .text(TextBlock(origin: CGPoint(x: 30, y: 40), string: "Turned label", fontSize: 24, look: .label)), style: Style(color: .red, shadow: false), rotation: -.pi / 8),
            Annotation(shape: .text(TextBlock(origin: CGPoint(x: 40, y: 170), string: "Bubble", fontSize: 22, look: .bubble, tail: CGPoint(x: 200, y: 280))), style: Style(color: .blue, shadow: false), rotation: .pi / 10),
        ]
        let first = try #require(AnnotationRenderer.flatten(document, base: base))
        let second = try #require(AnnotationRenderer.flatten(document, base: base))
        let one = try #require(first.dataProvider?.data as Data?), two = try #require(second.dataProvider?.data as Data?)
        #expect(one == two)
        func color(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = y * first.bytesPerRow + x * 4
            return (one[offset], one[offset + 1], one[offset + 2])
        }
        func isWhite(_ x: Int, _ y: Int) -> Bool { let c = color(x, y); return c.0 > 240 && c.1 > 240 && c.2 > 240 }
        // The image runs up and down, not across.
        #expect(!isWhite(300, 100) && !isWhite(300, 200))
        #expect(isWhite(250, 150) && isWhite(350, 150))
        // The label turned back a little: its upright plate's bottom right corner is left, its turned one caught.
        let label = document.items[1]
        let upright = label.upright(scale: 1).bounds(scale: 1)
        let corner = CGPoint(x: upright.maxX - 3, y: upright.maxY - 3)
        #expect(!label.contains(corner, tolerance: 0, scale: 1))
        #expect(label.contains(Annotation.turn(corner, about: upright.middle, by: label.angle), tolerance: 0, scale: 1))
        // The bubble's tip is where it points.
        #expect(near(document.items[2].tip(scale: 1)!, CGPoint(x: 200, y: 280), 0.01))
        if let folder = ProcessInfo.processInfo.environment["OMS_ROTATION_RENDER"],
           let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder).appendingPathComponent("turned.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, first, nil)
            CGImageDestinationFinalize(destination)
        }
    }

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

    @Test func theKnobTurnsTheSelectedMarkInStepsWithShiftAsOneUndoStep() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        session.undoManager.groupsByEvent = false
        #expect(canvas.zoom == 1)
        let mark = box(CGRect(x: 150, y: 100, width: 100, height: 40))
        session.undoManager.beginUndoGrouping()
        var document = session.document
        document.items = [mark]
        session.commit(document, actionName: "Add")
        session.undoManager.endUndoGrouping()
        session.select([mark.id])
        // The knob stands 22 points above the middle of the frame's top; dragged round to the right of the middle,
        // a little past a quarter turn, Shift brings it to the quarter.
        let frame = mark.bounds(scale: 1)
        let knob = CGPoint(x: frame.midX, y: frame.minY - AnnotationCanvasView.knobReach)
        try drag(canvas, in: window, session: session, from: knob, to: CGPoint(x: frame.midX + 80, y: frame.midY + 6), shift: true)
        let turned = try #require(session.document.item(mark.id))
        #expect(abs((turned.rotation ?? 0) - .pi / 2) < 1e-9)
        #expect(session.undoManager.undoActionName == "Rotate")
        // Its middle stays.
        #expect(near(turned.bounds(scale: 1).middle, frame.middle, 0.01))

        session.undoManager.beginUndoGrouping()
        canvas.straightenSelection(nil)
        session.undoManager.endUndoGrouping()
        #expect(session.undoManager.undoActionName == "Straighten")
        #expect(session.document.item(mark.id)?.rotation == nil)
        canvas.undo(nil)
        #expect(abs((session.document.item(mark.id)?.rotation ?? 0) - .pi / 2) < 1e-9)
        canvas.undo(nil)
        #expect(session.document.item(mark.id)?.rotation == nil)
    }

    @Test func aTurnedTextGrowsFromItsFirstCornerAsItIsTyped() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        let block = TextBlock(origin: CGPoint(x: 120, y: 80), string: "Hi", fontSize: 20, look: .label)
        let mark = Annotation(shape: .text(block), style: Style(), rotation: .pi / 4)
        var document = session.document
        document.items = [mark]
        session.commit(document, actionName: "Add")
        let corner = Annotation.turn(block.origin, about: mark.pivot(scale: 1), by: mark.angle)
        canvas.beginEditing(mark.id, isNew: false)
        let field = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        field.string = "Hi there, a longer line"
        canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        canvas.endEditing()
        let typed = try #require(session.document.item(mark.id))
        guard case .text(let grown) = typed.shape else { Issue.record("Not text"); return }
        #expect(grown.string == "Hi there, a longer line")
        #expect(typed.rotation == .pi / 4)
        #expect(near(Annotation.turn(grown.origin, about: typed.pivot(scale: 1), by: typed.angle), corner, 0.01))
    }

    @Test func onlyMarksThatTurnHaveAKnob() throws {
        let (canvas, session, window) = try makeCanvas()
        defer { window.close() }
        let arrow = Annotation(shape: .arrow(Arrow(start: CGPoint(x: 100, y: 120), end: CGPoint(x: 300, y: 120))), style: Style(lineWidth: 4, shadow: false))
        var document = session.document
        document.items = [arrow]
        session.commit(document, actionName: "Add")
        session.select([arrow.id])
        // Where a knob would stand above it, a press starts a marquee instead of turning anything.
        let frame = arrow.bounds(scale: 1)
        try drag(canvas, in: window, session: session, from: CGPoint(x: frame.midX, y: frame.minY - AnnotationCanvasView.knobReach), to: CGPoint(x: frame.maxX + 40, y: frame.midY))
        #expect(session.document.item(arrow.id)?.rotation == nil)
    }
}
