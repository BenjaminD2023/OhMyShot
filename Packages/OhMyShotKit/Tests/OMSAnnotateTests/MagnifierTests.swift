import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// What the redactions in these tests cover, in pixels from the top left.
private let secretRect = CGRect(x: 40, y: 50, width: 30, height: 25)

/// A noisy capture, every pixel unlike its neighbours, so a lens showing the wrong pixels shows it. `secret` changes
/// only what lies under `secretRect`.
private func noise(width: Int = 200, height: Int = 120, secret: Bool = false) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for y in 0..<height {
        for x in 0..<width {
            let hidden = secret && secretRect.contains(CGPoint(x: x, y: y))
            let red = CGFloat((x * 37 + y * 11 + (hidden ? 128 : 0)) % 256) / 255
            context.setFillColor(red: red, green: CGFloat((x * y + 7 * y) % 256) / 255, blue: CGFloat((x * 5 + y * 23) % 256) / 255, alpha: 1)
            // Core Graphics is y up: the row y from the top.
            context.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
        }
    }
    return context.makeImage()!
}

private func close(_ a: (r: Int, g: Int, b: Int, a: Int), _ b: (r: Int, g: Int, b: Int, a: Int), within tolerance: Int = 2) -> Bool {
    abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance && abs(a.a - b.a) <= tolerance
}

/// The pixels well inside a lens, clear of its ring, each with the pixel of the picture it should show: the
/// magnified spot plus its offset from the lens's middle over the zoom.
private func lensSamples(of magnifier: Magnifier) -> [(lens: (x: Int, y: Int), source: (x: Int, y: Int))] {
    let zoom = CGFloat(magnifier.zoom.rawValue)
    let inner = magnifier.radius - 6
    var samples: [(lens: (x: Int, y: Int), source: (x: Int, y: Int))] = []
    for y in Int(magnifier.center.y - inner)...Int(magnifier.center.y + inner) {
        for x in Int(magnifier.center.x - inner)...Int(magnifier.center.x + inner) {
            let dx = CGFloat(x) + 0.5 - magnifier.center.x, dy = CGFloat(y) + 0.5 - magnifier.center.y
            guard hypot(dx, dy) < inner else { continue }
            samples.append(((x, y), (Int((magnifier.source.x + dx / zoom).rounded(.down)), Int((magnifier.source.y + dy / zoom).rounded(.down)))))
        }
    }
    return samples
}

/// The magnifier mark: made, moved, kept in a project, and drawn on the canvas and in an export, where its lens
/// shows the picture with every redaction on it.
struct MagnifierTests {
    private let scratch = ScratchDefaults()

    // MARK: Making one

