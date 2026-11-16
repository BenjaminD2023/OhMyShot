import AppKit
import QuartzCore

/// Chips over the QR codes and barcodes found in a selection: one at each code (a QR code's top-right corner, a
/// barcode's right side, never over its bars), or, past `mostChips`, one for them all, which lists them. A chip opens a
/// small card beside it with what its code says, to copy, or to open when it is a web address; the code it came from is
/// outlined meanwhile.
///
/// Chips are the overlay's own chrome, never part of what is captured. The host lays this view over the selection's
/// display and shows it only while nothing is drawn or dragged (a mark drawn to point at a chip would be exported
/// without it), and gives it the codes in its own points. While a card is open, a press anywhere else only closes it,
/// so a press meant to close the card never starts a drag or finishes the capture. An open card has the keyboard:
/// Return copies, Tab goes to its buttons, Escape closes it, and the host gets the keyboard back (`onCardClosed`).
/// `openNextCard` is the keyboard's way to the chips.
///
/// Flipped: points from the top-left corner, as the overlay's selection views use.
@MainActor
public final class CodeChipsView: NSView {
    public struct Code: Equatable {
        /// Where the code lies, in this view's points.
        public var box: CGRect
        public var isMatrix: Bool
        public var payload: String
        /// The web page the code points to, when it is one.
        public var link: URL?

        public init(box: CGRect, isMatrix: Bool, payload: String, link: URL?) {
            self.box = box
            self.isMatrix = isMatrix
            self.payload = payload
            self.link = link
        }
    }

    /// The words the chips and the card say, from the host's catalog.
    public struct Wording {
        public var qrCode: String
        public var barcode: String
        public var codes: (Int) -> String
        public var copy: String
        public var openLink: String
        public var copied: String

        public init(qrCode: String, barcode: String, codes: @escaping (Int) -> String, copy: String, openLink: String, copied: String) {
            self.qrCode = qrCode
            self.barcode = barcode
            self.codes = codes
            self.copy = copy
            self.openLink = openLink
            self.copied = copied
        }
    }

    /// Past this many different codes, one chip stands for them all: more chips than this are no longer a choice
    /// anyone can make at a glance.
    public static let mostChips = 5
    static let chipHeight: CGFloat = 24

    /// Opens a code's web page; the host ends the capture first, as the overlay would otherwise cover the page.
    public var onOpen: ((URL) -> Void)?
    /// Whether a card may offer to open its code's web page now: not while ending the capture would throw away marks.
    public var canOpenLinks: () -> Bool = { true }
    /// A card was closed: the host takes the keyboard back.
    public var onCardClosed: (() -> Void)?
    /// Whether a card is open now.
    public var isShowingCard: Bool { card != nil }

    private let wording: Wording
    /// Codes with the same payload are one chip, its count beside the symbol.
    private struct Group {
        var codes: [Code]
        var payload: String { codes[0].payload }
    }

    private var groups: [Group] = []
    private var area: CGRect = .null
    private var chips: [ChipButton] = []
    private var card: CodeCard?
    /// The group whose card is open, so the keyboard goes on to the next.
    private var cardGroup: Int?
    private let outline = CAShapeLayer()

