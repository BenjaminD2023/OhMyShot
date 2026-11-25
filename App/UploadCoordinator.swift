import AppKit
import Foundation
import OMSCore
import OMSDesign
import OMSUI
import OSLog
import SwiftUI

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
    private let failureNotice = UploadFailureHUD()
    /// A headless failed upload currently held open in `failureNotice`, so Retry can still read its file before
    /// retention releases it.
    private var pendingFailedCaptureID: UUID?
    /// Uploads being deleted from their storage, so a second request waits for the first.
    private var deleting: Set<UUID> = []
    /// Asks before a file is removed from its storage; scripted checks answer for themselves.
    var confirmDeletion: @MainActor (_ title: String, _ message: String, _ button: String, _ destructive: Bool) -> Bool = UploadCoordinator.askToDelete
    /// Whether a capture's link went to the clipboard, for the card's wording and its Copy Link.
    private var linkCopied: Set<UUID> = []

    struct LastFailure: Equatable {
        let captureID: UUID
        let destinationName: String
        let message: String
    }

    /// Most recent upload failure, kept until a subsequent upload succeeds or another fails.
    private(set) var lastFailure: LastFailure?

    /// Where a link is copied. The clipboard; scripted checks point it at a pasteboard of their own.
    var pasteboard: NSPasteboard = .general
    /// Brings a capture's card back, so a failure that nobody saw can be retried from it. Returns whether a card
    /// could be restored.
    var restoreCard: ((UUID) -> Bool)?
    /// Whether Settings give a capture a card, which is what a failure that nobody saw comes back to. Set by the
    /// composition root, which knows whether the capture is a screenshot or a recording.
    var showsCard: ((UUID) -> Bool)?
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

    /// Whether there is anywhere to upload to: a default destination is set up.
    var canUpload: Bool {
        destinations.defaultDestination != nil
    }

    /// Uploads a capture's file.
    /// - Parameter destinationID: nil for the default destination.
    /// - Returns: false when there was nothing to upload to, or the capture is already uploading.
    @discardableResult
    func upload(captureID: UUID, fileURL: URL, destinationID: UUID? = nil) -> Bool {
        guard canUpload else {
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
        if pendingFailedCaptureID == captureID {
            pendingFailedCaptureID = nil
            failureNotice.hide(notifyDismiss: false)
        }
        if !center.retry(captureID: captureID) {
            Log.upload.notice("Retry not possible: the destination is gone")
            VoiceOver.announce(String(localized: "That destination was removed. Choose Upload again to pick another."))
            center.forget(captureID: captureID)
            quickAccess.setUpload(nil, for: captureID)
            ended?(captureID, .failed)
        } else if quickAccess.item(captureID) == nil {
            copied.show(String(localized: "Uploading…"), near: NSEvent.mouseLocation)
        }
    }

    /// Retries the most recent failed upload, if still retryable.
    @discardableResult
    func retryLastFailure() -> Bool {
        guard let failure = lastFailure else { return false }
        retry(captureID: failure.captureID)
        return center.isUploading(failure.captureID)
    }

    func cancel(captureID: UUID) {
        center.cancel(captureID: captureID)
    }

    /// Cancels every upload and waits for the transfers to stop, so nothing is half sent when the app quits.
    func cancelAll(then done: @escaping () -> Void) -> Bool {
        failureNotice.hide(notifyDismiss: true)
        guard !center.isIdle else { return false }
        Task {
            await center.cancelAll()
            done()
        }
        return true
    }

    var uploadingIDs: Set<UUID> {
        guard let pendingFailedCaptureID else { return center.uploadingIDs }
        return center.uploadingIDs.union([pendingFailedCaptureID])
    }

    // MARK: Links

    /// The link of the capture's newest upload that still works, asked of the records each time: a link past its
    /// expiry, or one whose upload was deleted or forgotten, is never offered. The center only says how a transfer goes.
    private func link(for captureID: UUID) -> URL? {
        records.link(for: captureID)
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
        VoiceOver.announce(String(localized: "Link copied."))
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
                VoiceOver.announce(String(localized: "That destination was removed, so the file can’t be deleted from here."))
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
                    records.forgetDeleted(record).forEach(refreshCard)
                    tell(String(localized: "Deleted from storage"), near: record.captureID)
                    Log.upload.notice("Deleted an upload from \(destination.kindName, privacy: .public)")
                } catch {
                    Log.upload.error("Delete failed")
                    let reason = error.localizedDescription
                    VoiceOver.announce(String(localized: "Couldn’t delete. \(reason)"))
                    NSSound.beep()
                    failureNotice.show(
                        title: String(localized: "Couldn’t delete from \(destination.name)"),
                        message: reason,
                        corner: settings.quickAccessCorner,
                        avoiding: quickAccess.cardsFrame,
                        retryTitle: nil,
                        onRetry: nil,
                        onDismiss: nil
                    )
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
        VoiceOver.announce(message)
    }

    private static func askToDelete(title: String, message: String, button: String, destructive: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
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
        if lastFailure?.captureID == captureID { lastFailure = nil }
        if pendingFailedCaptureID == captureID {
            pendingFailedCaptureID = nil
            failureNotice.hide(notifyDismiss: false)
        }
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
            if pendingFailedCaptureID == captureID {
                pendingFailedCaptureID = nil
                failureNotice.hide(notifyDismiss: false)
            }
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
            lastFailure = LastFailure(captureID: captureID, destinationName: destinationName, message: message)
            VoiceOver.announce(String(localized: "Upload failed. \(message)"))
            if quickAccess.item(captureID) != nil {
                NSSound.beep()
                ended?(captureID, .failed)
            } else if (showsCard?(captureID) ?? settings.showQuickAccess), restoreCard?(captureID) == true {
                // Nobody saw it: the card comes back with the failure and Retry.
                ended?(captureID, .failed)
            } else {
                // Headless failure (Quick Access is off, or no card can be restored): show a non-activating notice
                // with enough time to read and an interactive Retry button before releasing the capture file.
                presentHeadlessFailure(captureID: captureID, destinationName: destinationName, message: message)
            }
        }
    }

    private func presentHeadlessFailure(captureID: UUID, destinationName: String, message: String) {
        if let previous = pendingFailedCaptureID, previous != captureID {
            pendingFailedCaptureID = nil
            ended?(previous, .failed)
        }
        pendingFailedCaptureID = captureID
        NSSound.beep()
        failureNotice.show(
            title: String(localized: "Upload to \(destinationName) failed"),
            message: message,
            corner: settings.quickAccessCorner,
            avoiding: quickAccess.cardsFrame,
            retryTitle: String(localized: "Retry"),
            onRetry: { [weak self] in
                self?.retry(captureID: captureID)
            },
            onDismiss: { [weak self] in
                guard let self, self.pendingFailedCaptureID == captureID else { return }
                self.pendingFailedCaptureID = nil
                self.ended?(captureID, .failed)
            }
        )
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
            VoiceOver.announce(announcement)
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
}

