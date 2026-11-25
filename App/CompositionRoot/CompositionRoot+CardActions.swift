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

/// What becomes of a capture once it is kept (its card, its upload, its text read for the search), and what Quick Access
/// cards and Capture History do with it.
extension CompositionRoot {
    // MARK: Kept captures

    func didCapture(_ item: QuickAccessItem, forceQuickAccess: Bool = false) {
        if forceQuickAccess || settings.afterCapture(for: item.kind).showsQuickAccess {
            quickAccess.add(item)
        } else {
            // With history off and no card, nothing else may hold on to it: a screenshot already went to the clipboard
            // as a picture, and a copy was saved to the export folder. A recording's Studio window, for one, holds it.
            retention.releaseIfUnheld(item.id)
        }
        retention.removeExpired()
    }

    /// Settings' Upload after a capture: to the default destination, when there is one.
    func uploadKept(_ entry: HistoryItem) {
        guard uploads.canUpload else { return }
        uploadAfterCapture(entry)
    }

    /// The URL API's `action=upload`: the capture just kept goes to the default destination.
    func uploadAfterCapture(_ entry: HistoryItem) {
        upload(captureID: entry.id, fileURL: history.fileURL(for: entry))
    }

    /// Uploads a capture's picture as Settings write it: the capture itself when they leave it as it is, else a copy in
    /// the chosen format. A capture to be converted is read now, since with History off its file may be gone by the time
    /// the copy is made. When that copy cannot be made nothing is sent, and the card, or the reading by the pointer, says
    /// why: the capture itself would leave without the watermark, format, or border Settings promise. `scale` is the picture's
    /// pixels per point where the history has no record of it (a project's).
    func upload(captureID: UUID, fileURL: URL, to destination: UUID? = nil, scale: Double? = nil) {
        guard !files.output.isUnchanged, ExportedFiles.isPicture(fileURL) else {
            uploads.upload(captureID: captureID, fileURL: fileURL, destinationID: destination)
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return showSaveFailure(.converting(error), onCardOf: captureID)
        }
        let name = fileURL.deletingPathExtension().lastPathComponent
        let scale = history.item(id: captureID)?.pixelsPerPoint ?? scale
        Task {
            switch await files.exportedFile(forPictureData: data, named: name, scale: scale) {
            case .success(let file):
                quickAccess.clearHandOverFailure(for: captureID)
                uploads.upload(captureID: captureID, fileURL: file, destinationID: destination)
            case .failure(let failure): showSaveFailure(failure, onCardOf: captureID)
            }
        }
    }

    /// An upload ended. With history off a capture lives as long as something shows it, and an upload was one
    /// of those things: let it go now unless a card (or, after a failure, the card that comes back with Retry),
    /// or the editor, still holds it.
    func uploadEnded(_ id: UUID, _ outcome: UploadCoordinator.Outcome) {
        switch outcome {
        case .finished: usageTelemetry?.record(.upload)
        case .failed: usageTelemetry?.record(.uploadFailure)
        case .cancelled: break
        }
        if outcome == .failed, showsQuickAccess(forCaptureWith: id) { return }
        retention.releaseIfUnheld(id)
    }

    /// Says why a copy could not be saved, or made to be dragged out, shared, or uploaded: on the capture's card when
    /// `captureID` has one on screen, which holds it from closing by itself, else in the reading by the pointer (from the
    /// editor, a pin, History, or after a capture with Quick Access off). Either way VoiceOver hears it.
    func showSaveFailure(_ failure: ExportFailure, onCardOf captureID: UUID?) {
        usageTelemetry?.record(.exportFailure)
        if let captureID, quickAccess.showFailure(failure, for: captureID) { return }
        failureNotice.show(failure.summary, near: NSEvent.mouseLocation)
    }

    /// A card's Save or Save As outcome, its failure counted in usage data as `showSaveFailure` counts the others; the card
    /// says why itself.
    private func countingFailure(_ outcome: SaveOutcome) -> SaveOutcome {
        if outcome.failure != nil { usageTelemetry?.record(.exportFailure) }
        return outcome
    }

