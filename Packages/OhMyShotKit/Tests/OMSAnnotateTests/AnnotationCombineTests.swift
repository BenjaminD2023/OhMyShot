import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
struct AnnotationCombineTests {
    init() {
        // Pictures these tests add stay out of the app's own folder.
        PictureStore.use(URL.temporaryDirectory.appending(path: "OhMyShotKit Tests \(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory))
    }

    /// A picture of one color, `width` × `height` pixels.
    private func swatch(_ width: Int, _ height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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

    private func image(_ rect: CGRect, name: String) -> Annotation {
        Annotation(shape: .image(PlacedImage(rect: rect, name: name)), style: Style(shadow: false))
    }

    @Test func imagesResizeFromTheirCornersKeepingTheirShape() {
        let item = image(CGRect(x: 0, y: 0, width: 200, height: 100), name: "a.png")
        #expect(item.handles(scale: 1).map(\.handle) == [.topLeft, .topRight, .bottomRight, .bottomLeft])
        guard case .image(let kept) = item.moving(.bottomRight, to: CGPoint(x: 400, y: 120), constrained: false, scale: 1).shape,
              case .image(let free) = item.moving(.bottomRight, to: CGPoint(x: 400, y: 120), constrained: true, scale: 1).shape
        else { Issue.record("not an image"); return }
        #expect(kept.rect == CGRect(x: 0, y: 0, width: 400, height: 200))
        // Shift frees the proportions.
        #expect(free.rect == CGRect(x: 0, y: 0, width: 400, height: 120))
        // Inside an image a new mark can start, unless the image is selected.
        #expect(!item.contains(CGPoint(x: 100, y: 50), tolerance: 4, scale: 1, interior: false))
        #expect(item.contains(CGPoint(x: 100, y: 50), tolerance: 4, scale: 1))
    }

    @Test func addedImagesGrowTheCanvasAsOneStep() {
        let session = AnnotationSession(image: swatch(100, 80, red: 1, green: 1, blue: 1), scale: 2)
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.addImages([(name: "a.png", size: CGSize(width: 60, height: 40))], at: CGPoint(x: 120, y: 40))
        session.undoManager.endUndoGrouping()
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 150, height: 80))
        #expect(session.selection.count == 1)
        #expect(session.undoManager.undoActionName == "Add Image")
        session.undo()
        #expect(session.document.items.isEmpty && session.document.canvas == session.document.imageBounds)
    }

    @Test func movingAnImagePastTheEdgeGrowsTheCanvas() {
        let session = AnnotationSession(image: swatch(100, 80, red: 1, green: 1, blue: 1), scale: 1)
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.addImages([(name: "a.png", size: CGSize(width: 20, height: 20))], at: CGPoint(x: 50, y: 40))
        session.undoManager.endUndoGrouping()
        #expect(session.document.canvas == session.document.imageBounds)
        session.undoManager.beginUndoGrouping()
        session.beginLiveChange()
        var document = session.document
        document.items[0] = document.items[0].translated(by: CGSize(width: 0, height: 60))
        session.updateLive(document)
        session.growCanvasToHoldImages()
        session.endLiveChange(actionName: "Move")
        session.undoManager.endUndoGrouping()
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 100, height: 110))
        session.undo()
        #expect(session.document.canvas == session.document.imageBounds)
    }

    @Test func exportsCombineImagesUnderTheMarks() throws {
        let name = try PictureStore.shared.add(swatch(40, 40, red: 0, green: 0, blue: 1))
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100), scale: 1)
        document.canvas = CGRect(x: 0, y: 0, width: 160, height: 100)
        document.items = [
            Annotation(shape: .rectangle(Box(rect: CGRect(x: 120, y: 10, width: 10, height: 10), filled: true)), style: Style(color: .red, shadow: false)),
            image(CGRect(x: 110, y: 0, width: 40, height: 40), name: name),
        ]
        let output = try #require(AnnotationRenderer.flatten(document, base: swatch(100, 100, red: 1, green: 1, blue: 1)))
        #expect(output.width == 160)
        let combined = pixel(output, 140, 30)
        #expect(combined.blue == 255 && combined.red == 0)
        // The rectangle comes earlier in the document, yet as a mark it lies over the image.
        let mark = pixel(output, 125, 15)
        #expect(mark.red == 255 && mark.blue < 100)
        // Canvas no picture covers takes the capture's edge color, so the result reads as one picture.
        let gap = pixel(output, 130, 80)
        #expect(gap.alpha == 255 && gap.red == 255 && gap.blue == 255)
    }

    @Test func blursShowTheCombinedImagesUnderThem() throws {
        let name = try PictureStore.shared.add(swatch(60, 60, red: 0, green: 0.8, blue: 0))
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100), scale: 1)
        document.items = [
            image(CGRect(x: 20, y: 20, width: 60, height: 60), name: name),
            Annotation(shape: .redaction(Redaction(rect: CGRect(x: 40, y: 40, width: 20, height: 20), method: .pixelate)), style: Style(shadow: false)),
        ]
        let output = try #require(AnnotationRenderer.flatten(document, base: swatch(100, 100, red: 1, green: 1, blue: 1)))
        let redacted = pixel(output, 50, 50)
        // Green from the image, not white from the capture under it.
        #expect(redacted.green > 150 && redacted.red < 60)
    }

    @Test func aSpotlightDimsCombinedImagesToo() throws {
        let name = try PictureStore.shared.add(swatch(20, 20, red: 1, green: 1, blue: 1))
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100), scale: 1)
        document.items = [
            image(CGRect(x: 70, y: 70, width: 20, height: 20), name: name),
            Annotation(shape: .spotlight(Spot(rect: CGRect(x: 0, y: 0, width: 20, height: 20))), style: Style(shadow: false)),
        ]
        let output = try #require(AnnotationRenderer.flatten(document, base: swatch(100, 100, red: 1, green: 1, blue: 1)))
        #expect(pixel(output, 80, 80).red < 200)
        #expect(pixel(output, 10, 10).red == 255)
    }

    @Test func documentsKeepTheirImages() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 10, height: 10), scale: 2)
        document.items = [image(CGRect(x: 1, y: 2, width: 3, height: 4), name: "0123456789abcdef.png")]
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
    }
}
