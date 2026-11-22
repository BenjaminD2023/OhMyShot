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

/// What a picture pin's menu does, and pinning files and what the clipboard holds.
extension CompositionRoot {
    /// What a picture pin's menu does; text and color pins copy their own values.
    func makePinActions() -> PinController.Actions {
        PinController.Actions(
            copy: { [weak self] pin in
                guard let self, case .image(let image, let scale) = pin.content else { return }
                // The picture alone, as pins have always copied; it follows the 1×, sRGB, and border settings.
                Task { await files.copy(.init(image), png: nil, name: String(localized: "Pin"), scale: Double(scale), withFile: false) }
            },
            save: { [weak self] pin in
                guard let self, case .image(_, let scale) = pin.content else { return }
                if let entry = unchangedCapture(of: pin) {
                    Task { _ = self.savedOrSaidWhy(await self.files.saveScreenshot(fileAt: self.history.fileURL(for: entry), entry: entry, asks: true)) }
                } else {
                    Task {
                        guard let picture = await self.ownPicture(of: pin) else { return }
                        _ = self.savedOrSaidWhy(await self.files.saveScreenshot(.init(picture), scale: Double(scale), asks: true))
                    }
                }
            },
            saveAs: { [weak self] pin in self?.savePinAs(pin) },
            annotate: { [weak self] pin in
                guard let self, case .image(let image, let scale) = pin.content else { return }
                if case .capture(let id) = pin.origin, let entry = history.item(id: id) {
                    annotations.annotate(entry, scale: scale)
                } else {
                    Task { await self.annotate(image: image, scale: scale, pixelsPerPoint: Double(scale), name: String(localized: "Pin")) }
                }
            },
            recognizeText: { [weak self] pin in
                guard case .image(let image, let scale) = pin.content else { return }
                self?.textCapture.openPanel(image: image, scale: scale, source: String(localized: "Pin"))
            },
            fileForDrag: { [weak self] pin in
                guard let self, case .image(let image, let scale) = pin.content else { return nil }
                if let entry = unchangedCapture(of: pin) {
                    return handedOverOrSaidWhy(files.fileToHandOver(history.fileURL(for: entry), scale: entry.pixelsPerPoint))
                }
                // A capture's pin hands over what it shows as its capture would leave; a picture from elsewhere goes as it came.
                guard case .capture = pin.origin else { return pin.ownFile() }
                return handedOverOrSaidWhy(files.fileToHandOver(pin: pin.id, scale: Double(scale)) {
                    try PinController.Pin.pictureForHandOver(
                        image, onBackground: pin.onBackground, requiresBackground: pin.requiresBackground
                    )
                })
            }
        )
    }

