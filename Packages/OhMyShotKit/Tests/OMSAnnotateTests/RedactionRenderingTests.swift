import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore
import Testing
import Vision
@testable import OMSAnnotate

struct RedactionRenderingTests {
    private let scale: CGFloat = 2
    private let markID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    private func context(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func fixture(_ text: String, pointSize: CGFloat) throws -> (image: CGImage, rect: CGRect) {
        let font = try #require(CTFontCreateUIFontForLanguage(pointSize >= 36 ? .emphasizedSystem : .system, pointSize * scale, nil))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let pad = (pointSize * scale * 1.5).rounded()
        let width = Int(ceil(bounds.width) + 2 * pad)
        let height = Int(ceil(bounds.height) + 2 * pad)
        let context = try context(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, context)
        let rect = CGRect(x: pad, y: CGFloat(height) - pad - bounds.height, width: bounds.width, height: bounds.height)
        return (try #require(context.makeImage()), rect.insetBy(dx: -4 * scale, dy: -4 * scale).integral)
    }

    private func digits(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().filter(\.isNumber)
    }

    @Test func visionReadsNoDigitsInFilteredFixtures() throws {
        for size: CGFloat in [13, 24, 36, 60, 96] {
            for text in ["835 204", "4929 1038 5562 7716", "Hunter2!x"] {
                let (base, rect) = try fixture(text, pointSize: size)
                try #require(digits(in: base) == text.filter(\.isNumber), "Unreadable control: \(text) at \(size) pt")
                for method in [Redaction.Method.blur, .pixelate] {
                    let mark = Annotation(id: markID, shape: .redaction(Redaction(rect: rect, method: method)), style: Style())
                    let document = AnnotationDocument(pixelSize: CGSize(width: base.width, height: base.height), scale: scale, items: [mark])
                    let output = try #require(AnnotationRenderer.flatten(document, base: base))
                    let pixels = Pixels(output)
                    #expect(pixels[Int(rect.midX), Int(rect.midY)].r > 0, "Unexpected solid fallback for \(method) at \(size) pt")
                    #expect(try digits(in: output).isEmpty, "\(method) on \(text) at \(size) pt")
                }
            }
        }
    }

    @Test func aUISizedSelectionKeepsSmallBlocksButAHeadingGetsLargerOnes() {
        #expect(Redactor.blockSize(for: CGRect(x: 0, y: 0, width: 116, height: 47), scale: 2) == 12)
        #expect(Redactor.blockSize(for: CGRect(x: 0, y: 0, width: 785, height: 243), scale: 2) > 100)
    }

    private func box(_ rect: CGRect, color: RGBA) -> Annotation {
        Annotation(shape: .rectangle(Box(rect: rect, filled: true)), style: Style(color: color, shadow: false))
    }

    private func cornerFixture(opaqueBorder: Bool = false) throws -> CGImage {
        let input = try context(width: 64, height: 40)
        if opaqueBorder {
            input.setFillColor(CGColor(gray: 1, alpha: 1))
            input.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            input.clear(CGRect(x: 2, y: 2, width: 60, height: 36))
        }
        input.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        for x in stride(from: 20, to: 64, by: 8) { input.fill(CGRect(x: x, y: 7, width: 4, height: 26)) }
        return try #require(input.makeImage())
    }

    @Test(arguments: [Redaction.Method.blur, .pixelate], [false, true])
    func filteredCornerPreservesBackdropAndCardMatte(method: Redaction.Method, opaqueBorder: Bool) throws {
        let base = try cornerFixture(opaqueBorder: opaqueBorder)
        let redaction = Redaction(rect: CGRect(x: -4, y: -4, width: 55, height: 38), method: method)
        let mark = Annotation(id: markID, shape: .redaction(redaction), style: Style())
        let backdrop = Backdrop(fill: .color(RGBA(red: 1, green: 0, blue: 0)), padding: 0.1, cornerRadius: 14, shadow: 0)
        let document = AnnotationDocument(pixelSize: CGSize(width: 64, height: 40), scale: 1, items: [mark], backdrop: backdrop)
        let layout = try #require(document.backdropLayout(edges: EdgeAnalysis.of(base, canvas: document.canvas)))
        #expect(layout.isBare == !opaqueBorder)
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
        guard case let .filtered(tile, rect) = Redactor.coverage(for: redaction, id: markID, source: .init(base: base), scale: 1) else {
            Issue.record("Expected the real filter to succeed"); return
        }
        let reference = try context(width: pixels.width, height: pixels.height)
        reference.translateBy(x: 0, y: CGFloat(pixels.height))
        reference.scaleBy(x: 1, y: -1)
        reference.translateBy(x: -layout.output.minX, y: -layout.output.minY)
        reference.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        reference.fill(layout.output)
        if opaqueBorder {
            let path = CGPath(roundedRect: layout.card, cornerWidth: 14, cornerHeight: 14, transform: nil)
            reference.setFillColor(CGColor(gray: 1, alpha: 1))
            reference.addPath(path)
            reference.fillPath()
            reference.addPath(path)
            reference.clip()
        }
        reference.interpolationQuality = method == .pixelate ? .none : .high
        AnnotationRenderer.drawImage(tile, in: rect, context: reference)
        let expected = Pixels(try #require(reference.makeImage()))
        let outputRect = rect.offsetBy(dx: -layout.output.minX, dy: -layout.output.minY)
        #expect(pixels.region(outputRect) == expected.region(outputRect))
        #expect((0..<pixels.height).allSatisfy { y in (0..<pixels.width).allSatisfy { x in pixels[x, y].a == 255 } })
    }

    @Test func clearFilteredTilesSampleTheirOwnPositionsOnAGradient() throws {
        let base = try #require(context(width: 64, height: 40).makeImage())
        var document = AnnotationDocument(pixelSize: CGSize(width: 64, height: 40), scale: 1, backdrop: Backdrop(fill: .gradient(.rose), padding: 0))
        let ground = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
        document.items = [CGRect(x: 0, y: 0, width: 12, height: 12), CGRect(x: 52, y: 28, width: 12, height: 12)].map {
            Annotation(shape: .redaction(Redaction(rect: $0, method: .pixelate)), style: Style())
        }
        let covered = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
        #expect(abs(ground[4, 4].b - ground[60, 36].b) > 15)
        for (x, y) in [(4, 4), (60, 36)] {
            let sample = covered[x, y], expected = ground[x, y]
            #expect(sample.a == 255)
            #expect(max(abs(sample.r - expected.r), abs(sample.g - expected.g), abs(sample.b - expected.b)) <= 3)
        }
    }

    @Test(arguments: [Redaction.Method.blur, .pixelate])
    func translucentFilterReplacesOnlyItsClippedRectInTheFlattenedExport(method: Redaction.Method) throws {
        let width = 96, height = 48
        let input = try context(width: width, height: height)
        input.setFillColor(CGColor(gray: 1, alpha: 0.4))
        input.fill(CGRect(x: 0, y: 0, width: 40, height: height))
        input.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 0, to: 40, by: 8) { input.fill(CGRect(x: x, y: 4, width: 3, height: 36)) }
        let base = try #require(input.makeImage())
        let redaction = Redaction(rect: CGRect(x: -5.5, y: 8.5, width: 90, height: 30), method: method)
        let mark = Annotation(id: markID, shape: .redaction(redaction), style: Style())
        let below = box(CGRect(x: 60, y: 0, width: 24, height: 48), color: .green)
        let above = box(CGRect(x: 12, y: 25, width: 8, height: 18), color: .red)
        var document = AnnotationDocument(pixelSize: CGSize(width: width, height: height), scale: 1, items: [below, above])
        let outside = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
        document.items = [below, mark, above]
        let result = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))

        guard case let .filtered(image, rect) = Redactor.coverage(for: redaction, id: markID, source: .init(base: base), scale: 1) else {
            Issue.record("Expected a filtered image"); return
        }
        #expect(rect == CGRect(x: 0, y: 8, width: 85, height: 31))
        let alone = try context(width: width, height: height)
        alone.translateBy(x: 0, y: CGFloat(height))
        alone.scaleBy(x: 1, y: -1)
        alone.interpolationQuality = method == .pixelate ? .none : .high
        AnnotationRenderer.drawImage(image, in: rect, context: alone)
        AnnotationRenderer.draw(above, in: alone, scale: 1)
        let inside = Pixels(try #require(alone.makeImage()))
        #expect(inside[8, 15].a > 0 && inside[8, 15].a < 255)
        #expect(inside[80, 20].a == 0 && outside[80, 20].a == 255)
        #expect(result.region(rect) == inside.region(rect))
        for strip in [
            CGRect(x: 0, y: 0, width: width, height: 8), CGRect(x: 85, y: 8, width: 11, height: 31),
            CGRect(x: 0, y: 39, width: width, height: 9),
        ] {
            #expect(result.region(strip) == outside.region(strip))
        }
    }

    @Test func canvasFilteredLayerReplacesClearAndPartialPixelsBetweenNeighboringMarks() throws {
        let width = 36, height = 20
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let rect = CGRect(x: 5, y: 4, width: 24, height: 12)
        let tile = try context(width: 24, height: 12)
        tile.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5))
        tile.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        let mark = Annotation(shape: .redaction(Redaction(rect: canvas, method: .pixelate)), style: Style())
        let replacement = MarkLayer(mark: mark)
        replacement.coverage = .filtered(try #require(tile.makeImage()), rect)
        replacement.frame = replacement.documentDrawingBounds
        replacement.mapping = LayerMapping(origin: rect.origin, zoom: 1)
        #expect(replacement.frame == rect)

        let root = CALayer()
        root.frame = canvas
        let lower = CALayer()
        lower.frame = canvas
        lower.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let upper = CALayer()
        upper.frame = CGRect(x: 10, y: 0, width: 3, height: height)
        upper.backgroundColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        root.addSublayer(lower)
        root.addSublayer(replacement)
        root.addSublayer(upper)
        replacement.setNeedsDisplay()
        replacement.displayIfNeeded()

        let bytes = try renderedBytes(root, width: width, height: height)
        func bgra(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<offset + 4])
        }
        #expect(bgra(6, 10) == [128, 0, 0, 128])
        #expect(bgra(24, 10) == [0, 0, 0, 0])
        #expect(bgra(11, 10) == [0, 255, 0, 255])
        #expect(bgra(4, 10) == [0, 0, 255, 255] && bgra(29, 10) == [0, 0, 255, 255])
        #expect(bgra(6, 3) == [0, 0, 255, 255] && bgra(6, 16) == [0, 0, 255, 255])
        replacement.coverage = .opaque(rect)
        #expect(replacement.compositingFilter == nil && !replacement.masksToBounds)
    }

    private func renderedBytes(_ root: CALayer, width: Int, height: Int) throws -> [UInt8] {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        renderer.layer = root
        renderer.bounds = canvas
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(canvas)
        renderer.render()
        renderer.endFrame()
        let completion = try #require(queue.makeCommandBuffer())
        completion.commit()
        completion.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    @Test func canvasPixelatedCornerCompositesOverTheBackdropWithoutTheSourceDetail() throws {
        let base = try cornerFixture()
        let canvas = CGRect(x: 0, y: 0, width: 64, height: 40)
        let redaction = Redaction(rect: canvas, method: .pixelate)
        let backdrop = Backdrop(fill: .color(RGBA(red: 1, green: 0, blue: 0)), padding: 0, shadow: 0)
        let document = AnnotationDocument(pixelSize: canvas.size, scale: 1, backdrop: backdrop)
        let layout = try #require(document.backdropLayout(edges: EdgeAnalysis.of(base, canvas: canvas)))
        let surface = BackdropPainter.Surface(fill: backdrop.fill, layout: layout, shadow: nil)
        let root = CALayer()
        root.frame = canvas
        let ground = BackdropLayer()
        ground.frame = canvas
        ground.content = surface
        root.addSublayer(ground)
        let capture = CALayer()
        capture.frame = canvas
        capture.contents = base
        root.addSublayer(capture)
        let mark = MarkLayer(mark: Annotation(id: markID, shape: .redaction(redaction), style: Style()))
        mark.coverage = Redactor.coverage(for: redaction, id: markID, source: .init(base: base), scale: 1)
        guard case let .filtered(tile, _) = mark.coverage else { Issue.record("Expected pixelation"); return }
        mark.underlay = .init(surface: surface, blur: nil, matte: nil, canvas: canvas)
        mark.frame = mark.documentDrawingBounds
        root.addSublayer(mark)
        mark.displayIfNeeded()
        ground.displayIfNeeded()
        let rendered = try renderedBytes(root, width: 64, height: 40)
        let expectedRoot = CALayer()
        expectedRoot.frame = canvas
        expectedRoot.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let filtered = CALayer()
        filtered.contents = tile
        filtered.frame = canvas
        expectedRoot.addSublayer(filtered)
        let expected = try renderedBytes(expectedRoot, width: 64, height: 40)
        #expect(stride(from: 3, to: rendered.count, by: 4).allSatisfy { rendered[$0] == 255 })
        #expect(zip(rendered, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @Test(arguments: [Redaction.Method.blur, .pixelate])
    func failedFilterCoversOnlyTheIntersectionInTheFlattenedExport(method: Redaction.Method) throws {
        let context = try context(width: 40, height: 30)
        context.setFillColor(CGColor(gray: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let base = try #require(context.makeImage())
        var document = AnnotationDocument(pixelSize: CGSize(width: 40, height: 30), scale: scale)
        document.canvas = CGRect(x: -20, y: 0, width: 60, height: 30)
        let plain = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
        let style = Style(color: RGBA(red: 1, green: 0, blue: 0, alpha: 0.05))
        document.items = [
            CGRect(x: -8.5, y: 4.5, width: 18, height: 10),
            CGRect(x: -19, y: 2, width: 6, height: 10),
        ].map { Annotation(shape: .redaction(Redaction(rect: $0, method: method)), style: style) }
        var filtered: [CGRect] = []
        let output = try #require(AnnotationRenderer.flatten(document, base: base, redactionFilter: { _, rect, _, _, _ in
            filtered.append(rect)
            return nil
        }))
        #expect(filtered == [CGRect(x: 0, y: 4, width: 10, height: 11)])
        let pixels = Pixels(output)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                if (20..<30).contains(x), (4..<15).contains(y) {
                    #expect(pixels[x, y] == (0, 0, 0, 255))
                } else {
                    #expect(pixels[x, y] == plain[x, y])
                }
            }
        }
    }
}
