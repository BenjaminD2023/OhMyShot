import AppKit
import Foundation
import OMSAnnotate
import OMSCore
import OSLog

/// Opens captures in the annotation editor and keeps what is drawn on them: the capture's file then
/// shows the marks, while the original and the marks stay beside it in the history, so opening the
/// capture again picks up where the editing left off. One editor per capture.
final class AnnotationCoordinator {
    private let history: HistoryStore
    private var editors: [UUID: AnnotationEditorWindowController] = [:]
    /// Holds captures while their original and editable marks are loaded.
    private var opening: [UUID: AnnotationEditorWindowController.Presentation] = [:]
    /// Editors of project files, by file.
    private var projectEditors: [URL: AnnotationEditorWindowController] = [:]
    /// Saves a copy of a project's picture to the export location, with the scale it was made at; returns where it went.
    var saveFile: ((URL, Double) async -> URL?)?
    /// A capture's picture changed: its record, and the picture's encoded data.
    var onChange: ((HistoryItem, Data) -> Void)?
    /// The editor is loading or holding a capture (true), or has released it (false).
    var onEditing: ((UUID, Bool) -> Void)?
    /// A capture's editor is on screen and owns the capture, so its Quick Access card can close.
    var onOpen: ((UUID) -> Void)?
    /// Saves a copy of a capture's file to the export location; returns where it went.
    var saveCopy: ((HistoryItem, URL) async -> URL?)?
    /// Asks where and how to save a copy of an editor's picture: its file, the capture it is (nil for a project's), and
    /// its scale (nil when unknown). Returns where it went.
    var saveAs: ((URL, HistoryItem?, Double?) async -> URL?)?
    /// The file to hand to another app when an editor's picture is dragged out, from the picture's file and its scale
    /// (nil when unknown); nil when it could not be made, and then nothing goes.
    var fileToHandOver: ((URL, Double?) -> URL?)?
    /// Puts an editor's picture on the clipboard and reports success: the picture, its PNG, its name, and its scale (nil when unknown).
    var copyPicture: ((CGImage, Data, String, Double?) async -> Bool)?
    /// Pins an editor's picture as it looks now: the picture, its pixels per point, and the capture it is (nil for a project's).
    var pinPicture: ((CGImage, CGFloat, HistoryItem?) -> Void)?
    /// What an editor offers for uploading: the destinations as cards list them.
    var uploadMenu: (() -> UploadMenu)?
    /// Uploads an editor's picture file as a card's Upload does: the upload's identity (the capture's, or one of the
    /// project's editor), the file, the destination (nil for the default), and its scale (nil when unknown).
    var uploadFile: ((UUID, URL, UUID?, Double?) -> Void)?
    /// Whether the upload of that identity is under way.
    var isUploading: ((UUID) -> Bool)?

    init(history: HistoryStore) {
        self.history = history
        // What an earlier run left of projects' pictures: every project opened from now on has a newer folder. Not while
        // another copy still runs (a relaunch that went ahead while it waited on an editor's sheet): its open editors'
        // pictures are there, and what it leaves goes at the next launch.
        guard !Relauncher.otherInstancesAreRunning else { return }
        let start = Date.now
        Task.detached(priority: .background) { ProjectPicture.removeLeftovers(before: start) }
    }

    /// Opens `entry` in the editor, or brings its editor forward. `scale` is pixels per point of the
    /// screen it was captured on; the scale the capture itself has (marks kept with one, or a screenshot
    /// brought down to one pixel per point) comes first.
    func annotate(_ entry: HistoryItem, scale: CGFloat) {
        open(entry, scale: scale, presentation: .editor)
    }

    /// A compact preview with the same editable document, copy path, and history retention as the editor.
    func preview(_ entry: HistoryItem, scale: CGFloat) {
        open(entry, scale: scale, presentation: .preview)
    }

