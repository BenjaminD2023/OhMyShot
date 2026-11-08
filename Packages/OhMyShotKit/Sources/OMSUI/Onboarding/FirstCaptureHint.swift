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
    let captureID: UUID
    private let panel: FirstCaptureHintPanel
    private let content: NSHostingController<FirstCaptureHintView>
    private var lease: ActiveResources.Lease?
    #if DEBUG
    var debugWindow: NSWindow { panel }
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
        panel.setFrame(FirstCaptureHintPlacement.frame(size: fittingSize, card: card, visible: screen.visibleFrame), display: true)
    }

    // NSHostingView.fittingSize is zero before a layout when sizingOptions is empty. Measure the SwiftUI
    // tree explicitly so the very first presentation already has the full, localized text's height.
    var fittingSize: CGSize { content.sizeThatFits(in: CGSize(width: 320, height: 1000)) }

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
        hasShadow = true
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
                Button(action: close) { Text("Got It", bundle: .module).padding(.horizontal, 6) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(cgColor: Theme.Material.cardFill(dark: dark)), in: shape)
        .overlay(shape.strokeBorder(Color(cgColor: Theme.Material.edge(dark: dark, contrast: increased)),
                                    lineWidth: Theme.Material.edgeWidth(contrast: increased)))
    }

    /// One of the card's buttons as the card draws it, a white capsule with its symbol and name, and what it does.
    private func row(_ title: String, _ symbol: String, _ text: LocalizedStringKey) -> some View {
        GridRow {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.102))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color(white: 0.969), in: Capsule())
                .overlay(Capsule().strokeBorder(.black.opacity(contrast == .increased ? 0.35 : 0.1), lineWidth: contrast == .increased ? 1 : 0.5))
                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                .fixedSize()
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text, bundle: .module).font(.callout).fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}