/// Non-activating floating notice for upload and remote-delete failures when no Quick Access card is visible.
/// Follows `DESIGN.md` floating card tokens (12 pt continuous corners, floating card shadow, orange status symbol),
/// stays readable for 8 seconds (20 seconds with VoiceOver), pauses dismissal on hover, and offers one-click Retry.
private final class UploadFailureHUD {
    private var panel: UploadFailurePanel?
    private var dismissal: Task<Void, Never>?
    private var windowLease: ActiveResources.Lease?
    private var onDismiss: (() -> Void)?
    private var hovered = false

    private static let margin: CGFloat = Theme.Shadow.radius * 2 + Theme.Shadow.drop
    private static let displayDuration: TimeInterval = 8
    private static let voiceOverDuration: TimeInterval = 20

    func show(
        title: String,
        message: String,
        corner: QuickAccessCorner,
        avoiding cardsFrame: CGRect?,
        retryTitle: String?,
        onRetry: (() -> Void)?,
        onDismiss: (() -> Void)?
    ) {
        dismissal?.cancel()
        dismissal = nil
        let previousDismiss = self.onDismiss
        self.onDismiss = nil
        previousDismiss?()

        self.onDismiss = onDismiss
        hovered = false

        let panel = self.panel ?? UploadFailurePanel()
        self.panel = panel
        let card = UploadFailureCard(
            title: title,
            message: message,
            retryTitle: retryTitle,
            margin: Self.margin,
            onRetry: onRetry.map { retry in
                { [weak self] in
                    self?.hide(notifyDismiss: false)
                    retry()
                }
            },
            onClose: { [weak self] in self?.hide(notifyDismiss: true) },
            onHover: { [weak self] inside in self?.setHovered(inside) }
        )
        let hosting = NSHostingView(rootView: card)
        let size = hosting.fittingSize
        panel.contentView = hosting

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let cardSize = CGSize(width: max(1, size.width - Self.margin * 2), height: max(1, size.height - Self.margin * 2))
        let edgePad: CGFloat = 6
        let cornerInset: CGFloat = 26
        let rawX = corner.slidesFromLeft ? visible.minX + cornerInset : visible.maxX - cornerInset - cardSize.width
        let minX = visible.minX + edgePad
        let maxX = max(minX, visible.maxX - edgePad - cardSize.width)
        let x = min(max(rawX, minX), maxX)

        var rawY = visible.minY + cornerInset
        if let cardsFrame, visible.intersects(cardsFrame), cardsFrame.maxY + 12 + cardSize.height <= visible.maxY - edgePad {
            rawY = max(rawY, cardsFrame.maxY + 12)
        }
        let minY = visible.minY + edgePad
        let maxY = max(minY, visible.maxY - edgePad - cardSize.height)
        let y = min(max(rawY, minY), maxY)

        let frame = CGRect(origin: CGPoint(x: x - Self.margin, y: y - Self.margin), size: size)
        panel.setFrame(frame.integral, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if windowLease == nil { windowLease = ActiveResources.shared.acquire(.window) }
        scheduleDismissal()
    }

    func hide(notifyDismiss: Bool) {
        dismissal?.cancel()
        dismissal = nil
        hovered = false
        let dismissCallback = onDismiss
        onDismiss = nil
        panel?.orderOut(nil)
        panel = nil
        windowLease?.end()
        windowLease = nil
        if notifyDismiss { dismissCallback?() }
    }

    private func setHovered(_ inside: Bool) {
        guard hovered != inside else { return }
        hovered = inside
        if inside {
            dismissal?.cancel()
            dismissal = nil
        } else {
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        let delay = NSWorkspace.shared.isVoiceOverEnabled ? Self.voiceOverDuration : Self.displayDuration
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.hovered else { return }
            self.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        dismissal = Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard !Task.isCancelled else { return }
            self?.hide(notifyDismiss: true)
        }
    }
}

private final class UploadFailurePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private struct UploadFailureCard: View {
    let title: String
    let message: String
    let retryTitle: String?
    let margin: CGFloat
    let onRetry: (() -> Void)?
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let retryTitle, let onRetry {
                    Button(action: onRetry) {
                        Text(verbatim: retryTitle)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background {
            shape.fill(Color(cgColor: Theme.Material.cardFill(dark: colorScheme == .dark)))
                .shadow(color: .black.opacity(Double(Theme.Shadow.opacity)), radius: Theme.Shadow.radius, y: Theme.Shadow.drop)
        }
        .overlay {
            shape.strokeBorder(
                Color(cgColor: Theme.Material.edge(dark: colorScheme == .dark, contrast: contrast == .increased)),
                lineWidth: Theme.Material.edgeWidth(contrast: contrast == .increased)
            )
        }
        .onHover(perform: onHover)
        .padding(margin)
    }
}