    /// Where a copy saved from a window went, nil when it was not saved; a failure is said by the pointer first.
    func savedOrSaidWhy(_ outcome: SaveOutcome) -> URL? {
        if let failure = outcome.failure { showSaveFailure(failure, onCardOf: nil) }
        return outcome.url
    }

    /// What is to be handed over from a window or a pin, nil when it could not be made; then why is said by the pointer
    /// first, and nothing goes.
    func handedOverOrSaidWhy<Value>(_ result: Result<Value, ExportFailure>) -> Value? {
        switch result {
        case .success(let value): return value
        case .failure(let failure):
            showSaveFailure(failure, onCardOf: nil)
            return nil
        }
    }

    /// Whether Settings give the capture a card: the choice for screenshots, or for recordings.
    func showsQuickAccess(forCaptureWith id: UUID) -> Bool {
        settings.afterCapture(for: history.item(id: id)?.kind ?? .screenshot).showsQuickAccess
    }

    /// Has the text read in captures new to the history or with a new picture: now while the History window
    /// is open, else in a moment; not with history off, where they leave the history with their card.
    func readTextSoon(_ entry: HistoryItem) {
        guard settings.historyRetention != .never else { return }
        textReader.enqueue(entry, immediately: historyWindow != nil)
    }

    /// A capture's picture changed in the editor, or was turned, flipped, or scaled on its card: its card and
    /// its History thumbnail follow. `savedCopyIsStale`: the copy saved from the card is of the picture as it was,
    /// so the card offers Save again.
    func pictureChanged(_ entry: HistoryItem, data: Data, savedCopyIsStale: Bool = false) {
        let previous = pictureUpdates
        let thumbnail = quickAccess.pictureChanged(entry, savedCopyIsStale: savedCopyIsStale) {
            await previous?.value
            guard !Task.isCancelled else { return nil }
            return await HistoryStore.cardThumbnail(of: data, maxPixels: QuickAccessItem.thumbnailPixels)
        }
        // One after another: a big picture's thumbnail takes longer than a small one's, and an earlier change's
        // must not come in over a later one's.
        pictureUpdates = Task {
            await previous?.value
            if quickAccess.item(entry.id) != nil {
                // Its card hands over the new picture when dragged: converted meanwhile, off the main actor.
                files.prepareHandOver(history.fileURL(for: entry), scale: entry.pixelsPerPoint)
            }
            await thumbnail?.value
            if pins.contains(captureID: entry.id) {
                let fallback = scale(of: entry, orElse: 2)
                if let loaded = await Self.loadImage(data: data, fallbackScale: fallback) {
                    pins.update(captureID: entry.id, image: loaded.image, scale: loaded.scale)
                }
            }
            historyWindow?.reload(changed: [entry.id])
            readTextSoon(entry)
        }
    }

    /// Decodes updated image bytes off the main actor when refreshing an open pin.
    @concurrent private nonisolated static func loadImage(data: Data, fallbackScale: CGFloat) async -> ImageLoader.Loaded? {
        ImageLoader.load(data: data, fallbackScale: fallbackScale)
    }

    /// Opens an exported handover copy in the default external app so edits in apps like Preview never modify
    /// or corrupt OhMyShot's lossless History original or its editable annotations.
    private func openInExternalApp(_ url: URL, scale: Double?, captureID: UUID? = nil) {
        let handover: URL
        switch files.fileToHandOver(url, scale: scale) {
        case .success(let file):
            if let captureID { quickAccess.clearHandOverFailure(for: captureID) }
            handover = file
        case .failure(let failure):
            showSaveFailure(failure, onCardOf: captureID)
            return
        }
        guard ExportedFiles.isPicture(url), handover.standardizedFileURL == url.standardizedFileURL else {
            NSWorkspace.shared.open(handover)
            return
        }
        let directory = ExportedFiles.standardFolder
            .appending(path: "Open", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copy = directory.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            NSWorkspace.shared.open(copy)
        } catch {
            Log.capture.error("Preparing external copy for \(url.lastPathComponent, privacy: .private) failed: \(Log.kind(of: error), privacy: .public), \(error.localizedDescription, privacy: .private)")
            NSWorkspace.shared.open(handover)
        }
    }

