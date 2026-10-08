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
    /// A capture's picture changed: its record, and the picture's encoded data.
    var onChange: ((HistoryItem, Data) -> Void)?
    /// Saves a copy of a capture's file to the export location; returns where it went.
    var saveCopy: ((HistoryItem, URL) -> URL?)?

    init(history: HistoryStore) {
        self.history = history
    }

    /// Opens `entry` in the editor, or brings its editor forward. `scale` is pixels per point of the
    /// screen it was captured on.
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
                scale: loaded.document?.scale ?? scale,
                document: loaded.document,
                title: (entry.fileName as NSString).deletingPathExtension,
                fileURL: history.fileURL(for: entry),
                actions: .init(
                    keep: { [weak self] document, png, image in self?.keep(id, document: document, png: png, image: image) },
                    save: { [weak self] file in
                        guard let self, let entry = self.history.item(id: id) else { return nil }
                        return self.saveCopy?(entry, file)
                    }
                )
            )
            editor.onClose = { [weak self] in
                // Released on the next turn, never inside the window's own close.
                Task { @MainActor in
                    self?.editors[id] = nil
                    MemoryRelief.returnFreedPages()
                }
            }
            editors[id] = editor
            editor.show()
        }
    }

    /// The captures open in an editor: never expired from under it.
    var openCaptureIDs: Set<UUID> { Set(editors.keys) }

    /// Keeps every open editor's edits, for quitting.
    func keepAll() {
        editors.values.forEach { $0.keepNow() }
    }

    #if DEBUG
    /// The editor showing `id`, for scripted checks.
    func editor(for id: UUID) -> AnnotationEditorWindowController? {
        editors[id]
    }

    var openEditors: [AnnotationEditorWindowController] { Array(editors.values) }
    #endif

    private func keep(_ id: UUID, document: AnnotationDocument, png: Data, image: CGImage) -> URL? {
        guard let entry = history.item(id: id) else { return nil }
        do {
            let updated: HistoryItem
            if document.isEmpty {
                // Every mark gone and nothing cropped: the capture is what it was.
                updated = try history.restoreOriginal(of: entry)
            } else {
                updated = try history.replaceImage(of: entry, with: png, pixelWidth: image.width, pixelHeight: image.height, annotations: try JSONEncoder().encode(document))
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
