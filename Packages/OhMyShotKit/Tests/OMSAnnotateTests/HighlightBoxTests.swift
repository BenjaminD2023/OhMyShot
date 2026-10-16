import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
struct HighlightBoxTests {
    private func box(_ rect: CGRect, color: RGBA = .marker, cornerRadius: CGFloat = 0) -> Annotation {
        Annotation(shape: .highlightBox(Box(rect: rect, filled: true, cornerRadius: cornerRadius)), style: Style(color: color, lineWidth: 4, shadow: false))
    }

    @Test func theToolDrawsAFilledMarkerBoxByDragging() throws {
        let settings = ToolSettings.defaults(for: .highlightBox)
        #expect(settings.color == .marker && !settings.shadow)
        let mark = try #require(AnnotationTool.highlightBox.mark(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40), constrained: false, settings: settings))
        guard case .highlightBox(let drawn) = mark.shape else { throw Failure.shape }
        #expect(drawn.rect == CGRect(x: 10, y: 10, width: 50, height: 30) && drawn.filled)
        #expect(mark.style.color == .marker && !mark.style.shadow)
        #expect(AnnotationTool.highlightBox.dragsShape)
        // Shift makes a square.
        guard case .highlightBox(let square)? = AnnotationTool.highlightBox.mark(from: .zero, to: CGPoint(x: 50, y: 30), constrained: true, settings: settings)?.shape else { throw Failure.shape }
        #expect(square.rect.width == square.rect.height)
    }

    @Test func everyToolHasItsOwnKey() {
        let keys = AnnotationTool.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(AnnotationTool.highlightBox.key == "m")
        // On the rail and in place, next to the highlighter.
        #expect(ToolRail.groups[1].contains(.highlightBox))
        #expect(InPlaceToolbar.toolGroups[0].contains(.highlightBox))
        #expect(AnnotationCanvasView.inPlaceTools.contains(.highlightBox))
        #expect(NSImage(systemSymbolName: ToolRail.symbol(for: .highlightBox), accessibilityDescription: nil) != nil)
    }

    @Test func itBehavesAsAHighlightAndAShape() throws {
        let mark = box(CGRect(x: 10, y: 10, width: 80, height: 20))
        #expect(mark.multiplies && !mark.castsShadow && mark.coversArea)
        #expect(AnnotationSession.tool(for: mark) == .highlightBox)
        #expect(mark.bounds(scale: 2) == CGRect(x: 10, y: 10, width: 80, height: 20))
        #expect(mark.contains(CGPoint(x: 50, y: 20), tolerance: 3, scale: 2))
        // Only its edges catch a press while it is not selected, so a new mark can start inside it.
        #expect(!mark.contains(CGPoint(x: 50, y: 20), tolerance: 3, scale: 2, interior: false))
        #expect(mark.handles(scale: 2).count == 8)
        guard case .highlightBox(let wider) = mark.moving(.right, to: CGPoint(x: 150, y: 20), constrained: false, scale: 2).shape else { throw Failure.shape }
        #expect(wider.rect == CGRect(x: 10, y: 10, width: 140, height: 20))
        guard case .highlightBox(let moved) = mark.translated(by: CGSize(width: 5, height: -5)).shape else { throw Failure.shape }
        #expect(moved.rect.origin == CGPoint(x: 15, y: 5))
    }

    @Test func itRestylesWithTheCapsuleAndKeepsItsCorners() throws {
        var settings = ToolSettings.defaults(for: .highlightBox)
        let mark = box(CGRect(x: 0, y: 0, width: 40, height: 20), cornerRadius: 6)
        settings.adopt(mark)
        #expect(settings.cornerRadius == 6)
        settings.color = .green
        guard case .highlightBox(let restyled) = settings.applied(to: mark).shape else { throw Failure.shape }
        #expect(restyled.cornerRadius == 6 && settings.applied(to: mark).style.color == .green)
    }

