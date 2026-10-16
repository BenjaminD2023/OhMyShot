import AppKit
import Foundation
import ImageIO
import OMSCore
import OSLog

/// Turns, flips, and scales a screenshot's picture from its Quick Access card, and keeps the history's file and
/// record in step with it.
///
/// The new picture takes the capture's place and nothing is kept beside it: a capture that has an original
/// (marked up, cropped, or put on a background, which keeps its plain capture and its marks beside the picture)
/// is refused, since they would go on showing it as it was. Turning the marks too, or flattening them first,
/// is left to the editor.
final class PictureChangeCoordinator {
    private let history: HistoryStore
    /// Whether the editor has the capture open: it keeps its own picture when it closes, over any change.
    private let isBeingEdited: (UUID) -> Bool
    /// A card's capture's display's pixels per point, for a screenshot that has none of its own.
    private let displayScale: (QuickAccessItem) -> Double
    /// A capture's picture changed: its record, and the picture as encoded.
    private let changed: (HistoryItem, Data) -> Void
    /// Changes wait for the one before, so two quick turns are two turns.
    private var queue: Task<Void, Never>?

    init(
        history: HistoryStore,
        isBeingEdited: @escaping (UUID) -> Bool,
        displayScale: @escaping (QuickAccessItem) -> Double,
        changed: @escaping (HistoryItem, Data) -> Void
    ) {
        self.history = history
        self.isBeingEdited = isBeingEdited
        self.displayScale = displayScale
        self.changed = changed
    }

    /// What the card may do to the capture's picture now, and the scale Scale to 1× would start from.
    func offer(for item: QuickAccessItem) -> PictureChangeOffer {
        // A menu or VoiceOver asks this often: the capture's own record, not a listing of the whole history.
        guard let entry = record(of: item) else { return .unsupported }
        let availability = PictureChangeAvailability.of(
            isScreenshot: entry.kind == .screenshot, fileExtension: history.fileURL(for: entry).pathExtension,
            hasOriginal: history.hasOriginal(entry), isBeingEdited: isBeingEdited(entry.id)
        )
        return PictureChangeOffer(availability: availability, pixelsPerPoint: entry.pixelsPerPoint ?? displayScale(item))
    }

    private func record(of item: QuickAccessItem) -> HistoryItem? {
        history.item(fileName: item.fileURL.lastPathComponent).flatMap { $0.id == item.id ? $0 : nil }
    }

    func apply(_ change: PictureChange, to item: QuickAccessItem) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.run(change, on: item)
        }
    }

    private func run(_ change: PictureChange, on item: QuickAccessItem) async {
        // Asked again: the editor may have opened, or the capture been edited, or brought down to one pixel per point,
        // while this waited.
        let current = offer(for: item)
        guard current.availability == .available, let entry = record(of: item),
              let change = change.resolved(pixelsPerPoint: current.pixelsPerPoint)
        else { return NSSound.beep() }
        guard let picture = await Self.changedPicture(at: history.fileURL(for: entry), by: change) else {
            Log.capture.error("Changing the picture of \(entry.fileName, privacy: .public) failed")
            return NSSound.beep()
        }
        // Reading and writing the picture took a moment: the editor may have opened on the capture since.
        guard offer(for: item).availability == .available else { return NSSound.beep() }
        do {
            // One pixel per point is the scale the capture then has, for pins and printing.
            let scale: Double? = if case .scaleToOneX = change { 1 } else { nil }
            let updated = try history.replacePicture(of: entry, with: picture.data, pixelWidth: picture.width, pixelHeight: picture.height, pixelsPerPoint: scale)
            Log.capture.notice("Changed the picture of \(entry.fileName, privacy: .public): now \(picture.width, privacy: .public) × \(picture.height, privacy: .public)")
            changed(updated, picture.data)
        } catch {
            Log.capture.error("Keeping the changed picture failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// The picture in the file after the change, as a PNG, read and made off the main actor at its full size:
    /// scrolling captures are tens of thousands of pixels long.
    @concurrent
    private static func changedPicture(at url: URL, by change: PictureChange) async -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let changed = change.apply(to: image),
              let data = try? await ImageExporter.encode(changed, as: .png)
        else { return nil }
        return (data, changed.width, changed.height)
    }
}
