import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

@MainActor
struct PreviewEditorTests {
    private let scratch = ScratchDefaults()

    private func makePreview(actions: AnnotationEditorWindowController.Actions? = nil) -> AnnotationEditorWindowController {
        let file = URL.temporaryDirectory.appending(path: "OhMyShot Preview Test \(UUID().uuidString).png")
        let controller = AnnotationEditorWindowController(
            image: makeBase(), scale: 2, document: nil, title: "Preview test", fileURL: file,
            actions: actions ?? .init(keep: { _, _, _ in nil }, save: { _ in nil }), presentation: .preview
        )
        controller.session.undoManager.groupsByEvent = false
        return controller
    }

    private func step(_ session: AnnotationSession, _ change: () -> Void) {
        session.undoManager.beginUndoGrouping()
        change()
        session.undoManager.endUndoGrouping()
    }

    @Test func editExpandsTheSameCanvasWithItsMarksCropSelectionAndUndoHistory() throws {
        let controller = makePreview()
        defer { controller.window?.delegate = nil; controller.close() }
        let session = controller.session
        let window = try #require(controller.window)
        let content = controller.content
        let canvas = content.canvas
        let mark = Annotation(shape: .rectangle(Box(rect: CGRect(x: 20, y: 20, width: 30, height: 20))), style: Style())
        step(session) {
            var document = session.document
            document.items.append(mark)
            session.commit(document, selecting: [mark.id], actionName: "Add Rectangle")
        }
        step(session) { session.crop(to: CGRect(x: 10, y: 10, width: 120, height: 70)) }
        let previewDocument = session.document
        let previewSelection = session.selection
        #expect(controller.presentation == .preview)
        #expect(content.availableTools == ToolRail.previewGroups.flatMap { $0 })
        #expect(!content.availableTools.contains(.redact))

        controller.expandToFullEditor()

        #expect(controller.presentation == .editor)
        #expect(controller.window === window)
        #expect(controller.session === session)
        #expect(controller.content === content)
        #expect(controller.content.canvas === canvas)
        #expect(session.document == previewDocument)
        #expect(session.selection == previewSelection)
        #expect(content.availableTools == ToolRail.groups.flatMap { $0 })
        // AppKit may raise the frame minimum to accommodate the native toolbar.
        #expect(window.minSize.width >= AnnotationEditorWindowController.minimumSize.width)
        #expect(window.minSize.height >= AnnotationEditorWindowController.minimumSize.height)
        session.undoManager.undo()
        #expect(session.document.canvas == session.document.imageBounds)
        #expect(session.document.items == [mark])
        session.undoManager.redo()
        #expect(session.document == previewDocument)
    }

    @Test func expansionLeavesAnInProgressTextEditOnTheSameCanvas() {
        let controller = makePreview()
        defer {
            controller.content.canvas.endEditing()
            controller.window?.delegate = nil
            controller.close()
        }
        let session = controller.session
        let text = Annotation(shape: .text(TextBlock(origin: CGPoint(x: 20, y: 20), string: "Keep this text")), style: Style())
        step(session) {
            var document = session.document
            document.items.append(text)
            session.commit(document, selecting: [text.id], actionName: "Add Text")
        }
        let canvas = controller.content.canvas
        canvas.beginEditing(text.id, isNew: false)
        #expect(canvas.isEditingText)
        #expect(session.isInLiveChange)
        controller.expandToFullEditor()
        #expect(controller.content.canvas === canvas)
        #expect(canvas.isEditingText)
        #expect(session.isInLiveChange)
        #expect(session.document.items == [text])
    }

    @Test func anAdvancedKeyboardToolRevealsTheFullEditor() {
        let controller = makePreview()
        defer { controller.window?.delegate = nil; controller.close() }
        controller.session.tool = .ellipse
        #expect(controller.presentation == .editor)
        #expect(controller.session.tool == .ellipse)
        #expect(controller.content.availableTools.contains(.ellipse))
    }