    public init(wording: Wording) {
        self.wording = wording
        super.init(frame: .zero)
        wantsLayer = true
        outline.fillColor = nil
        outline.lineWidth = 2
        outline.lineDashPattern = [5, 3]
        outline.isHidden = true
        outline.actions = ["path": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(outline)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows chips for `codes` (this view's points) found in `area`, the selection in this view's points, replacing
    /// any shown; no codes clears them.
    public func show(_ codes: [Code], in area: CGRect) {
        dismissCard()
        self.area = area
        var groups: [Group] = []
        for code in codes {
            if let index = groups.firstIndex(where: { $0.payload == code.payload }) {
                groups[index].codes.append(code)
            } else {
                groups.append(Group(codes: [code]))
            }
        }
        self.groups = groups
        rebuildChips()
    }

    public func clear() {
        show([], in: .null)
    }

    /// The codes the chips stand for, one for each different payload, for tests and the debug summary.
    public var shownPayloads: [String] { groups.map(\.payload) }
    /// How many chips stand on screen: one for each different code, or one for them all past `mostChips`.
    public var chipCount: Int { chips.count }

    // MARK: Chips

    private func rebuildChips() {
        chips.forEach { $0.removeFromSuperview() }
        chips = []
        guard !groups.isEmpty else { return }
        let dark = effectiveAppearance.isDark
        if groups.count > Self.mostChips {
            let chip = ChipButton(symbol: "qrcode", count: nil, title: wording.codes(groups.count), dark: dark)
            chip.target = self
            chip.action = #selector(listCodes(_:))
            chip.setAccessibilityLabel(wording.codes(groups.count))
            chip.frame = CGRect(origin: inside(CGPoint(x: area.maxX - chip.fittingSize.width - 8, y: area.minY + 8), size: chip.fittingSize), size: chip.fittingSize)
            chips = [chip]
        } else {
            var taken: [CGRect] = []
            for (index, group) in groups.enumerated() {
                let first = group.codes[0]
                let chip = ChipButton(symbol: first.isMatrix ? "qrcode" : "barcode", count: group.codes.count > 1 ? group.codes.count : nil, title: nil, dark: dark)
                chip.tag = index
                chip.target = self
                chip.action = #selector(openCard(_:))
                chip.toolTip = Self.shortened(group.payload, to: 80)
                chip.setAccessibilityLabel("\(first.isMatrix ? wording.qrCode : wording.barcode): \(Self.shortened(group.payload, to: 80))")
                var frame = CGRect(origin: anchor(for: first, size: chip.fittingSize), size: chip.fittingSize)
                // Off the selection's corner handles, which a code drawn tight into a corner would put a chip on:
                // then it stands just inside the code's own corner.
                if cornerZones.contains(where: { $0.intersects(frame) }) {
                    frame.origin = CGPoint(x: first.box.maxX - frame.width - 4, y: first.box.minY + 4)
                    // Still on a handle (a code tight into a corner): below a top corner's, above a bottom one's.
                    for zone in cornerZones where zone.intersects(frame) {
                        frame.origin.y = zone.midY <= area.midY ? zone.maxY + 2 : zone.minY - 2 - frame.height
                    }
                }
                // Chips that would overlap step down out of each other's way.
                while taken.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(frame) }) {
                    frame.origin.y += frame.height + 4
                }
                frame.origin = inside(frame.origin, size: frame.size)
                taken.append(frame)
                chip.frame = frame
                chips.append(chip)
            }
        }
        for chip in chips {
            addSubview(chip)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                chip.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Theme.Motion.fade
                    chip.animator().alphaValue = 1
                }
            }
        }
    }

    /// Where a code's chip goes: half over a QR code's top-right corner, reaching outside it; beside a barcode's
    /// right end, clear of its bars and the quiet zone a scanner needs.
    private func anchor(for code: Code, size: CGSize) -> CGPoint {
        code.isMatrix
            ? CGPoint(x: code.box.maxX - size.width / 2, y: code.box.minY - size.height / 2)
            : CGPoint(x: code.box.maxX + 8, y: code.box.midY - size.height / 2)
    }

    /// Where the selection's corner handles take presses, which a chip must leave free.
    private var cornerZones: [CGRect] {
        guard !area.isNull else { return [] }
        let reach: CGFloat = 14
        return [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY), CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)]
            .map { CGRect(x: $0.x - reach, y: $0.y - reach, width: reach * 2, height: reach * 2) }
    }

    /// `origin` moved so a frame of `size` stays on the view, 6 pt from its edges.
    private func inside(_ origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX + 6), max(bounds.minX + 6, bounds.maxX - 6 - size.width)),
            y: min(max(origin.y, bounds.minY + 6), max(bounds.minY + 6, bounds.maxY - 6 - size.height))
        )
    }

    static func shortened(_ text: String, to length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > length else { return flat }
        let head = flat.prefix(length * 2 / 3), tail = flat.suffix(length - head.count - 1)
        return "\(head)…\(tail)"
    }

    @objc private func openCard(_ sender: ChipButton) {
        guard groups.indices.contains(sender.tag) else { return }
        showCard(for: sender.tag, beside: sender.frame)
    }

    /// The keyboard's way to the chips: opens the card of the next code, one after another; false when there are none.
    @discardableResult
    public func openNextCard() -> Bool {
        guard !groups.isEmpty, !isHidden else { return false }
        let next = cardGroup.map { ($0 + 1) % groups.count } ?? 0
        let beside = chips.indices.contains(next) && groups.count <= Self.mostChips ? chips[next].frame : chips.first?.frame ?? .zero
        showCard(for: next, beside: beside)
        return true
    }

    /// The chip that stands for many codes lists them; the one chosen opens its card.
    @objc private func listCodes(_ sender: ChipButton) {
        let menu = NSMenu()
        for (index, group) in groups.enumerated() {
            let item = NSMenuItem(title: Self.shortened(group.payload, to: 60), action: #selector(chooseListed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: group.codes[0].isMatrix ? "qrcode" : "barcode", accessibilityDescription: nil)
            menu.addItem(item)
        }
        // The overlay's panel floats above the pop-up menu level; it steps just below while the menu is open.
        let window = sender.window
        let level = window?.level
        if let window, window.level >= .popUpMenu { window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1) }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        if let window, let level { window.level = level }
    }

    @objc private func chooseListed(_ item: NSMenuItem) {
        guard groups.indices.contains(item.tag), let chip = chips.first else { return }
        showCard(for: item.tag, beside: chip.frame)
    }

    // MARK: The card

    private func showCard(for index: Int, beside chip: CGRect) {
        // Replaced, not closed: the keyboard stays with the cards.
        removeCard()
        let group = groups[index]
        let first = group.codes[0]
        let card = CodeCard(payload: group.payload, link: canOpenLinks() ? first.link : nil, wording: wording, dark: effectiveAppearance.isDark)
        card.onOpen = { [weak self] url in self?.onOpen?(url) }
        let size = card.fittingSize
        // Below the chip when there is room, else above it, on the view.
        var origin = CGPoint(x: chip.minX, y: chip.maxY + 6)
        if origin.y + size.height > bounds.maxY - 6 { origin.y = chip.minY - 6 - size.height }
        card.frame = CGRect(origin: inside(origin, size: size), size: size)
        addSubview(card)
        self.card = card
        cardGroup = index
        let path = CGMutablePath()
        for code in group.codes { path.addRect(code.box.insetBy(dx: -3, dy: -3)) }
        outline.path = path
        outline.strokeColor = Theme.cgColor(.controlAccentColor, for: effectiveAppearance)
        outline.isHidden = false
        window?.makeFirstResponder(card.copyButton)
        NSAccessibility.post(element: card, notification: .created)
    }

    /// Closes the card, if one is open, and gives the keyboard back to the host.
    public func dismissCard() {
        guard card != nil else { return }
        removeCard()
        cardGroup = nil
        onCardClosed?()
    }

    private func removeCard() {
        card?.removeFromSuperview()
        card = nil
        outline.isHidden = true
    }

    // MARK: Input

    /// Only the chips and the card take presses; everywhere else falls through to the selection under this view,
    /// except while a card is open, when a press anywhere closes it and does nothing else.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let hit = super.hitTest(point) else { return nil }
        if hit !== self { return hit }
        return card != nil ? self : nil
    }

    public override func mouseDown(with event: NSEvent) {
        dismissCard()
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, card != nil { return dismissCard() }
        super.keyDown(with: event)
    }

    // MARK: Debug

    #if DEBUG
    /// Opens the card of the code saying `payload`, as its chip would.
    public func debugOpenCard(for payload: String) {
        guard let index = groups.firstIndex(where: { $0.payload == payload }) else { return }
        showCard(for: index, beside: chips.indices.contains(index) ? chips[index].frame : chips.first?.frame ?? .zero)
    }

    /// Whether the open card offers to open its code's web page.
    public var debugCardOffersOpen: Bool { card?.offersOpen ?? false }

    public var debugChipFrames: [CGRect] { chips.map(\.frame) }
    public var debugCardFrame: CGRect? { card?.frame }
    #endif
}

