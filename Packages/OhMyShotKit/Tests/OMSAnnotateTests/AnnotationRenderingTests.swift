import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Pixels of a rendered image, top-left origin, in sRGB.
struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    /// Red, green, blue, alpha at `x`, `y` from the top left.
    subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), Int(bytes[index + 3]))
    }

    /// The pixels inside `rect` as one array, to compare regions.
    func region(_ rect: CGRect) -> [UInt8] {
        var out: [UInt8] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let start = (y * width + Int(rect.minX)) * 4
            out += bytes[start..<(start + Int(rect.width) * 4)]
        }
        return out
    }
}

/// A capture to draw on: white, with a black band across rows 40 to 59 and a checker of grays in the
/// lower right, so blurs and pixelations have something to work on.
func makeBase(width: Int = 200, height: Int = 100) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Core Graphics is y-up: rows 40–59 from the top are y 40–59 from the bottom too in a 100 px image.
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: CGFloat(height) - 60, width: CGFloat(width), height: 20))
    for x in stride(from: 120, to: width, by: 4) {
        for y in stride(from: 0, to: 30, by: 4) where (x / 4 + y / 4) % 2 == 0 {
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    return context.makeImage()!
}

struct AnnotationRenderingTests {
    private func render(_ items: [Annotation], scale: CGFloat = 1, canvas: CGRect? = nil, base: CGImage = makeBase()) -> Pixels {
        var document = AnnotationDocument(pixelSize: CGSize(width: base.width, height: base.height), scale: scale, items: items)
        if let canvas { document.canvas = canvas }
        return Pixels(AnnotationRenderer.flatten(document, base: base)!)
    }

    @Test func anOutlinedRectangleIsDrawnOnItsEdgeOnly() {
        let rect = Annotation(shape: .rectangle(Box(rect: CGRect(x: 20, y: 10, width: 60, height: 20))), style: Style(color: .red, lineWidth: 2, shadow: false))
        let pixels = render([rect])
        let edge = pixels[20, 20]
        #expect(edge.r > 240 && edge.g < 80 && edge.b < 80)
        let inside = pixels[50, 20]
        #expect(inside.r > 250 && inside.g > 250 && inside.b > 250)
    }

    @Test func strokeWidthsArePointsTimesTheScale() {
        // 2 pt at 2× is 4 px: centered on x = 20, it covers 18 to 21 and not 23.
        let rect = Annotation(shape: .rectangle(Box(rect: CGRect(x: 20, y: 10, width: 60, height: 20))), style: Style(color: .red, lineWidth: 2, shadow: false))
        let pixels = render([rect], scale: 2)
        #expect(pixels[18, 20].g < 80)
        #expect(pixels[21, 20].g < 80)
        #expect(pixels[23, 20].g > 250)
    }

    @Test func theHighlighterDarkensLikeInk() {
        // Wide enough that white is most of what it covers, as the ground around a line of text is.
        let stroke = Annotation(shape: .highlighter(Stroke(points: [CGPoint(x: 10, y: 50), CGPoint(x: 110, y: 50)])), style: Style(color: .marker, lineWidth: 60, shadow: false))
        let pixels = render([stroke])
        // Over the black band it stays black; over white it turns marker yellow.
        let overBlack = pixels[60, 50]
        #expect(overBlack.r < 10 && overBlack.g < 10 && overBlack.b < 10)
        let overWhite = pixels[60, 37]
        #expect(overWhite.r > 240 && overWhite.g > 210 && overWhite.b < 120)
    }

    @Test func solidRedactionCoversEverything() {
        let redaction = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 10, y: 30, width: 50, height: 40))), style: Style(color: .black, shadow: false))
        let pixels = render([redaction])
        for (x, y) in [(10, 30), (35, 35), (59, 69)] {
            #expect(pixels[x, y].r < 5 && pixels[x, y].g < 5)
        }
        #expect(pixels[61, 35].r > 250)
    }

    @Test func pixelationIsTheSameEveryTimeForAMarkAndDifferentForAnother() {
        let rect = CGRect(x: 100, y: 0, width: 96, height: 72)
        let id = UUID()
        let first = render([Annotation(id: id, shape: .redaction(Redaction(rect: rect, method: .pixelate)), style: Style())])
        let again = render([Annotation(id: id, shape: .redaction(Redaction(rect: rect, method: .pixelate)), style: Style())])
        let other = render([Annotation(shape: .redaction(Redaction(rect: rect, method: .pixelate)), style: Style())])
        #expect(first.region(rect) == again.region(rect))
        #expect(first.region(rect) != other.region(rect))
        // Blocks are at least 12 px: the first 12 pixels of a row are one color.
        let row = (100..<112).map { first[$0, 5] }
        #expect(row.allSatisfy { $0 == row[0] })
    }

    @Test func pixelationBlocksAreNeverSmallerThanTwelvePixels() {
        #expect(Redactor.blockSize(for: CGRect(x: 0, y: 0, width: 20, height: 10), scale: 1) == 12)
        #expect(Redactor.blockSize(for: CGRect(x: 0, y: 0, width: 2800, height: 100), scale: 2) == 100)
    }

    @Test func blurHidesTheBandsEdge() {
        // A sharp edge between white (row 39) and black (row 40) becomes a ramp.
        let blur = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 10, y: 20, width: 80, height: 60), method: .blur)), style: Style())
        let pixels = render([blur])
        let above = pixels[50, 38].r
        let below = pixels[50, 41].r
        #expect(above < 250 && below > 5)
        #expect(abs(above - below) < 120)
    }

    @Test func aCropKeepsOnlyTheCanvas() {
        let image = AnnotationRenderer.flatten({
            var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1)
            document.canvas = CGRect(x: 10, y: 35, width: 50, height: 30)
            return document
        }(), base: makeBase())!
        #expect(image.width == 50 && image.height == 30)
        let pixels = Pixels(image)
        // Rows 35–39 of the capture are white, 40–59 black.
        #expect(pixels[0, 0].r > 250)
        #expect(pixels[0, 10].r < 5)
    }

    @Test func canvasBeyondTheCaptureTakesItsEdgeColor() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1)
        document.canvas = CGRect(x: -20, y: 0, width: 220, height: 100)
        let image = AnnotationRenderer.flatten(document, base: makeBase())!
        let pixels = Pixels(image)
        #expect(image.width == 220)
        // The capture's edge is white: the canvas added beside it is too, never a clear sliver.
        #expect(pixels[5, 10].a == 255 && pixels[5, 10].r == 255)
        #expect(pixels[25, 10].a == 255)
    }

    @Test func aWindowsCanvasStaysClearBeyondIt() {
        // A window captured with its shadow: its corners are clear.
        let context = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 180, height: 80))
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1)
        document.canvas = CGRect(x: -20, y: 0, width: 220, height: 100)
        let image = AnnotationRenderer.flatten(document, base: context.makeImage()!)!
        #expect(Pixels(image)[5, 10].a == 0)
    }

    @Test func aSpotlightDimsEverythingButTheSpot() {
        let spot = Annotation(shape: .spotlight(Spot(rect: CGRect(x: 10, y: 5, width: 40, height: 20))), style: Style(shadow: false))
        let pixels = render([spot])
        #expect(pixels[20, 10].r > 250)
        let dimmed = pixels[150, 80].r
        #expect(abs(dimmed - 128) < 6)
    }

    @Test func overlappingSpotsStayBright() {
        let spots = [
            Annotation(shape: .spotlight(Spot(rect: CGRect(x: 10, y: 5, width: 40, height: 20))), style: Style()),
            Annotation(shape: .spotlight(Spot(rect: CGRect(x: 30, y: 5, width: 40, height: 20))), style: Style()),
        ]
        let pixels = render(spots)
        #expect(pixels[40, 10].r > 250)
    }

    @Test func shadowsFallDownward() {
        let rect = Annotation(shape: .rectangle(Box(rect: CGRect(x: 40, y: 10, width: 40, height: 20), filled: true)), style: Style(color: .blue, lineWidth: 2, shadow: true))
        let pixels = render([rect], scale: 2)
        // Just below the box is darker than just above it.
        #expect(pixels[60, 32].r < pixels[60, 8].r)
    }

    @Test func textIsDrawnWithinItsBounds() {
        let block = TextBlock(origin: CGPoint(x: 10, y: 60), string: "Hi", fontSize: 20)
        let item = Annotation(shape: .text(block), style: Style(color: .red, shadow: false))
        let bounds = item.bounds(scale: 1)
        let pixels = render([item])
        var inked = 0
        for x in Int(bounds.minX)..<Int(bounds.maxX) {
            for y in Int(bounds.minY)..<Int(bounds.maxY) where pixels[x, y].g < 128 {
                inked += 1
            }
        }
        #expect(inked > 30)
        // Upright: the cap height is in the top part of the line, so the bottom quarter is clear.
        let bottom = Int(bounds.maxY) - 3
        #expect((Int(bounds.minX)..<Int(bounds.maxX)).allSatisfy { pixels[$0, bottom].g > 200 })
    }

    @Test func aCounterIsADiscWithItsNumber() {
        let item = Annotation(shape: .counter(Counter(center: CGPoint(x: 50, y: 25), value: 1)), style: Style(color: .red, lineWidth: 4, shadow: false))
        let pixels = render([item])
        // 16 + 3 × 4 = 28 pt across: the disc's edge is red, its middle carries the white "1".
        #expect(pixels[50 - 12, 25].g < 80)
        #expect(item.bounds(scale: 1).width == 28)
    }
}
