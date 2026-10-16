import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
struct PictureTransformTests {
    init() {
        PictureStore.use(URL.temporaryDirectory.appending(path: "OhMyShotKit Tests \(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory))
    }

    private static let operations: [PictureOperation] = [.rotateRight, .rotateLeft, .flipHorizontally, .flipVertically]

    private static let orientations: [Orientation] = (0..<4).flatMap { turns in
        [false, true].map { Orientation(quarterTurns: turns, mirrored: $0) }
    }

    /// A capture 200 × 100 with marks on whole pixels, none of them symmetric. Text is added where it
    /// matters: the size of its box is not a whole number, so it does not come back exactly.
    private func makeDocument() -> AnnotationDocument {
        AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 2, items: [
            Annotation(shape: .rectangle(Box(rect: CGRect(x: 10, y: 20, width: 30, height: 10))), style: Style(lineWidth: 2)),
            Annotation(shape: .arrow(Arrow(start: CGPoint(x: 20, y: 70), end: CGPoint(x: 120, y: 30), bend: 14)), style: Style()),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 170, y: 20), value: 1)), style: Style()),
            Annotation(shape: .redaction(Redaction(rect: CGRect(x: 150, y: 50, width: 40, height: 20))), style: Style(color: .black)),
            Annotation(shape: .highlightBox(Box(rect: CGRect(x: 5, y: 80, width: 60, height: 12), filled: true)), style: Style(color: .marker, shadow: false)),
        ])
    }

    /// The pixel size and the pixels of a small picture whose every pixel has its own color.
    private func makeGrid(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(x * 40 + 10)
                bytes[index + 1] = UInt8(y * 40 + 10)
                bytes[index + 2] = 100
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001
    }

    // MARK: Orientation

    @Test func eachOperationComposesOnTopOfTheOrientationBeforeIt() {
        let source = CGSize(width: 30, height: 20)
        let probe = CGPoint(x: 7, y: 3)
        for orientation in Self.orientations {
            let size = orientation.size(of: source)
            for operation in Self.operations {
                let turn = Orientation.identity.applying(operation)
                let expected = probe.applying(orientation.transform(for: source)).applying(turn.transform(for: size))
                let actual = probe.applying(orientation.applying(operation).transform(for: source))
                #expect(close(expected, actual), "\(orientation) then \(operation)")
            }
        }
    }

    @Test func turnsAndFlipsUndoEachOther() {
        let document = makeDocument()
        func apply(_ operations: [PictureOperation]) -> AnnotationDocument? {
            operations.reduce(Optional(document)) { $0?.applying($1) }
        }
        let four = apply([.rotateRight, .rotateRight, .rotateRight, .rotateRight])
        #expect(four?.transform == nil)
        #expect(four?.items == document.items)
        #expect(apply([.rotateRight, .rotateLeft])?.items == document.items)
        #expect(apply([.flipHorizontally, .flipHorizontally])?.transform == nil)
        #expect(apply([.flipVertically, .flipVertically])?.items == document.items)
        // A vertical flip is a horizontal flip and a half turn.
        #expect(apply([.flipVertically])?.orientation == apply([.flipHorizontally, .rotateRight, .rotateRight])?.orientation)
        // Back where it started: the same document, not merely a look-alike. (Four turns change nothing, so
        // `applying` has nothing to return; a turn and its undo come back whole.)
        #expect(apply([.rotateRight, .rotateLeft, .flipHorizontally, .flipHorizontally]) == document)
    }

    @Test func aTurnedCaptureIsNoLongerWhatWasTaken() {
        let document = AnnotationDocument(pixelSize: CGSize(width: 40, height: 20), scale: 2)
        #expect(document.isEmpty)
        let turned = document.applying(.rotateRight)
        #expect(turned?.isEmpty == false)
        #expect(turned?.pictureSize == CGSize(width: 20, height: 40))
        #expect(turned?.imageBounds == CGRect(x: 0, y: 0, width: 20, height: 40))
        #expect(turned?.canvas == CGRect(x: 0, y: 0, width: 20, height: 40))
        // The capture's own size is what it was.
        #expect(turned?.pixelSize == document.pixelSize)
        #expect(turned?.applying(.rotateLeft)?.isEmpty == true)
    }

    // MARK: Marks

    @Test func marksStayOnTheSamePartOfThePictureWhenItIsTurned() throws {
        let document = makeDocument()
        let turned = try #require(document.applying(.rotateRight))
        // (x, y) goes to (100 - y, x) in a picture 100 high.
        guard case .rectangle(let box) = turned.items[0].shape else { throw Failure.shape }
        #expect(box.rect == CGRect(x: 70, y: 10, width: 10, height: 30))
        guard case .redaction(let redaction) = turned.items[3].shape else { throw Failure.shape }
        #expect(redaction.rect == CGRect(x: 30, y: 150, width: 20, height: 40))
        guard case .counter(let counter) = turned.items[2].shape else { throw Failure.shape }
        #expect(counter.center == CGPoint(x: 80, y: 170))
        #expect(turned.items.map(\.id) == document.items.map(\.id))
    }

    @Test func aFlipMirrorsMarksAcrossThePicture() throws {
        let document = makeDocument()
        let flipped = try #require(document.applying(.flipHorizontally))
        guard case .rectangle(let box) = flipped.items[0].shape else { throw Failure.shape }
        #expect(box.rect == CGRect(x: 160, y: 20, width: 30, height: 10))
        let below = try #require(document.applying(.flipVertically))
        guard case .rectangle(let lower) = below.items[0].shape else { throw Failure.shape }
        #expect(lower.rect == CGRect(x: 10, y: 70, width: 30, height: 10))
        // The canvas, cropped, goes with it.
        var cropped = document
        cropped.canvas = CGRect(x: 20, y: 10, width: 100, height: 50)
        #expect(cropped.applying(.flipHorizontally)?.canvas == CGRect(x: 80, y: 10, width: 100, height: 50))
        #expect(cropped.applying(.rotateLeft)?.canvas == CGRect(x: 10, y: 80, width: 50, height: 100))
    }

    @Test func anArrowsCurveFollowsThePictureAndAFlipSwapsItsBend() throws {
        let document = makeDocument()
        guard case .arrow(let original) = document.items[1].shape else { throw Failure.shape }
        let affines: [(PictureOperation, CGAffineTransform)] = Self.operations.map { operation in
            (operation, Orientation.identity.applying(operation).transform(for: document.pictureSize))
        }
        for (operation, affine) in affines {
            let changed = try #require(document.applying(operation))
            guard case .arrow(let arrow) = changed.items[1].shape else { throw Failure.shape }
            // Wherever the curve's middle was, it is there mapped.
            #expect(close(ArrowPath.middle(of: arrow), ArrowPath.middle(of: original).applying(affine)), "\(operation)")
            let flips = operation == .flipHorizontally || operation == .flipVertically
            #expect(arrow.bend == (flips ? -original.bend : original.bend), "\(operation)")
        }
        // A straight arrow stays straight.
        var straight = document
        straight.items[1].shape = .arrow(Arrow(start: .zero, end: CGPoint(x: 50, y: 20)))
        guard case .arrow(let kept) = straight.applying(.flipHorizontally)?.items[1].shape else { throw Failure.shape }
        #expect(kept.bend == 0)
    }

    @Test func textStaysUprightWhileItsMiddleMoves() throws {
        var document = makeDocument()
        document.items.append(Annotation(shape: .text(TextBlock(origin: CGPoint(x: 100, y: 60), string: "Hi there", fontSize: 14, look: .label)), style: Style()))
        let index = document.items.count - 1
        let before = document.items[index].bounds(scale: document.scale)
        for operation in Self.operations {
            let turn = Orientation.identity.applying(operation)
            let affine = turn.transform(for: document.pictureSize)
            let changed = try #require(document.applying(operation))
            guard case .text(let block) = changed.items[index].shape, case .text(let first) = document.items[index].shape else { throw Failure.shape }
            let after = changed.items[index].bounds(scale: changed.scale)
            // The letters are as they were, and the block is the size it was.
            #expect(block.string == first.string && block.fontSize == first.fontSize)
            #expect(abs(after.width - before.width) < 0.001 && abs(after.height - before.height) < 0.001)
            #expect(close(CGPoint(x: after.midX, y: after.midY), CGPoint(x: before.midX, y: before.midY).applying(affine)), "\(operation)")
        }
    }

    @Test func combinedImagesTurnWithThePicture() throws {
        var document = makeDocument()
        document.items.append(Annotation(shape: .image(PlacedImage(rect: CGRect(x: 20, y: 10, width: 60, height: 30), name: "a.png")), style: Style(shadow: false)))
        let turned = try #require(document.applying(.rotateRight))
        guard case .image(let image) = turned.items.last?.shape else { throw Failure.shape }
        #expect(image.rect == CGRect(x: 60, y: 20, width: 30, height: 60))
        #expect(image.orientation == Orientation(quarterTurns: 1))
        let back = try #require(turned.applying(.rotateLeft))
        guard case .image(let restored) = back.items.last?.shape else { throw Failure.shape }
        #expect(restored.orientation == nil)
        #expect(restored.rect == CGRect(x: 20, y: 10, width: 60, height: 30))
    }

    @Test func aTurnedImageIsDrawnTurnedInItsBox() throws {
        // Two pixels, red left of blue; turned right, red is above blue in a box one wide and two high.
        let source = makeGrid(width: 2, height: 1)
        let context = CGContext(
            data: nil, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: 2)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.drawImage(source, in: CGRect(x: 0, y: 0, width: 1, height: 2), orientation: Orientation(quarterTurns: 1), context: context)
        let pixels = Pixels(try #require(context.makeImage()))
        #expect(pixels[0, 0].r == 10 && pixels[0, 1].r == 50)

        // Flipped left to right, into a box two wide: blue is on the left.
        let flat = CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        flat.interpolationQuality = .none
        flat.translateBy(x: 0, y: 1)
        flat.scaleBy(x: 1, y: -1)
        AnnotationRenderer.drawImage(source, in: CGRect(x: 0, y: 0, width: 2, height: 1), orientation: Orientation(mirrored: true), context: flat)
        let mirrored = Pixels(try #require(flat.makeImage()))
        #expect(mirrored[0, 0].r == 50 && mirrored[1, 0].r == 10)
        // Without an orientation it is drawn as it is.
        flat.clear(CGRect(x: 0, y: 0, width: 2, height: 1))
        AnnotationRenderer.drawImage(source, in: CGRect(x: 0, y: 0, width: 2, height: 1), orientation: nil, context: flat)
        let plain = Pixels(try #require(flat.makeImage()))
        #expect(plain[0, 0].r == 10 && plain[1, 0].r == 50)
    }

    // MARK: The picture

    @Test func theCaptureIsTurnedPixelForPixel() throws {
        let grid = makeGrid(width: 3, height: 2)
        let document = AnnotationDocument(pixelSize: CGSize(width: 3, height: 2), scale: 1)
        #expect(try #require(document.picture(from: grid)) === grid)

        // (x, y) of the capture is at (height - 1 - y, x) once turned right.
        let rightDocument = try #require(document.applying(.rotateRight))
        let right = Pixels(try #require(rightDocument.picture(from: grid)))
        #expect(right.width == 2 && right.height == 3)
        for y in 0..<2 {
            for x in 0..<3 {
                let source = Pixels(grid)[x, y]
                #expect(right[1 - y, x].r == source.r && right[1 - y, x].g == source.g)
            }
        }
        let leftDocument = try #require(document.applying(.rotateLeft))
        let left = Pixels(try #require(leftDocument.picture(from: grid)))
        // (x, y) goes to (y, width - 1 - x).
        for y in 0..<2 {
            for x in 0..<3 {
                let source = Pixels(grid)[x, y]
                #expect(left[y, 2 - x].r == source.r && left[y, 2 - x].g == source.g)
            }
        }
        let mirroredDocument = try #require(document.applying(.flipHorizontally))
        let mirrored = Pixels(try #require(mirroredDocument.picture(from: grid)))
        let lowerDocument = try #require(document.applying(.flipVertically))
        let lower = Pixels(try #require(lowerDocument.picture(from: grid)))
        for y in 0..<2 {
            for x in 0..<3 {
                let source = Pixels(grid)[x, y]
                #expect(mirrored[2 - x, y].r == source.r && mirrored[2 - x, y].g == source.g)
                #expect(lower[x, 1 - y].r == source.r && lower[x, 1 - y].g == source.g)
            }
        }
    }

    @Test func aPictureThatCannotBeMadeIsNeverStoodInForByTheCapture() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 2)
        // A size no bitmap can have: the marks lie in its pixels, so the capture would be drawn wrong.
        document.transform = CaptureTransform(size: CGSize(width: 0, height: 10))
        #expect(document.picture(from: makeBase()) == nil)
        #expect(AnnotationRenderer.flatten(document, base: makeBase()) == nil)
    }

    @Test func theCaptureIsResizedToTheSizeAsked() throws {
        let document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 2)
        let half = try #require(document.applying(.resize(to: CGSize(width: 100, height: 50))))
        #expect(half.pictureSize == CGSize(width: 100, height: 50))
        #expect(half.canvas == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(half.scale == 1)
        let picture = try #require(half.picture(from: makeBase()))
        #expect(picture.width == 100 && picture.height == 50)
        // Turned after being resized, it stays that big.
        let turned = try #require(half.applying(.rotateRight))
        #expect(turned.pictureSize == CGSize(width: 50, height: 100))
        // Brought back to the size it was, and turned back, it is the document it was.
        let back = try #require(turned.applying(.resize(to: CGSize(width: 100, height: 200))).flatMap { $0.applying(.rotateLeft) })
        #expect(back == document)
    }

    @Test func resizingScalesMarksAndTheSizesTheyAreDrawnIn() throws {
        let document = makeDocument()
        let half = try #require(document.applying(.resize(to: CGSize(width: 100, height: 50))))
        guard case .rectangle(let box) = half.items[0].shape, case .redaction(let redaction) = half.items[3].shape else { throw Failure.shape }
        #expect(box.rect == CGRect(x: 5, y: 10, width: 15, height: 5))
        #expect(redaction.rect == CGRect(x: 75, y: 25, width: 20, height: 10))
        // Point sizes are unchanged, and the scale that turns them to pixels halves: a stroke is half as thick.
        #expect(half.items[0].style == document.items[0].style)
        #expect(half.scale == document.scale / 2)
        let outline = document.items[0].bounds(scale: document.scale)
        let smaller = half.items[0].bounds(scale: half.scale)
        #expect(abs(smaller.width - outline.width / 2) < 0.001 && abs(smaller.height - outline.height / 2) < 0.001)
        // Text grows from its corner, and a wrapped block's width with it.
        var wrapped = document
        wrapped.items.append(Annotation(shape: .text(TextBlock(origin: CGPoint(x: 100, y: 60), string: "Hi there", fontSize: 14, width: 80)), style: Style()))
        guard case .text(let block) = wrapped.applying(.resize(to: CGSize(width: 100, height: 50)))?.items.last?.shape else { throw Failure.shape }
        #expect(block.origin == CGPoint(x: 50, y: 30) && block.width == 40)
    }

    @Test func proportionsFollowTheCanvasWhenOnlyAPartIsKept() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 1000, height: 800), scale: 2)
        document.canvas = CGRect(x: 600, y: 100, width: 400, height: 300)
        let resized = try #require(document.applying(.resize(to: CGSize(width: 200, height: 150))))
        // The canvas is exactly the size asked for, and inside the picture that came of it.
        #expect(resized.canvas.size == CGSize(width: 200, height: 150))
        #expect(resized.imageBounds.contains(resized.canvas))
        #expect(resized.pictureSize == CGSize(width: 500, height: 400))
        #expect(!resized.canvasReachesPastCapture)
    }

    @Test func noPictureIsMadeLargerThanCanBeKept() {
        let document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 2)
        #expect(document.applying(.resize(to: CGSize(width: 20000, height: 10000))) == nil)
        #expect(document.applying(.resize(to: CGSize(width: 0, height: 10))) == nil)
        #expect(document.applying(.resize(to: CGSize(width: 200, height: 100))) == nil)
        #expect(!document.allowsCanvas(of: CGSize(width: 16385, height: 100)))
        #expect(document.allowsCanvas(of: CGSize(width: 2000, height: 1000)))
    }

    // MARK: Files

    @Test func documentsMadeBeforeTurnsExistedStillRead() throws {
        // A document as an earlier version wrote it: no transform, a combined image without an orientation.
        let json = """
        {"pixelSize":[200,100],"scale":2,"canvas":[[0,0],[200,100]],"items":[
          {"id":"4B7C5F3A-0000-4000-8000-000000000001","style":{"color":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":4,"shadow":true},
           "shape":{"image":{"_0":{"rect":[[0,0],[10,10]],"name":"a.png"}}}}
        ]}
        """
        let document = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        #expect(document.transform == nil)
        #expect(document.pictureSize == CGSize(width: 200, height: 100))
        guard case .image(let image) = document.items[0].shape else { throw Failure.shape }
        #expect(image.orientation == nil)
        // And a document that was never turned is written as it always was.
        let written = try String(decoding: JSONEncoder().encode(makeDocument()), as: UTF8.self)
        #expect(!written.contains("transform") && !written.contains("orientation"))
    }

    @Test func aTurnedDocumentRoundTrips() throws {
        var document = makeDocument()
        document.items.append(Annotation(shape: .image(PlacedImage(rect: CGRect(x: 0, y: 0, width: 10, height: 20), name: "a.png")), style: Style(shadow: false)))
        let changed = try #require(document.applying(.flipHorizontally).flatMap { $0.applying(.rotateRight) }.flatMap { $0.applying(.resize(to: CGSize(width: 50, height: 100))) })
        #expect(changed.transform != nil)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(changed))
        #expect(decoded == changed)
        // A corrupt turn count reads as a legal one.
        let odd = try JSONDecoder().decode(Orientation.self, from: Data(#"{"quarterTurns":6,"mirrored":true}"#.utf8))
        #expect(odd == Orientation(quarterTurns: 2, mirrored: true))
    }

    @Test func aProjectKeepsTheCapturesOwnPixelsAndStillOpensTurned() throws {
        let store = PictureStore(directory: URL.temporaryDirectory.appending(path: "OhMyShotKit Project \(UUID().uuidString)", directoryHint: .isDirectory))
        let capture = makeGrid(width: 6, height: 4)
        let document = try #require(AnnotationDocument(pixelSize: CGSize(width: 6, height: 4), scale: 2).applying(.rotateRight))
        let read = try AnnotationProject.read(AnnotationProject(capture: capture, document: document).data(pictures: store), pictures: store)
        #expect(read.capture.width == 6 && read.capture.height == 4)
        #expect(read.document == document)
        #expect(try #require(read.document.picture(from: read.capture)).width == 4)
        // The editor opens it turned, with the capture as it was taken still under it.
        let defaults = UserDefaults(suiteName: "OhMyShotKit.PictureTransformTests")!
        defer { defaults.removePersistentDomain(forName: "OhMyShotKit.PictureTransformTests") }
        let session = AnnotationSession(image: read.capture, scale: 2, document: read.document, defaults: defaults)
        #expect(session.document == document)
        #expect(session.base === read.capture)
        #expect(session.picture.width == 4 && session.picture.height == 6)
    }

    @Test func renderingCarriesTheTurnAndTheMarksTogether() throws {
        // A solid black redaction in the upper left of a white capture is in the upper right once turned right.
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 1)
        document.items = [Annotation(shape: .redaction(Redaction(rect: CGRect(x: 0, y: 0, width: 40, height: 20))), style: Style(color: .black, shadow: false))]
        let base = makeBase()
        let turned = try #require(document.applying(.rotateRight))
        let image = try #require(AnnotationRenderer.flatten(turned, base: base))
        #expect(image.width == 100 && image.height == 200)
        let pixels = Pixels(image)
        #expect(pixels[90, 10].r == 0 && pixels[10, 10].r == 255)
        // The capture's own black band (rows 40 to 59) is now a column, and the same one under the redaction.
        #expect(pixels[50, 190].r == 0 && pixels[35, 190].r == 255)
    }

    private enum Failure: Error {
        case shape
    }
}
