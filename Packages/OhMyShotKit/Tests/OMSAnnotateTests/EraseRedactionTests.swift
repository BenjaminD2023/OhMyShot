import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Erase fills a redaction from the picture around it: from nothing under it, and from nothing another
/// redaction covers.
struct EraseRedactionTests {
    private let markID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E5")!

    /// A capture drawn with the origin at the top left.
    private func picture(width: Int = 120, height: Int = 80, _ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return try #require(context.makeImage())
    }

    private func erasure(_ rect: CGRect) -> Annotation {
        Annotation(id: markID, shape: .redaction(Redaction(rect: rect, method: .erase)), style: Style(color: .black, shadow: false))
    }

    private func flattened(_ base: CGImage, items: [Annotation]) throws -> Pixels {
        let document = AnnotationDocument(pixelSize: CGSize(width: base.width, height: base.height), scale: 1, items: items)
        return Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
    }

    private static func gray(_ level: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(level) / 255, green: CGFloat(level) / 255, blue: CGFloat(level) / 255, alpha: 1)
    }

    /// Bars like a line of text.
    private static func text(in rect: CGRect, context: CGContext) {
        context.setFillColor(gray(20))
        for x in stride(from: rect.minX + 2, to: rect.maxX - 3, by: 6) {
            context.fill(CGRect(x: x, y: rect.minY + 3, width: 3, height: rect.height - 6))
        }
    }

    /// Every pixel a different color, from a seed.
    private static func noise(in rect: CGRect, seed: UInt8, context: CGContext) {
        var generator = SeededGenerator(seed: UUID(uuid: (seed, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)))
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                context.setFillColor(CGColor(
                    srgbRed: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator), alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }

    /// What lies around the erasure in each test: one color, a gradient, and stripes no model fits.
    private static let surroundings: [(String, (CGContext, CGSize) -> Void)] = [
        ("flat", { context, size in
            context.setFillColor(gray(242))
            context.fill(CGRect(origin: .zero, size: size))
        }),
        ("gradient", { context, size in
            for x in 0..<Int(size.width) {
                context.setFillColor(CGColor(srgbRed: 0.2 + 0.6 * CGFloat(x) / size.width, green: 0.5, blue: 0.9 - 0.5 * CGFloat(x) / size.width, alpha: 1))
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: size.height))
            }
        }),
        ("stripes", { context, size in
            for x in stride(from: 0, to: Int(size.width), by: 3) {
                context.setFillColor(CGColor(srgbRed: CGFloat(x % 7) / 7, green: CGFloat(x % 5) / 5, blue: CGFloat(x % 3) / 3, alpha: 1))
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 3, height: size.height))
            }
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 30, width: size.width, height: 4))
        }),
    ]

    /// Nothing under the mark reaches the fill: whatever the covered pixels are, the picture comes out the
    /// same, so nothing it covers can be recovered from it.
    @Test(arguments: [0, 1, 2])
    func nothingUnderTheMarkReachesTheFill(surrounding: Int) throws {
        let (name, paint) = Self.surroundings[surrounding]
        let rect = CGRect(x: 30, y: 24, width: 50, height: 22)
        let size = CGSize(width: 120, height: 80)
        let withText = try picture { context in
            paint(context, size)
            Self.text(in: rect, context: context)
        }
        let withNoise = try picture { context in
            paint(context, size)
            Self.noise(in: rect, seed: 7, context: context)
        }
        let first = try flattened(withText, items: [erasure(rect)])
        let second = try flattened(withNoise, items: [erasure(rect)])
        let whole = CGRect(origin: .zero, size: size)
        #expect(first.region(whole) == second.region(whole), "\(name)")
        // It did cover them: the text's bars are gone.
        #expect(first[33, 35].r > 60, "\(name)")
        #expect((0..<80).allSatisfy { y in (0..<120).allSatisfy { x in first[x, y].a == 255 } }, "\(name)")
    }

    /// Around one color the fill is that color, even with the edge of a word reaching into what is read.
    @Test func oneColorAroundFillsWithThatColor() throws {
        let rect = CGRect(x: 30, y: 24, width: 50, height: 22)
        let base = try picture { context in
            context.setFillColor(Self.gray(242))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            Self.text(in: rect, context: context)
            // A neighboring word's last letter, just past the mark's right edge.
            context.setFillColor(Self.gray(20))
            context.fill(CGRect(x: 80, y: 30, width: 2, height: 8))
        }
        let pixels = try flattened(base, items: [erasure(rect)])
        for y in 24..<46 {
            for x in 30..<80 {
                let pixel = pixels[x, y]
                #expect(pixel.r == 242 && pixel.g == 242 && pixel.b == 242, "\(x), \(y)")
            }
        }
    }

    /// Around an even gradient the fill carries it on.
    @Test func aGradientAroundCarriesOnThrough() throws {
        let rect = CGRect(x: 30, y: 24, width: 50, height: 22)
        let level = { (x: Int) in 40 + 200 * x / 119 }
        let base = try picture { context in
            for x in 0..<120 {
                context.setFillColor(Self.gray(level(x)))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 80))
            }
            Self.text(in: rect, context: context)
        }
        let pixels = try flattened(base, items: [erasure(rect)])
        for y in 24..<46 {
            for x in 30..<80 {
                #expect(abs(pixels[x, y].r - level(x)) <= 2, "\(x), \(y)")
            }
        }
    }

    /// Across the edge of two surfaces, each side carries its own color in.
    @Test func twoSurfacesBlendInFromTheirOwnSides() throws {
        let rect = CGRect(x: 40, y: 20, width: 40, height: 40)
        let base = try picture { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 40, width: 120, height: 40))
            Self.text(in: rect.insetBy(dx: 4, dy: 12), context: context)
        }
        let pixels = try flattened(base, items: [erasure(rect)])
        let top = pixels[60, 20], bottom = pixels[60, 59]
        #expect(top.r > 220 && top.g > 220 && top.b > 220)
        #expect(bottom.r < 30 && bottom.g < 30 && bottom.b > 120)
        // The left and right sides are each surface where it meets them.
        #expect(pixels[40, 30].r > 220 && pixels[40, 50].r < 30)
    }

    /// An erasure reads nothing another redaction covers, whatever its method, so it never spreads what
    /// that one hides; drawn alone it takes the whole band around it.
    @Test(arguments: [Redaction.Method.solid, .blur, .pixelate, .erase])
    func nothingAnotherRedactionCoversReachesTheFill(other: Redaction.Method) throws {
        let rect = CGRect(x: 30, y: 24, width: 50, height: 22)
        // Over the band on the right of the mark and a little of the mark, on fractional pixels.
        let hidden = CGRect(x: 70.4, y: 10.6, width: 30, height: 50)
        let size = CGSize(width: 120, height: 80)
        let paint = Self.surroundings[2].1
        let first = try picture { context in
            paint(context, size)
            Self.text(in: hidden.integral, context: context)
        }
        let second = try picture { context in
            paint(context, size)
            Self.noise(in: hidden.integral, seed: 9, context: context)
        }
        let redaction = Redaction(rect: rect, method: .erase)
        func tile(_ base: CGImage, covered: [CGRect]) throws -> Pixels {
            guard case let .filtered(image, area) = Redactor.coverage(for: redaction, id: markID, source: .init(base: base), scale: 1, covered: covered) else {
                Issue.record("Expected an erasure"); throw CancellationError()
            }
            #expect(area == rect)
            return Pixels(image)
        }
        let whole = CGRect(origin: .zero, size: rect.size)
        #expect(try tile(first, covered: [hidden, rect]).region(whole) == tile(second, covered: [hidden, rect]).region(whole))
        #expect(try tile(first, covered: []).region(whole) != tile(second, covered: []).region(whole))
        // The export says where the other redaction is.
        let other = Annotation(shape: .redaction(Redaction(rect: hidden, method: other)), style: Style(color: .black, shadow: false))
        let erased = try flattened(first, items: [erasure(rect), other])
        let expected = try tile(first, covered: [hidden, rect])
        for y in 24..<46 {
            for x in 30..<70 {
                let pixel = erased[x, y], reference = expected[x - 30, y - 24]
                #expect(pixel.r == reference.r && pixel.g == reference.g && pixel.b == reference.b, "\(x), \(y)")
            }
        }
    }

    /// A mark at the picture's edge reads the sides that lie in the picture; one with nothing around it to
    /// read is covered opaquely, as a redaction that can't be made is.
    @Test func theEdgesOfThePictureAreLeftOut() throws {
        let base = try picture { context in
            context.setFillColor(Self.gray(200))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            Self.text(in: CGRect(x: 0, y: 0, width: 40, height: 20), context: context)
        }
        let corner = try flattened(base, items: [erasure(CGRect(x: -10, y: -10, width: 50, height: 30))])
        #expect((0..<20).allSatisfy { y in (0..<40).allSatisfy { x in corner[x, y].r == 200 } })
        let everything = Redaction(rect: CGRect(x: -5, y: -5, width: 130, height: 90), method: .erase)
        guard case .opaque(let rect) = Redactor.coverage(for: everything, id: markID, source: .init(base: base), scale: 1) else {
            Issue.record("Expected an opaque cover"); return
        }
        #expect(rect == CGRect(x: 0, y: 0, width: 120, height: 80))
    }

    /// The capsule offers Erase beside the other methods, and a project with an erasure is format 4, so a
    /// version that can't draw it refuses it rather than failing to read it.
    @Test func erasingIsAMethodOfItsOwnInFormatFour() throws {
        #expect(Redaction.Method.allCases == [.solid, .blur, .pixelate, .erase])
        var settings = ToolSettings.defaults(for: .redact)
        settings.redaction = .erase
        let mark = try #require(AnnotationTool.redact.mark(from: CGPoint(x: 2, y: 2), to: CGPoint(x: 6, y: 4), constrained: false, settings: settings))
        #expect(mark.shape == .redaction(Redaction(rect: CGRect(x: 2, y: 2, width: 4, height: 2), method: .erase)))
        var document = AnnotationDocument(pixelSize: CGSize(width: 8, height: 4), scale: 1, items: [mark])
        #expect(AnnotationProject.version(for: document) == 4)
        #expect(AnnotationProject.version == 4)
        document.items = [ToolSettings.defaults(for: .redact).applied(to: mark)]
        #expect(AnnotationProject.version(for: document) == 1)
    }

    /// Beside a window's clear margin, an erasure reads only opaque pixels, so it never makes a hole in what it
    /// covers.
    @Test func anErasureIsOpaqueBesideAClearMargin() throws {
        let base = try picture { context in
            context.clear(CGRect(x: 0, y: 0, width: 120, height: 80))
            context.setFillColor(Self.gray(200))
            context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        }
        let redaction = Redaction(rect: CGRect(x: 40, y: 20, width: 40, height: 40), method: .erase)
        guard case let .filtered(image, _) = Redactor.coverage(for: redaction, id: markID, source: .init(base: base), scale: 1) else {
            Issue.record("No fill")
            return
        }
        let pixels = Pixels(image)
        var unlike = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let pixel = pixels[x, y]
                if pixel.a != 255 || abs(pixel.r - 200) > 2 { unlike += 1 }
            }
        }
        #expect(unlike == 0, "\(unlike) pixels are not the opaque gray beside the margin")
    }

    /// An erasure fills and reads only what the picture keeps, so Annotate Area's preview, made on the whole display,
    /// comes out the same once the picture is cut to the selection, and a crop lets nothing in from outside it.
    @Test func anErasureKeepsInsideTheCanvas() throws {
        let base = try picture { context in
            context.setFillColor(Self.gray(250))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 80))
            Self.text(in: CGRect(x: 30, y: 20, width: 40, height: 30), context: context)
        }
        let canvas = CGRect(x: 30, y: 10, width: 80, height: 60)
        // Reaching past the canvas's left edge, onto the red it leaves out.
        let redaction = Redaction(rect: CGRect(x: 20, y: 20, width: 50, height: 30), method: .erase)
        guard case let .filtered(whole, area) = Redactor.coverage(for: redaction, id: markID, source: .init(base: base), scale: 1, canvas: canvas) else {
            Issue.record("No fill")
            return
        }
        #expect(area == CGRect(x: 30, y: 20, width: 40, height: 30))
        let filled = Pixels(whole)
        var unlike = 0
        for y in 0..<filled.height {
            for x in 0..<filled.width where abs(filled[x, y].r - 250) > 2 || abs(filled[x, y].g - 250) > 2 { unlike += 1 }
        }
        #expect(unlike == 0, "\(unlike) pixels take in what lies outside the canvas")
        // The same erasure on the picture cut to the canvas, as Annotate Area keeps it.
        let cut = try #require(base.cropping(to: canvas))
        let moved = Redaction(rect: redaction.rect.offsetBy(dx: -canvas.minX, dy: -canvas.minY), method: .erase)
        guard case let .filtered(kept, keptArea) = Redactor.coverage(for: moved, id: markID, source: .init(base: cut), scale: 1) else {
            Issue.record("No fill on the cut picture")
            return
        }
        #expect(keptArea == area.offsetBy(dx: -canvas.minX, dy: -canvas.minY))
        let all = CGRect(x: 0, y: 0, width: whole.width, height: whole.height)
        #expect(Pixels(kept).region(all) == filled.region(all))
    }
}