    @Test func previewRailAndEveryBasicStyleFitTheMinimumWindowWithSavedColors() {
        let rail = ToolRail()
        rail.showPreviewTools(true)
        let minimum = AnnotationEditorWindowController.previewMinimumSize
        #expect(12 + rail.fittingSize.height + 8 <= minimum.height - 52 - 62)
        let colors = SavedColors(defaults: scratch.make())
        for index in 0..<SavedColors.limit { colors.add(RGBA(red: Double(index * 16) / 255, green: 0.5, blue: 0.25)) }
        let capsule = StyleCapsule()
        capsule.savedColors = colors
        for tool in rail.tools {
            var settings = ToolSettings.defaults(for: tool)
            settings.color = RGBA(red: 0.31, green: 0.42, blue: 0.53)
            for state in [0, 1, 2] {
                capsule.show(kind: tool, settings: settings, hasSelection: true, finding: state == 1, failed: state == 2)
                #expect(capsule.fittingSize.width + 24 <= minimum.width, "\(tool), state \(state): \(capsule.fittingSize.width)")
            }
        }
    }

    @Test func anEditDuringCopyKeepsOnlyTheDocumentThatProducedTheCopiedPixels() async throws {
        var keptDocument: AnnotationDocument?
        var copiedImage: CGImage?
        var keptImage: CGImage?
        var copiedPNG: Data?
        var keptPNG: Data?
        weak var preview: AnnotationEditorWindowController?
        var actions = AnnotationEditorWindowController.Actions(keep: { document, png, image in
            keptDocument = document
            keptImage = image
            keptPNG = png
            return URL.temporaryDirectory.appending(path: "synthetic-kept.png")
        }, save: { _ in nil })
        actions.copy = { image, png in
            copiedImage = image
            copiedPNG = png
            guard let session = preview?.session else { return }
            self.step(session) {
                var document = session.document
                document.items.append(Annotation(shape: .redaction(Redaction(rect: CGRect(x: 50, y: 40, width: 30, height: 15), method: .solid)), style: Style()))
                session.commit(document, actionName: "Redact")
            }
        }
        let controller = makePreview(actions: actions)
        preview = controller
        defer { controller.window?.delegate = nil; controller.close() }
        step(controller.session) {
            var document = controller.session.document
            document.items.append(Annotation(shape: .rectangle(Box(rect: CGRect(x: 20, y: 20, width: 30, height: 20))), style: Style()))
            controller.session.commit(document, actionName: "Add Rectangle")
        }
        let copiedDocument = controller.session.document
        controller.copyCapture(thenClose: false)
        for _ in 0..<200 {
            if keptDocument != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(keptDocument == copiedDocument)
        #expect(keptImage === copiedImage)
        #expect(keptPNG == copiedPNG && copiedPNG != nil)
        #expect(controller.session.document.items.count == 2)
        #expect(controller.session.hasUnkeptChanges)
    }

    @Test func aFailedKeepLeavesChangesPendingAndDoesNotHandOverTheOldFile() {
        let controller = makePreview()
        defer { controller.window?.delegate = nil; controller.close() }
        step(controller.session) { controller.session.crop(to: CGRect(x: 10, y: 10, width: 120, height: 70)) }
        controller.keepNow()
        #expect(controller.session.hasUnkeptChanges)
        #expect(controller.fileForDragging() == nil)
        #expect(controller.session.hasUnkeptChanges)
    }

    @Test func copyAppliesThePendingCropAndCopiesMarkedPixelsBeforeClosing() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var keptDocument: AnnotationDocument?
        var closed = false
        var copied = false
        var actions = AnnotationEditorWindowController.Actions(keep: { document, _, _ in
            keptDocument = document
            return URL.temporaryDirectory.appending(path: "preview-copy.png")
        }, save: { _ in nil })
        actions.copy = { image, png in
            #expect(!closed)
            await Task.yield()
            PasteboardWriter.write(png: png, image: image, to: pasteboard)
            copied = true
        }
        let controller = makePreview(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        controller.onClose = {
            #expect(copied)
            #expect(pasteboard.data(forType: .png) != nil)
            closed = true
        }
        step(controller.session) {
            var document = controller.session.document
            document.items.append(Annotation(
                shape: .rectangle(Box(rect: CGRect(x: 70, y: 10, width: 40, height: 20))),
                style: Style(color: .red, lineWidth: 2, shadow: false)
            ))
            controller.session.commit(document, actionName: "Add Rectangle")
        }
        controller.session.tool = .crop
        controller.content.canvas.chooseCropRatio(.fixed(1, 1))
        #expect(controller.session.document.canvas.width == 200)
        step(controller.session) { controller.content.canvas.copy(nil) }
        for _ in 0..<200 {
            if closed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(closed)
        #expect(keptDocument?.canvas.width == 100)
        #expect(!controller.session.hasUnkeptChanges)
        let data = try #require(pasteboard.data(forType: .png))
        let image = try #require(NSBitmapImageRep(data: data)?.cgImage)
        #expect(image.width == 100 && image.height == 100)
        let pixel = Pixels(image)[20, 20]
        #expect(pixel.r > 240 && pixel.g < 80 && pixel.b < 80)
    }

    @Test func copyFinishesTheTextBeingEditedBeforeRenderingAndClosing() async throws {
        var keptDocument: AnnotationDocument?
        var copiedPNG: Data?
        var closed = false
        var actions = AnnotationEditorWindowController.Actions(keep: { document, _, _ in
            keptDocument = document
            return URL.temporaryDirectory.appending(path: "preview-text.png")
        }, save: { _ in nil })
        actions.copy = { _, png in copiedPNG = png }
        let controller = makePreview(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        controller.onClose = { closed = true }
        let text = Annotation(shape: .text(TextBlock(origin: CGPoint(x: 20, y: 20), string: "New text")), style: Style())
        step(controller.session) {
            var document = controller.session.document
            document.items.append(text)
            controller.session.commit(document, selecting: [text.id], actionName: "Add Text")
        }
        controller.content.canvas.beginEditing(text.id, isNew: false)
        #expect(controller.content.canvas.isEditingText)
        let textView = try #require(controller.window?.firstResponder as? NSTextView)
        textView.insertText("Edited text", replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
        step(controller.session) { controller.copyCapture() }
        for _ in 0..<200 {
            if closed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(closed && !controller.content.canvas.isEditingText)
        let keptText = try #require(keptDocument?.items.first)
        guard case .text(let block) = keptText.shape else {
            Issue.record("The edited text mark was not kept")
            return
        }
        #expect(keptText.id == text.id && block.string == "Edited text")
        let image = try #require(copiedPNG.flatMap { NSBitmapImageRep(data: $0)?.cgImage })
        #expect(Pixels(image).region(CGRect(x: 15, y: 15, width: 160, height: 25)) != Pixels(makeBase()).region(CGRect(x: 15, y: 15, width: 160, height: 25)))
    }

    @Test(arguments: [true, false]) func saveExportsThePendingCropAndLeavesThePreviewOpen(succeeds: Bool) async throws {
        let file = URL.temporaryDirectory.appending(path: "preview-save-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        var saved = false
        var closed = false
        let actions = AnnotationEditorWindowController.Actions(keep: { _, png, _ in
            try? png.write(to: file)
            return file
        }, save: { url in
            #expect(url == file)
            saved = true
            return succeeds ? url : nil
        })
        let controller = makePreview(actions: actions)
        defer { controller.window?.delegate = nil; controller.close() }
        controller.onClose = { closed = true }
        controller.session.tool = .crop
        controller.content.canvas.chooseCropRatio(.fixed(1, 1))
        step(controller.session) { controller.content.canvas.save(nil) }
        for _ in 0..<200 {
            if saved { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(saved && !closed)
        #expect(controller.presentation == .preview)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: file))?.cgImage)
        #expect(image.width == 100 && image.height == 100)
        #expect(!controller.session.hasUnkeptChanges)
    }
}