    /// The app's own standard windows on screen (Settings, Capture History, the editor, the OCR panel), which
    /// captures and recordings take in as they would any app's. What floats over the screen to capture it
    /// (the overlay, Quick Access, readings, the countdown, the recording's bar) is borderless and stays out.
    static func standardWindowIDs() -> Set<CGWindowID> {
        Set(NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    /// Whether the clipboard may hold something to pin, judged by its types alone: reading the types
    /// never asks for clipboard access, reading the contents may.
    static func clipboardMayHoldPin() -> Bool {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types else { return false }
        return PasteboardImage.mayHoldImage(pasteboard) || types.contains(.string) || types.contains(.color)
    }

    /// Pins what the clipboard holds: a picture first, then a color (a color, or text that is exactly a
    /// color's value), then text. Beeps when there is nothing to pin.
    func pinClipboard() {
        let pasteboard = NSPasteboard.general
        let scale = displays.layout.displayUnderPointer?.pixelsPerPoint ?? 2
        switch PasteboardImage.read(pasteboard) {
        case .file(let url):
            return pin(fileAt: url, fallbackScale: scale)
        case .data(let data):
            guard let loaded = ImageLoader.load(data: data, fallbackScale: scale) else { return NSSound.beep() }
            pins.pin(loaded.image, scale: loaded.scale, origin: .clipboard)
            return
        case nil:
            break
        }
        // A copied file that is not a picture brings its name along as text: that is not what was meant.
        if pasteboard.types?.contains(.fileURL) == true { return NSSound.beep() }
        if let color = NSColor(from: pasteboard).flatMap({ PinColor($0.cgColor) }) {
            pins.pin(color: color)
        } else if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let color = PinColor.parse(text) { pins.pin(color: color) } else { pins.pin(text: text) }
        } else {
            NSSound.beep()
        }
    }

    /// Pins a picture file; `origin` says when it is a capture's. A file with no resolution of its own is
    /// taken at `fallbackScale`, its display's for a capture.
    func pin(fileAt url: URL, origin: PinController.Origin? = nil, fallbackScale: CGFloat = 2) {
        Task {
            guard let loaded = await Self.loadImage(url, fallbackScale: fallbackScale) else {
                Log.capture.error("Could not read \(url.lastPathComponent, privacy: .private) to pin it")
                return NSSound.beep()
            }
            pins.pin(loaded.image, scale: loaded.scale, origin: origin ?? .file(url))
        }
    }

    /// Prints a picture file, the print panel as a sheet on `window` when there is one. A file with no resolution
    /// of its own is taken at `fallbackScale`, so it prints at the size it was on screen.
    func printPicture(fileAt url: URL, fallbackScale: CGFloat, from window: NSWindow? = nil) {
        Task {
            guard let loaded = await Self.loadImage(url, fallbackScale: fallbackScale) else {
                Log.capture.error("Could not read \(url.lastPathComponent, privacy: .private) to print it")
                return NSSound.beep()
            }
            ImagePrinter.print(loaded.image, pixelsPerPoint: loaded.scale, title: url.deletingPathExtension().lastPathComponent, from: window)
        }
    }

    func choosePicturesToPin() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image]
        chooser.allowsMultipleSelection = true
        chooser.message = String(localized: "Choose pictures to keep on screen.")
        chooser.prompt = String(localized: "Pin")
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard response == .OK else { return }
            for url in chooser.urls { self?.pin(fileAt: url) }
        }
        chooser.orderFrontRegardless()
    }

    /// The capture a picture pin came from while its file still holds the pin's picture. Once the editor keeps later edits
    /// in it, or it leaves the history, Save and a drag take the pin's own picture as it leaves the app (`ownPicture`).
    private func unchangedCapture(of pin: PinController.Pin) -> HistoryItem? {
        guard case .capture(let id) = pin.origin, let entry = history.item(id: id) else { return nil }
        let file = history.fileURL(for: entry).path(percentEncoded: false)
        guard let changed = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date else { return nil }
        return pin.shows(fileChangedAt: changed) ? entry : nil
    }

    /// A picture pin's own picture as it leaves the app, read off the main actor: for one laid over where it was taken,
    /// which leaves out the background its capture was put on, the capture as the history kept it, on that background
    /// (`PinController.Pin.onBackground`). Nil when that can't be read, which the pointer says: the picture without it
    /// does not leave in its place.
    private func ownPicture(of pin: PinController.Pin) async -> CGImage? {
        guard case .image(let image, _) = pin.content else { return nil }
        let onBackground = pin.onBackground
        let requiresBackground = pin.requiresBackground
        let read = await Task.detached(priority: .userInitiated) {
            Result {
                try PinController.Pin.pictureForHandOver(image, onBackground: onBackground, requiresBackground: requiresBackground)
            }.mapError { ExportFailure.converting($0) }
        }.value
        return handedOverOrSaidWhy(read)
    }

    private func savePinAs(_ pin: PinController.Pin) {
        guard case .image(_, let scale) = pin.content else { return }
        Task {
            guard let picture = await ownPicture(of: pin) else { return }
            _ = savedOrSaidWhy(await files.saveScreenshotAs(.init(picture), scale: Double(scale)))
        }
    }
}
