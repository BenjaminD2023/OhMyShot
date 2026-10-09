import AppKit
import Foundation
import OMSAnnotate
import OMSCapture
import OMSCore
import OSLog
import UniformTypeIdentifiers

/// Turns a capture request into a history item: shows the overlay, captures the chosen region or window,
/// encodes it off the main actor, keeps it in the history, copies it, and hands it to Quick Access.
/// Nothing is written to the Desktop unless the user saves or turns on saving after capture.
final class CaptureCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let overlay: OverlayController
    private let history: HistoryStore
    /// Receives every finished capture, already in the history; the composition root decides whether
    /// it gets a Quick Access card.
    var onCaptured: ((QuickAccessItem) -> Void)?
    /// Opens a capture in the annotation editor: its record and its pixels per point.
    var openInEditor: ((HistoryItem, CGFloat) -> Void)?
    #if DEBUG
    /// The in-place annotation on screen, for scripted checks.
    private(set) weak var inPlaceView: InPlaceAnnotationView?
    #endif
    private lazy var shutter = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true
    )

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController, history: HistoryStore) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        self.history = history
    }

    /// - Parameters:
    ///   - copiesToClipboard: false for scripted checks, which never touch the clipboard.
    ///   - freezes: whether the screen holds still while selecting; nil follows the setting. Scripted
    ///     checks on drawn screens pass true, so the real screen is never captured.
    func captureArea(copiesToClipboard: Bool = true, freezes: Bool? = nil) {
        begin(mode: .area, copiesToClipboard: copiesToClipboard, freezes: freezes)
    }

    /// Choose an area (or a window) and mark it up in place, on the frozen screen; then copy it, save
    /// it, or carry on in the editor.
    /// - Parameter copiesToClipboard: false for scripted checks, which never touch the clipboard.
    func annotateArea(copiesToClipboard: Bool = true) {
        guard !overlay.isActive else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        overlay.onAnnotate = { [weak self] request in self?.annotateInPlace(request, appName: app, copiesToClipboard: copiesToClipboard) }
        overlay.begin(mode: .area, purpose: .annotate) { _ in }
    }

    private func annotateInPlace(_ request: OverlayController.AnnotationRequest, appName: String?, copiesToClipboard: Bool) {
        let display = request.display
        let host = request.host
        // The overlay is y up in global points; the frozen frame is y down from the display's corner.
        let area = CGRect(
            x: request.area.minX - display.frame.minX, y: display.frame.maxY - request.area.maxY,
            width: request.area.width, height: request.area.height
        )
        let scale = CGFloat(request.frame.image.width) / max(display.frame.width, 1)
        // Back to global points, y up, from wherever the selection was moved or resized to.
        let frame = { (result: InPlaceAnnotationView.Result) in
            CapturedFrame(image: result.capture, hdrImage: nil, displayID: display.id, frame: CGRect(
                x: display.frame.minX + result.area.minX, y: display.frame.maxY - result.area.maxY,
                width: result.area.width, height: result.area.height
            ))
        }
        let view = InPlaceAnnotationView(
            frame: request.frame.image, scale: scale, size: host.bounds.size, selection: area,
            actions: .init(
                copy: { [weak self] result in
                    // The overlay goes first, so the screen comes back at once; the result renders after.
                    self?.overlay.finishAnnotation()
                    Task { await self?.deliver(frame(result), appName: appName, copiesToClipboard: copiesToClipboard, marks: result.document, copy: .always) }
                },
                save: { [weak self] result in
                    self?.overlay.finishAnnotation()
                    Task { await self?.deliver(frame(result), appName: appName, copiesToClipboard: copiesToClipboard, marks: result.document, savesCopy: true) }
                },
                openInEditor: { [weak self] result in
                    self?.overlay.finishAnnotation()
                    Task { [weak self] in
                        guard let self, let entry = await self.deliver(
                            frame(result), appName: appName, marks: result.document, copy: .never, showsCard: false, playsSound: false
                        ) else { return }
                        self.openInEditor?(entry, scale)
                    }
                },
                cancel: { [weak self] in self?.overlay.cancel() }
            )
        )
        view.frame = host.bounds
        host.addSubview(view)
        view.begin()
        #if DEBUG
        inPlaceView = view
        #endif
    }

    /// Hover a window and click it: captured on its own, with its rounded corners and shadow.
    func captureWindow() {
        begin(mode: .window)
    }

    /// Captures the whole display under the pointer.
    func captureFullscreen() {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        Task {
            let probe = LatencyProbe("capture.fullscreen")
            do {
                let frame = try await capturer.captureDisplay(display)
                probe.end()
                await deliver(frame, appName: app)
            } catch {
                Log.capture.error("Fullscreen capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Captures a region and delivers it, as the overlay does after a drag. Also used by scripted checks.
    /// - Parameter copiesToClipboard: false leaves the clipboard alone whatever the settings say, so
    ///   scripted test captures never replace what the user copied.
    func captureRegion(_ rect: CGRect, on display: DisplayInfo, appName: String?, copiesToClipboard: Bool = true) async {
        let probe = LatencyProbe("capture.region")
        do {
            let frame = try await capturer.captureRegion(rect, on: display)
            probe.end()
            await deliver(frame, appName: appName, copiesToClipboard: copiesToClipboard)
        } catch {
            Log.capture.error("Region capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Delivers a drawn picture as if it were a capture (history and a card), never touching the
    /// clipboard: for scripted checks that must not read the screen.
    func deliverDemo(_ image: CGImage, displayID: CGDirectDisplayID) async {
        let frame = CapturedFrame(image: image, hdrImage: nil, displayID: displayID, frame: CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        await deliver(frame, appName: "Demo", copiesToClipboard: false)
    }
    #endif

    // MARK: Saving

    /// Saves a copy of a capture to the export location under the file-name template.
    func save(_ item: QuickAccessItem) -> URL? {
        save(fileAt: item.fileURL)
    }

    /// Saves a copy of a capture's file to the export location, under the file's name.
    func save(fileAt url: URL) -> URL? {
        do {
            let directory = settings.exportDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = url.deletingPathExtension().lastPathComponent
            let destination = ImageExporter.availableURL(in: directory, name: name, format: .png)
            try FileManager.default.copyItem(at: url, to: destination)
            Log.capture.notice("Saved \(destination.lastPathComponent, privacy: .public)")
            return destination
        } catch {
            Log.capture.error("Saving failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    /// Asks where to save a copy.
    func saveAs(_ item: QuickAccessItem) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.fileURL.lastPathComponent
        panel.directoryURL = settings.exportDirectory
        panel.allowedContentTypes = [.png]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: item.fileURL, to: url)
            return url
        } catch {
            Log.capture.error("Save As failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    // MARK: Private

    private func begin(mode: OverlayController.Mode, copiesToClipboard: Bool = true, freezes: Bool? = nil) {
        guard !overlay.isActive else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        overlay.freezesScreen = freezes ?? settings.freezeScreen
        overlay.begin(mode: mode) { [weak self] outcome in
            switch outcome {
            case .region(_, _, _, let frozen?):
                // The screen was held still: the selection is kept as it was seen.
                Task { await self?.deliver(frozen, appName: app, copiesToClipboard: copiesToClipboard) }
            case .region(let rect, let display, _, nil):
                Task { await self?.captureRegion(rect, on: display, appName: app, copiesToClipboard: copiesToClipboard) }
            case .window(let target, _):
                // A window is captured on its own, frozen or not: with its shadow and its transparent
                // corners, which the frozen screen does not have.
                Task { await self?.captureWindow(target, copiesToClipboard: copiesToClipboard) }
            case .annotated, .cancelled:
                break
            }
        }
    }

    private func captureWindow(_ target: WindowTarget, copiesToClipboard: Bool = true) async {
        let probe = LatencyProbe("capture.window")
        do {
            let frame = try await capturer.captureWindow(target, shadow: true, layout: displays.layout)
            probe.end()
            await deliver(frame, appName: target.ownerName, copiesToClipboard: copiesToClipboard)
        } catch {
            Log.capture.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether a delivered capture goes to the clipboard: as the settings say, always (copying is what
    /// finishing in-place annotation means), or never (it carries on in the editor).
    enum Copy {
        case asSet
        case always
        case never
    }

    /// Keeps a capture in the history, copies it, saves it, and gives it a Quick Access card, as the
    /// settings say. `marks` are drawn on it first (in-place annotation); the background chosen for
    /// every screenshot is set under them. Returns its record.
    @discardableResult
    private func deliver(
        _ frame: CapturedFrame, appName: String?, copiesToClipboard: Bool = true,
        marks: AnnotationDocument? = nil, copy: Copy = .asSet, savesCopy: Bool = false, showsCard: Bool = true, playsSound: Bool = true
    ) async -> HistoryItem? {
        if settings.playSounds, playsSound { shutter?.play() }
        let probe = LatencyProbe("capture.deliver")
        do {
            let png = try await ImageExporter.encode(frame.image, as: .png)
            // Marks drawn in place, and the background chosen for every screenshot, are drawn in first. The
            // capture's file then shows them while the capture and the document stay beside it, as edits
            // do, so the editor can change or remove them.
            var shown = (image: frame.image, png: png)
            var document: Data?
            let scale = frame.frame.width > 0 ? CGFloat(frame.image.width) / frame.frame.width : 1
            if let composed = await composed(frame.image, scale: scale, marks: marks), let composedPNG = try? await ImageExporter.encode(composed.image, as: .png) {
                shown = (composed.image, composedPNG)
                document = composed.document
            }
            let copies = switch copy {
            case .asSet: copiesToClipboard && settings.copyAfterCapture
            case .always: copiesToClipboard
            case .never: false
            }
            // On the clipboard before anything is written, so the picture is not lost if keeping it fails.
            if copies {
                PasteboardWriter.write(png: shown.png, image: shown.image)
            }
            let name = FilenameTemplate.standard.name(date: .now, appName: appName)
            var entry = try history.add(
                data: png,
                name: name,
                fileExtension: ImageExporter.Format.png.fileExtension,
                kind: .screenshot,
                pixelWidth: frame.image.width,
                pixelHeight: frame.image.height,
                appName: appName
            )
            if let document {
                entry = try history.replaceImage(
                    of: entry, with: shown.png, pixelWidth: shown.image.width, pixelHeight: shown.image.height, annotations: document
                )
            }
            var item = QuickAccessItem(
                id: entry.id,
                fileURL: history.fileURL(for: entry),
                thumbnail: await HistoryStore.thumbnail(of: shown.png, maxPixels: 560) ?? shown.image,
                pixelWidth: shown.image.width,
                pixelHeight: shown.image.height,
                displayID: frame.displayID,
                createdAt: entry.createdAt
            )
            if settings.saveAfterCapture || savesCopy {
                item.savedURL = save(item)
            }
            probe.end()
            Log.capture.notice("Captured \(frame.image.width, privacy: .public)x\(frame.image.height, privacy: .public) into history as \(entry.fileName, privacy: .public)\(marks.map { " with \($0.items.count) mark(s)" } ?? "", privacy: .public)")
            if showsCard { onCaptured?(item) }
            return entry
        } catch {
            Log.capture.error("Keeping the capture failed: \(error.localizedDescription, privacy: .public)")
            // Said out loud too: the overlay is gone, and nothing else would show that the capture was not kept.
            NSSound.beep()
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: String(localized: "The capture couldn’t be kept."), .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
            return nil
        }
    }

    /// The capture as it is kept: with marks drawn in place and the background chosen for every new
    /// screenshot set under them, and the document that recreates it; nil when it is kept as captured.
    private func composed(_ image: CGImage, scale: CGFloat, marks: AnnotationDocument?) async -> (image: CGImage, document: Data)? {
        var document = marks ?? AnnotationDocument(pixelSize: CGSize(width: image.width, height: image.height), scale: scale)
        if document.backdrop == nil { document.backdrop = BackdropPresets.shared.automatic?.backdrop }
        guard !document.isEmpty, let rendered = await AnnotationRenderer.render(document, base: image), let data = try? JSONEncoder().encode(document) else { return nil }
        return (rendered, data)
    }
}
