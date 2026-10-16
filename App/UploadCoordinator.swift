import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog

/// Uploads captures to the destinations the user set up, and says how it went: on the capture's card while
/// it is on screen, by the pointer in the Copied reading when it is not, and aloud for VoiceOver.
///
/// The work is `UploadCenter`'s; this is the interface around it. An upload belongs to the capture, so it
/// goes on when its card is closed or the History window is, and its confirmation still shows. Nothing here
/// runs between uploads.
final class UploadCoordinator {
    let destinations: UploadDestinationStore
    let center: UploadCenter
    /// Every finished upload, for Copy Link later, Settings' list, and deleting from the storage.
    let records: UploadRecordStore
    private let uploader: Uploader
    private let settings: SettingsStore
    private let quickAccess: QuickAccessController
    private let copied = CopiedHUD()
    /// Uploads being deleted from their storage, so a second request waits for the first.
    private var deleting: Set<UUID> = []
    /// Asks before a file is removed from its storage; scripted checks answer for themselves.
    var confirmDeletion: @MainActor (_ title: String, _ message: String, _ button: String, _ destructive: Bool) -> Bool = UploadCoordinator.askToDelete
    /// Whether a capture's link went to the clipboard, for the card's wording and its Copy Link.
    private var linkCopied: Set<UUID> = []

    /// Where a link is copied. The clipboard; scripted checks point it at a pasteboard of their own.
    var pasteboard: NSPasteboard = .general
    /// Brings a capture's card back, so a failure that nobody saw can be retried from it.
    var restoreCard: ((UUID) -> Void)?
    #if DEBUG
    /// Told every change of every upload, for scripted checks.
    var debugStatus: ((UUID, UploadStatus?) -> Void)?
    #endif
    /// An upload ended (done, failed, or cancelled): its capture may be let go if nothing else holds it.
    var ended: ((UUID, Outcome) -> Void)?

    enum Outcome {
        case finished
        case failed
        case cancelled
    }

    /// Said where an upload was asked for and nothing can receive it.
    static var noDestinationMessage: String {
        String(localized: "Set up a destination in Settings › Sharing.")
    }

    init(settings: SettingsStore, quickAccess: QuickAccessController, records: UploadRecordStore = .standard()) {
        self.settings = settings
        self.quickAccess = quickAccess
        self.records = records
        let secrets = KeychainSecretStore()
        destinations = UploadDestinationStore(secrets: secrets)
        uploader = Uploader(secrets: secrets)
        center = UploadCenter(store: destinations, uploader: uploader)
        center.onChange = { [weak self] id, status, destinationName in
            self?.changed(id, status, destinationName: destinationName)
        }
    }

    // MARK: Starting

    /// Uploads a capture's file.
    /// - Parameter destinationID: nil for the default destination.
    /// - Returns: false when there was nothing to upload to, or the capture is already uploading.
    @discardableResult
    func upload(captureID: UUID, fileURL: URL, destinationID: UUID? = nil) -> Bool {
        guard destinations.defaultDestination != nil else {
            tellNoDestination()
            return false
        }
        // The name the person knows the capture by: the history file's own name is that.
        let started = center.start(captureID: captureID, fileURL: fileURL, originalName: fileURL.lastPathComponent, destinationID: destinationID) { [weak self] result, destination in
            self?.finished(captureID, result, destination)
        }
        if !started { Log.upload.notice("Upload not started: no such destination, or already uploading") }
        // Started from History or the URL API with no card to show it: the pointer's reading says so.
        if started, quickAccess.item(captureID) == nil { copied.show(String(localized: "Uploading…"), near: NSEvent.mouseLocation) }
        return started
    }

    func isUploading(_ captureID: UUID) -> Bool {
        center.isUploading(captureID)
    }

    func retry(captureID: UUID) {
        if !center.retry(captureID: captureID) {
            Log.upload.notice("Retry not possible: the destination is gone")
            announce(String(localized: "That destination was removed. Choose Upload again to pick another."))
            center.forget(captureID: captureID)
            quickAccess.setUpload(nil, for: captureID)
        }
    }

    func cancel(captureID: UUID) {
        center.cancel(captureID: captureID)
    }

    /// Cancels every upload and waits for the transfers to stop, so nothing is half sent when the app quits.
    func cancelAll(then done: @escaping () -> Void) -> Bool {
        guard !center.isIdle else { return false }
        Task {
            await center.cancelAll()
            done()
        }
        return true
    }

