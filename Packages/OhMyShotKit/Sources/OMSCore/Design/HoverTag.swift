import AppKit
import QuartzCore

/// A button whose help is a hover tag while it is a symbol alone: a moment after the pointer rests on it, a small
/// capsule beside it names what it does. A titled chip already says so, and keeps the system's tooltip.
///
/// The system's tooltip comes late, and over the capture overlay's panels not at all, so a symbol-only chip
/// registers none: `toolTip` keeps its text for the tag, VoiceOver's help, and tests.
///
/// A subclass reports the pointer as before, calling through to `mouseEntered` and `mouseExited`.
open class HoverTagButton: NSButton {
    private var help: String?

    /// Which side of the chip the tag stands on: below a horizontal bar's chip, beside a vertical rail's.
    /// It moves to the other side when the screen's edge leaves no room.
    public var hoverTagEdge: NSRectEdge = .minY

    /// How far from the chip the tag stands: past the capsule's inset around its chips, then a little room.
    public var hoverTagGap: CGFloat = 12

    open override var toolTip: String? {
        get { help }
        set {
            help = newValue
            syncSystemToolTip()
            if HoverTag.shared.isShowing(for: self) { HoverTag.shared.withdraw(from: self) }
        }
    }

    open override var imagePosition: NSControl.ImagePosition {
        didSet { syncSystemToolTip() }
    }

    /// Whether the help shows as a tag: a symbol alone does not say what it does.
    public var showsHoverTag: Bool {
        imagePosition == .imageOnly && !(help ?? "").isEmpty
    }

    private func syncSystemToolTip() {
        super.toolTip = showsHoverTag ? nil : help
    }

    /// VoiceOver reads the help as the system's tooltip would have given it.
    open override func accessibilityHelp() -> String? {
        super.accessibilityHelp() ?? help
    }

    open override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard showsHoverTag, let help else { return }
        HoverTag.shared.schedule(help, for: self, edge: hoverTagEdge, gap: hoverTagGap)
    }

    open override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        HoverTag.shared.withdraw(from: self)
    }

    /// A press is the chip being used: its tag steps aside until the pointer comes back.
    open override func mouseDown(with event: NSEvent) {
        HoverTag.shared.withdraw(from: self)
        super.mouseDown(with: event)
    }

    open override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        HoverTag.shared.withdraw(from: self)
    }

    open override func viewDidHide() {
        super.viewDidHide()
        HoverTag.shared.withdraw(from: self)
    }
}

/// The one hover tag on screen: a small capsule in the reading capsule's materials, in a window of its own just above
/// the chip's window, so it shows over the overlay's panels as over the editor.
@MainActor
public final class HoverTag {
    public static let shared = HoverTag()

    /// How long the pointer rests on a chip before its tag shows.
    static let delay: TimeInterval = 0.5
    /// Moving on from a chip whose tag was showing (or just was) shows the next one at once, as menus do.
    static let warmWindow: TimeInterval = 0.4
    static let maxTextWidth: CGFloat = 280
    /// Room around the capsule inside the tag's window, for its shadow.
    private static let margin: CGFloat = 12

    private weak var owner: NSView?
    private var pending: Timer?
    private var panel: NSPanel?
    private let capsule = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var lastShown: Date = .distantPast

    private init() {}

    /// Whether the tag is up (or on its way) for `view`.
    public func isShowing(for view: NSView) -> Bool {
        owner === view
    }

