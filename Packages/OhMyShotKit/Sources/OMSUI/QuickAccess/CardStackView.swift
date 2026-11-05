import AppKit
import Foundation
import OMSCore
import OMSDesign
import QuartzCore
import QuickLookUI

/// The column of capture cards, newest at the bottom. Transparent; each card draws its own soft shadow,
/// so the view keeps a margin around the cards for it.
///
/// Not flipped: cards are placed from the bottom up, so they stay put on screen while the panel grows or
/// shrinks at the top.
final class CardStackView: NSView {
    /// What a card's buttons, menu, or VoiceOver asked of its capture. The keys arrive apart (`onKey`): the card that
    /// has the keyboard is the owner's to know, and a command from a key gives the keyboard back where a click does not.
    var onCommand: ((CardCommand, QuickAccessItem) -> Void)?
    /// The file to hand to another app for a capture, dragged out or shared.
    var fileToHandOver: ((QuickAccessItem) -> URL)?
    /// What the menu offers for uploading, read each time a menu opens (see `UploadMenu`).
    var uploadMenu: () -> UploadMenu = { .hidden }
    var hasLink: ((QuickAccessItem) -> Bool)?
    var canDeleteFromStorage: ((QuickAccessItem) -> Bool)?
    /// The upload a capture has now, for a card made after it began (restored from Recently Closed).
    var currentUpload: ((QuickAccessItem) -> CardUpload?)?
    /// What can be done to a capture's picture now, read when a menu opens.
    var pictureOffer: (QuickAccessItem) -> PictureChangeOffer = { _ in .unsupported }
    /// How many cards the stack has.
    var cardCount: () -> Int = { 1 }
    /// A card is kept from closing (the pointer over it, its menu open, a drag out of it) or let go.
    var onHold: ((UUID, CardCountdown.Hold, Bool) -> Void)?
    /// A card was clicked: the keyboard goes to it.
    var onFocus: ((UUID) -> Void)?
    /// The pointer actively entered or left a card: gives the non-activating panel keyboard focus while hovered.
    var onPointerHover: ((UUID, Bool) -> Void)?
    /// A key of the table arrived while the panel has the keyboard; whether the stack's owner took it.
    var onKey: ((CardCommand) -> Bool)?

    /// How large the cards are, and which corner they stack in: the stack's owner sets them before each layout.
    var size = QuickAccessSize.medium
    var corner = QuickAccessCorner.bottomLeft

    /// Quick Look for the card that has the keyboard.
    let quickLook = CardQuickLook()

    /// Room for each card's shadow to fade out completely: twice its blur plus its drop.
    static let margin: CGFloat = Theme.Shadow.radius * 2 + Theme.Shadow.drop
    static let gap: CGFloat = 12

    /// The panel's width for cards of `size`.
    static func width(for size: QuickAccessSize) -> CGFloat {
        size.cardWidth + margin * 2
    }

    private var cards: [UUID: CaptureCardView] = [:]
    private var generation = 0

    /// The height a stack of `items` needs, margins included.
    static func height(for items: [QuickAccessItem], size: QuickAccessSize) -> CGFloat {
        let heights = items.map { CaptureCardView.preferredHeight(for: $0, size: size) }
        return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * gap + margin * 2
    }

