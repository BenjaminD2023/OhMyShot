import AppKit
import Foundation
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
    /// Sets a new screenshot on the background chosen for every screenshot, if there is one: the
    /// picture to show and copy, and the document that recreates it from the capture. Given the capture
    /// and its pixels per point.
    var compose: ((CGImage, CGFloat) async -> (image: CGImage, document: Data)?)?
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

    func captureArea() {
        begin(mode: .area)
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

    private func begin(mode: OverlayController.Mode) {
        guard !overlay.isActive else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        overlay.freezesScreen = settings.freezeScreen
        overlay.begin(mode: mode) { [weak self] outcome in
            switch outcome {
            case .region(let rect, let display, _):
                Task { await self?.captureRegion(rect, on: display, appName: app) }
            case .window(let target, _):
                Task { await self?.captureWindow(target) }
            case .cancelled:
                break
            }
        }
    }

    private func captureWindow(_ target: WindowTarget) async {
        let probe = LatencyProbe("capture.window")
        do {
            let frame = try await capturer.captureWindow(target, shadow: true, layout: displays.layout)
            probe.end()
            await deliver(frame, appName: target.ownerName)
        } catch {
            Log.capture.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deliver(_ frame: CapturedFrame, appName: String?, copiesToClipboard: Bool = true) async {
        if settings.playSounds { shutter?.play() }
        let probe = LatencyProbe("capture.deliver")
        do {
            let png = try await ImageExporter.encode(frame.image, as: .png)
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
            // On a background chosen for every screenshot, the capture's file shows the background while
            // the capture and the background's settings stay beside it, as edits do, so the editor can
            // change or remove it.
            var shown = (image: frame.image, png: png)
            let scale = frame.frame.width > 0 ? CGFloat(frame.image.width) / frame.frame.width : 1
            if let composed = await compose?(frame.image, scale), let composedPNG = try? await ImageExporter.encode(composed.image, as: .png) {
                entry = try history.replaceImage(
                    of: entry, with: composedPNG, pixelWidth: composed.image.width, pixelHeight: composed.image.height, annotations: composed.document
                )
                shown = (composed.image, composedPNG)
            }
            if copiesToClipboard, settings.copyAfterCapture {
                PasteboardWriter.write(png: shown.png, image: shown.image)
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
            if settings.saveAfterCapture {
                item.savedURL = save(item)
            }
            probe.end()
            Log.capture.notice("Captured \(frame.image.width, privacy: .public)x\(frame.image.height, privacy: .public) into history as \(entry.fileName, privacy: .public)")
            onCaptured?(item)
        } catch {
            Log.capture.error("Keeping the capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
