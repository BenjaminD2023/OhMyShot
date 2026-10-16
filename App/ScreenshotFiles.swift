import AppKit
import Foundation
import ImageIO
import OMSCore
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// Every way a screenshot leaves the app as a file or as a picture on the clipboard, written as Settings say
/// (`ScreenshotOutput`) and named from the file name pattern.
///
/// The history keeps each capture as a lossless PNG as it was taken, and this converts a copy when one is wanted:
/// saved to the export folder, saved with Save As, dragged out, uploaded, handed to a shortcut, copied.
final class ScreenshotFiles {
    private let settings: SettingsStore
    private let history: HistoryStore
    /// When converted copies too old to want were last cleared: at launch, then about hourly while copies are made.
    private var lastSweep = Date.now

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    /// Clears converted copies nobody can still want, off the main actor, at most once an hour: the app may run for weeks.
    private func sweepConvertedCopies() {
        guard Date.now.timeIntervalSince(lastSweep) > 3600 else { return }
        lastSweep = .now
        Task.detached(priority: .background) { ExportedFiles.removeOld() }
    }

    /// How screenshots are written now.
    var output: ScreenshotOutput { settings.screenshotOutput }

    /// A picture in memory, and the extended-range copy of it when the capture has one.
    struct Picture {
        var image: CGImage
        var hdr: CGImage?

        init(_ image: CGImage, hdr: CGImage? = nil) {
            self.image = image
            self.hdr = hdr
        }
    }

    /// Where a saved screenshot comes from: a capture's file, or a picture that has none (a pin from the clipboard).
    private enum Source {
        case file(URL, Picture?)
        case picture(Picture)

        var fileURL: URL? {
            if case .file(let url, _) = self { url } else { nil }
        }
    }

    // MARK: Names

    /// What a saved copy is called.
    private struct Name {
        let text: String
        /// Whether the pattern gave it, so a file saved under it takes a number.
        let fromPattern: Bool
    }

    /// The name a copy of a capture is offered under: the pattern's, with the capture's date, app, and window and the
    /// next number, for a capture named from the pattern; else the name it has, as a picture opened from a file does.
    private func offeredName(for entry: HistoryItem?, fileURL: URL?) -> Name {
        if let entry, entry.isTemplateNamed == true {
            return Name(text: settings.nextFileName(date: entry.createdAt, appName: entry.appName, windowTitle: entry.windowTitle), fromPattern: true)
        }
        guard let fileURL else {
            return Name(text: settings.nextFileName(date: .now, appName: nil, windowTitle: nil), fromPattern: true)
        }
        return Name(text: fileURL.deletingPathExtension().lastPathComponent, fromPattern: false)
    }

    /// A file is to be saved as `name`: the pattern's counter moves on if the name is the pattern's.
    private func didName(_ name: String, offered: Name) {
        if offered.fromPattern { settings.didSaveFile(named: name, offered: offered.text) }
    }

    private static func folderName(_ directory: URL) -> String {
        FileManager.default.displayName(atPath: directory.path(percentEncoded: false))
    }

    // MARK: Saving

    /// Saves a screenshot to the export folder, in the format Settings choose and named from the pattern.
    /// - Parameters:
    ///   - scale: the capture's pixels per point, which 1× needs; the history's record of it by default.
    ///   - picture: the capture in memory, when it is at hand: an HDR copy of it makes a HEIC with a gain map.
    ///   - asks: asks for the name first, when Settings say to; a save nobody is waiting at (the URL API's, a
    ///     shortcut's) passes false.
    /// - Returns: where it went; nil when it was cancelled or failed (which beeps).
    func saveScreenshot(fileAt url: URL, entry: HistoryItem? = nil, scale: Double? = nil, picture: Picture? = nil, asks: Bool) async -> URL? {
        let entry = entry ?? history.item(forFileAt: url)
        return await save(.file(url, picture), entry: entry, scale: scale ?? entry?.pixelsPerPoint, asks: asks)
    }

    /// The same for a picture that has no file of its own.
    func saveScreenshot(_ picture: Picture, scale: Double?, asks: Bool) async -> URL? {
        await save(.picture(picture), entry: nil, scale: scale, asks: asks)
    }

