import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Each redaction reads the picture as it lies beneath it, every redaction drawn before it on it, and a blurred background
/// is made from the picture with its redactions on it, so nothing a redaction hides comes back through another one, or
/// around the picture.
struct StackedRedactionTests {
    private let scratch = ScratchDefaults()
    /// The solid redactions' color: white and it mixed keep red and green the same, which red under them never does.
    private let ink = RGBA(red: 0, green: 0, blue: 1)

    /// White, with a red block where `secret` says: what a solid redaction is drawn over to hide.
    private func picture(width: Int = 120, height: Int = 90, secret: CGRect) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(secret)
        return try #require(context.makeImage())
    }

    private func redaction(_ rect: CGRect, _ method: Redaction.Method = .solid) -> Annotation {
        Annotation(shape: .redaction(Redaction(rect: rect, method: method)), style: Style(color: ink, shadow: false))
    }

    private func document(_ base: CGImage, _ items: [Annotation], backdrop: Backdrop? = nil) -> AnnotationDocument {
        AnnotationDocument(pixelSize: CGSize(width: base.width, height: base.height), scale: 1, items: items, backdrop: backdrop)
    }

    /// Whether every pixel of `pixels` in `rect` is within `tolerance` of the solid redactions' color.
    private func isInk(_ pixels: Pixels, _ rect: CGRect, tolerance: Int) -> Bool {
        (Int(rect.minY)..<Int(rect.maxY)).allSatisfy { y in
            (Int(rect.minX)..<Int(rect.maxX)).allSatisfy { x in
                let pixel = pixels[x, y]
                return pixel.r <= tolerance && pixel.g <= tolerance && pixel.b >= 255 - tolerance && pixel.a == 255
            }
        }
    }

    /// The most that red stands above green in `pixels` within `rect`: nothing in white, the ink, or any mixture
    /// of the two.
    private func redness(_ pixels: Pixels, _ rect: CGRect) -> Int {
        (Int(rect.minY)..<Int(rect.maxY)).flatMap { y in (Int(rect.minX)..<Int(rect.maxX)).map { x in pixels[x, y].r - pixels[x, y].g } }.max() ?? 0
    }

    /// A blur or pixelation inside a solid redaction shows the solid: its blocks' noise moves it a little, and the
    /// blur reads nothing past the solid, so it is the solid exactly.
    @Test(arguments: [Redaction.Method.blur, .pixelate])
    func aRedactionOverASolidOneShowsTheSolid(method: Redaction.Method) throws {
        let base = try picture(secret: CGRect(x: 20, y: 20, width: 80, height: 50))
        let solid = redaction(CGRect(x: 10, y: 10, width: 100, height: 70))
        // The blur reads 18 px around its 20 px box, all inside the solid.
        let over = CGRect(x: 50, y: 35, width: 20, height: 20)
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(document(base, [solid, redaction(over, method)]), base: base)))
        #expect(isInk(pixels, over, tolerance: method == .blur ? 0 : 19))
    }

    /// A blur reaching past a solid redaction blurs the solid into the picture around it, never what the solid hides.
    @Test func aBlurPastASolidRedactionBlursTheSolid() throws {
        let base = try picture(secret: CGRect(x: 30, y: 30, width: 60, height: 30))
        let items = [redaction(CGRect(x: 26, y: 26, width: 68, height: 38)), redaction(CGRect(x: 10, y: 10, width: 100, height: 70), .blur)]
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(document(base, items), base: base)))
        #expect(redness(pixels, CGRect(x: 0, y: 0, width: 120, height: 90)) <= 2)
    }

    /// A pixelation over a blur pixelates the blur, as it is drawn on the picture.
    @Test func aPixelationOverABlurPixelatesTheBlur() throws {
        let base = makeBase()
        let blur = redaction(CGRect(x: 10, y: 20, width: 120, height: 60), .blur)
        let pixelate = redaction(CGRect(x: 40, y: 30, width: 60, height: 36), .pixelate)
        let blurred = try #require(AnnotationRenderer.flatten(document(base, [blur]), base: base))
        guard case .redaction(let pixelation) = pixelate.shape,
              case let .filtered(expected, rect)? = Redactor.coverage(for: pixelation, id: pixelate.id, source: .init(base: blurred), scale: 1),
              case let .filtered(plain, _)? = Redactor.coverage(for: pixelation, id: pixelate.id, source: .init(base: base), scale: 1)
        else { Issue.record("Expected pixelations"); return }
        let whole = CGRect(origin: .zero, size: rect.size)
        // The blur changed what lies there, so a pixelation reading under it would show.
        #expect(Pixels(expected).region(whole) != Pixels(plain).region(whole))
        let stacked = Pixels(try #require(AnnotationRenderer.flatten(document(base, [blur, pixelate]), base: base)))
        #expect(stacked.region(rect) == Pixels(expected).region(whole))
    }

    /// The canvas shows what the export shows: a blur over a solid redaction blurs the solid, reads the picture again
    /// once the solid is dragged away, and blurs the solid again when it comes back.
    @Test func theCanvasBlursWhatTheRedactionsBeneathLeave() throws {
        let base = try picture(secret: CGRect(x: 20, y: 20, width: 80, height: 50))
        let session = AnnotationSession(image: base, scale: 1, tool: .select, defaults: scratch.make())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = AnnotationCanvasView(session: session)
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()

        let solid = redaction(CGRect(x: 10, y: 10, width: 100, height: 70))
        let blur = redaction(CGRect(x: 50, y: 35, width: 20, height: 20), .blur)
        let tile = CGRect(x: 0, y: 0, width: 20, height: 20)
        func shown() throws -> Pixels {
            guard case let .filtered(image, rect) = try #require(canvas.markLayer(for: blur.id)).coverage else {
                Issue.record("Expected a blur on the canvas"); return Pixels(base)
            }
            #expect(rect == CGRect(x: 50, y: 35, width: 20, height: 20))
            return Pixels(image)
        }
        func exported() throws -> [UInt8] {
            Pixels(try #require(AnnotationRenderer.flatten(session.document, base: base))).region(CGRect(x: 50, y: 35, width: 20, height: 20))
        }

        var document = session.document
        document.items = [solid, blur]
        session.commit(document, actionName: "Add Redaction")
        #expect(isInk(try shown(), tile, tolerance: 0))
        #expect(try shown().region(tile) == (try exported()))

        session.beginLiveChange()
        document.items = [solid.translated(by: CGSize(width: 0, height: 200)), blur]
        session.updateLive(document)
        session.endLiveChange(actionName: "Move")
        #expect(redness(try shown(), tile) > 100)
        #expect(try shown().region(tile) == (try exported()))

        document.items = [solid, blur]
        session.commit(document, actionName: "Move")
        #expect(isInk(try shown(), tile, tolerance: 0))
    }

    /// A blurred background is made from the picture with its redactions on it: around the picture it carries no trace
    /// of what a solid redaction hides, in the export or in the editor.
    @Test func aBlurredBackgroundCarriesNothingASolidRedactionHides() throws {
        let base = try picture(width: 80, height: 60, secret: CGRect(x: 10, y: 10, width: 60, height: 40))
        let backdrop = Backdrop(fill: .blur, padding: 0.25, shadow: 0)
        let solid = redaction(CGRect(x: 8, y: 8, width: 64, height: 44))
        let bare = Pixels(try #require(AnnotationRenderer.flatten(document(base, [], backdrop: backdrop), base: base)))
        let covered = Pixels(try #require(AnnotationRenderer.flatten(document(base, [solid], backdrop: backdrop), base: base)))
        // The room above the picture, all background.
        let room = CGRect(x: 0, y: 0, width: covered.width, height: 10)
        #expect(redness(bare, room) > 30)
        #expect(redness(covered, room) <= 2)

        let session = AnnotationSession(image: base, scale: 1, tool: .select, defaults: scratch.make())
        var edited = session.document
        edited.backdrop = backdrop
        session.commit(edited, actionName: "Background")
        let before = try #require(session.blurredCapture)
        #expect(redness(Pixels(before), CGRect(x: 0, y: 0, width: before.width, height: before.height)) > 30)
        edited.items = [solid]
        session.commit(edited, actionName: "Add Redaction")
        let after = try #require(session.blurredCapture)
        #expect(redness(Pixels(after), CGRect(x: 0, y: 0, width: after.width, height: after.height)) <= 2)
        // Not made again at every step of a drag, but once it ends.
        session.beginLiveChange()
        edited.items = [solid.translated(by: CGSize(width: 200, height: 0))]
        session.updateLive(edited)
        #expect(session.blurredCapture === after)
        session.endLiveChange(actionName: "Move")
        let moved = try #require(session.blurredCapture)
        #expect(redness(Pixels(moved), CGRect(x: 0, y: 0, width: moved.width, height: moved.height)) > 30)
    }

    /// A redaction fitting what it hides exactly, on a capture many times larger than the background's small picture,
    /// with its edges between that picture's pixels: none of what it hides gets into the pixels along its edge.
    @Test func aBlurredBackgroundKeepsNothingAlongATightRedactionsEdge() throws {
        let secret = CGRect(x: 101, y: 87, width: 333, height: 217)
        let base = try picture(width: 1000, height: 700, secret: secret)
        let document = document(base, [redaction(secret)])
        let blurred = try #require(BackdropPainter.blurredCapture(
            base, canvas: document.canvas, redactions: document.redactionCovers(source: .init(base: base)), scale: 1
        ))
        #expect(redness(Pixels(blurred), CGRect(x: 0, y: 0, width: blurred.width, height: blurred.height)) <= 2)
    }
}