/// A chip over a code: the code's symbol in a capsule of the reading capsule's materials, with how many codes say the
/// same when more than one, or the count of codes for the chip standing for them all.
private final class ChipButton: HoverTagButton {
    init(symbol: String, count: Int?, title: String?, dark: Bool) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let text = title ?? count.map { "×\($0)" }
        if let text {
            attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85),
            ])
            imagePosition = .imageLeading
        } else {
            imagePosition = .imageOnly
        }
        // The symbol in the accent color says the chip can be pressed: it is an action on the white capsule, which
        // otherwise all but disappears on a white page.
        contentTintColor = .controlAccentColor
        hoverTagEdge = .minY
        hoverTagGap = 6
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = Theme.Material.capsuleFill(dark: dark)
        layer?.borderWidth = Theme.Material.edgeWidth(contrast: contrast)
        layer?.borderColor = Theme.Material.edge(dark: dark, contrast: contrast)
        layer?.cornerRadius = CodeChipsView.chipHeight / 2
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The pointer resting on the chip shows what its code says, in a hover tag.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override var fittingSize: NSSize {
        let natural = super.fittingSize
        let width = imagePosition == .imageOnly ? CodeChipsView.chipHeight + 6 : natural.width + 16
        return NSSize(width: ceil(width), height: CodeChipsView.chipHeight)
    }
}

