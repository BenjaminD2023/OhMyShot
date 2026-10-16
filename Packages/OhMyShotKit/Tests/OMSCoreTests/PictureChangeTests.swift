import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

/// Turning, flipping, and scaling a screenshot's picture.
struct PictureChangeTests {
    private typealias Pixel = [UInt8]
    private static let red: Pixel = [255, 0, 0, 255]
    private static let green: Pixel = [0, 255, 0, 255]
    private static let blue: Pixel = [0, 0, 255, 255]
    private static let cyan: Pixel = [0, 255, 255, 255]
    private static let magenta: Pixel = [255, 0, 255, 255]
    private static let yellow: Pixel = [255, 255, 0, 255]

    /// A picture 3 wide and 2 high, with a different color in every pixel (top row first):
    ///
    ///     red  green  blue
    ///     cyan magenta yellow
    private func sample(space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        let rows: [[Pixel]] = [[Self.red, Self.green, Self.blue], [Self.cyan, Self.magenta, Self.yellow]]
        return try image(rows, space: space)
    }

    private func image(_ rows: [[Pixel]], space: CGColorSpace, alpha: CGImageAlphaInfo = .premultipliedLast) throws -> CGImage {
        var bytes = rows.flatMap { $0.flatMap { $0 } }
        let width = rows[0].count, height = rows.count
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: alpha.rawValue
            ))
            return try #require(context.makeImage())
        }
    }

    /// The picture's pixels in sRGB, top row first.
    private func pixels(of image: CGImage) throws -> [[Pixel]] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let width = image.width, height = image.height
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { row in
            (0..<width).map { column in Array(bytes[(row * width + column) * 4..<(row * width + column) * 4 + 4]) }
        }
    }

    @Test func turningRightPutsTheLeftColumnOnTop() throws {
        let turned = try #require(PictureChange.rotateRight.apply(to: sample()))
        #expect(turned.width == 2 && turned.height == 3)
        #expect(try pixels(of: turned) == [[Self.cyan, Self.red], [Self.magenta, Self.green], [Self.yellow, Self.blue]])
    }

    @Test func turningLeftPutsTheRightColumnOnTop() throws {
        let turned = try #require(PictureChange.rotateLeft.apply(to: sample()))
        #expect(turned.width == 2 && turned.height == 3)
        #expect(try pixels(of: turned) == [[Self.blue, Self.yellow], [Self.green, Self.magenta], [Self.red, Self.cyan]])
    }

    @Test func flippingHorizontallyMirrorsEachRow() throws {
        let flipped = try #require(PictureChange.flipHorizontal.apply(to: sample()))
        #expect(flipped.width == 3 && flipped.height == 2)
        #expect(try pixels(of: flipped) == [[Self.blue, Self.green, Self.red], [Self.yellow, Self.magenta, Self.cyan]])
    }

    @Test func flippingVerticallySwapsTheRows() throws {
        let flipped = try #require(PictureChange.flipVertical.apply(to: sample()))
        #expect(flipped.width == 3 && flipped.height == 2)
        #expect(try pixels(of: flipped) == [[Self.cyan, Self.magenta, Self.yellow], [Self.red, Self.green, Self.blue]])
    }

    @Test func fourTurnsAndTwoFlipsComeBackToThePicture() throws {
        let original = try sample()
        var turned = original
        for _ in 0..<4 { turned = try #require(PictureChange.rotateRight.apply(to: turned)) }
        #expect(try pixels(of: turned) == pixels(of: original))
        let once = try #require(PictureChange.rotateLeft.apply(to: original))
        let back = try #require(PictureChange.rotateRight.apply(to: once))
        #expect(try pixels(of: back) == pixels(of: original))
        let twice = try #require(PictureChange.flipHorizontal.apply(to: PictureChange.flipHorizontal.apply(to: original)!))
        #expect(try pixels(of: twice) == pixels(of: original))
    }

    @Test func aWideGamutPictureStaysWideGamut() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let turned = try #require(PictureChange.rotateLeft.apply(to: sample(space: p3)))
        #expect(turned.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
        let scaled = try #require(PictureChange.scaleToOneX(pixelsPerPoint: 2).apply(to: image(Array(repeating: Array(repeating: Self.red, count: 4), count: 4), space: p3)))
        #expect(scaled.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    }

    @Test func aSixteenBitPictureStaysSixteenBit() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let picture = try #require(context.makeImage())
        #expect(picture.bitsPerComponent == 16)
        let turned = try #require(PictureChange.rotateLeft.apply(to: picture))
        #expect(turned.bitsPerComponent == 16 && turned.width == 1 && turned.height == 2)
        #expect(try #require(PictureChange.scaleToOneX(pixelsPerPoint: 2).apply(to: picture)).bitsPerComponent == 16)
    }

    @Test func anEightBitPictureStaysEightBit() throws {
        #expect(try #require(PictureChange.flipVertical.apply(to: sample())).bitsPerComponent == 8)
    }

    @Test func transparencyIsKept() throws {
        let clear: Pixel = [0, 0, 0, 0]
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let turned = try #require(PictureChange.flipHorizontal.apply(to: image([[clear, Self.red]], space: space)))
        #expect(try pixels(of: turned) == [[Self.red, clear]])
    }

    @Test func anOpaquePictureStaysWithoutAnAlphaChannel() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let opaque = try image([[Self.red, Self.green]], space: space, alpha: .noneSkipLast)
        let turned = try #require(PictureChange.rotateRight.apply(to: opaque))
        #expect(turned.alphaInfo == .noneSkipLast)
    }

    @Test func sizesAreWorkedOutWithoutThePicture() {
        #expect(PictureChange.rotateLeft.size(ofWidth: 300, height: 200) == (200, 300))
        #expect(PictureChange.rotateRight.size(ofWidth: 300, height: 200) == (200, 300))
        #expect(PictureChange.flipHorizontal.size(ofWidth: 300, height: 200) == (300, 200))
        #expect(PictureChange.flipVertical.size(ofWidth: 300, height: 200) == (300, 200))
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 2).size(ofWidth: 300, height: 200) == (150, 100))
        // Half a point rounds up, and a picture is never gone.
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 2).size(ofWidth: 5, height: 3) == (3, 2))
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 3).size(ofWidth: 1, height: 1) == (1, 1))
    }

    @Test func scalingToOneXHalvesARetinaPicture() throws {
        let retina = try image(Array(repeating: Array(repeating: Self.green, count: 8), count: 6), space: CGColorSpace(name: CGColorSpace.sRGB)!)
        let scaled = try #require(PictureChange.scaleToOneX(pixelsPerPoint: 2).apply(to: retina))
        #expect(scaled.width == 4 && scaled.height == 3)
        #expect(try pixels(of: scaled).allSatisfy { $0.allSatisfy { $0 == Self.green } })
    }

    @Test func aPictureAlreadyAtOneXIsLeftAlone() throws {
        let picture = try sample()
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 1).apply(to: picture) === picture)
    }

    @Test func scalingToOneXStartsFromTheScaleTheCaptureHasNow() {
        // Asked for on a 2× capture, but run once an earlier Scale to 1× has made it 1×: nothing is left to do.
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 2).resolved(pixelsPerPoint: 1) == nil)
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 2).resolved(pixelsPerPoint: 0.5) == nil)
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 2).resolved(pixelsPerPoint: 2) == .scaleToOneX(pixelsPerPoint: 2))
        #expect(PictureChange.scaleToOneX(pixelsPerPoint: 2).resolved(pixelsPerPoint: 3) == .scaleToOneX(pixelsPerPoint: 3))
    }

    @Test func turnsAndFlipsDoNotDependOnTheScale() {
        for change in [PictureChange.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical] {
            #expect(change.resolved(pixelsPerPoint: 1) == change)
            #expect(change.resolved(pixelsPerPoint: 2) == change)
        }
    }
}

