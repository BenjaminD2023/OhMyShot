import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Three lines of text, 30 px tall, 20 px apart.
nonisolated private let lineA = TextLine(rect: CGRect(x: 100, y: 100, width: 400, height: 30), words: [100...160, 175...240, 255...330, 345...500])
nonisolated private let lineB = TextLine(rect: CGRect(x: 100, y: 150, width: 300, height: 30), words: [100...150, 165...230, 245...400])
nonisolated private let lineC = TextLine(rect: CGRect(x: 100, y: 200, width: 350, height: 30), words: [100...200, 215...450])
nonisolated private let lines = [lineA, lineB, lineC]

struct TextSnappingTests {
    private func rects(_ points: [CGPoint]) -> [CGRect]? {
        guard let first = points.first, var snapping = TextSnapping(at: first, lines: lines) else { return nil }
        points.dropFirst().forEach { snapping.extend(to: $0) }
        return snapping.rects
    }

    @Test func aClickOnAWordHighlightsTheWord() {
        // A little taller than the text, and wider by as much as the gaps allow: never past halfway to the
        // next word, so the band stops cleanly between two.
        #expect(rects([CGPoint(x: 200, y: 115)]) == [CGRect(x: 169, y: 97, width: 77, height: 36)])
    }

    @Test func aDragAlongALineCoversWholeWords() {
        // From the middle of the first word to the middle of the third: all three, the first one's start
        // padded fully as nothing is before it.
        #expect(rects([CGPoint(x: 120, y: 115), CGPoint(x: 300, y: 118)]) == [CGRect(x: 94, y: 97, width: 242, height: 36)])
        // Past the line's end: the last word, and no farther.
        #expect(rects([CGPoint(x: 480, y: 115), CGPoint(x: 700, y: 115)]) == [CGRect(x: 339, y: 97, width: 167, height: 36)])
    }

    @Test func aDragStartedOffTextDoesNotSnap() {
        #expect(rects([CGPoint(x: 200, y: 60)]) == nil)
        #expect(rects([CGPoint(x: 700, y: 115)]) == nil)
        // Just above the text still starts on it.
        #expect(rects([CGPoint(x: 200, y: 92)])?.count == 1)
    }

    @Test func aWaveringHandStaysOnItsLine() {
        // Down into the gap, short of its middle, and back: only the first line.
        let found = rects([CGPoint(x: 120, y: 115), CGPoint(x: 250, y: 138), CGPoint(x: 400, y: 120)])
        #expect(found == [CGRect(x: 94, y: 97, width: 412, height: 36)])
    }

    @Test func draggingDownFromALinesEndCarriesOnAlongTheNext() {
        // From the third word to the end of the first line, then down: the rest of the first line, and
        // the second from its start to the word under the pointer, as a text selection would.
        let down = rects([CGPoint(x: 300, y: 115), CGPoint(x: 480, y: 115), CGPoint(x: 200, y: 165)])
        #expect(down == [CGRect(x: 249, y: 97, width: 257, height: 36), CGRect(x: 94, y: 147, width: 142, height: 36)])
        // The same the other way up.
        #expect(rects([CGPoint(x: 200, y: 165), CGPoint(x: 300, y: 115)]) == down)
        // Past the second line's end: all of it.
        let whole = rects([CGPoint(x: 120, y: 115), CGPoint(x: 480, y: 165)])
        #expect(whole == [CGRect(x: 94, y: 97, width: 412, height: 36), CGRect(x: 94, y: 147, width: 312, height: 36)])
    }

