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
        retryUpdateReminderAfterActivity()
        if forceQuickAccess || settings.afterCapture(for: item.kind).showsQuickAccess {
            quickAccess.add(item)
        } else {
            // With history off and no card, nothing else may hold on to it: a screenshot already went to the clipboard
            // as a picture, and a copy was saved to the export folder. A recording's Studio window, for one, holds it.
            retention.releaseIfUnheld(item.id)
        }
        retention.removeExpired()
        readTextSoon()
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
    /// the copy is made.
    private func upload(captureID: UUID, fileURL: URL, to destination: UUID? = nil) {
        guard !files.output.isUnchanged, ExportedFiles.isPicture(fileURL), let data = try? Data(contentsOf: fileURL) else {
            uploads.upload(captureID: captureID, fileURL: fileURL, destinationID: destination)
            return
        }
        let name = fileURL.deletingPathExtension().lastPathComponent
        let scale = history.item(id: captureID)?.pixelsPerPoint
        Task {
            let file = await files.exportedFile(forPictureData: data, named: name, scale: scale) ?? fileURL
            uploads.upload(captureID: captureID, fileURL: file, destinationID: destination)
        }
    }

    /// An upload ended. With history off a capture lives as long as something shows it, and an upload was one
    /// of those things: let it go now unless a card (or, after a failure, the card that comes back with Retry),
    /// or the editor, still holds it.
    func uploadEnded(_ id: UUID, _ outcome: UploadCoordinator.Outcome) {
        if outcome == .failed, showsQuickAccess(forCaptureWith: id) { return }
        retention.releaseIfUnheld(id)
    }

    /// Whether Settings give the capture a card: the choice for screenshots, or for recordings.
    func showsQuickAccess(forCaptureWith id: UUID) -> Bool {
        settings.afterCapture(for: history.item(id: id)?.kind ?? .screenshot).showsQuickAccess
    }

    /// Has the text read in captures new to the history or with a new picture: now while the History window
    /// is open, else in a moment; not with history off, where they leave the history with their card.
    func readTextSoon() {
        guard settings.historyRetention != .never else { return }
        if historyWindow != nil {
            textReader.readNow()
        } else {
            textReader.readSoon()
        }
    }

    /// A capture's picture changed in the editor, or was turned, flipped, or scaled on its card: its card and
    /// its History thumbnail follow. `savedCopyIsStale`: the copy saved from the card is of the picture as it was,
    /// so the card offers Save again.
    func pictureChanged(_ entry: HistoryItem, data: Data, savedCopyIsStale: Bool = false) {
        // One after another: a big picture's thumbnail takes longer than a small one's, and an earlier change's
        // must not come in over a later one's.
        let previous = pictureUpdates
        pictureUpdates = Task {
            await previous?.value
            if quickAccess.item(entry.id) != nil {
                // Its card hands over the new picture when dragged: converted meanwhile, off the main actor.
                files.prepareHandOver(history.fileURL(for: entry), scale: entry.pixelsPerPoint)
            }
            if let card = quickAccess.item(entry.id),
               let thumbnail = await HistoryStore.cardThumbnail(of: data, maxPixels: QuickAccessItem.thumbnailPixels) {
                quickAccess.update(QuickAccessItem(
                    entry, fileURL: history.fileURL(for: entry), thumbnail: thumbnail, displayID: card.displayID,
                    savedURL: savedCopyIsStale ? nil : card.savedURL
                ), keepsSaved: !savedCopyIsStale)
            }
            historyWindow?.reload(changed: [entry.id])
            readTextSoon()
        }
    }

    // MARK: Card and History actions

    func makeQuickAccessActions() -> QuickAccessController.Actions {
        var actions = QuickAccessController.Actions(
            copy: { [weak self] item in self?.files.copy(fileAt: item.fileURL) },
            save: { [weak self] item, asks in await self?.files.saveCapture(fileAt: item.fileURL, asks: asks) },
            saveAs: { [weak self] item in await self?.files.saveCaptureAs(fileAt: item.fileURL) },
            open: { item in NSWorkspace.shared.open(item.fileURL) },
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
                guard let self, item.kind == .screenshot else { return }
                pin(fileAt: item.fileURL, origin: .capture(item.id), fallbackScale: scale(of: item, orElse: 2))
            },
            moveToTrash: { [weak self] item in
                guard let self else { return }
                uploads.cancel(captureID: item.id)
                // As in CleanShot, the capture goes as a whole: the copy this card saved goes to the Trash
                // with it. Both can be put back from the Trash.
                if let saved = item.savedURL {
                    try? FileManager.default.trashItem(at: saved, resultingItemURL: nil)
                }
                if let entry = history.item(id: item.id) {
                    history.moveToTrash(entry)
                }
                historyWindow?.reload()
                retention.sweepWallpaperPictures()
            },
            // With history off, a capture lives only as long as something holds it: its card, its editor or window, an
            // upload, the clipboard. The card is already out of the stack when this is called.
            closed: { [weak self] item in self?.retention.releaseIfUnheld(item.id) }
        )
        actions.print = { [weak self] item in
            guard let self, item.kind == .screenshot else { return }
            printPicture(fileAt: item.fileURL, fallbackScale: scale(of: item, orElse: 2))
        }
        actions.fileToHandOver = { [weak self] item in self?.files.fileToHandOver(item.fileURL) ?? item.fileURL }
        actions.preferences = { [weak self] in self?.settings.quickAccessPreferences ?? QuickAccessPreferences() }
        actions.pictureChangeOffer = { [weak self] item in self?.pictureChanges.offer(for: item) ?? .unsupported }
        actions.changePicture = { [weak self] item, change in self?.pictureChanges.apply(change, to: item) }
        actions.isBeingEdited = { [weak self] item in self?.annotations.openCaptureIDs.contains(item.id) ?? false }
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
        var historyActions = HistoryActions(
            restore: { [weak self] entry in Task { await self?.restore(entry) } },
            copy: { [weak self] entry in
                guard let self else { return }
                files.copy(fileAt: history.fileURL(for: entry))
            },
            save: { [weak self] entry in
                guard let self else { return }
                Task {
                    guard let item = await self.quickAccessItem(for: entry) else { return }
                    if let url = await self.files.saveCapture(fileAt: item.fileURL) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            },
            open: { [weak self] entry in
                guard let self else { return }
                NSWorkspace.shared.open(history.fileURL(for: entry))
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
                self?.uploads.cancel(captureID: entry.id)
                self?.quickAccess.remove(entry.id)
                self?.history.moveToTrash(entry)
                self?.retention.sweepWallpaperPictures()
            }
        )
        historyActions.print = { [weak self] entry, window in
            guard let self, entry.kind == .screenshot else { return }
            printPicture(fileAt: history.fileURL(for: entry), fallbackScale: scale(of: entry, orElse: 2), from: window)
        }
        historyActions.sharing.menu = { [weak self] in self?.uploads.destinations.menu ?? .hidden }
        historyActions.sharing.upload = { [weak self] entry, destination in
            guard let self else { return }
            upload(captureID: entry.id, fileURL: history.fileURL(for: entry), to: destination)
        }
        historyActions.fileToHandOver = { [weak self] entry in
            guard let self else { return nil }
            return files.fileToHandOver(history.fileURL(for: entry), scale: entry.pixelsPerPoint)
        }
        // Each in the format Settings choose, as one dragged out would be.
        historyActions.copyFiles = { [weak self] entries in
            guard let self else { return }
            let captures = entries.map { (url: history.fileURL(for: $0), scale: $0.pixelsPerPoint) }
            Task { PasteboardWriter.write(fileURLs: await self.files.filesToHandOver(captures)) }
        }
        historyActions.sharing.isUploading = { [weak self] entry in self?.uploads.isUploading(entry.id) ?? false }
        historyActions.sharing.cancel = { [weak self] entry in self?.uploads.cancel(captureID: entry.id) }
        historyActions.sharing.hasLink = { [weak self] entry in self?.uploads.hasLink(entry.id) ?? false }
        historyActions.sharing.copyLink = { [weak self] entry in self?.uploads.copyLink(captureID: entry.id) }
        historyActions.sharing.canDeleteFromStorage = { [weak self] entry in self?.uploads.canDeleteFromStorage(entry.id) ?? false }
        historyActions.sharing.deleteFromStorage = { [weak self] entry in self?.uploads.deleteFromStorage(captureID: entry.id) }
        let controller = HistoryWindowController(
            store: history, settings: settings, actions: historyActions, textReader: textReader,
            expiredCount: { [weak self] in self?.retention.expiredCount(for: $0) ?? 0 }
        )
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in self?.historyWindow = nil }
        return controller
    }

    /// A recording was edited or put back as it was made: its card shows it as it is now.
    func recordingChanged(_ entry: HistoryItem) {
        historyWindow?.reload()
        guard let card = quickAccess.item(entry.id) else { return }
        Task {
            let url = history.fileURL(for: entry)
            guard let thumbnail = await HistoryStore.cardThumbnail(of: url, maxPixels: QuickAccessItem.thumbnailPixels) else { return }
            quickAccess.update(QuickAccessItem(entry, fileURL: url, thumbnail: thumbnail, displayID: card.displayID, savedURL: card.savedURL))
        }
    }

    /// Brings a history item back as a Quick Access card.
    func restore(_ entry: HistoryItem) async {
        guard let item = await quickAccessItem(for: entry) else { return }
        quickAccess.add(item)
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
