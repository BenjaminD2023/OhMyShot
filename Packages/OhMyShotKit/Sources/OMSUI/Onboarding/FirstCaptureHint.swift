import AppKit
import OMSCore
import OMSDesign
import SwiftUI

/// Geometry in screen points, shared by both Quick Access corners and testable without windows or a display.
enum FirstCaptureHintPlacement {
    static func frame(size: CGSize, card: CGRect, visible: CGRect) -> CGRect {
        let bounds = visible.insetBy(dx: 12, dy: 12)
        let size = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        let gap: CGFloat = 12
        let origin: CGPoint
        if card.maxX + gap + size.width <= bounds.maxX {
            origin = CGPoint(x: card.maxX + gap, y: card.minY)
        } else if card.minX - gap - size.width >= bounds.minX {
            origin = CGPoint(x: card.minX - gap - size.width, y: card.minY)
        } else if card.maxY + gap + size.height <= bounds.maxY {
            origin = CGPoint(x: card.minX, y: card.maxY + gap)
        } else {
            origin = CGPoint(x: card.minX, y: card.minY - gap - size.height)
        }
        return CGRect(x: min(max(origin.x, bounds.minX), bounds.maxX - size.width),
                      y: min(max(origin.y, bounds.minY), bounds.maxY - size.height), width: size.width, height: size.height)
    }
}

/// A single hint beside the practice card. It never activates the app or makes itself key, and has no timer.
final class FirstCaptureHintController {
    /// Room around the card for its shadow to fade out completely, as the text result card leaves: twice the blur
    /// plus the drop. The panel is that much larger than the card on every side.
    static let margin: CGFloat = Theme.Shadow.radius * 2 + Theme.Shadow.drop

    let captureID: UUID
    private let panel: FirstCaptureHintPanel
    private let content: NSHostingController<FirstCaptureHintView>
    private var lease: ActiveResources.Lease?
    #if DEBUG
    var debugWindow: NSWindow { panel }
    /// The card itself on screen, without the shadow's room.
    var debugCardFrame: CGRect { panel.frame.insetBy(dx: Self.margin, dy: Self.margin) }
    #endif

    init(captureID: UUID, isCopied: Bool, isSaved: Bool, close: @escaping () -> Void) {
        self.captureID = captureID
        panel = FirstCaptureHintPanel()
        content = NSHostingController(rootView: FirstCaptureHintView(isCopied: isCopied, isSaved: isSaved, close: close))
        content.sizingOptions = []
        panel.contentViewController = content
        panel.onDismiss = close
    }

    func show(near card: CGRect) {
        place(near: card)
        if lease == nil { lease = ActiveResources.shared.acquire(.window) }
        panel.orderFrontRegardless()
        VoiceOver.announce(String(localized: "Your first capture is ready. Copy, save, or annotate it using its Quick Access card.", bundle: .module), from: panel)
    }

    func place(near card: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(card) }) ?? NSScreen.main else { return }
        // The hint's card is placed; the panel reaches past it by the shadow's room, which takes no clicks.
        let frame = FirstCaptureHintPlacement.frame(size: fittingSize, card: card, visible: screen.visibleFrame)
        panel.setFrame(frame.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
    }

    // NSHostingView.fittingSize is zero before a layout when sizingOptions is empty. Measure the SwiftUI
    // tree explicitly so the very first presentation already has the full, localized text's height.
    /// The card's size, without the shadow's room around it.
    var fittingSize: CGSize {
        let room = Self.margin * 2
        let whole = content.sizeThatFits(in: CGSize(width: FirstCaptureHintView.width + room, height: 1000))
        return CGSize(width: whole.width - room, height: whole.height - room)
    }

    func dismiss() {
        panel.orderOut(nil)
        lease?.end()
        lease = nil
    }
}

private final class FirstCaptureHintPanel: NSPanel {
    var onDismiss: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The card draws the floating card's shadow itself, as the Quick Access card beside it does.
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        title = String(localized: "Your First Capture", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

private struct FirstCaptureHintView: View {
    static let width: CGFloat = 320
    let isCopied: Bool
    let isSaved: Bool
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        let increased = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.green).accessibilityHidden(true)
                Text("Your first capture is ready", bundle: .module)
                    .font(.headline).accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)
            Text("Point at the card to show its buttons. Double-click it to mark it up.", bundle: .module)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            // The capsules share a column as wide as the widest name, so the sentences start together in every language.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                row(String(localized: "Copy", bundle: .module), "doc.on.doc", isCopied
                    ? "It’s already copied: paste it anywhere with ⌘V."
                    : "Copies it, ready to paste with ⌘V.")
                row(isSaved ? String(localized: "Saved", bundle: .module) : String(localized: "Save", bundle: .module),
                    isSaved ? "checkmark" : "square.and.arrow.down", isSaved
                    ? "Click to show the file in Finder."
                    : "Keeps a file. Or drag the card into any app.")
                row(String(localized: "Annotate", bundle: .module), "pencil.and.scribble", "Adds arrows, text, and highlights.")
            }
            .padding(.bottom, 16)
            HStack {
                Spacer()
                // The panel never becomes key, where AppKit draws a standard button dimmed: the card's own chip.
                HintChip(title: String(localized: "Got It", bundle: .module), symbolName: "checkmark", action: close)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            shape.fill(Color(cgColor: Theme.Material.cardFill(dark: dark)))
                .shadow(color: .black.opacity(Double(Theme.Shadow.opacity)), radius: Theme.Shadow.radius, y: Theme.Shadow.drop)
        }
        .overlay(shape.strokeBorder(Color(cgColor: Theme.Material.edge(dark: dark, contrast: increased)),
                                    lineWidth: Theme.Material.edgeWidth(contrast: increased)))
        .padding(FirstCaptureHintController.margin)
    }

    /// One of the card's buttons as the card draws it, the action white capsule with its symbol and name in the
    /// card's ink and face, and what it does. It names a button and is not one: smaller than the card's, and flat,
    /// with a hairline where the card's capsule has its lift.
    private func row(_ title: String, _ symbol: String, _ text: LocalizedStringKey) -> some View {
        GridRow {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                .labelStyle(.titleAndIcon)
                .font(Font(Theme.Typeface.label(size: 11, weight: .semibold) as CTFont))
                .foregroundStyle(Color(white: Theme.ActionWhite.ink))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color(white: Theme.ActionWhite.fill), in: Capsule())
                .overlay(Capsule().strokeBorder(.black.opacity(contrast == .increased ? Theme.ActionWhite.contrastEdge : 0.1),
                                                lineWidth: contrast == .increased ? 1 : 0.5))
                .fixedSize()
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text, bundle: .module).font(.callout).fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One of the cards' hand-drawn chips, in the hint: it takes the first click in a panel that is not key, shows its
/// hover and press there, and is a button to VoiceOver.
private struct HintChip: NSViewRepresentable {
    let title: String
    let symbolName: String
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed(_ sender: Any?) { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> CardButton {
        let button = CardButton(style: .chip, title: title, symbolName: symbolName)
        button.target = context.coordinator
        button.action = #selector(Coordinator.pressed(_:))
        return button
    }

    func updateNSView(_ button: CardButton, context: Context) {
        context.coordinator.action = action
        if button.title != title { button.title = title }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CardButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