    @Test func linesBetweenAreHighlightedWhole() {
        let found = rects([CGPoint(x: 120, y: 115), CGPoint(x: 120, y: 215)])
        #expect(found == [
            CGRect(x: 94, y: 97, width: 412, height: 36),
            CGRect(x: 94, y: 147, width: 312, height: 36),
            CGRect(x: 94, y: 197, width: 112, height: 36),
        ])
    }

    @Test func itKeepsToTheColumnItStartedIn() throws {
        // A line in the column beside, on the second line's row: the pointer over it reaches the second
        // line, not it.
        let beside = TextLine(rect: CGRect(x: 700, y: 150, width: 200, height: 30), words: [700...780, 795...900])
        var snapping = try #require(TextSnapping(at: CGPoint(x: 120, y: 115), lines: lines + [beside]))
        #expect(snapping.column == [0, 1, 2])
        snapping.extend(to: CGPoint(x: 800, y: 165))
        #expect(snapping.rects == [CGRect(x: 94, y: 97, width: 412, height: 36), CGRect(x: 94, y: 147, width: 312, height: 36)])
    }

    @Test func bandsOfCloseLinesMeetWithoutOverlapping() throws {
        // Lines 6 px apart: each band's padding gives way at the middle of the gap.
        let close = [
            TextLine(rect: CGRect(x: 100, y: 100, width: 300, height: 30), words: [100...200, 215...400]),
            TextLine(rect: CGRect(x: 100, y: 136, width: 300, height: 30), words: [100...200, 215...400]),
        ]
        var snapping = try #require(TextSnapping(at: CGPoint(x: 150, y: 115), lines: close))
        snapping.extend(to: CGPoint(x: 150, y: 151))
        #expect(snapping.rects.map(\.minY) == [97, 133])
        #expect(snapping.rects.map(\.maxY) == [133, 169])
    }
}

