import AppKit
import Foundation
import ImageIO
import OMSAnnotate
import OMSCore
import OSLog

/// Opens captures in the annotation editor and keeps what is drawn on them: the capture's file then
/// shows the marks, while the original and the marks stay beside it in the history, so opening the
/// capture again picks up where the editing left off. One editor per capture.
final class AnnotationCoordinator {
    private let history: HistoryStore
    private var editors: [UUID: AnnotationEditorWindowController] = [:]
    /// Editors of project files, by file.
    private var projectEditors: [URL: AnnotationEditorWindowController] = [:]
    /// Saves a copy of a project's picture to the export location, with the scale it was made at; returns where it went.
    var saveFile: ((URL, Double) async -> URL?)?
    /// A capture's picture changed: its record, and the picture's encoded data.
    var onChange: ((HistoryItem, Data) -> Void)?
    /// A capture's editor opened (true) or closed (false).
    var onEditing: ((UUID, Bool) -> Void)?
    /// Saves a copy of a capture's file to the export location; returns where it went.
    var saveCopy: ((HistoryItem, URL) async -> URL?)?
    /// The file to hand to another app when an editor's picture is dragged out, from the picture's file and its scale
    /// (nil when unknown).
    var fileToHandOver: ((URL, Double?) -> URL)?
    /// Puts an editor's picture on the clipboard: the picture, its PNG, its name, and its scale (nil when unknown).
    var copyPicture: ((CGImage, Data, String, Double?) async -> Void)?

    init(history: HistoryStore) {
        self.history = history
    }

    /// Opens `entry` in the editor, or brings its editor forward. `scale` is pixels per point of the
    /// screen it was captured on; the scale the capture itself has (marks kept with one, or a screenshot
    /// brought down to one pixel per point) comes first.
    func annotate(_ entry: HistoryItem, scale: CGFloat) {
        if let editor = editors[entry.id] {
            editor.show()
            return
        }
        guard entry.kind == .screenshot else { return }
        let history = history
        Task { [weak self] in
            guard let loaded = await Self.load(entry, from: history) else {
                Log.capture.error("Could not read \(entry.fileName, privacy: .public) to annotate it")
                NSSound.beep()
                return
            }
            guard let self else { return }
            // Opened twice while loading: the first one wins.
            if let editor = editors[entry.id] {
                editor.show()
                return
            }
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
                    coordinator: self, name: (entry.fileName as NSString).deletingPathExtension, scale: { [weak self] in self?.history.item(id: id)?.pixelsPerPoint }
                )
            )
            editor.onClose = { [weak self] in
                // Released on the next turn, never inside the window's own close.
                Task { @MainActor in
                    self?.editors[id] = nil
                    self?.onEditing?(id, false)
                    MemoryRelief.returnFreedPages()
                }
            }
            editors[id] = editor
            onEditing?(id, true)
            editor.show()
        }
    }

    /// The editor's actions: keeping and saving as given, and dragging out and copying as the file settings say.
    private static func editorActions(
        keep: @escaping (AnnotationDocument, Data, CGImage) -> URL?, save: @escaping (URL) async -> URL?,
        coordinator: AnnotationCoordinator, name: String, scale: @escaping () -> Double?
    ) -> AnnotationEditorWindowController.Actions {
        var actions = AnnotationEditorWindowController.Actions(keep: keep, save: save)
        actions.fileToHandOver = { [weak coordinator] file in coordinator?.fileToHandOver?(file, scale()) ?? file }
        actions.copy = { [weak coordinator] image, png in
            if let copy = coordinator?.copyPicture {
                await copy(image, png, name, scale())
            } else {
                PasteboardWriter.write(png: png, image: image)
            }
        }
        return actions
    }

    /// The captures open in an editor: never expired from under it.
    var openCaptureIDs: Set<UUID> { Set(editors.keys) }

    /// Keeps every open editor's edits, for quitting.
    func keepAll() {
        editors.values.forEach { $0.keepNow() }
        projectEditors.values.forEach { $0.keepNow() }
    }

    /// Opens a project file in the editor, or brings its editor forward. Edits are kept in the project
    /// when the window closes and whenever the picture leaves it, as a capture's are kept in the history;
    /// the picture itself is kept beside the app's caches, for dragging out and saving copies.
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
                Log.capture.error("Could not open the project \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                NSApp.activate()
                NSAlert(error: error).runModal()
                return
            }
            guard let self else { return }
            if let editor = projectEditors[file] {
                editor.show()
                return
            }
            let capture = opened.project.capture
            let capturePNG = opened.project.capturePNG
            let picture = opened.picture
            let projectScale = Double(opened.project.document.scale)
            let editor = AnnotationEditorWindowController(
                image: capture,
                scale: opened.project.document.scale,
                document: opened.project.document,
                title: file.deletingPathExtension().lastPathComponent,
                fileURL: picture,
                actions: Self.editorActions(
                    keep: { document, png, _ in
                        do {
                            try AnnotationProject(capture: capture, document: document, capturePNG: capturePNG).write(to: file)
                            try png.write(to: picture, options: .atomic)
                            Log.capture.notice("Kept the marks in the project \(file.lastPathComponent, privacy: .public): \(document.items.count, privacy: .public) mark(s)")
                            return picture
                        } catch {
                            Log.capture.error("Keeping the project failed: \(error.localizedDescription, privacy: .public)")
                            return nil
                        }
                    },
                    save: { [weak self] picture in await self?.saveFile?(picture, projectScale) },
                    coordinator: self, name: file.deletingPathExtension().lastPathComponent, scale: { projectScale }
                )
            )
            editor.onClose = { [weak self] in
                Task { @MainActor in
                    self?.projectEditors[file] = nil
                    MemoryRelief.returnFreedPages()
                }
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
        let folder = URL.cachesDirectory.appending(path: Log.subsystem, directoryHint: .isDirectory).appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appending(path: file.deletingPathExtension().lastPathComponent + ".png")
        guard let image = await AnnotationRenderer.render(project.document, base: project.capture) else { throw CocoaError(.fileReadCorruptFile) }
        try await ImageExporter.encode(image, as: .png).write(to: picture, options: .atomic)
        return (project, picture)
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
            Log.capture.notice("Kept the marks on \(entry.fileName, privacy: .public): \(document.items.count, privacy: .public) mark(s)")
            return file
        } catch {
            Log.capture.error("Keeping the marks failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The capture as it was taken and any marks made on it before, read off the main actor.
    @concurrent
    private static func load(_ entry: HistoryItem, from history: HistoryStore) async -> (image: CGImage, document: AnnotationDocument?)? {
        let marked = history.hasOriginal(entry)
        let url = marked ? history.originalURL(for: entry) : history.fileURL(for: entry)
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var document: AnnotationDocument?
        if marked, let data = try? Data(contentsOf: history.annotationsURL(for: entry)) {
            document = try? JSONDecoder().decode(AnnotationDocument.self, from: data)
        }
        return (image, document)
    }
}