    /// Shows `items`, oldest at the top. Cards that stay glide to their new places, `entering` slides in
    /// from the screen edge, and cards no longer listed slide out. `completion` runs once the motion has
    /// ended, unless a newer call has started its own, so a shrinking panel can wait for the cards.
    func show(_ items: [QuickAccessItem], entering: UUID?, completion: (() -> Void)? = nil) {
        generation += 1
        let generation = generation
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.slide
        let ids = Set(items.map(\.id))
        let leaving = cards.values.filter { !ids.contains($0.item.id) }
        leaving.forEach { cards[$0.item.id] = nil }

        // From the bottom up: the newest card is the last item.
        var frames: [UUID: CGRect] = [:]
        var y = Self.margin
        for item in items.reversed() {
            let height = CaptureCardView.preferredHeight(for: item, size: size)
            frames[item.id] = CGRect(x: Self.margin, y: y, width: size.cardWidth, height: height)
            y += height + Self.gap
        }

        var staying: [(CaptureCardView, CGRect)] = []
        for item in items {
            guard let frame = frames[item.id] else { continue }
            if let card = cards[item.id] {
                card.size = size
                card.slidesFromLeft = corner.slidesFromLeft
                card.item = item
                if card.frame != frame { staying.append((card, frame)) }
            } else {
                let card = makeCard(for: item)
                card.slidesFromLeft = corner.slidesFromLeft
                card.frame = frame
                if item.id == entering { card.slideIn(fromLeft: corner.slidesFromLeft) }
            }
        }

        // Cards leave toward the edge they came from.
        let departure: CGFloat = corner.slidesFromLeft ? -40 : 40
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (card, frame) in staying {
                card.animator().frame = frame
            }
            for card in leaving {
                card.animator().alphaValue = 0
                card.animator().setFrameOrigin(CGPoint(x: card.frame.minX + departure, y: card.frame.minY))
            }
        }
        Task { [weak self] in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            leaving.forEach { $0.removeFromSuperview() }
            guard let self, generation == self.generation else { return }
            completion?()
        }
    }

    func showCopied(_ id: UUID) {
        cards[id]?.showCopied()
    }

    func previewHover(_ id: UUID) {
        cards[id]?.setHovering(true)
    }

    /// Hovers the card under the pointer, and no other, after the cards have moved: AppKit sends nothing to a card
    /// that comes in under a pointer at rest, or one that glides out from under it, until the pointer moves.
    func updatePointerHover() {
        for (id, card) in cards {
            card.setHovering(window?.isVisible == true && screenFrame(ofCard: id)?.contains(NSEvent.mouseLocation) == true)
        }
    }

    func markSaved(_ id: UUID, at url: URL) {
        cards[id]?.item.savedURL = url
        cards[id]?.showSaved()
    }

    func markUnsaved(_ id: UUID) {
        cards[id]?.item.savedURL = nil
        cards[id]?.showUnsaved()
    }

    #if DEBUG
    func debugShare(of id: UUID) { cards[id]?.debugShare() }

    func debugShowMenu(of id: UUID, whileOpen: @escaping @MainActor ([String]) async -> Void) {
        cards[id]?.debugShowMenu(whileOpen: whileOpen)
    }
    #endif

    func setUpload(_ upload: CardUpload?, for id: UUID) {
        cards[id]?.upload = upload
    }

    func setCountdown(_ state: (remaining: TimeInterval, interval: TimeInterval)?, for id: UUID) {
        cards[id]?.setCountdown(state)
    }

    /// Shades a card moved to the Trash under "Moved to Trash" and Undo while it waits to go, or brings it back.
    func setTrashing(_ trashing: Bool, for id: UUID) {
        cards[id]?.isTrashing = trashing
        if !trashing { updatePointerHover() }
    }

    /// Rings the card that has the keyboard, and no other.
    func select(_ id: UUID?) {
        for (cardID, card) in cards { card.isSelected = cardID == id }
    }

    // MARK: Keys

    /// The stack takes the keys the panel is given: the first responder of a panel that was clicked or asked
    /// for, so the keys of the table (`CardKeys`) reach it.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    /// An accessory app's menu bar is not there to route ⌘ keys, so the cards answer their own.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let key = Self.key(of: event),
              let command = CardKeys.command(for: key, modifiers: Self.modifiers(of: event)) else { return false }
        return onKey?(command) ?? false
    }

    private static func key(of event: NSEvent) -> CardKeys.Key? {
        switch event.keyCode {
        case 53: .escape
        case 51, 117: .delete
        case 49: .space
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: event.charactersIgnoringModifiers?.lowercased().first.map(CardKeys.Key.character)
        }
    }

    private static func modifiers(of event: NSEvent) -> CardKeys.Modifiers {
        var modifiers: CardKeys.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    // MARK: Quick Look

    /// The preview panel asks the key window's responders for a controller; the stack is the one.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    /// Where a card is on screen, for what is shown beside it.
    func screenFrame(ofCard id: UUID) -> CGRect? {
        guard let card = cards[id], let window else { return nil }
        return window.convertToScreen(card.convert(card.bounds, to: nil))
    }

    /// Shows a capture's new picture on its card.
    func replace(_ item: QuickAccessItem) {
        cards[item.id]?.item = item
    }

    private func makeCard(for item: QuickAccessItem) -> CaptureCardView {
        let card = CaptureCardView(item: item, size: size)
        card.onCommand = { [weak self, weak card] command in card.map { self?.onCommand?(command, $0.item) } }
        card.pictureOffer = { [weak self, weak card] in card.flatMap { self?.pictureOffer($0.item) } ?? .unsupported }
        card.cardCount = { [weak self] in self?.cardCount() ?? 1 }
        card.onHold = { [weak self, weak card] hold, on in card.map { self?.onHold?($0.item.id, hold, on) } }
        card.onFocus = { [weak self, weak card] in card.map { self?.onFocus?($0.item.id) } }
        card.onPointerHover = { [weak self, weak card] hovering in card.map { self?.onPointerHover?($0.item.id, hovering) } }
        card.fileToHandOver = { [weak self, weak card] in card.map { self?.fileToHandOver?($0.item) ?? $0.item.fileURL } }
        card.uploadMenu = { [weak self] in self?.uploadMenu() ?? .hidden }
        card.hasLink = { [weak self, weak card] in card.flatMap { self?.hasLink?($0.item) } ?? false }
        card.canDeleteFromStorage = { [weak self, weak card] in card.flatMap { self?.canDeleteFromStorage?($0.item) } ?? false }
        card.upload = currentUpload?(item)
        addSubview(card)
        cards[item.id] = card
        return card
    }
}