@MainActor
@Suite(.serialized)
struct TextHighlightCanvasTests {
    /// A session whose capture reads as holding `found`, counting each read; each read takes `delay`.
    private func makeSession(reads: ReadCounter = ReadCounter(), delay: Duration = .zero, found: [TextLine] = lines) -> AnnotationSession {
        let context = CGContext(
            data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        let session = AnnotationSession(image: context.makeImage()!, scale: 1, tool: .arrow)
        session.undoManager.groupsByEvent = false
        session.textReader = { _ in
            CaptureReading(textLines: {
                await reads.increment()
                if delay > .zero { try? await Task.sleep(for: delay) }
                return found
            })
        }
        return session
    }

    private func waitForLines(_ session: AnnotationSession) async {
        for _ in 0..<100 where session.isFindingTextLines || session.textLines.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The canvas on `session`, filling an unshown window at one view point per pixel.
    private func makeCanvas(_ session: AnnotationSession) -> (canvas: AnnotationCanvasView, window: NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, on canvas: AnnotationCanvasView, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: canvas.windowPoint(forDocument: point), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: canvas.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func drag(on canvas: AnnotationCanvasView, _ points: [CGPoint], modifiers: NSEvent.ModifierFlags = []) {
        canvas.session.undoManager.beginUndoGrouping()
        canvas.mouseDown(with: mouse(.leftMouseDown, at: points[0], on: canvas, modifiers: modifiers))
        for point in points.dropFirst() { canvas.mouseDragged(with: mouse(.leftMouseDragged, at: point, on: canvas, modifiers: modifiers)) }
        canvas.mouseUp(with: mouse(.leftMouseUp, at: points.last!, on: canvas, modifiers: modifiers))
        canvas.session.undoManager.endUndoGrouping()
    }

    @Test func theCaptureIsReadOnceTheHighlighterIsInHand() async {
        let reads = ReadCounter()
        let session = makeSession(reads: reads)
        #expect(!session.isReadingForTool)
        session.tool = .highlighter
        #expect(session.isReadingForTool)
        await waitForLines(session)
        #expect(session.textLines == lines)
        #expect(!session.isReadingForTool)
        session.tool = .arrow
        session.tool = .highlighter
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await reads.value == 1)
    }

    @Test func aReadingDroppedMidwayReadsAgainTheNextTime() async {
        let reads = ReadCounter()
        let session = makeSession(reads: reads, delay: .milliseconds(150))
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        #expect(session.isFindingTextLines)
        canvas.removeFromSuperview()
        #expect(!session.isFindingTextLines)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(session.textLines.isEmpty)
        session.tool = .arrow
        session.tool = .highlighter
        await waitForLines(session)
        #expect(session.textLines == lines)
        #expect(await reads.value == 2)
    }

    @Test func aDragOnTextSnapsToIt() async throws {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        await waitForLines(session)
        drag(on: canvas, [CGPoint(x: 120, y: 115), CGPoint(x: 200, y: 117), CGPoint(x: 300, y: 118)])
        let item = try #require(session.document.items.first)
        #expect(item.shape == .textHighlight(TextHighlight(rects: [CGRect(x: 94, y: 97, width: 242, height: 36)])))
        #expect(item.style.color == session.settings(for: .highlighter).color)
        #expect(session.undoManager.undoActionName == "Highlight")
        // Its height is the text's: the size control means nothing for it.
        session.select([item.id])
        #expect(!session.sizeApplies)
        #expect(AnnotationSession.tool(for: item) == .highlighter)
    }

    @Test func aWordHighlightedTwiceIsHighlightedOnce() async {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        await waitForLines(session)
        // A double click on a word: the second click adds nothing over the first.
        drag(on: canvas, [CGPoint(x: 200, y: 115)])
        drag(on: canvas, [CGPoint(x: 200, y: 115)])
        #expect(session.document.items.count == 1)
        // Another word still gets its own.
        drag(on: canvas, [CGPoint(x: 300, y: 115)])
        #expect(session.document.items.count == 2)
    }

    @Test func highlightingOverAHighlightExtendsIt() async throws {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        // Tool settings are kept between sessions: start from marker yellow, and leave it so.
        session.changeSettings("Color") { $0.color = .marker }
        defer { session.changeSettings("Color") { $0.color = .marker } }
        await waitForLines(session)
        drag(on: canvas, [CGPoint(x: 120, y: 115), CGPoint(x: 200, y: 115)])
        let first = try #require(session.document.items.first)
        // On from the second word to the fourth: one band from the first word to the fourth, in the first
        // highlight's place, as one step.
        drag(on: canvas, [CGPoint(x: 200, y: 117), CGPoint(x: 400, y: 117)])
        #expect(session.document.items.count == 1)
        #expect(session.document.items.first?.id == first.id)
        #expect(session.document.items.first?.shape == .textHighlight(TextHighlight(rects: [CGRect(x: 94, y: 97, width: 412, height: 36)])))
        session.undoManager.undo()
        #expect(session.document.items == [first])
        // A click on a word inside it changes nothing.
        drag(on: canvas, [CGPoint(x: 150, y: 115)])
        #expect(session.document.items == [first])
        // In another color, it is a highlight of its own.
        session.changeSettings("Color") { $0.color = .green }
        drag(on: canvas, [CGPoint(x: 200, y: 117), CGPoint(x: 400, y: 117)])
        #expect(session.document.items.count == 2)
    }

    @Test func highlightsJoinedAcrossAMarkKeepTheUppermostPlace() async throws {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        await waitForLines(session)
        // A highlight under an arrow and one over it, then a stroke along the line joining both.
        drag(on: canvas, [CGPoint(x: 120, y: 115)])
        session.undoManager.beginUndoGrouping()
        var document = session.document
        document.items.append(Annotation(shape: .arrow(Arrow(start: CGPoint(x: 150, y: 60), end: CGPoint(x: 300, y: 125))), style: Style()))
        session.commit(document, actionName: "Add Arrow")
        session.undoManager.endUndoGrouping()
        drag(on: canvas, [CGPoint(x: 300, y: 115)])
        let upper = try #require(session.document.items.last)
        drag(on: canvas, [CGPoint(x: 120, y: 117), CGPoint(x: 300, y: 117)])
        // The joined highlight is where the upper one was, still over the arrow.
        #expect(session.document.items.count == 2)
        if case .arrow = session.document.items.first?.shape {} else { Issue.record("the arrow is not under the highlight") }
        #expect(session.document.items.last?.id == upper.id)
        #expect(session.document.items.last?.shape == .textHighlight(TextHighlight(rects: [CGRect(x: 94, y: 97, width: 242, height: 36)])))
    }

    @Test func aPictureCombinedAfterReadingIsReadAgain() async {
        let reads = ReadCounter()
        let session = makeSession(reads: reads)
        session.tool = .highlighter
        await waitForLines(session)
        var document = session.document
        document.items.append(Annotation(shape: .image(PlacedImage(rect: CGRect(x: 100, y: 100, width: 50, height: 50), name: "absent.png")), style: Style(color: .black, lineWidth: 0, shadow: false)))
        session.undoManager.beginUndoGrouping()
        session.commit(document, actionName: "Add Image")
        session.undoManager.endUndoGrouping()
        await waitForLines(session)
        #expect(await reads.value == 2)
        #expect(session.textLines == lines)
        // Undone, the picture is gone again: read once more.
        session.undoManager.undo()
        await waitForLines(session)
        #expect(await reads.value == 3)
    }

    @Test func aPressOnTheNextLineStartsAHighlightThere() async throws {
        // Lines 6 px apart, as in code: the first line's highlight hugs the second.
        let tight = [
            TextLine(rect: CGRect(x: 100, y: 100, width: 300, height: 30), words: [100...200, 215...400]),
            TextLine(rect: CGRect(x: 100, y: 136, width: 300, height: 30), words: [100...200, 215...400]),
        ]
        let session = makeSession(found: tight)
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        await waitForLines(session)
        drag(on: canvas, [CGPoint(x: 150, y: 115), CGPoint(x: 300, y: 115)])
        let first = try #require(session.document.items.first)
        // Within reach of the first highlight's lower edge, and on the second line: a new highlight there,
        // the first one left where it is.
        drag(on: canvas, [CGPoint(x: 150, y: 137), CGPoint(x: 300, y: 145)])
        #expect(session.document.items.count == 2)
        #expect(session.document.items.first == first)
        guard case .textHighlight(let second) = session.document.items.last?.shape else {
            Issue.record("no second highlight")
            return
        }
        #expect(second.rects.map(\.minY) == [133])
    }

    @Test func offTextOrWithCommandItDrawsFreely() async {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        await waitForLines(session)
        drag(on: canvas, [CGPoint(x: 120, y: 40), CGPoint(x: 300, y: 50)])
        drag(on: canvas, [CGPoint(x: 120, y: 115), CGPoint(x: 300, y: 118)], modifiers: .command)
        #expect(session.document.items.count == 2)
        #expect(session.document.items.allSatisfy { if case .highlighter = $0.shape { true } else { false } })
        #expect(session.undoManager.undoActionName == "Draw")
    }

    @Test func commandFreesTheStrokeMidDrag() async throws {
        let session = makeSession()
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        await waitForLines(session)
        session.undoManager.beginUndoGrouping()
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 120, y: 115), on: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 118), on: canvas))
        func flags(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
            )!
        }
        canvas.flagsChanged(with: flags(.command))
        guard case .highlighter(let stroke) = session.document.items.first?.shape else {
            Issue.record("not freed: \(String(describing: session.document.items.first?.shape))")
            return
        }
        #expect(stroke.points.count == 2)
        canvas.flagsChanged(with: flags([]))
        if case .textHighlight = session.document.items.first?.shape {} else { Issue.record("not snapped again") }
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 300, y: 118), on: canvas))
        session.undoManager.endUndoGrouping()
        #expect(session.document.items.count == 1)
    }

    @Test func aStrokeBeforeTheLinesComeInIsDrawnFreely() async {
        let session = makeSession(delay: .milliseconds(200))
        let (canvas, window) = makeCanvas(session)
        defer { window.close() }
        session.tool = .highlighter
        drag(on: canvas, [CGPoint(x: 120, y: 115), CGPoint(x: 300, y: 118)])
        if case .highlighter = session.document.items.first?.shape {} else { Issue.record("snapped before reading") }
        await waitForLines(session)
        // Not snapped afterwards either.
        if case .highlighter = session.document.items.first?.shape {} else { Issue.record("snapped afterwards") }
    }
}

