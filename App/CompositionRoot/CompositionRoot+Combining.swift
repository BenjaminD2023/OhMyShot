import AppKit
import Foundation
import ImageIO
import OMSCore
import OMSUI
import OSLog

/// History's commands on several screenshots at once: Combine into Collage and Export as PDF.
extension CompositionRoot {
    /// Opens the Collage window on `entries`, in the order given. The collage is a new capture: it joins the history as
    /// it is made (no watermark, as every capture is kept) and opens in the editor.
    func combineIntoCollage(_ entries: [HistoryItem]) {
        let entries = entries.filter { $0.kind == .screenshot }
        guard entries.count >= 2 else { return NSSound.beep() }
        let files = entries.map { (url: history.fileURL(for: $0), pixelsPerPoint: $0.pixelsPerPoint) }
        Task { [weak self] in
            guard let pictures = await Self.collagePictures(files) else {
                Log.capture.error("Combine into Collage: a screenshot could not be read")
                return NSSound.beep()
            }
            guard let self else { return }
            // As sharp as the sharpest picture in it.
            let scale = max(1, entries.compactMap(\.pixelsPerPoint).max() ?? 1)
            self.collageWindow?.close()
            let actions = CollageWindowController.Actions(
                copy: { [weak self] image, scale in
                    guard let self else { return false }
                    return await self.copyCollage(image, scale: scale, pictureCount: pictures.count)
                },
                save: { [weak self] image, scale in
                    guard let self else { return false }
                    guard let url = self.savedOrSaidWhy(await self.files.saveScreenshotAs(.init(image), scale: Double(scale))) else { return false }
                    Log.capture.notice("Saved \(pictures.count, privacy: .public) screenshots as collage \(url.lastPathComponent, privacy: .private)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    return true
                },
                edit: { [weak self] image, scale in
                    guard let self else { return }
                    Log.capture.notice("Combined \(pictures.count, privacy: .public) screenshots into a \(image.width, privacy: .public)x\(image.height, privacy: .public) collage")
                    Task { await self.annotate(image: image, scale: scale, pixelsPerPoint: Double(scale), name: nil) }
                }
            )
            let window = CollageWindowController(pictures: pictures, scale: CGFloat(scale), actions: actions)
            window.onClose = MemoryRelief.releasingOnNextTurn { [weak self, weak window] in
                if self?.collageWindow === window { self?.collageWindow = nil }
            }
            self.collageWindow = window
            window.show()
        }
    }

    /// Encodes a rendered collage with matching Retina DPI, adds it to History, and copies it to the clipboard.
    private func copyCollage(_ image: CGImage, scale: CGFloat, pictureCount: Int) async -> Bool {
        let date = Date.now
        let fileName = settings.nextFileName(date: date, appName: nil, windowTitle: nil)
        let pixelsPerPoint = Double(scale)
        do {
            let png = try await ImageExporter.encode(image, as: .png, pixelsPerPoint: pixelsPerPoint)
            let entry = try history.add(
                data: png, name: fileName, fileExtension: ImageExporter.Format.png.fileExtension,
                kind: .screenshot, pixelWidth: image.width, pixelHeight: image.height, appName: nil,
                pixelsPerPoint: pixelsPerPoint, isTemplateNamed: true, date: date
            )
            historyWindow?.reload()
            readTextSoon(entry)
            let copied = await files.copy(
                .init(image), png: png, name: (entry.fileName as NSString).deletingPathExtension,
                scale: pixelsPerPoint, historyFile: history.fileURL(for: entry)
            )
            retention.releaseIfUnheld(entry.id)
            if copied {
                Log.capture.notice("Copied collage of \(pictureCount, privacy: .public) screenshots (\(image.width, privacy: .public)x\(image.height, privacy: .public))")
            }
            return copied
        } catch {
            Log.capture.error("Copying collage failed: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
            return false
        }
    }

    /// The pictures of `files`, each with its size in points (one point a pixel when its scale is unknown); nil when one
    /// cannot be read.
    @concurrent
    private static func collagePictures(_ files: [(url: URL, pixelsPerPoint: Double?)]) async -> [CollageRenderer.Picture]? {
        var pictures: [CollageRenderer.Picture] = []
        for file in files {
            guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            let scale = max(file.pixelsPerPoint ?? ImageLoader.pixelsPerPoint(of: source) ?? 1, 0.01)
            pictures.append(CollageRenderer.Picture(image: image, size: CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale)))
        }
        return pictures
    }

    /// Asks where to save, then writes `entries` as one PDF, a page each in the order given, each picture written as
    /// every copy that leaves the app is (Settings › Screenshots: 1×, sRGB, the border, the watermark).
    func exportPDF(_ entries: [HistoryItem]) {
        let entries = entries.filter { $0.kind == .screenshot }
        guard let first = entries.first else { return NSSound.beep() }
        let files = entries.map { (url: history.fileURL(for: $0), pixelsPerPoint: $0.pixelsPerPoint) }
        let name = (first.fileName as NSString).deletingPathExtension
        let output = settings.screenshotOutput
        let remembered = UserDefaults.standard.string(forKey: Self.pdfPageSizeKey).flatMap(PDFExport.PageSize.init(rawValue:)) ?? .picture
        Task {
            guard let (url, pageSize) = await SavePanel.askForPDF(name: name, pageSize: remembered, directory: settings.exportDirectory) else { return }
            UserDefaults.standard.set(pageSize.rawValue, forKey: Self.pdfPageSizeKey)
            do {
                let data = try await PDFExport.data(ofFiles: files, output: output, pageSize: pageSize, title: name)
                try ImageExporter.write(data, to: url)
                Log.capture.notice("Exported \(files.count, privacy: .public) screenshot(s) as \(url.lastPathComponent, privacy: .private)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                Log.capture.error("Export as PDF failed: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
                NSSound.beep()
            }
        }
    }

    /// The page size Export as PDF last used, to start from next time.
    private static let pdfPageSizeKey = "historyPDFPageSize"
}
