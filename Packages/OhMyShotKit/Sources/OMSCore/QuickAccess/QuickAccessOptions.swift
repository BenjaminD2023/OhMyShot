import CoreGraphics
import Foundation

/// Which corner of the screen Quick Access cards stack in.
public enum QuickAccessCorner: String, CaseIterable, Sendable {
    case bottomLeft
    case bottomRight
    case topLeft
    case topRight

    /// Whether cards come in from the left edge of the screen, and leave toward it.
    public var slidesFromLeft: Bool { self == .bottomLeft || self == .topLeft }

    /// Whether the stack anchors to the top edge of the visible frame.
    public var isTop: Bool { self == .topLeft || self == .topRight }
}

/// How large Quick Access cards are.
public enum QuickAccessSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    /// A card's width in points; medium is `CardPicture.width`.
    public var cardWidth: CGFloat {
        switch self {
        case .small: 180
        case .medium: CardPicture.width
        case .large: 260
        }
    }

    /// The most a card's picture stands tall: `CardPicture.tallest` at this size's width.
    public var tallest: CGFloat {
        (CardPicture.tallest * cardWidth / CardPicture.width).rounded()
    }

    /// The least a card stands tall at any size, which is what its two buttons and the corner buttons need.
    public static let shortest: CGFloat = 100

    /// A card's height for a picture of this many pixels: its shape at the card's width, kept between the
    /// shortest and the tallest (extreme shapes letterbox).
    public func cardHeight(pixelWidth: Int, pixelHeight: Int) -> CGFloat {
        let aspect = CGFloat(pixelHeight) / CGFloat(max(pixelWidth, 1))
        return min(max(cardWidth * aspect, Self.shortest), tallest)
    }
}

/// What a card does when its time is up.
public enum QuickAccessCloseAction: String, CaseIterable, Sendable {
    /// Closes; the capture stays in Capture History, unless History keeps nothing, when it goes with its card.
    case close
    /// Saves a copy to the export folder first, unless the card has been saved, and closes.
    case saveAndClose
}

/// How Quick Access looks and behaves, as Settings has it. Read each time a card appears.
public struct QuickAccessPreferences: Equatable, Sendable {
    public var corner: QuickAccessCorner
    public var size: QuickAccessSize
    /// Whether the cards go to the display with the pointer, instead of the one the capture was taken on.
    public var onPointerDisplay: Bool
    /// Seconds a card stays before it closes by itself; 0 for never.
    public var closeAfter: Int
    public var closeAction: QuickAccessCloseAction
    /// Whether copying, saving, pinning, printing, or dragging a card closes it automatically.
    public var closesAfterAction: Bool

    public init(
        corner: QuickAccessCorner = .bottomLeft,
        size: QuickAccessSize = .medium,
        onPointerDisplay: Bool = false,
        closeAfter: Int = 3,
        closeAction: QuickAccessCloseAction = .close,
        closesAfterAction: Bool = true
    ) {
        self.corner = corner
        self.size = size
        self.onPointerDisplay = onPointerDisplay
        self.closeAfter = closeAfter
        self.closeAction = closeAction
        self.closesAfterAction = closesAfterAction
    }

    /// How long a card stays, or nil for ever.
    public var closeInterval: TimeInterval? {
        closeAfter > 0 ? TimeInterval(closeAfter) : nil
    }

    /// Whether a card that closes by itself takes its capture with it when it was not saved: with `history` keeping
    /// nothing, a capture lives only as long as its card, and Close does not keep it (Save and Close does).
    public func closingDiscardsUnsavedCaptures(history: HistoryRetention) -> Bool {
        closeInterval != nil && closeAction == .close && history == .never
    }
}