    var uploadingIDs: Set<UUID> { center.uploadingIDs }

    // MARK: Links

    /// The link of a capture's last upload that still works: this session's, or one kept in the records.
    private func link(for captureID: UUID) -> URL? {
        center.link(for: captureID) ?? records.link(for: captureID)
    }

    /// Whether a capture has a link to copy. With no destination set up the capture interface offers nothing
    /// about uploads, links of earlier uploads included; Settings › Sharing still lists them.
    func hasLink(_ captureID: UUID) -> Bool {
        !destinations.destinations.isEmpty && link(for: captureID) != nil
    }

    /// Copy Link on a card: the link of the capture's last upload, copied and said so.
    func copyLink(captureID: UUID) {
        guard let link = link(for: captureID) else { return }
        write(link)
        linkCopied.insert(captureID)
        quickAccess.setUpload(.finished(linkCopied: true), for: captureID)
        confirm(String(localized: "Link copied"), for: captureID, announcement: String(localized: "Link copied."))
    }

    // MARK: Records

    /// Copy Link in Settings' list.
    func copyLink(of record: UploadRecord) {
        guard !record.isExpired() else { return }
        write(record.link)
        announce(String(localized: "Link copied."))
    }

    func open(_ record: UploadRecord) {
        NSWorkspace.shared.open(record.link)
    }

    func forget(_ record: UploadRecord) {
        records.forget(id: record.id)
        refreshCard(record)
    }

    func forgetAllRecords() {
        let captures = Set(records.records.compactMap(\.captureID))
        records.forgetAll()
        for id in captures { quickAccess.setUpload(center.status(for: id).map { cardUpload($0, for: id) }, for: id) }
    }

    // MARK: Deleting

    /// Whether a capture's newest upload can be removed from its storage, and the card or History should offer
    /// it: a signed delete needs its destination, a deletion address does not.
    func canDeleteFromStorage(_ captureID: UUID) -> Bool {
        guard !destinations.destinations.isEmpty, let record = records.removable(for: captureID) else { return false }
        return canDelete(record)
    }

    func canDelete(_ record: UploadRecord) -> Bool {
        switch record.removal {
        case .request?: destinations.destination(id: record.destinationID) != nil
        case .openAddress?: true
        case nil: false
        }
    }

    func deleteFromStorage(captureID: UUID) {
        guard let record = records.removable(for: captureID) else { return }
        deleteFromStorage(record)
    }

    /// Asks, then removes the file from its storage: with a signed request, or by opening the address the server
    /// gave. The record is forgotten once the file is gone.
    func deleteFromStorage(_ record: UploadRecord) {
        guard !deleting.contains(record.id), let removal = record.removal else { return }
        switch removal {
        case .openAddress(let address):
            let asked = confirmDeletion(
                String(localized: "Open the deletion link for “\(record.fileName)”?"),
                String(localized: "\(record.destinationName) gave an address that deletes the file when it’s opened. It opens in your browser, and the upload is taken off this list."),
                String(localized: "Open Link"), false
            )
            guard asked else { return }
            NSWorkspace.shared.open(address)
            records.forget(id: record.id)
            refreshCard(record)
        case .request:
            guard let destination = destinations.destination(id: record.destinationID) else {
                announce(String(localized: "That destination was removed, so the file can’t be deleted from here."))
                return
            }
            let asked = confirmDeletion(
                String(localized: "Delete “\(record.fileName)” from \(destination.name)?"),
                String(localized: "The file is removed from the storage, and its link stops working. This can’t be undone."),
                String(localized: "Delete"), true
            )
            guard asked else { return }
            deleting.insert(record.id)
            Task { [weak self] in
                guard let self else { return }
                defer { deleting.remove(record.id) }
                do {
                    try await uploader.delete(record, from: destination)
                    records.forget(id: record.id)
                    refreshCard(record)
                    tell(String(localized: "Deleted from storage"), near: record.captureID)
                    Log.upload.notice("Deleted an upload from \(destination.kindName, privacy: .public)")
                } catch {
                    Log.upload.error("Delete failed")
                    let reason = error.localizedDescription
                    tell(String(localized: "Couldn’t delete. \(reason)"), near: record.captureID)
                    NSSound.beep()
                }
            }
        }
    }

