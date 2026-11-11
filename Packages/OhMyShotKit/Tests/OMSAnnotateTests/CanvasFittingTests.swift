import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// The canvas growing to hold marks past its edges, and the color the room it adds takes.
@MainActor
@Suite(.serialized)
struct CanvasFittingTests {
    private let scratch = ScratchDefaults()

    /// A picture of one color, with `stripe` (pixels, y down) painted in a second.
    private func picture(
        _ width: Int, _ height: Int, _ color: (CGFloat, CGFloat, CGFloat),
        stripe: CGRect? = nil, stripeColor: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
    ) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let stripe {
            context.setFillColor(CGColor(srgbRed: stripeColor.0, green: stripeColor.1, blue: stripeColor.2, alpha: 1))
            context.fill(CGRect(x: stripe.minX, y: CGFloat(height) - stripe.maxY, width: stripe.width, height: stripe.height))
        }
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    private func box(_ rect: CGRect) -> Annotation {
        Annotation(shape: .rectangle(Box(rect: rect, filled: true)), style: Style(color: .red, shadow: false))
    }

    private func makeSession(scale: CGFloat = 1) -> AnnotationSession {
        let session = AnnotationSession(image: picture(100, 80, (1, 1, 1)), scale: scale, tool: .rectangle, defaults: scratch.make())
        session.undoManager.groupsByEvent = false
        return session
    }

    // MARK: Fitting