    // MARK: Card and History actions

    func makeQuickAccessActions() -> QuickAccessController.Actions {
        var actions = QuickAccessController.Actions(
            copy: { [weak self] item in await self?.files.copyToClipboard(fileAt: item.fileURL) ?? false },
            save: { [weak self] item, asks in
                guard let self else { return .cancelled }
                return countingFailure(await files.saveCapture(fileAt: item.fileURL, asks: asks))
            },
            saveAs: { [weak self] item in
                guard let self else { return .cancelled }
                return countingFailure(await files.saveCaptureAs(fileAt: item.fileURL))
            },
            open: { [weak self] item in
                guard let self else { return }
                let pixelScale = history.item(id: item.id)?.pixelsPerPoint ?? displays.layout.display(id: item.displayID).map { Double($0.pixelsPerPoint) }
                openInExternalApp(item.fileURL, scale: pixelScale, captureID: item.id)
            },
            annotate: { [weak self] item in
                guard let self, let entry = history.item(id: item.id) else { return }
                // A recording opens in the recording window.
                guard item.kind == .screenshot else { return recordings.open(entry) }
                annotate(entry, displayID: item.displayID)
            },
            reveal: { item in NSWorkspace.shared.activateFileViewerSelecting([item.savedURL ?? item.fileURL]) },
            recognizeText: { [weak self] item in
                guard let self, item.kind == .screenshot else { return }
                let scale = scale(of: item, orElse: 1)
                Task { await self.textCapture.openPanel(forFileAt: item.fileURL, fallbackScale: scale) }
            },
            pin: { [weak self] item in
                guard let self, item.kind == .screenshot else { return false }
                guard let loaded = await Self.loadImage(item.fileURL, fallbackScale: scale(of: item, orElse: 2)) else {
                    NSSound.beep()
                    return false
                }
                pins.pin(loaded.image, scale: loaded.scale, origin: .capture(item.id))
                return true
            },
            moveToTrash: { [weak self] item in
                guard let self, let entry = history.item(id: item.id) else { throw CocoaError(.fileNoSuchFile) }
                try history.moveToTrash(entry)
                uploads.cancel(captureID: item.id)
                // As in CleanShot, the capture goes as a whole: the copy this card saved goes to the Trash
                // with it. Both can be put back from the Trash. A copy saved from the editor or Capture History
                // stays where it was saved.
                if let saved = item.ownSavedURL {
                    do {
                        try FileManager.default.trashItem(at: saved, resultingItemURL: nil)
                    } catch let error as CocoaError where error.code == .fileNoSuchFile {
                        // The user already removed the copy.
                    } catch {
                        NSApp.presentError(error)
                    }
                }
                historyWindow?.reload()
                retention.sweepWallpaperPictures()
            },
            // With history off, a capture lives only as long as something holds it: its card, its editor or window, an
            // upload, the clipboard. The card is already out of the stack when this is called.
            closed: { [weak self] item in self?.retention.releaseIfUnheld(item.id) }
        )
        actions.print = { [weak self] item in
            guard let self, item.kind == .screenshot else { return false }
            guard let loaded = await Self.loadImage(item.fileURL, fallbackScale: scale(of: item, orElse: 2)) else {
                NSSound.beep()
                return false
            }
            return await ImagePrinter.printAndWait(
                loaded.image, pixelsPerPoint: loaded.scale, title: item.fileURL.deletingPathExtension().lastPathComponent
            )
        }
        actions.copyText = { [weak self] item in
            guard let self, item.kind == .screenshot else { return .noText }
            return await textCopier.copyText(ofPictureAt: item.fileURL)
        }
        actions.fileToHandOver = { [weak self] item in self?.files.fileToHandOver(item.fileURL) ?? .success(item.fileURL) }
        actions.codes = { [weak self] item in
            guard let self, settings.showsCodesInSelection, item.kind == .screenshot,
                  let loaded = await Self.loadImage(item.fileURL) else { return [] }
            let codes = (try? await VisionPipeline.selectionCodes(in: loaded.image)) ?? []
            return codes.map { FoundCode(payload: $0.payload, isMatrix: $0.kind.isMatrix, box: $0.box) }
        }
        actions.preferences = { [weak self] in self?.settings.quickAccessPreferences ?? QuickAccessPreferences() }
        actions.pictureChangeOffer = { [weak self] item in self?.pictureChanges.offer(for: item) ?? .unsupported }
        actions.changePicture = { [weak self] item, change in self?.pictureChanges.apply(change, to: item) }
        actions.isBeingEdited = { [weak self] item in self?.annotations.openCaptureIDs.contains(item.id) ?? false }
        actions.combineIntoCollage = { [weak self] items in
            guard let self else { return }
            let entries = items.compactMap { history.item(id: $0.id) }.filter { $0.kind == .screenshot }
            guard entries.count >= 2 else { return }
            combineIntoCollage(entries)
        }
        actions.exportAsPDF = { [weak self] items in
            guard let self else { return }
            let entries = items.compactMap { history.item(id: $0.id) }.filter { $0.kind == .screenshot }
            guard entries.count >= 2 else { return }
            exportPDF(entries)
        }
        actions.translate = { [weak self] item in
            guard let self, item.kind == .screenshot else { return }
            let scale = scale(of: item, orElse: 1)
            Task { await self.textCapture.openPanel(forFileAt: item.fileURL, fallbackScale: scale, source: item.fileURL.lastPathComponent, translating: true) }
        }
        actions.sharing = makeSharingActions()
        return actions
    }