struct TextHighlightMarkTests {
    private let highlight = Annotation(
        shape: .textHighlight(TextHighlight(rects: [CGRect(x: 10, y: 20, width: 100, height: 30), CGRect(x: 10, y: 45, width: 60, height: 30)])),
        style: Style(color: .marker, lineWidth: 18, shadow: false)
    )

    @Test func itRoundTripsThroughJSON() throws {
        let document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 2, items: [highlight])
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
    }

    @Test func itMovesWholeAndHasNoHandles() {
        let moved = highlight.translated(by: CGSize(width: 5, height: -5))
        #expect(moved.shape == .textHighlight(TextHighlight(rects: [CGRect(x: 15, y: 15, width: 100, height: 30), CGRect(x: 15, y: 40, width: 60, height: 30)])))
        #expect(highlight.handles(scale: 2).isEmpty)
        #expect(highlight.bounds(scale: 2) == CGRect(x: 10, y: 20, width: 100, height: 55))
        #expect(highlight.contains(CGPoint(x: 60, y: 30), tolerance: 2, scale: 2))
        #expect(!highlight.contains(CGPoint(x: 100, y: 70), tolerance: 2, scale: 2))
        #expect(!highlight.castsShadow)
        #expect(highlight.multiplies)
    }

    @Test func overlappingBandsDarkenOnceAndCornersAreRounded() {
        let context = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let base = context.makeImage()!
        let document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1, items: [highlight])
        let pixels = Pixels(AnnotationRenderer.flatten(document, base: base)!)
        // Where the two lines' bands meet, the yellow is the same as where one band lies.
        let once = pixels[40, 30], twice = pixels[40, 47]
        #expect(once.r == twice.r && once.g == twice.g && once.b == twice.b)
        #expect(once.b < 120)
        // A rounded corner leaves its very corner clear.
        #expect(pixels[10, 20].b > 250)
    }
}