/// The canvas draws an erasure as the export does, and makes it again when a redaction beside it comes or
/// moves.
@MainActor
struct EraseCanvasTests {
    private let scratch = ScratchDefaults()

    @Test func theCanvasErasesAsTheExportDoes() throws {
        let width = 120, height = 80
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for x in stride(from: 0, to: width, by: 3) {
            context.setFillColor(CGColor(srgbRed: CGFloat(x % 7) / 7, green: CGFloat(x % 5) / 5, blue: CGFloat(x % 3) / 3, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 3, height: height))
        }
        let base = try #require(context.makeImage())
        let session = AnnotationSession(image: base, scale: 1, tool: .select, defaults: scratch.make())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = AnnotationCanvasView(session: session)
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()

        let erasure = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 30, y: 24, width: 50, height: 22), method: .erase)), style: Style(color: .black, shadow: false))
        let solid = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 70, y: 10, width: 30, height: 50))), style: Style(color: .black, shadow: false))
        func shown() throws -> [UInt8] {
            guard case let .filtered(image, _) = try #require(canvas.markLayer(for: erasure.id)).coverage else {
                Issue.record("Expected an erasure on the canvas"); return []
            }
            return Pixels(image).region(CGRect(x: 0, y: 0, width: 50, height: 22))
        }
        func exported(_ document: AnnotationDocument) throws -> [UInt8] {
            let pixels = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
            return pixels.region(CGRect(x: 30, y: 24, width: 40, height: 22))
        }
        func left(_ tile: [UInt8]) -> [UInt8] {
            (0..<22).flatMap { row in tile[(row * 50 * 4)..<(row * 50 * 4 + 40 * 4)] }
        }

        var document = session.document
        document.items = [erasure]
        session.commit(document, actionName: "Add Redaction")
        let alone = try shown()
        #expect(left(alone) == (try exported(document)))
        // A solid redaction over the band on its right: the erasure no longer reads what it hides.
        document.items = [erasure, solid]
        session.commit(document, actionName: "Add Redaction")
        let beside = try shown()
        #expect(beside != alone)
        #expect(left(beside) == (try exported(document)))
        // Moved away, the erasure reads that band again.
        document.items = [erasure, Annotation(id: solid.id, shape: .redaction(Redaction(rect: CGRect(x: 0, y: 70, width: 10, height: 10))), style: solid.style)]
        session.commit(document, actionName: "Move")
        #expect(try shown() == alone)
    }

    /// While cropping, the whole picture shows, and an erasure reaching past the canvas covers what it covers there
    /// too, as it will once a wider crop is kept; the crop put down, it keeps inside the canvas again.
    @Test func whileCroppingAnErasureCoversPastTheCanvas() throws {
        let width = 120, height = 80
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let base = try #require(context.makeImage())
        let session = AnnotationSession(image: base, scale: 1, tool: .select, defaults: scratch.make())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = AnnotationCanvasView(session: session)
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()

        let erasure = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 40, y: 24, width: 50, height: 22), method: .erase)), style: Style(color: .black, shadow: false))
        var document = session.document
        document.canvas = CGRect(x: 0, y: 0, width: 60, height: 80)
        document.items = [erasure]
        session.commit(document, actionName: "Add Redaction")
        func covered() throws -> CGRect? {
            guard case let .filtered(_, rect) = try #require(canvas.markLayer(for: erasure.id)).coverage else { return nil }
            return rect
        }
        #expect(try covered() == CGRect(x: 40, y: 24, width: 20, height: 22))
        session.tool = .crop
        #expect(try covered() == CGRect(x: 40, y: 24, width: 50, height: 22))
        session.tool = .select
        #expect(session.document.canvas == CGRect(x: 0, y: 0, width: 60, height: 80))
        #expect(try covered() == CGRect(x: 40, y: 24, width: 20, height: 22))
    }

    /// During a drag an erasure is not filled again at each step: its last fill stretches over the box, so nothing
    /// under it shows, and it is filled for where it lies once the drag ends.
    @Test func anErasureIsFilledAgainOnceADragEnds() throws {
        let width = 120, height = 80
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: height))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 60, y: 0, width: 60, height: height))
        let base = try #require(context.makeImage())
        let session = AnnotationSession(image: base, scale: 1, tool: .select, defaults: scratch.make())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = AnnotationCanvasView(session: session)
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()

        let erasure = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 10, y: 20, width: 30, height: 20), method: .erase)), style: Style(color: .black, shadow: false))
        var document = session.document
        document.items = [erasure]
        session.commit(document, actionName: "Add Redaction")
        func coverage() throws -> (image: CGImage, rect: CGRect)? {
            guard case let .filtered(image, rect) = try #require(canvas.markLayer(for: erasure.id)).coverage else { return nil }
            return (image, rect)
        }
        let dark = try #require(try coverage())
        // Dragged onto the light half.
        session.beginLiveChange()
        let moved = CGRect(x: 75, y: 20, width: 40, height: 20)
        document.items = [Annotation(id: erasure.id, shape: .redaction(Redaction(rect: moved, method: .erase)), style: erasure.style)]
        session.updateLive(document)
        let dragging = try #require(try coverage())
        #expect(dragging.image === dark.image && dragging.rect == moved)
        session.endLiveChange(actionName: "Move")
        let light = try #require(try coverage())
        #expect(light.rect == moved && light.image !== dark.image)
        let fresh = Redactor.coverage(for: Redaction(rect: moved, method: .erase), id: erasure.id, source: .init(base: base), scale: 1, canvas: session.document.canvas)
        guard case let .filtered(expected, _)? = fresh else { Issue.record("No fill"); return }
        #expect(Pixels(light.image).region(CGRect(x: 0, y: 0, width: 40, height: 20)) == Pixels(expected).region(CGRect(x: 0, y: 0, width: 40, height: 20)))
    }
}