    /// What cards offer for uploading. Every closure asks the destinations when it is called, so a destination
    /// added or removed in Settings shows in the next menu that opens.
    private func makeSharingActions() -> QuickAccessController.Actions.Sharing {
        var sharing = QuickAccessController.Actions.Sharing()
        sharing.menu = { [weak self] in self?.uploads.destinations.menu ?? .hidden }
        sharing.upload = { [weak self] item, destination in self?.upload(captureID: item.id, fileURL: item.fileURL, to: destination) }
        sharing.cancel = { [weak self] item in self?.uploads.cancel(captureID: item.id) }
        sharing.retry = { [weak self] item in self?.uploads.retry(captureID: item.id) }
        sharing.copyLink = { [weak self] item in self?.uploads.copyLink(captureID: item.id) }
        sharing.hasLink = { [weak self] item in self?.uploads.hasLink(item.id) ?? false }
        sharing.canDeleteFromStorage = { [weak self] item in self?.uploads.canDeleteFromStorage(item.id) ?? false }
        sharing.deleteFromStorage = { [weak self] item in self?.uploads.deleteFromStorage(captureID: item.id) }
        sharing.current = { [weak self] item in self?.uploads.cardState(item.id) }
        return sharing
    }

    func makeHistoryWindow() -> HistoryWindowController {
        let saveBatch = HistorySaveBatch()
        var historyActions = HistoryActions(
            restore: { [weak self] entry in Task { await self?.restore(entry) } },
            copy: { [weak self] entry in
                guard let self else { return }
                files.copy(fileAt: history.fileURL(for: entry))
            },
            save: { [weak self] entry in
                guard let self else { return }
                saveBatch.enqueue(entry) { [weak self] batch in
                    guard let self else { return }
                    let asks = batch.count == 1
                    var savedURLs: [URL] = []
                    for item in batch {
                        if let url = self.savedOrSaidWhy(await self.files.saveCapture(fileAt: self.history.fileURL(for: item), asks: asks)) {
                            // The capture's card shows it saved, and no longer says a copy couldn't be: closing by itself
                            // saves no other. It is not the card's own copy, which the card's Move to Trash takes.
                            self.quickAccess.markSaved(item.id, at: url)
                            savedURLs.append(url)
                        }
                    }
                    if !savedURLs.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
                    }
                }
            },
            open: { [weak self] entry in
                guard let self else { return }
                openInExternalApp(history.fileURL(for: entry), scale: entry.pixelsPerPoint)
            },
            annotate: { [weak self] entry in
                guard let self else { return }
                guard entry.kind == .screenshot else { return recordings.open(entry) }
                annotate(entry, displayID: quickAccess.item(entry.id)?.displayID)
            },
            reveal: { [weak self] entry in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([history.fileURL(for: entry)])
            },
            recognizeText: { [weak self] entry in
                guard let self else { return }
                let scale = scale(of: entry, orElse: 1)
                Task { await self.textCapture.openPanel(forFileAt: self.history.fileURL(for: entry), fallbackScale: scale) }
            },
            pin: { [weak self] entry in
                guard let self else { return }
                pin(fileAt: history.fileURL(for: entry), origin: .capture(entry.id), fallbackScale: scale(of: entry, orElse: 2))
            },
            moveToTrash: { [weak self] entry in
                guard let self else { throw CocoaError(.fileNoSuchFile) }
                try history.moveToTrash(entry)
                uploads.cancel(captureID: entry.id)
                quickAccess.remove(entry.id)
                retention.sweepWallpaperPictures()
            }
        )
        historyActions.isBeingEdited = { [weak self] entry in self?.annotations.openCaptureIDs.contains(entry.id) ?? false }
        historyActions.copyText = { [weak self] entry in
            guard let self, entry.kind == .screenshot else { return .noText }
            return await textCopier.copyText(ofPictureAt: history.fileURL(for: entry))
        }
        historyActions.translate = { [weak self] entry in
            guard let self, entry.kind == .screenshot else { return }
            let scale = scale(of: entry, orElse: 1)
            Task {
                await self.textCapture.openPanel(
                    forFileAt: self.history.fileURL(for: entry),
                    fallbackScale: scale,
                    source: entry.appName ?? entry.fileName,
                    translating: true
                )
            }
        }
        historyActions.saveAs = { [weak self] entry in
            guard let self else { return }
            Task {
                if let url = self.savedOrSaidWhy(await self.files.saveCaptureAs(fileAt: self.history.fileURL(for: entry))) {
                    self.quickAccess.markSaved(entry.id, at: url)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        historyActions.print = { [weak self] entry, window in
            guard let self, entry.kind == .screenshot else { return }
            printPicture(fileAt: history.fileURL(for: entry), fallbackScale: scale(of: entry, orElse: 2), from: window)
        }
        historyActions.combine = { [weak self] entries in self?.combineIntoCollage(entries) }
        historyActions.exportPDF = { [weak self] entries, _ in self?.exportPDF(entries) }
        historyActions.sharing.menu = { [weak self] in self?.uploads.destinations.menu ?? .hidden }
        historyActions.sharing.upload = { [weak self] entry, destination in
            guard let self else { return }
            upload(captureID: entry.id, fileURL: history.fileURL(for: entry), to: destination)
        }
        historyActions.fileToHandOver = { [weak self] entry in
            guard let self else { return nil }
            return handedOverOrSaidWhy(files.fileToHandOver(history.fileURL(for: entry), scale: entry.pixelsPerPoint))
        }
        historyActions.filesToHandOver = { [weak self] entries in
            guard let self else { return nil }
            let captures = entries.map { (url: history.fileURL(for: $0), scale: $0.pixelsPerPoint) }
            return handedOverOrSaidWhy(await files.filesToHandOver(captures))
        }
        // Each in the format Settings choose, as one dragged out would be; none when one of them cannot be.
        historyActions.copyFiles = { [weak self] entries in
            guard let self else { return }
            let captures = entries.map { (url: history.fileURL(for: $0), scale: $0.pixelsPerPoint) }
            Task {
                if let urls = self.handedOverOrSaidWhy(await self.files.filesToHandOver(captures)) {
                    PasteboardWriter.write(fileURLs: urls)
                }
            }
        }
        historyActions.sharing.isUploading = { [weak self] entry in self?.uploads.isUploading(entry.id) ?? false }
        historyActions.sharing.cancel = { [weak self] entry in self?.uploads.cancel(captureID: entry.id) }
        historyActions.sharing.hasLink = { [weak self] entry in self?.uploads.hasLink(entry.id) ?? false }
        historyActions.sharing.copyLink = { [weak self] entry in self?.uploads.copyLink(captureID: entry.id) }
        historyActions.sharing.canDeleteFromStorage = { [weak self] entry in self?.uploads.canDeleteFromStorage(entry.id) ?? false }
        historyActions.sharing.deleteFromStorage = { [weak self] entry in self?.uploads.deleteFromStorage(captureID: entry.id) }
        let controller = HistoryWindowController(
            store: history, settings: settings, actions: historyActions, textReader: textReader,
            retentionPreview: { [weak self] in await self?.retention.preview(for: $0) }
        )
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in self?.historyWindow = nil }
        return controller
    }

    /// A recording was edited or put back as it was made: its card shows it as it is now.
    func recordingChanged(_ entry: HistoryItem) {
        historyWindow?.reload()
        let url = history.fileURL(for: entry)
        quickAccess.pictureChanged(entry, savedCopyIsStale: true) {
            await HistoryStore.cardThumbnail(of: url, maxPixels: QuickAccessItem.thumbnailPixels)
        }
    }

    /// Brings a history item back as a Quick Access card.
    func restore(_ entry: HistoryItem) async {
        quickAccess.restore(entry, on: displays.layout.pointerDisplay?.id ?? 0)
    }

    func quickAccessItem(for entry: HistoryItem) async -> QuickAccessItem? {
        let url = history.fileURL(for: entry)
        guard let thumbnail = await HistoryStore.cardThumbnail(of: url, maxPixels: QuickAccessItem.thumbnailPixels) else { return nil }
        return QuickAccessItem(entry, fileURL: url, thumbnail: thumbnail, displayID: displays.layout.pointerDisplay?.id ?? 0)
    }

    /// A card's capture's pixels per point, for a file that says nothing of its resolution: as the history records it, else
    /// its display's (captures are saved without a resolution, so the scale is their display's, unless it was scaled to one
    /// pixel per point); `fallback` once that display is gone.
    private func scale(of item: QuickAccessItem, orElse fallback: CGFloat) -> CGFloat {
        history.item(id: item.id)?.pixelsPerPoint.map { CGFloat($0) } ?? displays.layout.display(id: item.displayID)?.pixelsPerPoint ?? fallback
    }

    /// A history capture's pixels per point, for a file that says nothing of its resolution: as the history records it,
    /// else the sharpest display's (the display a capture came from is not recorded; most captures come from the
    /// sharpest); `fallback` with no display.
    private func scale(of entry: HistoryItem, orElse fallback: CGFloat) -> CGFloat {
        entry.pixelsPerPoint.map { CGFloat($0) } ?? displays.layout.sharpestPixelsPerPoint ?? fallback
    }
}

/// Coalesces synchronous Save calls from Capture History (such as Save N Captures or ⌘S on a multi-selection) so
/// batch saves run sequentially without popping up N filename prompts or N Finder windows.
private final class HistorySaveBatch {
    private var pending: [HistoryItem] = []
    private var flushTask: Task<Void, Never>?

    func enqueue(_ entry: HistoryItem, perform: @escaping ([HistoryItem]) async -> Void) {
        pending.append(entry)
        guard flushTask == nil else { return }
        flushTask = Task {
            await Task.yield()
            let batch = pending
            pending.removeAll()
            flushTask = nil
            await perform(batch)
        }
    }
}
