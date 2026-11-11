import AppKit
import Foundation
import ImageIO
import OMSCore
import Testing
@testable import OMSAnnotate

/// What the editor keeps in the capture when it copies, and when keeping fails.
@MainActor
struct EditorKeepingTests {
    private func makeEditor(actions: AnnotationEditorWindowController.Actions? = nil) -> AnnotationEditorWindowController {
        let file = URL.temporaryDirectory.appending(path: "OhMyShot Keeping Test \(UUID().uuidString).png")
        let controller = AnnotationEditorWindowController(
            image: makeBase(), scale: 2, document: nil, title: "Keeping test", fileURL: file,
            actions: actions ?? .init(keep: { _, _, _ in nil }, save: { _ in nil })
        )
        controller.session.undoManager.groupsByEvent = false
        return controller
    }

    private func step(_ session: AnnotationSession, _ change: () -> Void) {
        session.undoManager.beginUndoGrouping()
        change()
        session.undoManager.endUndoGrouping()
    }

    @Test(arguments: [false, true])
    func successfulCopyKeepsTheRenderedEditsAndClosesOnlyWhenRequested(thenClose: Bool) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var keptDocument: AnnotationDocument?
        var closed = false
        var actions = AnnotationEditorWindowController.Actions(keep: { document, _, _ in
            keptDocument = document
            return URL.temporaryDirectory.appending(path: "kept.png")
        }, save: { _ in nil })
        actions.copy = { image, png in
            #expect(!closed)
            return PasteboardWriter.write(png: png, image: image, to: pasteboard)
        }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        controller.onClose = { closed = true }
        step(controller.session) { controller.session.crop(to: CGRect(x: 10, y: 10, width: 120, height: 70)) }
        let document = controller.session.document

        await controller.copyCapture(thenClose: thenClose).value

        let data = try #require(pasteboard.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 120 && image.height == 70)
        #expect(keptDocument == document)
        #expect(!controller.session.hasUnkeptChanges)
        #expect(closed == thenClose)
    }

    @Test func failedCopyLeavesTheEditorAndEditsOpen() async {
        var closed = false
        var kept = false
        var actions = AnnotationEditorWindowController.Actions(keep: { _, _, _ in
            kept = true
            return URL.temporaryDirectory.appending(path: "kept.png")
        }, save: { _ in nil })
        actions.copy = { _, _ in false }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        controller.onClose = { closed = true }
        step(controller.session) { controller.session.crop(to: CGRect(x: 10, y: 10, width: 120, height: 70)) }
        let document = controller.session.document

        await controller.copyCapture(thenClose: true).value

        #expect(!closed)
        #expect(!kept)
        #expect(controller.session.hasUnkeptChanges)
        #expect(controller.session.document == document)
    }

    /// A mark made while the copy renders and goes to the clipboard is not kept as the copied picture's marks: the
    /// capture keeps the marks its picture shows, and the new mark waits to be kept.
    @Test func aMarkMadeDuringACopyIsNotKeptWithTheCopiedPicture() async throws {
        var keptDocument: AnnotationDocument?
        var copiedImage: CGImage?
        var keptImage: CGImage?
        var copiedPNG: Data?
        var keptPNG: Data?
        weak var editor: AnnotationEditorWindowController?
        var actions = AnnotationEditorWindowController.Actions(keep: { document, png, image in
            keptDocument = document
            keptImage = image
            keptPNG = png
            return URL.temporaryDirectory.appending(path: "kept.png")
        }, save: { _ in nil })
        actions.copy = { image, png in
            copiedImage = image
            copiedPNG = png
            guard let session = editor?.session else { return false }
            self.step(session) {
                var document = session.document
                document.items.append(Annotation(shape: .redaction(Redaction(rect: CGRect(x: 50, y: 40, width: 30, height: 15), method: .solid)), style: Style()))
                session.commit(document, actionName: "Redact")
            }
            return true
        }
        let controller = makeEditor(actions: actions)
        editor = controller
        defer { controller.window?.delegate = nil; controller.close() }
        step(controller.session) {
            var document = controller.session.document
            document.items.append(Annotation(shape: .rectangle(Box(rect: CGRect(x: 20, y: 20, width: 30, height: 20))), style: Style()))
            controller.session.commit(document, actionName: "Add Rectangle")
        }
        let copiedDocument = controller.session.document
        await controller.copyCapture().value
        #expect(keptDocument == copiedDocument)
        #expect(keptImage === copiedImage)
        #expect(keptPNG == copiedPNG && copiedPNG != nil)
        #expect(controller.session.document.items.count == 2)
        #expect(controller.session.hasUnkeptChanges)
    }

    /// Edits that could not be kept stay unkept, and dragging out does not hand over the file without them.
    @Test func aFailedKeepLeavesTheEditsUnkeptAndHandsNothingOver() {
        let controller = makeEditor()
        defer { controller.window?.delegate = nil; controller.close() }
        step(controller.session) { controller.session.crop(to: CGRect(x: 10, y: 10, width: 120, height: 70)) }
        controller.keepNow()
        #expect(controller.session.hasUnkeptChanges)
        #expect(controller.fileForDragging() == nil)
        #expect(controller.session.hasUnkeptChanges)
    }
}