extension TextHighlightCanvasTests {
    @Test func theHighlighterSnapsInPlaceToo() async throws {
        // A line inside the selection (80, 40, 100, 60) pt of a 400 × 300 pt display at 2×, in its pixels.
        let line = TextLine(rect: CGRect(x: 170, y: 100, width: 160, height: 24), words: [170...220, 232...280, 292...330])
        let context = CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let annotator = InPlaceAnnotationView(
            frame: context.makeImage()!, scale: 2, size: CGSize(width: 400, height: 300), selection: CGRect(x: 80, y: 40, width: 100, height: 60),
            actions: .init(copy: { _ in }, save: { _ in }, openInEditor: { _ in }, cancel: {})
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        annotator.frame = window.contentView!.bounds
        window.contentView!.addSubview(annotator)
        annotator.layoutSubtreeIfNeeded()
        annotator.session.textReader = { _ in CaptureReading(textLines: { [line] }) }
        annotator.session.tool = .highlighter
        for _ in 0..<100 where annotator.session.textLines.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // From the first word to the second, in the display's points.
        annotator.simulateDrag(from: CGPoint(x: 90, y: 56), to: CGPoint(x: 125, y: 56))
        guard case .textHighlight(let highlight) = annotator.session.document.items.first?.shape else {
            Issue.record("not snapped: \(String(describing: annotator.session.document.items.first?.shape))")
            return
        }
        // Over the first two words, stopping halfway to the third.
        #expect(highlight.rects == [CGRect(x: 165, y: 98, width: 120, height: 28)], "\(highlight.rects)")
    }
}

extension TextHighlightCanvasTests {
    @Test func aSmallAreaOfALargeScreenIsReadAlone() async throws {
        // A 2000 × 1000 display with a 200 × 100 selection, as in place: read are the selection and 160 px
        // around it, and what is found there lands where it is in the whole picture.
        let sizes = SizeRecorder()
        let context = CGContext(
            data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let session = AnnotationSession(image: context.makeImage()!, scale: 2, tool: .arrow)
        session.textReader = { image in
            CaptureReading(textLines: {
                await sizes.record(CGSize(width: image.width, height: image.height))
                return [TextLine(rect: CGRect(x: 170, y: 170, width: 100, height: 20), words: [170...270])]
            })
        }
        var document = session.document
        document.canvas = CGRect(x: 1000, y: 500, width: 200, height: 100)
        session.commit(document, actionName: "Crop")
        session.tool = .highlighter
        for _ in 0..<100 where session.textLines.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await sizes.value == CGSize(width: 520, height: 420))
        #expect(session.textLines.first?.rect == CGRect(x: 1010, y: 510, width: 100, height: 20))
        #expect(session.textLines.first?.words == [1010...1110])
    }
}

/// Remembers a size from any task.
actor SizeRecorder {
    private(set) var value: CGSize?
    func record(_ size: CGSize) { value = size }
}
