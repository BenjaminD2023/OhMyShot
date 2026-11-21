import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
struct AnnotationBackdropTests {
    /// A white picture with a black block where `content` says, and optionally a clear top-left pixel.
    private func page(width: Int, height: Int, content: CGRect?, clearCorner: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // y down, as the document is.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let content {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(content)
        }
        if clearCorner {
            context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
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

    /// The most opaque pixel of the picture's outermost ring.
    private func outerRingAlpha(_ image: CGImage) -> UInt8 {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let ring = (0..<width).flatMap { [($0, 0), ($0, height - 1)] } + (0..<height).flatMap { [(0, $0), (width - 1, $0)] }
        return ring.map { bytes[($0.1 * width + $0.0) * 4 + 3] }.max() ?? 0
    }

    private let opaqueEdge = EdgeAnalysis(opaque: true, edgeColor: nil, content: nil)

    @Test func paddingIsMeasuredAgainstTheCapturesSize() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 100), scale: 2)
        document.backdrop = Backdrop(padding: 0.1)
        let layout = try #require(document.backdropLayout(edges: opaqueEdge))
        // The side of a square of 400 × 100 is 200: a tenth of it is 20 on every side.
        #expect(layout.output == CGRect(x: -20, y: -20, width: 440, height: 140))
        #expect(layout.card == document.imageBounds)
        #expect(layout.cornerRadius == 24)
    }

    @Test func aShapeGrowsThePictureOnTheSideTheAlignmentLeavesOpen() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 100), scale: 1)
        document.backdrop = Backdrop(padding: 0.1, ratio: Backdrop.Ratio(1, 1), alignment: .top)
        var layout = try #require(document.backdropLayout(edges: opaqueEdge))
        #expect(layout.output == CGRect(x: -20, y: -20, width: 440, height: 440))
        document.backdrop?.alignment = .bottom
        layout = try #require(document.backdropLayout(edges: opaqueEdge))
        #expect(layout.output == CGRect(x: -20, y: -320, width: 440, height: 440))
        document.backdrop?.alignment = .center
        layout = try #require(document.backdropLayout(edges: opaqueEdge))
        #expect(layout.output == CGRect(x: -20, y: -170, width: 440, height: 440))
        // A shape narrower than the picture grows it downward or upward, never smaller.
        document.backdrop?.ratio = Backdrop.Ratio(16, 9)
        layout = try #require(document.backdropLayout(edges: opaqueEdge))
        #expect(layout.output.width == 440 && layout.output.height == 248)
    }

    @Test func balanceCentersWhatTheCaptureShowsAndInsetAddsRoom() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 100), scale: 1)
        document.backdrop = Backdrop(padding: 0, inset: 0, balanced: true)
        let edges = EdgeAnalysis(opaque: true, edgeColor: .white, content: CGRect(x: 100, y: 10, width: 200, height: 60))
        var layout = try #require(document.backdropLayout(edges: edges))
        // 100 either side already; 10 above and 30 below become 30 and 30.
        #expect(layout.card == CGRect(x: 0, y: -20, width: 400, height: 120))
        #expect(layout.matte == .white)
        document.backdrop?.inset = 0.05
        layout = try #require(document.backdropLayout(edges: edges))
        #expect(layout.card == CGRect(x: -10, y: -30, width: 420, height: 140))
        // Without one edge color there is nothing to fill the room with.
        layout = try #require(document.backdropLayout(edges: EdgeAnalysis(opaque: true, edgeColor: nil, content: nil)))
        #expect(layout.card == document.imageBounds && layout.matte == nil)
        // Canvas reaching past such a capture, for images combined beside it, is white.
        document.canvas = CGRect(x: 0, y: 0, width: 600, height: 100)
        layout = try #require(document.backdropLayout(edges: EdgeAnalysis(opaque: true, edgeColor: nil, content: nil)))
        #expect(layout.matte == .white)
    }

    @Test func aWindowWithItsShadowGetsNoCard() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 300, height: 200), scale: 2)
        document.backdrop = Backdrop(inset: 0.1, balanced: true, cornerRadius: 20)
        let layout = try #require(document.backdropLayout(edges: EdgeAnalysis(opaque: false, edgeColor: .white, content: CGRect(x: 10, y: 10, width: 10, height: 10))))
        #expect(layout.isBare)
        #expect(layout.card == document.imageBounds && layout.cornerRadius == 0 && layout.matte == nil)
    }

    @Test func theEdgeIsReadFromTheCapture() {
        let image = page(width: 400, height: 200, content: CGRect(x: 100, y: 20, width: 200, height: 100))
        let edges = EdgeAnalysis.of(image, canvas: CGRect(x: 0, y: 0, width: 400, height: 200))
        #expect(edges.opaque)
        #expect(edges.edgeColor == .white)
        #expect(edges.content == CGRect(x: 100, y: 20, width: 200, height: 100))
        // Cropped to part of it, only that part counts.
        let cropped = EdgeAnalysis.of(image, canvas: CGRect(x: 50, y: 0, width: 300, height: 150))
        #expect(cropped.content == CGRect(x: 100, y: 20, width: 200, height: 100))
        let blank = EdgeAnalysis.of(page(width: 50, height: 50, content: nil), canvas: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(blank.edgeColor == .white && blank.content == nil)
        let window = EdgeAnalysis.of(page(width: 50, height: 50, content: nil, clearCorner: true), canvas: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(!window.opaque)
    }

    @Test func exportsSetTheCaptureOnTheBackground() throws {
        let image = page(width: 100, height: 100, content: CGRect(x: 40, y: 40, width: 20, height: 20))
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100), scale: 1)
        document.backdrop = Backdrop(fill: .color(RGBA(red: 1, green: 0, blue: 0)), padding: 0.1, cornerRadius: 0, shadow: 0)
        let output = try #require(AnnotationRenderer.flatten(document, base: image))
        #expect(output.width == 120 && output.height == 120)
        let corner = pixel(output, 2, 2)
        #expect(corner.red == 255 && corner.green == 0 && corner.alpha == 255)
        let middle = pixel(output, 60, 60)
        #expect(middle.red == 0 && middle.alpha == 255)
        let page = pixel(output, 15, 15)
        #expect(page.red == 255 && page.green == 255)
        // A clear background leaves the room transparent.
        document.backdrop?.fill = .clear
        let clear = try #require(AnnotationRenderer.flatten(document, base: image))
        #expect(pixel(clear, 2, 2).alpha == 0)
    }

    @Test func clearRoomHoldsTheWholeShadowOfASmallCapture() throws {
        // 210 × 80 pt at 2×: a tenth of its size is narrower than the shadow, which used to stop in a line.
        let image = page(width: 420, height: 160, content: nil)
        var document = AnnotationDocument(pixelSize: CGSize(width: 420, height: 160), scale: 2)
        document.backdrop = Backdrop(fill: .clear, padding: 0.08, shadow: 0.5)
        let layout = try #require(document.backdropLayout(edges: opaqueEdge))
        // Falling 14 px with a 48 px blur, the shadow reaches 72 px out, 58 above and 86 below.
        #expect(layout.output == CGRect(x: -72, y: -58, width: 564, height: 304))
        #expect(outerRingAlpha(try #require(AnnotationRenderer.flatten(document, base: image))) == 0)
        // Room wider than the shadow stays as it was.
        document = AnnotationDocument(pixelSize: CGSize(width: 3000, height: 2000), scale: 2)
        document.backdrop = Backdrop(fill: .clear, padding: 0.08, shadow: 0.5)
        #expect(try #require(document.backdropLayout(edges: opaqueEdge)).output == CGRect(x: -196, y: -196, width: 3392, height: 2392))
        // A filled background keeps its room: the shadow lies on the fill, cut by the picture's edge or not.
        document = AnnotationDocument(pixelSize: CGSize(width: 420, height: 160), scale: 2)
        document.backdrop = Backdrop(padding: 0.08, shadow: 0.5)
        #expect(try #require(document.backdropLayout(edges: opaqueEdge)).output == CGRect(x: -21, y: -21, width: 462, height: 202))
    }

    @Test func roundedCornersAndShadowLiesEvenAllRound() throws {
        let image = page(width: 400, height: 300, content: nil)
        var document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300), scale: 2)
        document.backdrop = BackdropPresets.roundedShadow.backdrop
        let layout = try #require(document.backdropLayout(edges: EdgeAnalysis.of(image, canvas: document.canvas)))
        // A 32 px blur reaches 48 px out on every side, and no farther.
        #expect(layout.output == CGRect(x: -48, y: -48, width: 496, height: 396))
        #expect(layout.card == document.imageBounds && layout.cornerRadius == 30)
        let output = try #require(AnnotationRenderer.flatten(document, base: image))
        #expect(outerRingAlpha(output) == 0)
        // The capture's corner is cut away, and the shadow is as deep above it as below it.
        #expect(pixel(output, 48, 48).alpha < 128)
        let above = pixel(output, 248, 44).alpha
        let below = pixel(output, 248, 351).alpha
        #expect(above > 0 && above == below)
        // A window keeps its own corners and shadow.
        let window = try #require(document.backdropLayout(edges: EdgeAnalysis(opaque: false, edgeColor: nil, content: nil)))
        #expect(window.isBare && window.output == document.imageBounds)
    }

    @Test func aBackgroundKeptBeforeShadowStylesFallsAsItDid() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Backdrop())) as? [String: Any])
        #expect(json["shadowStyle"] == nil)
        let falling = try #require(CardShadow(Backdrop(), scale: 2))
        #expect(falling.blur == 48 && falling.drop == 14)
        let even = try #require(CardShadow(Backdrop(shadow: 0.5, shadowStyle: .even), scale: 2))
        #expect(even.blur == 32 && even.drop == 0 && even.opacity == falling.opacity)
        #expect(CardShadow(Backdrop(shadow: 0), scale: 2) == nil)
        let rounded = BackdropPresets.roundedShadow.backdrop
        #expect(try JSONDecoder().decode(Backdrop.self, from: JSONEncoder().encode(rounded)) == rounded)
    }

    @Test func marksReachOntoTheBackground() throws {
        let image = page(width: 100, height: 100, content: nil)
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100), scale: 1)
        document.backdrop = Backdrop(fill: .clear, padding: 0.2, shadow: 0)
        document.items = [Annotation(shape: .rectangle(Box(rect: CGRect(x: -15, y: -15, width: 10, height: 10), filled: true)), style: Style(color: .blue, shadow: false))]
        let output = try #require(AnnotationRenderer.flatten(document, base: image))
        let mark = pixel(output, 10, 10)
        #expect(mark.blue > 200 && mark.alpha == 255)
    }

    @Test func aBackgroundAloneIsAnEdit() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 10, height: 10), scale: 1)
        #expect(document.isEmpty)
        document.backdrop = Backdrop()
        #expect(!document.isEmpty)
        // Marks kept before backgrounds existed still open.
        var plain = AnnotationDocument(pixelSize: CGSize(width: 10, height: 10), scale: 1)
        plain.items = [Annotation(shape: .counter(Counter(center: .zero, value: 1)), style: Style())]
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        json["backdrop"] = nil
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == plain && decoded.backdrop == nil)
        document.backdrop = Backdrop(fill: .picture("a.png"), ratio: Backdrop.Ratio(4, 3), alignment: .bottomRight)
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
    }

    @Test func aSliderDragIsOneUndoStep() {
        let session = AnnotationSession(image: page(width: 40, height: 40, content: nil), scale: 1)
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.beginLiveChange()
        for step in 1...5 {
            session.changeBackdrop("Padding") { $0.padding = CGFloat(step) / 50 }
        }
        session.endLiveChange(actionName: "Padding")
        session.undoManager.endUndoGrouping()
        #expect(session.document.backdrop?.padding == 0.1)
        #expect(session.undoManager.undoActionName == "Padding")
        session.undo()
        #expect(session.document.backdrop == nil)
    }

    @Test func roundedCornersAndShadowIsThereWithoutSavingIt() {
        let scratch = ScratchDefaults()
        let defaults = scratch.make()
        let presets = BackdropPresets(defaults: defaults)
        #expect(presets.all.isEmpty && presets.choices == [BackdropPresets.roundedShadow])
        presets.setAutomatic(BackdropPresets.roundedShadow.id)
        #expect(BackdropPresets(defaults: defaults).automatic == BackdropPresets.roundedShadow)
        let saved = presets.add(name: "Sky", backdrop: Backdrop())
        #expect(presets.choices == [BackdropPresets.roundedShadow, saved])
        presets.remove(saved.id)
        #expect(presets.automatic == BackdropPresets.roundedShadow)
    }

    @Test func aWindowIsNotGivenRoundedCornersAndShadow() {
        let scratch = ScratchDefaults()
        let presets = BackdropPresets(defaults: scratch.make())
        #expect(presets.automaticForWindows == nil)
        presets.setAutomatic(BackdropPresets.roundedShadow.id)
        #expect(presets.automatic == BackdropPresets.roundedShadow && presets.automaticForWindows == nil)
        let saved = presets.add(name: "Sky", backdrop: Backdrop())
        presets.setAutomatic(saved.id)
        #expect(presets.automaticForWindows == saved)
    }

    @Test func theLastBackgroundPictureIsKeptAmongThePresetsPictures() {
        let scratch = ScratchDefaults()
        let defaults = scratch.make()
        let presets = BackdropPresets(defaults: defaults)
        #expect(presets.lastPicture == nil && presets.pictureNames.isEmpty)
        presets.add(name: "Wall", backdrop: Backdrop(fill: .picture("wall.png")))
        presets.lastPicture = "beach.jpg"
        #expect(presets.pictureNames == ["wall.png", "beach.jpg"])
        // Under the key earlier versions kept it by, so a picture chosen before is still offered.
        #expect(defaults.string(forKey: "annotation.backdropPicture") == "beach.jpg")
        #expect(BackdropPresets(defaults: defaults).lastPicture == "beach.jpg")
    }
}
