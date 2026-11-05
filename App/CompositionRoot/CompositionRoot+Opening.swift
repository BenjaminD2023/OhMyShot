import AppKit
import Foundation
import ImageIO
import Observation
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSRecording
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// Pictures and projects opened in the editor: from files, the Share extension, and the clipboard.
extension CompositionRoot {
    /// Opens files in the editor: projects as they are; pictures are added to the history first, so
    /// their marks are kept and stay editable like a capture's.
    func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            if url.pathExtension.lowercased() == AnnotationProject.fileExtension {
                annotations.openProject(at: url)
            } else if ImageLoader.canLoad(url) {
                Task { await annotateImage(at: url) }
            }
        }
    }

    /// The Share extension's hand-over: the pictures in its batch go to the editor, or onto the screen as pins.
    /// They are taken one at a time, each read and opened before the next is read, so a large share does not
    /// hold every picture decoded at once; the batch is removed when all are done, and batches nobody
    /// collected go with it.
    func receiveShared(_ handoff: ShareHandoff) {
        let inbox = ShareInbox.standard()
        let pictures: [URL]
        do {
            pictures = try inbox.pictures(inBatch: handoff.batch)
        } catch {
            Log.automation.error("Share hand-over refused: \(String(describing: error), privacy: .public)")
            return NSSound.beep()
        }
        // A pin is shown at the size a picture with no resolution of its own had on screen; the editor takes it at one pixel
        // per point, as it does a file opened with Open With.
        let pinScale = displays.layout.displayUnderPointer?.pixelsPerPoint ?? 2
        Task {
            var opened = 0
            for url in pictures {
                guard let picture = await Self.loadImage(url, fallbackScale: handoff.action == .pin ? pinScale : 1) else {
                    Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) shared to \(handoff.action.rawValue, privacy: .public) it")
                    continue
                }
                switch handoff.action {
                case .annotate: await annotate(picture, name: url.deletingPathExtension().lastPathComponent)
                case .pin: pins.pin(picture.image, scale: picture.scale, origin: .clipboard)
                }
                opened += 1
            }
            inbox.discard(batch: handoff.batch)
            inbox.removeStaleBatches()
            if opened == 0 { NSSound.beep() }
        }
    }

    /// Chooses pictures or projects to open in the editor.
    func chooseFilesToAnnotate() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image, AnnotationProject.contentType]
        chooser.allowsMultipleSelection = true
        chooser.message = String(localized: "Choose a picture to mark up, or a project to go on with.")
        chooser.prompt = String(localized: "Annotate")
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(chooser.urls)
        }
        chooser.orderFrontRegardless()
    }

    private func annotateImage(at url: URL) async {
        guard let loaded = await Self.loadImage(url) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to annotate it")
            NSSound.beep()
            return
        }
        await annotate(loaded, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Opens a picture from a file or the clipboard in the editor. A picture whose file said nothing of its resolution
    /// (none, or 72 dpi) is one pixel per point, opened and kept in the history so: saving at 1× leaves it at its size
    /// rather than halving it on a guess, and a pin or a print shows it at its size too.
    /// `name`: what it is called in the history; nil names it from the file name pattern, as a capture is.
    func annotate(_ loaded: ImageLoader.Loaded, name: String?) async {
        let scale = loaded.usesFallbackScale ? 1 : loaded.scale
        await annotate(image: loaded.image, scale: scale, pixelsPerPoint: Double(scale), name: name)
    }

    /// Opens a picture with no capture of its own in the editor, added to the history first so its marks
    /// are kept like a capture's. `pixelsPerPoint` is the scale the history records, nil when the picture has none of its
    /// own; `scale` is what the editor opens it at.
    func annotate(image: CGImage, scale: CGFloat, pixelsPerPoint: Double?, name: String?) async {
        let date = Date.now
        let fileName = name ?? settings.nextFileName(date: date, appName: nil, windowTitle: nil)
        do {
            let png = try await ImageExporter.encode(image, as: .png)
            let entry = try history.add(
                data: png, name: fileName, fileExtension: ImageExporter.Format.png.fileExtension,
                kind: .screenshot, pixelWidth: image.width, pixelHeight: image.height, appName: nil, pixelsPerPoint: pixelsPerPoint,
                isTemplateNamed: name == nil ? true : nil, date: date
            )
            historyWindow?.reload()
            readTextSoon()
            annotations.annotate(entry, scale: scale)
        } catch {
            Log.capture.error("Adding \(fileName, privacy: .public) to the history failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// Decodes off the main actor: a large photo takes a while.
    @concurrent nonisolated static func loadImage(_ url: URL, fallbackScale: CGFloat = 1) async -> ImageLoader.Loaded? {
        ImageLoader.load(contentsOf: url, fallbackScale: fallbackScale)
    }

    /// Opens a capture in the annotation editor; `displayID` is the screen it came from, for its scale.
    func annotate(_ entry: HistoryItem, displayID: CGDirectDisplayID?) {
        let layout = displays.layout
        // The display a history capture came from is not recorded; most come from the sharpest.
        let scale = displayID.flatMap { layout.display(id: $0)?.pixelsPerPoint } ?? layout.sharpestPixelsPerPoint ?? 1
        annotations.annotate(entry, scale: scale)
    }
}