    @Test func aMarkPastTheEdgeGrowsTheCanvasWithRoomAllAround() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 2)
        let mark = box(CGRect(x: 90, y: 10, width: 30, height: 20))
        document.items = [mark]
        let fitted = document.fittingCanvas(holding: [mark.id])
        let reach = mark.bounds(scale: 2)
        // 20 points, 40 pixels, past the mark on its side, and as much on every other.
        #expect(fitted.canvas == CGRect(x: -40, y: -40, width: reach.maxX + 40 + 40, height: 80 + 80).integral)
        #expect(fitted.canvasBeforeGrowing == document.imageBounds)
        #expect(fitted.canvasReachesPastCapture)
    }

    @Test func marksWithinTheCanvasLeaveItAlone() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        let mark = box(CGRect(x: 10, y: 10, width: 30, height: 20))
        document.items = [mark]
        let fitted = document.fittingCanvas(holding: [mark.id])
        #expect(fitted == document)
    }

    @Test func theCanvasShrinksBackAsTheMarkComesBackIn() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        let mark = box(CGRect(x: -30, y: 10, width: 20, height: 20))
        document.items = [mark]
        document = document.fittingCanvas(holding: [mark.id])
        #expect(document.canvas.minX < -30)
        document.items[0] = mark.translated(by: CGSize(width: 60, height: 0))
        document = document.fittingCanvas(holding: [mark.id])
        #expect(document.canvas == document.imageBounds && document.canvasBeforeGrowing == nil)
    }

    @Test func aMarkACropCutStaysCutUntilItIsTouched() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        let cut = box(CGRect(x: 40, y: 10, width: 50, height: 20))
        let other = box(CGRect(x: 10, y: 50, width: 10, height: 10))
        document.items = [cut, other]
        document.canvas = CGRect(x: 0, y: 0, width: 60, height: 80)
        // Drawing elsewhere leaves the crop as it is.
        #expect(document.fittingCanvas(holding: [other.id]).canvas == CGRect(x: 0, y: 0, width: 60, height: 80))
        // Moving the cut mark brings the canvas out to hold it.
        #expect(document.fittingCanvas(holding: [cut.id]).canvas.maxX > 90)
    }

    @Test func spotsTakeNoCanvasAndImagesTakeNoRoom() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        let spot = Annotation(shape: .spotlight(Spot(rect: CGRect(x: 80, y: 10, width: 60, height: 20))), style: Style())
        let image = Annotation(shape: .image(PlacedImage(rect: CGRect(x: 100, y: 0, width: 40, height: 40), name: "a.png")), style: Style(shadow: false))
        document.items = [spot]
        #expect(document.fittingCanvas(holding: [spot.id]).canvas == document.imageBounds)
        document.items = [image]
        // Combined edge to edge, as one picture.
        #expect(document.fittingCanvas(holding: [image.id]).canvas == CGRect(x: 0, y: 0, width: 140, height: 80))
    }

    @Test func aSideGrowsOnlySoFar() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        let far = box(CGRect(x: 20_000, y: 10, width: 10, height: 10))
        document.items = [far]
        let fitted = document.fittingCanvas(holding: [far.id])
        #expect(fitted.canvas.maxX == 100 + AnnotationDocument.canvasGrowthLimit)
    }

    @Test func turningCarriesTheCanvasAsSet() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        let mark = box(CGRect(x: 90, y: 10, width: 30, height: 20))
        document.items = [mark]
        document = document.fittingCanvas(holding: [mark.id])
        let turned = try #require(document.applying(.rotateRight))
        #expect(turned.canvasBeforeGrowing == turned.imageBounds)
        let resized = try #require(document.applying(.resize(to: CGSize(width: 80, height: 60))))
        #expect(resized.canvasBeforeGrowing == nil)
    }

    @Test func theCanvasAsSetIsKeptInTheFileOnlyWhenItGrew() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80), scale: 1)
        let plain = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        #expect(!plain.contains("canvasBeforeGrowing"))
        let mark = box(CGRect(x: 90, y: 10, width: 30, height: 20))
        document.items = [mark]
        document = document.fittingCanvas(holding: [mark.id])
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
    }

    // MARK: The session

    @Test func drawingPastTheEdgeGrowsTheCanvasInTheSameStep() {
        let session = makeSession()
        let mark = box(CGRect(x: 90, y: 10, width: 30, height: 20))
        session.undoManager.beginUndoGrouping()
        session.beginLiveChange()
        var document = session.document
        document.items.append(mark)
        session.updateLive(document)
        session.fitCanvas(holding: [mark.id])
        session.endLiveChange(actionName: "Add Rectangle")
        session.undoManager.endUndoGrouping()
        #expect(session.document.canvas.maxX > 120)
        #expect(session.undoManager.undoActionName == "Add Rectangle")
        session.undo()
        #expect(session.document.items.isEmpty && session.document.canvas == session.document.imageBounds)
    }

    @Test func deletingWhatHeldTheCanvasOutShrinksIt() {
        let session = makeSession()
        let mark = box(CGRect(x: 90, y: 10, width: 30, height: 20))
        var document = session.document
        document.items.append(mark)
        session.undoManager.beginUndoGrouping()
        session.commit(session.fitted(document, holding: [mark.id]), selecting: [mark.id], actionName: "Add Rectangle")
        session.undoManager.endUndoGrouping()
        #expect(session.document.canvasReachesPastCapture)
        session.undoManager.beginUndoGrouping()
        session.deleteSelection()
        session.undoManager.endUndoGrouping()
        #expect(session.document.canvas == session.document.imageBounds)
    }

    @Test func aLockedOrInPlaceCanvasNeverGrows() {
        let locked = makeSession()
        locked.locksCanvas = true
        let fixed = makeSession()
        fixed.keepsCanvasFixed = true
        for session in [locked, fixed] {
            let mark = box(CGRect(x: 90, y: 10, width: 30, height: 20))
            var document = session.document
            document.items.append(mark)
            session.beginLiveChange()
            session.updateLive(document)
            session.fitCanvas(holding: [mark.id])
            session.cancelLiveChange()
            #expect(session.document.canvas == session.document.imageBounds)
        }
    }

    // MARK: Its color

    @Test func theRoomAddedTakesTheEdgesMostCommonColor() {
        // Navy along most of the edge, white along the rest: no one color holds most of the edge, yet the
        // navy is the most common.
        let image = picture(100, 100, (0.08, 0.08, 0.25), stripe: CGRect(x: 0, y: 55, width: 100, height: 45))
        let edges = EdgeAnalysis.of(image, canvas: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(edges.edgeColor == nil)
        let navy = edges.canvasColor
        #expect(navy.map { $0.blue > $0.red && $0.red < 0.15 } == true)
        #expect(document(past: edges).canvasMatte(edges: edges) == navy)
    }

    /// A document whose canvas reaches past its capture.
    private func document(past edges: EdgeAnalysis) -> AnnotationDocument {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100), scale: 1)
        document.canvas = CGRect(x: -10, y: 0, width: 110, height: 100)
        return document
    }

    @Test func likeColorsCountTogether() {
        // Three near navies, each less common than the white, outnumber it together.
        func strip(_ colors: [(UInt8, UInt8, UInt8, Int)]) -> Bitmap {
            var bitmap = Bitmap(width: colors.reduce(0) { $0 + $1.3 }, height: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var index = 0
            for (red, green, blue, count) in colors {
                for _ in 0..<count {
                    bitmap.bytes.replaceSubrange(index..<index + 4, with: [255, red, green, blue])
                    index += 4
                }
            }
            return bitmap
        }
        let color = EdgeAnalysis.commonColor(of: [strip([(255, 255, 255, 40), (20, 20, 60, 30), (24, 22, 66, 20), (18, 21, 58, 10)])])
        #expect(color == RGBA(red: 20.0 / 255, green: 20.0 / 255, blue: 60.0 / 255))
    }

    @Test func anExportFillsTheRoomAddedWithThatColor() throws {
        let base = picture(100, 100, (0.08, 0.08, 0.25), stripe: CGRect(x: 0, y: 55, width: 100, height: 45))
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100), scale: 1)
        let mark = box(CGRect(x: -50, y: 10, width: 20, height: 20))
        document.items = [mark]
        document = document.fittingCanvas(holding: [mark.id])
        let output = try #require(AnnotationRenderer.flatten(document, base: base))
        #expect(output.width == Int(document.canvas.width))
        // Above the capture, in the room added on every side.
        let room = pixel(output, Int(-document.canvas.minX) + 50, 5)
        #expect(room.alpha == 255 && room.blue > room.red && room.red < 40)
        // The mark, past the capture's edge, is kept.
        let kept = pixel(output, Int(-document.canvas.minX) - 40, Int(-document.canvas.minY) + 20)
        #expect(kept.red == 255 && kept.blue < 80)
    }
}