    private func save(_ source: Source, entry: HistoryItem?, scale: Double?, asks: Bool) async -> URL? {
        let output = output
        // A capture left as it is, a PNG, is copied: what the history holds is what is saved.
        let copied: URL? = if case .file(let url, _) = source, output.isUnchanged { url } else { nil }
        let fileExtension = copied?.pathExtension ?? output.format.fileExtension
        let directory = settings.exportDirectory
        let offered = offeredName(for: entry, fileURL: source.fileURL)
        var name = offered.text
        if asks && settings.asksForFileName {
            guard let typed = await FileNamePrompt.ask(offering: name, fileExtension: fileExtension, folder: Self.folderName(directory)) else {
                Log.capture.notice("Saving cancelled")
                return nil
            }
            name = typed
        }
        didName(name, offered: offered)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = ImageExporter.availableURL(in: directory, name: name, fileExtension: fileExtension)
            if let copied {
                try FileManager.default.copyItem(at: copied, to: destination)
            } else {
                try ImageExporter.write(try await Self.encoded(source, scale: scale, output: output).data, to: destination)
            }
            Log.capture.notice("Saved \(destination.lastPathComponent, privacy: .public)")
            return destination
        } catch {
            Log.capture.error("Saving failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    private static func encoded(_ source: Source, scale: Double?, output: ScreenshotOutput) async throws -> PictureExport.Encoded {
        switch source {
        case .file(_, let picture?), .picture(let picture):
            try await PictureExport.encoded(picture.image, pixelsPerPoint: scale, hdr: picture.hdr, output: output)
        case .file(let url, nil):
            try await PictureExport.encoded(fileAt: url, pixelsPerPoint: scale, output: output)
        }
    }

    /// Asks where to save a screenshot, and saves it there: in the format of the name typed, else the one Settings
    /// choose. The panel opens in the export folder. Returns where it went; nil when cancelled or failed.
    func saveScreenshotAs(fileAt url: URL, entry: HistoryItem? = nil, scale: Double? = nil) async -> URL? {
        let entry = entry ?? history.item(forFileAt: url)
        let scale = scale ?? entry?.pixelsPerPoint
        let output = output
        let sourceFormat = ImageExporter.Format(fileExtension: url.pathExtension)
        let offered = offeredName(for: entry, fileURL: url)
        // A capture left as it is is saved as the kind of file it is.
        let preferred = output.isUnchanged ? sourceFormat ?? .png : output.format
        guard let chosen = await SavePanel.ask(name: offered.text, types: SavePanel.pictureTypes(preferring: preferred), directory: settings.exportDirectory) else {
            return nil
        }
        didName(chosen.deletingPathExtension().lastPathComponent, offered: offered)
        let format = ImageExporter.Format(fileExtension: chosen.pathExtension) ?? preferred
        do {
            // Written atomically over a file the person agreed to replace: if reading or encoding fails, it stays as it was.
            if output.isUnchanged, format == sourceFormat {
                try ImageExporter.write(try Data(contentsOf: url), to: chosen)
            } else {
                let encoded = try await PictureExport.encoded(fileAt: url, pixelsPerPoint: scale, output: output.with(format: format))
                try ImageExporter.write(encoded.data, to: chosen)
            }
            Log.capture.notice("Saved \(chosen.lastPathComponent, privacy: .public) with Save As")
            return chosen
        } catch {
            Log.capture.error("Save As failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    /// Save As for a picture that has no file of its own (a pin from the clipboard).
    func saveScreenshotAs(_ picture: Picture, scale: Double?) async -> URL? {
        let output = output
        let offered = offeredName(for: nil, fileURL: nil)
        guard let chosen = await SavePanel.ask(name: offered.text, types: SavePanel.pictureTypes(preferring: output.format), directory: settings.exportDirectory) else {
            return nil
        }
        didName(chosen.deletingPathExtension().lastPathComponent, offered: offered)
        do {
            let format = ImageExporter.Format(fileExtension: chosen.pathExtension) ?? output.format
            let encoded = try await PictureExport.encoded(picture.image, pixelsPerPoint: scale, hdr: picture.hdr, output: output.with(format: format))
            try ImageExporter.write(encoded.data, to: chosen)
            return chosen
        } catch {
            Log.capture.error("Save As failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    /// Asks where to save a copy of a recording, as the kind of file it is. Returns where it went; nil when cancelled or failed.
    func saveRecordingAs(_ file: URL) async -> URL? {
        let types = [UTType(filenameExtension: file.pathExtension) ?? .data]
        guard let url = await SavePanel.ask(name: file.deletingPathExtension().lastPathComponent, types: types, directory: settings.exportDirectory) else { return nil }
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: file, to: url)
            return url
        } catch {
            Log.capture.error("Save As failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    // MARK: Handing over

    /// The file to hand to another app when a capture is dragged out of a card, History, or the editor: the capture's own
    /// when Settings leave it as it is, else a copy in the chosen format, made now (and kept, so a second drag
    /// is quick). A recording is its own file.
    func fileToHandOver(_ url: URL, scale: Double? = nil) -> URL {
        let output = output
        guard !output.isUnchanged, ExportedFiles.isPicture(url) else { return url }
        do {
            defer { sweepConvertedCopies() }
            return try ExportedFiles.file(for: url, pixelsPerPoint: scale ?? history.item(forFileAt: url)?.pixelsPerPoint, output: output)
        } catch {
            Log.capture.error("Converting \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return url
        }
    }

    /// The same where nobody drags, for a capture whose bytes are in hand: an upload, which must not depend on the
    /// capture's file staying. Converted off the main actor. Nil when the bytes are no picture or cannot be converted.
    func exportedFile(forPictureData data: Data, named name: String, scale: Double?) async -> URL? {
        let output = output
        guard let loaded = await Self.decode(data) else { return nil }
        do {
            defer { sweepConvertedCopies() }
            return try await ExportedFiles.fileOffMain(forPicture: loaded, named: name, pixelsPerPoint: scale, output: output)
        } catch {
            Log.capture.error("Converting \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// What a shortcut is handed for a capture: the picture as Settings write it, read now.
    func shortcutFile(for entry: HistoryItem) async throws -> (data: Data, name: String, type: UTType) {
        let url = history.fileURL(for: entry)
        let output = output
        let stem = (entry.fileName as NSString).deletingPathExtension
        guard !output.isUnchanged, ExportedFiles.isPicture(url) else {
            let data = try Data(contentsOf: url)
            return (data, entry.fileName, UTType(filenameExtension: url.pathExtension) ?? .png)
        }
        let encoded = try await PictureExport.encoded(fileAt: url, pixelsPerPoint: entry.pixelsPerPoint, output: output)
        return (encoded.data, "\(stem).\(encoded.fileExtension)", encoded.format.type)
    }

    // MARK: Clipboard

    /// Copies a capture from its file: a card's and History's Copy. By default the picture alone, no file: some apps paste
    /// a file reference instead of the picture when both are offered. A recording, a movie or a GIF, goes as its
    /// file, as Finder's Copy does: a GIF's picture alone would paste as its first frame.
    func copy(fileAt url: URL) {
        guard !HistoryStore.isRecording(url) else { return PasteboardWriter.write(fileURL: url) }
        // As it has always been: the capture's PNG, as it is.
        if !output.changesPicture, settings.clipboardFormat == .pictureOnly {
            guard
                let data = try? Data(contentsOf: url),
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to copy it")
                return
            }
            return PasteboardWriter.write(png: data, image: image)
        }
        Task {
            guard let loaded = await Self.load(url) else {
                Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to copy it")
                return
            }
            await copy(Picture(loaded.image), png: loaded.data, name: url.deletingPathExtension().lastPathComponent, scale: history.item(forFileAt: url)?.pixelsPerPoint, historyFile: url)
        }
    }

    /// Puts a picture on the clipboard: its PNG, scaled, converted, and given a border as Settings say, and with
    /// Settings' file beside it when they say so.
    /// - Parameters:
    ///   - png: the picture already encoded, as it is, if it is.
    ///   - name: the file's name, if one is made.
    ///   - historyFile: the capture's file in the history, which is the clipboard's file when Settings leave it as it is
    ///     and the history keeps captures.
    ///   - withFile: false for a picture that is to go alone (a pin's).
    func copy(_ picture: Picture, png: Data?, name: String, scale: Double?, historyFile: URL? = nil, withFile: Bool = true) async {
        let output = output
        var shown = picture.image
        var data = png
        if output.changesPicture {
            guard let processed = await PictureExport.clipboardPicture(shown, pixelsPerPoint: scale, output: output) else { return NSSound.beep() }
            shown = processed.image
            data = processed.png
        }
        if data == nil { data = try? await ImageExporter.encode(shown, as: .png) }
        guard let data else { return NSSound.beep() }
        var file: URL?
        if withFile, settings.clipboardFormat == .fileAndPicture {
            // The history's file only where it stays: with History off, a capture leaves it when its card closes.
            if output.isUnchanged, let historyFile, settings.historyRetention != .never {
                file = historyFile
            } else {
                file = try? await ExportedFiles.fileOffMain(forClipboard: picture.image, hdr: picture.hdr, named: name, pixelsPerPoint: scale, output: output)
                sweepConvertedCopies()
            }
        }
        PasteboardWriter.write(png: data, image: shown, fileURL: file)
    }

    @concurrent private static func decode(_ data: Data) async -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// Reads a picture file with its bytes, off the main actor.
    @concurrent private static func load(_ url: URL) async -> (image: CGImage, data: Data)? {
        guard
            let data = try? Data(contentsOf: url),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image, data)
    }
}