    /// Shows `text` on `edge` of `view`, `gap` off it, once the pointer has rested there, or at once right after
    /// another tag.
    public func schedule(_ text: String, for view: NSView, edge: NSRectEdge = .minY, gap: CGFloat = 12) {
        pending?.invalidate()
        owner = view
        let warm = panel?.isVisible == true || Date().timeIntervalSince(lastShown) < Self.warmWindow
        if warm {
            show(text, for: view, edge: edge, gap: gap, fades: false)
            return
        }
        hidePanel()
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view, self.owner === view else { return }
                self.show(text, for: view, edge: edge, gap: gap, fades: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pending = timer
    }

    /// Takes `view`'s tag down, or stops it from coming; another view's tag stays.
    public func withdraw(from view: NSView) {
        guard owner === view else { return }
        dismiss()
    }

    public func dismiss() {
        pending?.invalidate()
        pending = nil
        if panel?.isVisible == true { lastShown = Date() }
        owner = nil
        hidePanel()
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func show(_ text: String, for view: NSView, edge: NSRectEdge, gap: CGFloat, fades: Bool) {
        pending = nil
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else {
            owner = nil
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.appearance = view.effectiveAppearance
        applyAppearance(of: view.effectiveAppearance)
        label.stringValue = text

        // The capsule as wide as its text, up to a few words a line; one line is a full capsule, more lines a card.
        let font = label.font ?? Theme.Typeface.label()
        label.preferredMaxLayoutWidth = Self.maxTextWidth
        let textSize = label.sizeThatFits(CGSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude))
        let textWidth = ceil(min(textSize.width, Self.maxTextWidth))
        let textHeight = ceil(textSize.height)
        let oneLine = textHeight < ceil(font.ascender - font.descender + font.leading) * 1.5
        let capsuleSize = CGSize(width: textWidth + 22, height: textHeight + 9)
        let radius = oneLine ? capsuleSize.height / 2 : 9

        let chip = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.frame ?? chip.insetBy(dx: -1000, dy: -1000)
        let frame = Self.frame(of: capsuleSize, beside: chip, edge: edge, gap: gap, within: screen)

        let m = Self.margin
        panel.setFrame(frame.insetBy(dx: -m, dy: -m), display: false)
        capsule.frame = CGRect(x: m, y: m, width: frame.width, height: frame.height)
        capsule.layer?.cornerRadius = radius
        capsule.layer?.shadowPath = CGPath(roundedRect: capsule.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        label.frame = CGRect(x: 11, y: (frame.height - textHeight) / 2, width: textWidth, height: textHeight)

        // Above the chip's window and moving with it; at its level, so it shows over the overlay's panels too.
        panel.level = window.level
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        let animates = fades && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animates ? 0 : 1
        panel.orderFront(nil)
        if animates {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.fade
                panel.animator().alphaValue = 1
            }
        }
        lastShown = Date()
    }

    /// Where a tag of `size` stands beside `chip`: centered on it, `gap` off the given edge, on the other side when that
    /// one runs off `screen`, and kept inside it.
    public static func frame(of size: CGSize, beside chip: CGRect, edge: NSRectEdge, gap: CGFloat, within screen: CGRect) -> CGRect {
        let bounds = screen.insetBy(dx: 4, dy: 4)
        var origin: CGPoint
        switch edge {
        case .minX, .maxX:
            let right = chip.maxX + gap
            let left = chip.minX - gap - size.width
            let x = edge == .maxX
                ? (right + size.width <= bounds.maxX ? right : left)
                : (left >= bounds.minX ? left : right)
            origin = CGPoint(x: x, y: chip.midY - size.height / 2)
        default:
            let below = chip.minY - gap - size.height
            let above = chip.maxY + gap
            let y = edge == .minY
                ? (below >= bounds.minY ? below : above)
                : (above + size.height <= bounds.maxY ? above : below)
            origin = CGPoint(x: chip.midX - size.width / 2, y: y)
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: origin, size: size).integral
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Chrome, never content: kept out of captures taken while it shows.
        panel.sharingType = .none
        panel.setAccessibilityElement(false)

        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content
        capsule.wantsLayer = true
        capsule.layer?.borderWidth = 0.5
        capsule.layer?.shadowColor = .black
        capsule.layer?.shadowOpacity = 0.18
        capsule.layer?.shadowRadius = 8
        capsule.layer?.shadowOffset = CGSize(width: 0, height: -2)
        content.addSubview(capsule)
        label.font = Theme.Typeface.label(size: 12, weight: .medium)
        label.alignment = .left
        label.isSelectable = false
        label.setAccessibilityElement(false)
        capsule.addSubview(label)
        return panel
    }

    /// The reading capsule's materials, so every small note over the screen looks alike.
    private func applyAppearance(of appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        capsule.layer?.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96)
        capsule.layer?.borderWidth = contrast ? 1 : 0.5
        capsule.layer?.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
        label.textColor = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
    }
}
