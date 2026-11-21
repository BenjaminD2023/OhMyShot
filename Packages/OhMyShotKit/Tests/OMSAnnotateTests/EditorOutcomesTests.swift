import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

/// Pin to Screen, Upload, and Share… from the editor: each keeps the edits in the capture first, then hands on the
/// picture or its file as a card would.
@MainActor
struct EditorOutcomesTests {
    private let kept = URL.temporaryDirectory.appending(path: "OhMyShot Outcomes Kept.png")

    private func makeEditor(actions: AnnotationEditorWindowController.Actions) -> AnnotationEditorWindowController {
        let file = URL.temporaryDirectory.appending(path: "OhMyShot Outcomes Test \(UUID().uuidString).png")
        let controller = AnnotationEditorWindowController(
            image: makeBase(), scale: 2, document: nil, title: "Outcomes test", fileURL: file, actions: actions
        )
        controller.session.undoManager.groupsByEvent = false
        return controller
    }

    private func crop(_ session: AnnotationSession) {
        session.undoManager.beginUndoGrouping()
        session.crop(to: CGRect(x: 10, y: 10, width: 120, height: 70))
        session.undoManager.endUndoGrouping()
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// Copy hands on the scale of the picture it copies, which it renders before keeping: after a kept resize is undone,
    /// the restored picture's, not the resized one's.
    @Test func copyHandsOnThePicturesOwnScale() async {
        var copied: [CGFloat] = []
        var actions = AnnotationEditorWindowController.Actions(keep: { [kept] _, _, _ in kept }, save: { _ in nil })
        actions.copy = { _, _, scale in
            copied.append(scale)
            return true
        }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        let session = controller.session
        session.undoManager.beginUndoGrouping()
        session.apply(.resize(to: CGSize(width: 100, height: 50)))
        session.undoManager.endUndoGrouping()

        await controller.copy().value
        session.undo()
        await controller.copy().value

        #expect(copied == [1, 2])
    }

    @Test func pinKeepsTheEditsAndPinsThePictureAsItLooks() async throws {
        var keptDocument: AnnotationDocument?
        var pinned: (image: CGImage, scale: CGFloat)?
        var actions = AnnotationEditorWindowController.Actions(keep: { [kept] document, _, _ in
            keptDocument = document
            return kept
        }, save: { _ in nil })
        actions.pin = { image, scale in pinned = (image, scale) }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        crop(controller.session)
        let document = controller.session.document

        await controller.pin().value

        let picture = try #require(pinned)
        #expect(picture.image.width == 120 && picture.image.height == 70 && picture.scale == 2)
        #expect(keptDocument == document)
        #expect(!controller.session.hasUnkeptChanges)
    }

    @Test func uploadKeepsTheEditsFirstAndSendsTheKeptFile() async {
        var keptDocument: AnnotationDocument?
        var uploaded: [(file: URL, destination: UUID?)] = []
        var actions = AnnotationEditorWindowController.Actions(keep: { [kept] document, _, _ in
            keptDocument = document
            return kept
        }, save: { _ in nil })
        actions.upload = { file, destination in
            // The edits are in the file before it goes.
            #expect(keptDocument != nil)
            uploaded.append((file, destination))
        }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        crop(controller.session)
        let destination = UUID()

        await controller.upload(to: destination).value
        // Nothing new to keep: the file already holds the edits, and a plain Upload goes to the default.
        await controller.upload().value

        #expect(uploaded.map(\.file) == [kept, kept])
        #expect(uploaded.map(\.destination) == [destination, nil])
        #expect(!controller.session.hasUnkeptChanges)
    }

    /// A capture uploads once at a time: while it is uploading, Upload is off in the File menu, and from Save Options it
    /// beeps and sends nothing, rather than starting an upload that would be turned away.
    @Test func uploadWaitsForTheOneUnderWay() async {
        var uploading = true
        var uploaded = 0
        var actions = AnnotationEditorWindowController.Actions(keep: { [kept] _, _, _ in kept }, save: { _ in nil })
        actions.upload = { _, _ in uploaded += 1 }
        actions.uploadMenu = { .upload }
        actions.isUploading = { uploading }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        let upload = menuItem(#selector(AnnotationEditorWindowController.uploadCapture(_:)))

        #expect(!controller.validateMenuItem(upload))
        await controller.upload().value
        #expect(uploaded == 0)

        uploading = false
        #expect(controller.validateMenuItem(upload))
        await controller.upload().value
        #expect(uploaded == 1)
    }

    /// Edits that could not be kept are not in the file: uploading it would send the picture without them.
    @Test func editsThatCannotBeKeptUploadNothing() async {
        var uploaded = 0
        var actions = AnnotationEditorWindowController.Actions(keep: { _, _, _ in nil }, save: { _ in nil })
        actions.upload = { _, _ in uploaded += 1 }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        crop(controller.session)

        await controller.upload().value

        #expect(uploaded == 0)
        #expect(controller.session.hasUnkeptChanges)
    }

    @Test func shareHandsOverTheKeptFileInTheChosenFormat() async {
        let converted = URL.temporaryDirectory.appending(path: "OhMyShot Outcomes Converted.jpg")
        var keptDocument: AnnotationDocument?
        var actions = AnnotationEditorWindowController.Actions(keep: { [kept] document, _, _ in
            keptDocument = document
            return kept
        }, save: { _ in nil })
        actions.fileToHandOver = { [kept] file in file == kept ? converted : file }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        crop(controller.session)
        let document = controller.session.document

        let shared = await controller.fileForSharing()

        #expect(shared == converted)
        #expect(keptDocument == document)
    }

    /// The File menu's Pin to Screen and Upload answer only when the editor offers them: Upload once a destination is set up.
    @Test func theFileMenuOffersPinAndUploadAsTheEditorDoes() {
        var destinations = UploadMenu.hidden
        var actions = AnnotationEditorWindowController.Actions(keep: { _, _, _ in nil }, save: { _ in nil })
        actions.upload = { _, _ in }
        actions.uploadMenu = { destinations }
        let controller = makeEditor(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        let pin = menuItem(#selector(AnnotationEditorWindowController.pinToScreen(_:)))
        let upload = menuItem(#selector(AnnotationEditorWindowController.uploadCapture(_:)))
        let share = menuItem(#selector(AnnotationEditorWindowController.shareCapture(_:)))

        #expect(!controller.validateMenuItem(pin))
        #expect(!controller.validateMenuItem(upload))
        #expect(controller.validateMenuItem(share))
        destinations = .upload
        #expect(controller.validateMenuItem(upload))

        var withPin = actions
        withPin.pin = { _, _ in }
        let pinning = makeEditor(actions: withPin)
        defer { pinning.window?.delegate = nil; pinning.close() }
        #expect(pinning.validateMenuItem(pin))
    }
}