/// What a card may do to a capture's picture.
struct PictureChangeAvailabilityTests {
    @Test func anUntouchedScreenshotCanBeChanged() {
        #expect(PictureChangeAvailability.of(isScreenshot: true, fileExtension: "png", hasOriginal: false, isBeingEdited: false) == .available)
        #expect(PictureChangeAvailability.of(isScreenshot: true, fileExtension: "PNG", hasOriginal: false, isBeingEdited: false) == .available)
    }

    /// A photo added from a file would lose some of itself being written again, and its orientation is not in its pixels.
    @Test func aPictureThatIsNoPNGIsNotOffered() {
        for fileExtension in ["jpg", "jpeg", "heic", "tiff", "gif", ""] {
            #expect(PictureChangeAvailability.of(isScreenshot: true, fileExtension: fileExtension, hasOriginal: false, isBeingEdited: false) == .unsupported)
        }
    }

    /// An original beside the picture means marks, a crop, or a background: all of them would stay as they were.
    @Test func aCaptureWithAnOriginalIsRefused() {
        #expect(PictureChangeAvailability.of(isScreenshot: true, fileExtension: "png", hasOriginal: true, isBeingEdited: false) == .marked)
    }

    @Test func aCaptureOpenInTheEditorIsRefused() {
        #expect(PictureChangeAvailability.of(isScreenshot: true, fileExtension: "png", hasOriginal: false, isBeingEdited: true) == .beingEdited)
    }

