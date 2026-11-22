import CoreGraphics
import Foundation

/// A capture shown as a Quick Access card: its file in the history, a thumbnail, whether the user has
/// saved a copy yet, and which copy is the card's own.
public struct QuickAccessItem: Identifiable, Sendable {
    /// The history item's identifier, so a restored card is the same capture.
    public let id: UUID
    public let kind: HistoryItem.Kind
    /// The capture's file in the history folder.
    public let fileURL: URL
    public let thumbnail: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let displayID: CGDirectDisplayID
    public let createdAt: Date
    /// A recording's length.
    public let duration: TimeInterval?
    /// Where the user saved a copy last, from the card, the editor, or Capture History, once they have: the card shows it
    /// saved, its Save shows this copy in Finder, and neither Save All nor closing by itself saves another.
    public var savedURL: URL?
    /// The copy the card saved itself, or the one saved as the capture was taken (Settings' Save after capture), which its
    /// Move to Trash takes with the capture. A copy saved from the editor or Capture History is never the card's own.
    public var ownSavedURL: URL?

    /// The longest side of a card's thumbnail, in pixels.
    public static let thumbnailPixels = 560

    public init(
        id: UUID,
        kind: HistoryItem.Kind = .screenshot,
        fileURL: URL,
        thumbnail: CGImage,
        pixelWidth: Int,
        pixelHeight: Int,
        displayID: CGDirectDisplayID,
        createdAt: Date = .now,
        duration: TimeInterval? = nil,
        savedURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.thumbnail = thumbnail
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayID = displayID
        self.createdAt = createdAt
        self.duration = duration
        self.savedURL = savedURL
    }

    /// The card of a capture kept in the history, as its record has it: its file there, its thumbnail, and the display
    /// it shows on.
    public init(_ entry: HistoryItem, fileURL: URL, thumbnail: CGImage, displayID: CGDirectDisplayID, savedURL: URL? = nil) {
        self.init(
            id: entry.id, kind: entry.kind, fileURL: fileURL, thumbnail: thumbnail, pixelWidth: entry.pixelWidth, pixelHeight: entry.pixelHeight,
            displayID: displayID, createdAt: entry.createdAt, duration: entry.duration, savedURL: savedURL
        )
    }
}