/// The card a chip opens: what the code says, a button to copy it, and one to open it when it is a web page.
private final class CodeCard: NSView {
    var onOpen: ((URL) -> Void)?
    private let payload: String
    private let link: URL?
    private let wording: CodeChipsView.Wording
    /// Return presses it: copying is what a code's card is most often for, and it never ends the capture.
    let copyButton: NSButton
    var offersOpen: Bool { link != nil }
    private let stack: NSStackView

    init(payload: String, link: URL?, wording: CodeChipsView.Wording, dark: Bool) {
        self.payload = payload
        self.link = link
        self.wording = wording
        let label = NSTextField(wrappingLabelWithString: CodeChipsView.shortened(payload, to: 400))
        label.isSelectable = true
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingMiddle
        label.preferredMaxLayoutWidth = 300
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        copyButton = NSButton(title: wording.copy, target: nil, action: nil)
        copyButton.controlSize = .small
        copyButton.bezelStyle = .push
        copyButton.keyEquivalent = "\r"
        var buttons: [NSView] = [copyButton]
        if link != nil {
            let open = NSButton(title: wording.openLink, target: nil, action: nil)
            open.controlSize = .small
            open.bezelStyle = .push
            buttons.append(open)
            stack = NSStackView(views: [label, NSStackView(views: buttons)])
            super.init(frame: .zero)
            open.target = self
            open.action = #selector(openLink)
        } else {
            stack = NSStackView(views: [label, NSStackView(views: buttons)])
            super.init(frame: .zero)
        }
        copyButton.target = self
        copyButton.action = #selector(copyPayload)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 324),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        wantsLayer = true
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = Theme.Material.cardFill(dark: dark)
        layer?.borderWidth = Theme.Material.edgeWidth(contrast: contrast)
        layer?.borderColor = Theme.Material.edge(dark: dark, contrast: contrast)
        layer?.cornerRadius = Theme.Radius.card
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.masksToBounds = false
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(CodeChipsView.shortened(payload, to: 200))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    @objc private func copyPayload() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        copyButton.title = wording.copied
        VoiceOver.announce(wording.copied, from: self)
    }

    @objc private func openLink() {
        guard let link else { return }
        onOpen?(link)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return (superview as? CodeChipsView)?.dismissCard() ?? () }
        super.keyDown(with: event)
    }
}