    @Test func aClickPutsTheLensOverWhatItMagnifiesAtTheLoupesSize() throws {
        let mark = try #require(AnnotationTool.magnifier.mark(
            from: CGPoint(x: 100, y: 80), to: CGPoint(x: 101, y: 80), constrained: false, settings: ToolSettings(zoom: .three), scale: 2
        ))
        guard case .magnifier(let magnifier) = mark.shape else { Issue.record("Not a magnifier: \(mark.shape)"); return }
        #expect(magnifier.source == CGPoint(x: 100, y: 80))
        #expect(magnifier.center == magnifier.source)
        // 120 pt across, as the overlay's loupe is, in a Retina capture's pixels.
        #expect(magnifier.radius == 120)
        #expect(magnifier.zoom == .three)
        #expect(!magnifier.isDetached)
        #expect(!mark.castsShadow)
    }

    @Test func draggingAwayTakesTheLensClearOfWhatItMagnifies() throws {
        let start = CGPoint(x: 50, y: 60)
        let mark = try #require(AnnotationTool.magnifier.mark(
            from: start, to: CGPoint(x: 250, y: 60), constrained: false, settings: ToolSettings(zoom: .two), scale: 1
        ))
        guard case .magnifier(let magnifier) = mark.shape else { Issue.record("Not a magnifier"); return }
        #expect(magnifier.source == start)
        #expect(magnifier.center == CGPoint(x: 250, y: 60))
        #expect(magnifier.isDetached)
        // The ring around what is magnified is a handle of its own; the lens is sized by its corners.
        let handles = mark.handles(scale: 1)
        #expect(handles.contains { $0.handle == .start && $0.point == start })
        #expect(handles.filter { $0.handle != .start }.count == 4)
        #expect(mark.drawingBounds(scale: 1).contains(magnifier.sourceRect))
        #expect(mark.contains(CGPoint(x: 250, y: 60), tolerance: 0, scale: 1))
        #expect(!mark.contains(CGPoint(x: 150, y: 60), tolerance: 0, scale: 1))
    }

    @Test func movingTheLensLeavesWhatItMagnifiesAndSettlesBackOverIt() throws {
        let mark = Annotation(shape: .magnifier(Magnifier(source: CGPoint(x: 100, y: 100), radius: 40, zoom: .two)), style: Style())
        #expect(mark.handles(scale: 1).allSatisfy { $0.handle != .start })
        let moved = mark.dragged(by: CGSize(width: 150, height: 0))
        guard case .magnifier(let away) = moved.shape else { Issue.record("Not a magnifier"); return }
        #expect(away.source == CGPoint(x: 100, y: 100))
        #expect(away.center == CGPoint(x: 250, y: 100))
        // Dropped close to it again, the lens stands over what it magnifies.
        guard case .magnifier(let back) = moved.dragged(by: CGSize(width: -145, height: 3)).shape else { Issue.record("Not a magnifier"); return }
        #expect(back.center == back.source)
        // Moved with the arrow keys or with other marks, it moves whole.
        guard case .magnifier(let nudged) = moved.translated(by: CGSize(width: 1, height: 2)).shape else { Issue.record("Not a magnifier"); return }
        #expect(nudged.source == CGPoint(x: 101, y: 102))
        #expect(nudged.center == CGPoint(x: 251, y: 102))
        // The ring's handle moves what is magnified; a corner sizes the lens about its middle.
        guard case .magnifier(let aimed) = moved.moving(.start, to: CGPoint(x: 90, y: 120), constrained: false, scale: 1).shape else {
            Issue.record("Not a magnifier"); return
        }
        #expect(aimed.source == CGPoint(x: 90, y: 120))
        #expect(aimed.center == away.center)
        guard case .magnifier(let sized) = moved.moving(.topLeft, to: CGPoint(x: 190, y: 70), constrained: false, scale: 1).shape else {
            Issue.record("Not a magnifier"); return
        }
        #expect(sized.radius == 60)
        #expect(sized.center == away.center)
    }

    @Test func theZoomIsAStyleSettingKeptWithTheTool() throws {
        let mark = Annotation(shape: .magnifier(Magnifier(source: .zero, radius: 40, zoom: .two)), style: Style())
        var settings = ToolSettings.defaults(for: .magnifier)
        settings.zoom = .four
        guard case .magnifier(let restyled) = settings.applied(to: mark).shape else { Issue.record("Not a magnifier"); return }
        #expect(restyled.zoom == .four)
        var adopted = ToolSettings()
        adopted.adopt(settings.applied(to: mark))
        #expect(adopted.zoom == .four)
        // Settings kept before there were magnifiers still read, at 2×.
        var kept = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ToolSettings())) as? [String: Any])
        kept["magnifierZoom"] = nil
        let read = try JSONDecoder().decode(ToolSettings.self, from: JSONSerialization.data(withJSONObject: kept))
        #expect(read.zoom == .two)
    }

    @Test func turningOrResizingThePictureKeepsTheLensOverTheSameSpot() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1)
        document.items = [Annotation(shape: .magnifier(Magnifier(source: CGPoint(x: 20, y: 30), center: CGPoint(x: 150, y: 50), radius: 30)), style: Style())]
        let turned = try #require(document.applying(.rotateRight))
        guard case .magnifier(let magnifier) = turned.items.first?.shape else { Issue.record("Not a magnifier"); return }
        #expect(magnifier.source == CGPoint(x: 70, y: 20))
        #expect(magnifier.center == CGPoint(x: 50, y: 150))
        #expect(magnifier.radius == 30)
        let halved = try #require(document.applying(.resize(to: CGSize(width: 100, height: 50))))
        guard case .magnifier(let small) = halved.items.first?.shape else { Issue.record("Not a magnifier"); return }
        #expect(small.source == CGPoint(x: 10, y: 15))
        #expect(small.radius == 15)
    }

    // MARK: The project file

    @Test func onlyAProjectWithAMagnifierNeedsFormatFour() throws {
        func version(of document: AnnotationDocument) throws -> Int? {
            let data = try AnnotationProject(capture: noise(width: 8, height: 4), document: document).data()
            return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["version"] as? Int
        }
        var document = AnnotationDocument(pixelSize: CGSize(width: 8, height: 4), scale: 1)
        document.items = [Annotation(shape: .redaction(Redaction(rect: CGRect(x: 0, y: 0, width: 4, height: 2), method: .blur)), style: Style())]
        #expect(try version(of: document) == 1)
        let magnifier = Magnifier(source: CGPoint(x: 2, y: 2), center: CGPoint(x: 6, y: 1), radius: 3, zoom: .four)
        document.items.append(Annotation(shape: .magnifier(magnifier), style: Style()))
        #expect(try version(of: document) == 4)
        let read = try AnnotationProject.read(AnnotationProject(capture: noise(width: 8, height: 4), document: document).data())
        #expect(read.document.items.last?.shape == .magnifier(magnifier))
    }

    // MARK: Exported

    @Test(arguments: Magnifier.Zoom.allCases)
    func theLensShowsThePictureUnderItLarger(zoom: Magnifier.Zoom) throws {
        let base = noise()
        let magnifier = Magnifier(source: CGPoint(x: 50, y: 60), center: CGPoint(x: 150, y: 60), radius: 30, zoom: zoom)
        let plain = AnnotationDocument(pixelSize: CGSize(width: 200, height: 120), scale: 1)
        var document = plain
        document.items = [Annotation(shape: .magnifier(magnifier), style: Style())]
        let output = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
        let picture = Pixels(try #require(AnnotationRenderer.flatten(plain, base: base)))
        var mismatches = 0
        for (lens, source) in lensSamples(of: magnifier) where !close(output[lens.x, lens.y], picture[source.x, source.y]) {
            mismatches += 1
        }
        #expect(mismatches == 0, "\(mismatches) lens pixels show the wrong part of the picture")
        // A white ring edges the lens.
        let rim = output[150, 60 - 30]
        #expect(rim.r > 230 && rim.g > 230 && rim.b > 230)
    }

    /// A lens shows every redaction as it is drawn on the picture, whether the redaction lies above it or below,
    /// so the pixels one hides never show in it: it matches the picture with its redactions, magnified.
    @Test(arguments: Redaction.Method.allCases, [false, true])
    func anExportedLensNeverShowsWhatARedactionHides(method: Redaction.Method, redactionAbove: Bool) throws {
        let lens = Magnifier(source: CGPoint(x: 55, y: 60), center: CGPoint(x: 150, y: 60), radius: 40, zoom: .two)
        let magnifier = Annotation(shape: .magnifier(lens), style: Style())
        let redaction = Annotation(shape: .redaction(Redaction(rect: secretRect, method: method)), style: Style(color: .black))
        var shown: [[UInt8]] = []
        for secret in [false, true] {
            let base = noise(secret: secret)
            let redacted = AnnotationDocument(pixelSize: CGSize(width: 200, height: 120), scale: 1, items: [redaction])
            var document = redacted
            document.items = redactionAbove ? [magnifier, redaction] : [redaction, magnifier]
            let output = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
            let picture = Pixels(try #require(AnnotationRenderer.flatten(redacted, base: base)))
            var mismatches = 0
            for (point, source) in lensSamples(of: lens) where !close(output[point.x, point.y], picture[source.x, source.y], within: 3) {
                mismatches += 1
            }
            #expect(mismatches == 0, "\(mismatches) lens pixels differ from the redacted picture")
            shown.append(output.region(lens.lensRect.insetBy(dx: 12, dy: 12)))
        }
        // A solid cover hides everything: what lies under it changes nothing the lens shows.
        if method == .solid { #expect(shown[0] == shown[1]) }
    }

    /// What a crop leaves out never shows in a lens, as it never shows in the picture.
    @Test func aLensShowsNothingACropLeavesOut() throws {
        let lens = Magnifier(source: CGPoint(x: 30, y: 60), center: CGPoint(x: 150, y: 60), radius: 30, zoom: .two)
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 120), scale: 1)
        document.items = [Annotation(shape: .magnifier(lens), style: Style())]
        // Kept from x 100 on: the lens stays, the spot it magnifies is cut off.
        document.canvas = CGRect(x: 100, y: 0, width: 100, height: 120)
        let output = Pixels(try #require(AnnotationRenderer.flatten(document, base: noise())))
        #expect(output.width == 100)
        var shown = 0
        for (point, _) in lensSamples(of: lens) where !close(output[point.x - 100, point.y], (255, 255, 255, 255)) {
            shown += 1
        }
        #expect(shown == 0, "\(shown) lens pixels show what the crop leaves out")
    }

    /// A spot the crop's edge runs through shows what the crop keeps of it, and only that.
    @Test func aLensShowsWhatACropKeepsOfItsSpot() throws {
        let lens = Magnifier(source: CGPoint(x: 100, y: 60), center: CGPoint(x: 150, y: 60), radius: 30, zoom: .two)
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 120), scale: 1)
        document.items = [Annotation(shape: .magnifier(lens), style: Style())]
        document.canvas = CGRect(x: 100, y: 0, width: 100, height: 120)
        let picture = Pixels(noise())
        let output = Pixels(try #require(AnnotationRenderer.flatten(document, base: noise())))
        var kept = 0, wrong = 0
        for (point, source) in lensSamples(of: lens) {
            let shown = output[point.x - 100, point.y]
            if source.x >= 100 {
                kept += 1
                if !close(shown, picture[source.x, source.y]) { wrong += 1 }
            } else if !close(shown, (255, 255, 255, 255)) {
                wrong += 1
            }
        }
        #expect(kept > 0)
        #expect(wrong == 0, "\(wrong) lens pixels show the wrong side of the crop")
    }

    // MARK: On the canvas

    @MainActor
    private func makeCanvas(base: CGImage, tool: AnnotationTool? = nil) throws -> (AnnotationCanvasView, AnnotationSession, NSWindow) {
        let session = AnnotationSession(image: base, scale: 1, tool: tool, defaults: scratch.make())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: base.width, height: base.height), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, session, window)
    }

    /// A press, a drag when `end` differs, and a release, at points in the capture's pixels.
    @MainActor
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

    /// A document opened with magnifiers in it, as one reopened from History is, shows what is under them at once.
    @MainActor
    @Test func aReopenedLensShowsThePictureAtOnce() throws {
        let magnifier = Annotation(shape: .magnifier(Magnifier(source: CGPoint(x: 55, y: 60), center: CGPoint(x: 150, y: 60), radius: 40)), style: Style())
        let document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 120), scale: 1, items: [magnifier])
        let session = AnnotationSession(image: noise(), scale: 1, document: document, tool: .select, defaults: scratch.make())
        let canvas = AnnotationCanvasView(session: session)
        #expect(canvas.markLayer(for: magnifier.id)?.lens != nil)
    }

    /// Dragged on its own, a magnifier moves its lens alone; dragged with other marks, it moves whole.
    @MainActor
    @Test func movedWithOtherMarksAMagnifierMovesWhole() throws {
        let (canvas, session, window) = try makeCanvas(base: noise(), tool: .select)
        defer { window.close() }
        let magnifier = Annotation(shape: .magnifier(Magnifier(source: CGPoint(x: 40, y: 40), center: CGPoint(x: 140, y: 60), radius: 30)), style: Style())
        let box = Annotation(shape: .rectangle(Box(rect: CGRect(x: 10, y: 90, width: 30, height: 20))), style: Style())
        var document = session.document
        document.items = [magnifier, box]
        session.commit(document, actionName: "Add")
        session.select([magnifier.id, box.id])
        try press(canvas, in: window, from: CGPoint(x: 140, y: 60), to: CGPoint(x: 150, y: 70))
        guard case .magnifier(let moved) = session.document.item(magnifier.id)?.shape else { Issue.record("The magnifier is gone"); return }
        #expect(moved.center == CGPoint(x: 150, y: 70))
        #expect(moved.source == CGPoint(x: 50, y: 50))
        #expect(session.document.item(box.id)?.shape == .rectangle(Box(rect: CGRect(x: 20, y: 100, width: 30, height: 20))))
    }

    @MainActor
    /// Given room to fit in, a lens takes the size that fits where it stands, never below the smallest and never moved
    /// from where it was put, and a drag takes it clear by that size.
    @Test func aLensGivenRoomFitsWhereItStands() throws {
        let settings = ToolSettings()
        // A selection 200 × 48 less the handles' reach.
        let room = CGRect(x: 8.5, y: 8.5, width: 183, height: 31)
        let start = CGPoint(x: 70, y: 24), end = CGPoint(x: 97, y: 24)
        guard case .magnifier(let dragged) = AnnotationTool.magnifier.mark(from: start, to: end, constrained: false, settings: settings, room: room)?.shape
        else { Issue.record("No magnifier"); return }
        #expect(dragged.source == start && dragged.center == end)
        #expect(dragged.radius == 15.5)
        #expect(dragged.isDetached)
        // At full size the same drag is still within what the lens shows.
        guard case .magnifier(let full) = AnnotationTool.magnifier.mark(from: start, to: end, constrained: false, settings: settings)?.shape
        else { Issue.record("No magnifier"); return }
        #expect(full.center == start && full.radius == Magnifier.lensRadius)
        // A drag past the room leaves the lens at its edge, where it can still be reached.
        guard case .magnifier(let past) = AnnotationTool.magnifier.mark(
            from: start, to: CGPoint(x: 300, y: 60), constrained: false, settings: settings, room: room
        )?.shape else { Issue.record("No magnifier"); return }
        #expect(past.center == CGPoint(x: 191.5, y: 39.5) && past.radius == Magnifier.smallestRadius)
        // A Shift drag past it keeps its angle, stopping where its line leaves the room.
        let taller = CGRect(x: 8.5, y: 8.5, width: 183, height: 83)
        guard case .magnifier(let snapped) = AnnotationTool.magnifier.mark(
            from: CGPoint(x: 70, y: 30), to: CGPoint(x: 170, y: 130), constrained: true, settings: settings, room: taller
        )?.shape else { Issue.record("No magnifier"); return }
        #expect(snapped.center == CGPoint(x: 131.5, y: 91.5))
        // A click by the canvas's edge, outside the room, puts the lens over the spot clicked all the same.
        let edge = CGPoint(x: 1, y: 24)
        guard case .magnifier(let byTheEdge) = AnnotationTool.magnifier.mark(from: edge, to: edge, constrained: false, settings: settings, room: room)?.shape
        else { Issue.record("No magnifier"); return }
        #expect(byTheEdge.center == edge && byTheEdge.source == edge)
        // Nor does a drag out past the edge that the room holds within what the lens shows.
        let outward = AnnotationTool.magnifier.mark(from: CGPoint(x: 188, y: 24), to: CGPoint(x: 210, y: 24), constrained: false, settings: settings, room: room)
        guard case .magnifier(let held) = outward?.shape else { Issue.record("No magnifier"); return }
        #expect(held.center == CGPoint(x: 188, y: 24) && held.radius == Magnifier.smallestRadius)
        // Dragged in from an edge, a lens follows once the pointer leaves what it showed where it started, and takes the
        // larger size that fits where it now stands, still overlapping its spot until it clears that.
        let inward = AnnotationTool.magnifier.mark(from: CGPoint(x: 12, y: 24), to: CGPoint(x: 25, y: 24), constrained: false, settings: settings, room: room)
        guard case .magnifier(let grown) = inward?.shape else { Issue.record("No magnifier"); return }
        #expect(grown.center == CGPoint(x: 25, y: 24) && grown.radius == 15.5)
        #expect(!grown.isDetached)
        // Too short a selection for the smallest lens: it stays over the spot clicked, at its smallest.
        let short = CGRect(x: 8.5, y: 8.5, width: 283, height: 1)
        guard case .magnifier(let clicked) = AnnotationTool.magnifier.mark(
            from: CGPoint(x: 150, y: 9), to: CGPoint(x: 150, y: 9), constrained: false, settings: settings, scale: 2, room: short
        )?.shape else { Issue.record("No magnifier"); return }
        #expect(clicked.center == CGPoint(x: 150, y: 9) && clicked.radius == Magnifier.smallestRadius * 2)
    }

    @Test func clickingOrDraggingWithTheToolMakesALens() throws {
        let (canvas, session, window) = try makeCanvas(base: noise(width: 400, height: 200), tool: .magnifier)
        defer { window.close() }
        try press(canvas, in: window, from: CGPoint(x: 100, y: 100))
        guard case .magnifier(let clicked) = session.document.items.last?.shape else { Issue.record("No magnifier made by a click"); return }
        #expect(clicked.source == CGPoint(x: 100, y: 100))
        #expect(clicked.center == clicked.source)
        #expect(clicked.radius == Magnifier.lensRadius)

        // Clear of the first lens, which a press on would take hold of.
        session.tool = .magnifier
        try press(canvas, in: window, from: CGPoint(x: 220, y: 60), to: CGPoint(x: 330, y: 130))
        guard case .magnifier(let dragged) = session.document.items.last?.shape else { Issue.record("No magnifier made by a drag"); return }
        #expect(dragged.source == CGPoint(x: 220, y: 60))
        #expect(dragged.center == CGPoint(x: 330, y: 130))
        #expect(dragged.isDetached)
        #expect(session.document.items.count == 2)
    }

    /// On a canvas that cannot grow, as Annotate Area's selection is, a new lens is made small enough to fit inside it
    /// with room for its handles all round, over the spot clicked, so it can be resized; by an edge it stays over the
    /// spot at its smallest rather than move off it.
    @MainActor
    @Test func onACanvasThatCannotGrowALensFitsInsideWithItsHandles() throws {
        let (canvas, session, window) = try makeCanvas(base: noise(width: 400, height: 200), tool: .magnifier)
        defer { window.close() }
        session.keepsCanvasFixed = true
        var document = session.document
        document.canvas = CGRect(x: 150, y: 70, width: 100, height: 60)
        session.commit(document, actionName: "Crop")
        canvas.layoutSubtreeIfNeeded()
        let reach = (SelectionLayer.handleSize / 2 + 4) / canvas.zoom
        let room = document.canvas.insetBy(dx: reach, dy: reach)
        try press(canvas, in: window, from: CGPoint(x: 200, y: 100))
        guard case .magnifier(let middle) = session.document.items.last?.shape else { Issue.record("No magnifier made"); return }
        #expect(middle.center == middle.source && middle.source == CGPoint(x: 200, y: 100))
        #expect(middle.radius < Magnifier.lensRadius)
        #expect(room.insetBy(dx: -0.01, dy: -0.01).contains(middle.lensRect), "\(middle.lensRect) is not inside \(room)")

        session.tool = .magnifier
        try press(canvas, in: window, from: CGPoint(x: 160, y: 76))
        guard case .magnifier(let edge) = session.document.items.last?.shape else { Issue.record("No magnifier made by the edge"); return }
        #expect(edge.center == edge.source && edge.source == CGPoint(x: 160, y: 76))
        #expect(edge.radius == Magnifier.smallestRadius)
        #expect(session.document.items.count == 2)
    }

    /// The canvas shows in a lens the picture with every redaction on it, kept up to date as redactions come
    /// and go: the same pixels an export shows.
    @MainActor
    @Test(arguments: Redaction.Method.allCases)
    func aLensOnTheCanvasNeverShowsWhatARedactionHides(method: Redaction.Method) throws {
        let base = noise(secret: true)
        let (canvas, session, window) = try makeCanvas(base: base, tool: .select)
        defer { window.close() }
        let lens = Magnifier(source: CGPoint(x: 55, y: 60), center: CGPoint(x: 150, y: 60), radius: 40, zoom: .two)
        let magnifier = Annotation(shape: .magnifier(lens), style: Style())
        let redaction = Annotation(shape: .redaction(Redaction(rect: secretRect, method: method)), style: Style(color: .black))
        var document = session.document
        document.items = [magnifier]
        session.commit(document, actionName: "Add")
        // Covered after the lens was made, from above it.
        document.items = [magnifier, redaction]
        session.commit(document, actionName: "Add")

        let shown = Pixels(try #require(canvas.markLayer(for: magnifier.id)?.lens))
        let area = MagnifierPainter.lensArea(of: lens)
        #expect(shown.width == Int(area.width) && shown.height == Int(area.height))
        let redacted = AnnotationDocument(pixelSize: CGSize(width: 200, height: 120), scale: 1, items: [redaction])
        let picture = Pixels(try #require(AnnotationRenderer.flatten(redacted, base: base)))
        var mismatches = 0
        for y in 0..<shown.height {
            for x in 0..<shown.width where !close(shown[x, y], picture[Int(area.minX) + x, Int(area.minY) + y], within: 3) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0, "\(mismatches) lens pixels differ from the redacted picture")
        // Taken away, the lens shows the picture plainly again.
        document.items = [magnifier]
        session.commit(document, actionName: "Delete")
        let plain = Pixels(try #require(canvas.markLayer(for: magnifier.id)?.lens))
        let under = (x: Int(secretRect.midX - area.minX), y: Int(secretRect.minY - area.minY) + 2)
        #expect(close(plain[under.x, under.y], Pixels(base)[Int(area.minX) + under.x, Int(area.minY) + under.y]))
    }
}