    @Test func itRoundTripsThroughJSON() throws {
        let document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 50), scale: 2, items: [box(CGRect(x: 1, y: 2, width: 30, height: 10), cornerRadius: 2)])
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document)
    }

    /// A 100 × 50 capture: white on the left half, black on the right, mid-gray along the bottom strip.
    private func makeCapture() -> CGImage {
        let context = CGContext(
            data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        return context.makeImage()!
    }

    @Test func itMultipliesIntoTheLightPictureAndLeavesDarkTextDark() throws {
        let marker = RGBA.marker
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 50), scale: 1)
        // Across the white half and the black half.
        document.items = [box(CGRect(x: 20, y: 10, width: 50, height: 20), color: marker)]
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(document, base: makeCapture())))
        func close(_ value: Int, _ expected: Double) -> Bool { abs(value - Int((expected * 255).rounded())) <= 1 }
        // White takes the marker color; black stays black; outside the box nothing changed.
        let onWhite = pixels[30, 20]
        #expect(close(onWhite.r, marker.red) && close(onWhite.g, marker.green) && close(onWhite.b, marker.blue))
        #expect(pixels[60, 20].r == 0 && pixels[60, 20].g == 0 && pixels[60, 20].b == 0)
        #expect(pixels[30, 40].r == 255 && pixels[10, 20].r == 255 && pixels[90, 20].r == 0)
        // Just inside and outside its edge.
        #expect(pixels[20, 10].b < 255 && pixels[19, 10].b == 255 && pixels[69, 29].b == 0 && pixels[30, 30].b == 255)
    }

    @Test func itScreensATintOverDarkGroundSoTheBoxShows() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 50), scale: 1)
        document.items = [box(CGRect(x: 60, y: 10, width: 30, height: 20))]
        // Over the black half multiplying would leave nothing to see.
        let picture = makeCapture()
        let ground = HighlightGround.under(document.items[0], in: picture, origin: .zero, scale: 1)
        #expect(ground == .dark)
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(document, base: picture)))
        let lit = pixels[70, 20]
        #expect(lit.r > 0 || lit.g > 0 || lit.b > 0)
        // And it is a tint, not the marker itself.
        #expect(lit.r < 120)
    }

    /// A picture of one gray with `draw` over it.
    private func ground(width: Int, height: Int, gray: CGFloat, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    @Test func aWideBoxIsReadAllOverItsGround() {
        let wide = box(CGRect(x: 0, y: 0, width: 800, height: 400))
        // Fine dark lines, 1 px wide every 10, on light ground: the lines are a tenth of it, however a few
        // pixels sampled out of the whole box might line up with them.
        let lined = ground(width: 800, height: 400, gray: 1) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in stride(from: 0, to: 800, by: 10) { context.fill(CGRect(x: x, y: 0, width: 1, height: 400)) }
        }
        #expect(HighlightGround.under(wide, in: lined, origin: .zero, scale: 1) == .light)
        // The same turned over: light lines on dark ground.
        let reversed = ground(width: 800, height: 400, gray: 0) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            for x in stride(from: 0, to: 800, by: 10) { context.fill(CGRect(x: x, y: 0, width: 1, height: 400)) }
        }
        #expect(HighlightGround.under(wide, in: reversed, origin: .zero, scale: 1) == .dark)
        // A third of the box the other shade, in one band, does not turn the rest over.
        let band = ground(width: 800, height: 400, gray: 1) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 130, width: 800, height: 130))
        }
        #expect(HighlightGround.under(wide, in: band, origin: .zero, scale: 1) == .light)
        let darkBand = ground(width: 800, height: 400, gray: 0) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 130, width: 800, height: 130))
        }
        #expect(HighlightGround.under(wide, in: darkBand, origin: .zero, scale: 1) == .dark)
        // A tall box, too, and one only part of the picture is under.
        let tall = box(CGRect(x: 100, y: 0, width: 40, height: 400))
        #expect(HighlightGround.under(tall, in: band, origin: .zero, scale: 1) == .light)
        #expect(HighlightGround.under(box(CGRect(x: 0, y: 140, width: 800, height: 100)), in: band, origin: .zero, scale: 1) == .dark)
    }

    @Test func aCornerRadiusRoundsTheBox() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 100, height: 50), scale: 1)
        document.items = [box(CGRect(x: 10, y: 10, width: 40, height: 30), cornerRadius: 10)]
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(document, base: makeCapture())))
        // The very corner is left alone; the middle of an edge is covered.
        #expect(pixels[10, 10].b == 255)
        #expect(pixels[30, 10].b < 255)
    }

    private enum Failure: Error {
        case shape
    }
}
