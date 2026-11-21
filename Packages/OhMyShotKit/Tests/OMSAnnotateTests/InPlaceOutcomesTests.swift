import AppKit
import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

/// Pin and Upload when marking up in place: offered beside Save, finished with the marked selection, on ⇧⌘P and
/// ⇧⌘U, and a pin that shows the marks.
@MainActor
struct InPlaceOutcomesTests {
    private func white(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func view(pin: ((InPlaceAnnotationView.Result) -> Void)? = nil, upload: ((InPlaceAnnotationView.Result) -> Void)? = nil) -> InPlaceAnnotationView {
        var actions = InPlaceAnnotationView.Actions(copy: { _ in }, save: { _ in }, openInEditor: { _ in }, cancel: {})
        actions.pin = pin
        actions.upload = upload
        return InPlaceAnnotationView(
            frame: white(width: 800, height: 600), scale: 2, size: CGSize(width: 400, height: 300),
            selection: CGRect(x: 80, y: 40, width: 100, height: 60), actions: actions
        )
    }

    private func key(_ character: String, keyCode: UInt16, also: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: also.union([.command, .shift]), timestamp: 0, windowNumber: 0, context: nil,
            characters: character.uppercased(), charactersIgnoringModifiers: character.uppercased(), isARepeat: false, keyCode: keyCode
        ))
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

    @Test func pinAndUploadStandBetweenSaveAndCancelOnlyWhenOffered() {
        #expect(view().toolbar.shownActions == [.undo, .redo, .openInEditor, .save, .cancel, .copy])
        #expect(view(pin: { _ in }).toolbar.shownActions == [.undo, .redo, .openInEditor, .save, .pin, .cancel, .copy])
        #expect(view(pin: { _ in }, upload: { _ in }).toolbar.shownActions == [.undo, .redo, .openInEditor, .save, .pin, .upload, .cancel, .copy])
    }

    @Test func pinFinishesWithTheMarkedSelectionOnce() throws {
        var pinned: [InPlaceAnnotationView.Result] = []
        var uploaded = 0
        let annotator = view(pin: { pinned.append($0) }, upload: { _ in uploaded += 1 })
        var document = annotator.session.document
        document.items = [Annotation(shape: .rectangle(Box(rect: CGRect(x: 170, y: 90, width: 20, height: 20))), style: Style())]
        annotator.session.commit(document, actionName: "Add")

        annotator.toolbar.press(.pin)
        annotator.toolbar.press(.upload)

        let result = try #require(pinned.first)
        #expect(pinned.count == 1 && uploaded == 0)
        #expect(result.capture.width == 200 && result.capture.height == 120)
        #expect(result.document.items.count == 1)
    }

    /// With Command, P and U are Pin and Upload; the tools keep their plain letters. Upload answers only when offered.
    @Test func commandShiftKeysPinAndUploadWhileTheLettersStayTools() throws {
        var pins = 0
        let annotator = view(pin: { _ in pins += 1 })
        #expect(!annotator.performKeyEquivalent(with: try key("u", keyCode: 32)))
        #expect(annotator.performKeyEquivalent(with: try key("p", keyCode: 35)))
        #expect(pins == 1 && annotator.session.tool == .select)

        var uploads = 0
        let uploading = view(upload: { _ in uploads += 1 })
        #expect(!uploading.performKeyEquivalent(with: try key("p", keyCode: 35)))
        #expect(uploading.performKeyEquivalent(with: try key("u", keyCode: 32)))
        #expect(uploads == 1)
    }

    /// Caps Lock leaves the keys as they are, as on a card; Option or Control makes them other keys.
    @Test func capsLockLeavesPinAndUploadKeys() throws {
        var pins = 0, uploads = 0
        #expect(view(pin: { _ in pins += 1 }).performKeyEquivalent(with: try key("p", keyCode: 35, also: .capsLock)))
        #expect(view(upload: { _ in uploads += 1 }).performKeyEquivalent(with: try key("u", keyCode: 32, also: .capsLock)))
        #expect(!view(pin: { _ in pins += 1 }).performKeyEquivalent(with: try key("p", keyCode: 35, also: .option)))
        #expect(pins == 1 && uploads == 1)
    }

    /// A pin over the area shows what was drawn there, a redaction included, at the capture's own size: never the
    /// capture without its marks, and never a background, which would not fit the area.
    @Test func aPinShowsTheMarksAndNoBackground() async throws {
        let base = white(width: 200, height: 100)
        var document = AnnotationDocument(pixelSize: CGSize(width: 200, height: 100), scale: 2)
        document.items = [Annotation(shape: .redaction(Redaction(rect: CGRect(x: 20, y: 20, width: 60, height: 40), method: .solid)), style: Style())]
        document.backdrop = Backdrop(padding: 0.1)

        let pinned = try #require(await CaptureRendition.pinned(document, on: base))

        #expect(pinned.width == 200 && pinned.height == 100)
        let covered = pixel(pinned, 50, 40)
        #expect(!(covered.red > 250 && covered.green > 250 && covered.blue > 250))
        let clear = pixel(pinned, 150, 80)
        #expect(clear.red > 250 && clear.green > 250 && clear.blue > 250)
    }
}