    private func open(_ entry: HistoryItem, scale: CGFloat, presentation: AnnotationEditorWindowController.Presentation) {
        if let editor = editors[entry.id] {
            if presentation == .editor { editor.expandToFullEditor() }
            editor.show()
            onOpen?(entry.id)
            return
        }
        guard entry.kind == .screenshot else { return }
        if let pending = opening[entry.id] {
            if pending == .preview, presentation == .editor { opening[entry.id] = .editor }
            return
        }
        let id = entry.id
        opening[id] = presentation
        // Loading also holds the capture: a three-second card must not expire while its image is read.
        onEditing?(id, true)
        let history = history
        Task { [weak self] in
            guard let self else { return }
            defer {
                opening.removeValue(forKey: id)
                if editors[id] == nil { onEditing?(id, false) }
            }
            guard let loaded = await AnnotationCaptureSource.load(entry, from: history) else {
                Log.capture.error("Could not read \(entry.fileName, privacy: .private) to annotate it")
                NSApp.activate()
                NSAlert(error: CocoaError(.fileReadCorruptFile)).runModal()
                return
            }
            if loaded.requiresFlattenedCopy {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "The saved marks couldn’t be opened.")
                alert.informativeText = String(localized: "You can edit a copy of the picture as it appears in History. Its existing marks can’t be changed. The original capture will be left alone.")
                alert.addButton(withTitle: String(localized: "Edit a Flattened Copy"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            do {
                let item = try await loaded.itemForEditing(entry, in: history)
                if item.id != id { onEditing?(item.id, true) }
                showEditor(for: item, source: loaded, scale: scale, presentation: opening[id] ?? presentation)
                onOpen?(id)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func showEditor(for entry: HistoryItem, source loaded: AnnotationCaptureSource, scale: CGFloat, presentation: AnnotationEditorWindowController.Presentation) {
        let id = entry.id
        let editor = AnnotationEditorWindowController(
            image: loaded.image,
            scale: loaded.document?.scale ?? entry.pixelsPerPoint.map { CGFloat($0) } ?? scale,
            document: loaded.document,
            title: (entry.fileName as NSString).deletingPathExtension,
            fileURL: history.fileURL(for: entry),
            actions: Self.editorActions(
                keep: { [weak self] document, png, image in self?.keep(id, document: document, png: png, image: image) },
                save: { [weak self] file in
                    guard let self, let entry = self.history.item(id: id) else { return nil }
                    return await self.saveCopy?(entry, file)
                },
                coordinator: self, name: (entry.fileName as NSString).deletingPathExtension, scale: { [weak self] in self?.history.item(id: id)?.pixelsPerPoint },
                entry: { [weak self] in self?.history.item(id: id) }, uploadID: { id }
            ),
            presentation: presentation
        )
        editor.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in
            self?.editors[id] = nil
            self?.onEditing?(id, false)
            MemoryRelief.endEventWait()
        }
        editors[id] = editor
        editor.show()
    }

    /// Opens a capture History couldn't take in the editor all the same, so what was drawn on it is not lost with it:
    /// `image` as it was taken, `document` its marks and background, its pixels per point, the name it was to have,
    /// `record`, History's record of it as it was taken when History took that much, and `add`, which tries again to add
    /// it to History as it was taken and returns its record. The editor holds the only copy of the marks. They stay unkept
    /// until History has them, which every keep tries again (Copy, Save, a drag, closing, and the Retry of closing's
    /// alert), adding the capture first when History has no record of it. Until then nothing that needs the capture's file
    /// goes, and closing or quitting asks first, as for edits that can't be kept.
    func annotate(notKept image: CGImage, document: AnnotationDocument?, scale: CGFloat, title: String, record: HistoryItem?, add: @escaping () throws -> HistoryItem) {
        // The capture's id from the start when History has its record, so Keep captures doesn't remove it from under the
        // editor; without one a key of its own, so quitting asks about this editor too, until History has the capture.
        var id = record?.id ?? UUID()
        var inHistory = record != nil
        if inHistory { onEditing?(id, true) }
        let editor = AnnotationEditorWindowController(
            image: image, scale: scale, document: document, title: title, fileURL: nil,
            actions: Self.editorActions(
                keep: { [weak self] document, png, picture in
                    guard let self else { return nil }
                    if !inHistory {
                        do {
                            let entry = try add()
                            editors[entry.id] = editors.removeValue(forKey: id)
                            id = entry.id
                            inHistory = true
                            onEditing?(id, true)
                            Log.capture.notice("Added \(entry.fileName, privacy: .private) to the history from its editor")
                        } catch {
                            Log.capture.error("Adding a capture to the history from its editor failed: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
                            return nil
                        }
                    }
                    return keep(id, document: document, png: png, image: picture)
                },
                save: { [weak self] file in
                    guard let self, let entry = history.item(id: id) else { return nil }
                    return await saveCopy?(entry, file)
                },
                coordinator: self, name: title, scale: { [weak self] in self?.history.item(id: id)?.pixelsPerPoint ?? Double(scale) },
                entry: { [weak self] in self?.history.item(id: id) }, uploadID: { id }
            )
        )
        editor.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in
            self?.editors[id] = nil
            if inHistory { self?.onEditing?(id, false) }
            MemoryRelief.endEventWait()
        }
        editors[id] = editor
        editor.show()
    }

    /// The editor's actions: keeping and saving as given, and dragging out, copying, pinning, and uploading as a card
    /// does them. `uploadID` names the editor's uploads: the capture's own, or one a project's editor keeps.
    private static func editorActions(
        keep: @escaping (AnnotationDocument, Data, CGImage) -> URL?, save: @escaping (URL) async -> URL?,
        coordinator: AnnotationCoordinator, name: String, scale: @escaping () -> Double?, entry: @escaping () -> HistoryItem?, uploadID: @escaping () -> UUID
    ) -> AnnotationEditorWindowController.Actions {
        var actions = AnnotationEditorWindowController.Actions(keep: keep, save: save)
        actions.saveAs = { [weak coordinator] file in await coordinator?.saveAs?(file, entry(), scale()) }
        actions.fileToHandOver = { [weak coordinator] file in
            guard let fileToHandOver = coordinator?.fileToHandOver else { return file }
            return fileToHandOver(file, scale())
        }
        actions.copy = { [weak coordinator] image, png, pictureScale in
            if let copy = coordinator?.copyPicture {
                // The picture copied is rendered now, before it is kept: its own scale, not the last kept one, which
                // differs after an undone resize. A capture whose scale is unknown stays unknown.
                return await copy(image, png, name, scale().map { _ in Double(pictureScale) })
            } else {
                return PasteboardWriter.write(png: png, image: image)
            }
        }
        // A picture whose edits couldn't be kept is the pin's own: the capture's file, which its Save and a drag would take,
        // doesn't show them, a redaction among them.
        actions.pin = { [weak coordinator] image, pixelsPerPoint, kept in coordinator?.pinPicture?(image, pixelsPerPoint, kept ? entry() : nil) }
        actions.uploadMenu = { [weak coordinator] in coordinator?.uploadMenu?() ?? .hidden }
        actions.upload = { [weak coordinator] file, destination in coordinator?.uploadFile?(uploadID(), file, destination, scale()) }
        actions.isUploading = { [weak coordinator] in coordinator?.isUploading?(uploadID()) ?? false }
        return actions
    }

    /// The captures open in an editor: never expired from under it.
    var openCaptureIDs: Set<UUID> { Set(editors.keys).union(opening.keys) }

    /// Whether an editor is open or on its way, a project's too.
    var isEditing: Bool { !editors.isEmpty || !opening.isEmpty || !projectEditors.isEmpty }

    func closeBeforeQuitting() async -> Bool {
        while let editor = editors.values.first(where: { !$0.didClose }) ?? projectEditors.values.first(where: { !$0.didClose }) {
            guard await editor.closeBeforeQuitting() else { return false }
        }
        return true
    }

    /// Opens a project file in the editor, or brings its editor forward. Edits are kept in the project
    /// when the window closes and whenever the picture leaves it, as a capture's are kept in the history;
    /// the picture itself is kept in the app's caches, in a folder of this editor's own (`ProjectPicture`), for
    /// dragging out and saving copies.
    func openProject(at url: URL) {
        let file = url.standardizedFileURL
        if let editor = projectEditors[file] {
            editor.show()
            return
        }
        Task { [weak self] in
            let opened: (project: AnnotationProject, picture: URL)
            do {
                opened = try await Self.loadProject(file)
            } catch {
                Log.capture.error("Could not open the project \(file.lastPathComponent, privacy: .private): \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
                NSApp.activate()
                NSAlert(error: error).runModal()
                return
            }
            guard let self else {
                ProjectPicture.remove(opened.picture, after: .zero)
                return
            }
            if let editor = projectEditors[file] {
                // Opened twice at once: the editor already open is the one, and nothing has this picture.
                ProjectPicture.remove(opened.picture, after: .zero)
                editor.show()
                return
            }
            let capture = opened.project.capture
            let capturePNG = opened.project.capturePNG
            let picture = opened.picture
            // Image Size changes the document's scale, so each keep records it for the outcomes that follow.
            var projectScale = Double(opened.project.document.scale)
            // A project is in no history, so its uploads go under an identity of their own.
            let uploadID = UUID()
            let editor = AnnotationEditorWindowController(
                image: capture,
                scale: opened.project.document.scale,
                document: opened.project.document,
                title: file.deletingPathExtension().lastPathComponent,
                fileURL: picture,
                actions: Self.editorActions(
                    keep: { document, png, _ in
                        do {
                            let preview = try AnnotationProject(capture: capture, document: document, capturePNG: capturePNG)
                                .keep(at: file, preview: png, previewURL: picture)
                            Log.capture.notice("Kept the marks in the project \(file.lastPathComponent, privacy: .private): \(document.items.count, privacy: .public) mark(s)")
                            projectScale = Double(document.scale)
                            return preview
                        } catch {
                            Log.capture.error("Keeping the project failed: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
                            return nil
                        }
                    },
                    save: { [weak self] picture in await self?.saveFile?(picture, projectScale) },
                    coordinator: self, name: file.deletingPathExtension().lastPathComponent, scale: { projectScale }, entry: { nil }, uploadID: { uploadID }
                )
            )
            editor.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in
                self?.projectEditors[file] = nil
                ProjectPicture.remove(picture)
                MemoryRelief.endEventWait()
            }
            projectEditors[file] = editor
            // The title bar shows the project's icon, to drag or to find in Finder.
            editor.window?.representedURL = file
            editor.show()
        }
    }

    /// Reads a project and renders its picture into the caches, off the main actor.
    @concurrent
    private static func loadProject(_ file: URL) async throws -> (project: AnnotationProject, picture: URL) {
        let project = try AnnotationProject.read(from: file)
        return (project, try await ProjectPicture.make(for: project, from: file))
    }

    #if DEBUG
    /// The editor showing `id`, for scripted checks.
    func editor(for id: UUID) -> AnnotationEditorWindowController? {
        editors[id]
    }

    var openEditors: [AnnotationEditorWindowController] { Array(editors.values) + Array(projectEditors.values) }
    #endif

    private func keep(_ id: UUID, document: AnnotationDocument, png: Data, image: CGImage) -> URL? {
        guard let entry = history.item(id: id) else { return nil }
        do {
            let updated: HistoryItem
            // The document's scale is the picture's: a resize scales it with the pixels, and undoing one scales it back. A
            // capture that had no scale (a picture from a file that gave none) is not given the one the editor guessed.
            let scale = entry.pixelsPerPoint == nil ? nil : Double(document.scale)
            if document.isEmpty {
                // Every mark gone and nothing cropped: the capture is what it was.
                updated = try history.restoreOriginal(of: entry, pixelsPerPoint: scale)
            } else {
                updated = try history.replaceImage(
                    of: entry, with: png, pixelWidth: image.width, pixelHeight: image.height, annotations: try JSONEncoder().encode(document),
                    pixelsPerPoint: scale
                )
            }
            let file = history.fileURL(for: updated)
            let data = (try? Data(contentsOf: file)) ?? png
            onChange?(updated, data)
            Log.capture.notice("Kept the marks on \(entry.fileName, privacy: .private): \(document.items.count, privacy: .public) mark(s)")
            return file
        } catch {
            Log.capture.error("Keeping the marks failed: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

}