    @Test func recordingsAndOtherFormsAreNotOffered() {
        #expect(PictureChangeAvailability.of(isScreenshot: false, fileExtension: "mp4", hasOriginal: false, isBeingEdited: false) == .unsupported)
        #expect(PictureChangeAvailability.of(isScreenshot: false, fileExtension: "png", hasOriginal: false, isBeingEdited: false) == .unsupported)
        #expect(PictureChangeAvailability.of(isScreenshot: true, fileExtension: "gif", hasOriginal: true, isBeingEdited: true) == .unsupported)
    }
}

/// The history keeps a changed picture as the capture, with no original beside it.
struct HistoryPictureChangeTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryPictureChangeTests-\(UUID().uuidString)"))
    }

    private func read(_ text: String, of item: HistoryItem, in store: HistoryStore) throws {
        try store.setText(text, of: item, readFrom: try #require(store.stamp(of: item)))
    }

    @Test func aCaptureIsFoundByItsFileNameFromItsOwnRecord() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 30, pixelHeight: 20, appName: "Safari")
        let second = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 5, pixelHeight: 6, appName: nil)
        #expect(store.item(fileName: first.fileName)?.id == first.id)
        #expect(store.item(fileName: first.fileName)?.appName == "Safari")
        #expect(store.item(fileName: second.fileName)?.id == second.id)
        #expect(store.item(fileName: second.fileName)?.pixelWidth == 5)
        #expect(store.item(fileName: "missing.png") == nil)
    }

    @Test func theNewPictureTakesTheCapturesPlaceAndSize() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 30, pixelHeight: 20, appName: "Safari")
        let turned = try store.replacePicture(of: item, with: Data([2, 2]), pixelWidth: 20, pixelHeight: 30)
        #expect(turned.pixelWidth == 20 && turned.pixelHeight == 30)
        #expect(turned.id == item.id && turned.fileName == item.fileName && turned.appName == "Safari")
        #expect(store.item(id: item.id)?.pixelWidth == 20)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([2, 2]))
        #expect(store.items().count == 1)
    }

    /// An original or marks left beside it would show the editor, a restore, and Revert the picture as it was.
    @Test func noOriginalAndNoMarksAreLeftBesideIt() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 30, pixelHeight: 20, appName: nil)
        try store.replacePicture(of: item, with: Data([2]), pixelWidth: 20, pixelHeight: 30)
        try store.replacePicture(of: item, with: Data([3]), pixelWidth: 30, pixelHeight: 20)
        #expect(!store.hasOriginal(item))
        #expect(!FileManager.default.fileExists(atPath: store.annotationsURL(for: item).path(percentEncoded: false)))
        // Put back as taken, it is the same picture: there is nothing to put back.
        let restored = try store.restoreOriginal(of: item)
        #expect(restored.pixelWidth == 30)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([3]))
    }

    @Test func aCaptureThatWasEditedIsRefusedAndLeftAsItIs() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 30, pixelHeight: 20, appName: nil)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 30, pixelHeight: 20, annotations: Data([9]))
        #expect(throws: HistoryStore.PictureError.hasOriginal) {
            try store.replacePicture(of: marked, with: Data([3]), pixelWidth: 20, pixelHeight: 30)
        }
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([2]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        #expect(store.item(id: item.id)?.pixelWidth == 30)
    }

    @Test func scalingKeepsOnePixelPerPointAsTheCapturesScale() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 400, pixelHeight: 200, appName: nil)
        #expect(item.pixelsPerPoint == nil)
        let scaled = try store.replacePicture(of: item, with: Data([2]), pixelWidth: 200, pixelHeight: 100, pixelsPerPoint: 1)
        #expect(scaled.pixelsPerPoint == 1)
        #expect(store.item(id: item.id)?.pixelsPerPoint == 1)
        // A later turn leaves the scale as it is.
        let turned = try store.replacePicture(of: scaled, with: Data([3]), pixelWidth: 100, pixelHeight: 200)
        #expect(turned.pixelsPerPoint == 1)
    }

    @Test func textReadFromTheOldPictureIsReadAgain() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 30, pixelHeight: 20, appName: nil)
        try read("Hello", of: item, in: store)
        #expect(store.text(of: item) == "Hello")
        let turned = try store.replacePicture(of: item, with: Data([2, 2, 2]), pixelWidth: 20, pixelHeight: 30)
        #expect(store.text(of: turned) == nil)
        #expect(store.needingText(store.items()).map(\.id) == [item.id])
    }
}