    /// A removed or forgotten upload leaves nothing for its card to claim: the link it offered is gone with it.
    private func refreshCard(_ record: UploadRecord) {
        guard let id = record.captureID else { return }
        if records.link(for: id) == nil { center.forget(captureID: id) }
        linkCopied.remove(id)
        quickAccess.setUpload(center.status(for: id).map { cardUpload($0, for: id) }, for: id)
    }

    /// The reading by the pointer, and aloud.
    private func tell(_ message: String, near captureID: UUID?) {
        copied.show(message.count > 90 ? String(message.prefix(89)) + "…" : message, near: NSEvent.mouseLocation)
        announce(message)
    }

    private static func askToDelete(title: String, message: String, button: String, destructive: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if destructive {
            // A removal that can’t be undone is not what Return does: Cancel is the default, and the removal is
            // the red button beside it.
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: button).hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn
        }
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What a card shows of a capture's upload now.
    func cardState(_ captureID: UUID) -> CardUpload? {
        center.status(for: captureID).map { cardUpload($0, for: captureID) }
    }

    // MARK: Events

    private func finished(_ captureID: UUID, _ result: UploadResult, _ destination: UploadDestination) {
        // With no card to hold the link, copying it is the only way it reaches anyone.
        let copies = settings.copyLinkAfterUpload || quickAccess.item(captureID) == nil
        if copies {
            write(result.link)
            linkCopied.insert(captureID)
        } else {
            linkCopied.remove(captureID)
        }
        records.add(UploadRecord(captureID: captureID, date: .now, fileName: result.fileName, destination: destination, result: result))
        quickAccess.setUpload(.finished(linkCopied: copies), for: captureID)
        let message = copies ? String(localized: "Link copied") : String(localized: "Uploaded")
        confirm(message, for: captureID, announcement: copies
            ? String(localized: "Uploaded to \(destination.name). Link copied.")
            : String(localized: "Uploaded to \(destination.name)."))
        Log.upload.notice("Upload to \(destination.kindName, privacy: .public) done, link \(copies ? "copied" : "kept", privacy: .public)")
    }

    private func changed(_ captureID: UUID, _ status: UploadStatus?, destinationName: String) {
        #if DEBUG
        debugStatus?(captureID, status)
        #endif
        guard let status else {
            quickAccess.setUpload(nil, for: captureID)
            ended?(captureID, .cancelled)
            return
        }
        if case .finished = status {
            // The card was already told by `finished`, which knows whether the link was copied.
            ended?(captureID, .finished)
            return
        }
        quickAccess.setUpload(cardUpload(status, for: captureID), for: captureID)
        if case .failed(let message) = status {
            Log.upload.error("Upload to \(destinationName, privacy: .private) failed")
            announce(String(localized: "Upload failed. \(message)"))
            if quickAccess.item(captureID) != nil {
                NSSound.beep()
            } else if settings.showQuickAccess {
                // Nobody saw it: the card comes back with the failure and Retry.
                restoreCard?(captureID)
            } else {
                // The reason in the reading itself: with no card there is no tooltip to hover.
                let reason = message.count > 90 ? message.prefix(89) + "…" : Substring(message)
                copied.show(String(localized: "Upload failed. \(String(reason))"), near: NSEvent.mouseLocation)
            }
            ended?(captureID, .failed)
        }
    }

    private func cardUpload(_ status: UploadStatus, for captureID: UUID) -> CardUpload {
        switch status {
        case .uploading(let fraction): .uploading(fraction: fraction)
        case .finished: .finished(linkCopied: linkCopied.contains(captureID))
        case .failed(let message): .failed(message: message)
        }
    }

    // MARK: Saying so

    /// The confirmation: on the card when there is one, else the Copied reading by the pointer.
    private func confirm(_ text: String, for captureID: UUID, announcement: String) {
        if quickAccess.item(captureID) == nil {
            copied.show(text, near: NSEvent.mouseLocation)
        } else {
            announce(announcement)
        }
    }

    func tellNoDestination() {
        Log.upload.notice("Upload asked for, with no destination set up")
        copied.show(Self.noDestinationMessage, near: NSEvent.mouseLocation)
    }

    private func write(_ link: URL) {
        pasteboard.clearContents()
        pasteboard.setString(link.absoluteString, forType: .string)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
