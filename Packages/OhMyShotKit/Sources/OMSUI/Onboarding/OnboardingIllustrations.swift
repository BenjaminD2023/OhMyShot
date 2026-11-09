import AppKit
import OMSCore
import OMSDesign
import SwiftUI

// Diagrams for the guide's steps. Each is drawn from the shipped marks and the app's own overlay and card vocabulary,
// in system colors, so it reads in both appearances. They show where things are; none of them is a screenshot.

/// The width of the guide's column: its diagrams, lists, and instructions.
enum OnboardingColumn {
    static let width: CGFloat = 440
}

/// The stage every diagram sits on: a faint well with a hairline, the width of the guide's column.
struct IllustrationStage<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .frame(width: OnboardingColumn.width, height: height, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Keys as keycaps, one per modifier and one for the key: ⇧ ⌘ 4. VoiceOver reads the keys as one.
struct KeyCaps: View {
    let keys: String
    var size: CGFloat = 12
    @Environment(\.colorSchemeContrast) private var contrast

    static func parts(of keys: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var parts: [String] = []
        var rest = Substring(keys)
        while let first = rest.first, modifiers.contains(first) {
            parts.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.parts(of: keys).enumerated()), id: \.offset) { _, part in
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                Text(verbatim: part)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .frame(minWidth: size + 4)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.16), lineWidth: contrast == .increased ? 1 : 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: keys))
    }
}

/// The menu bar icon opens a compact launcher: one main capture and a grid of other capture modes.
struct MenuBarPreview: View {
    struct Entry: Hashable {
        let title: String
        let keys: String?
    }

    let entries: [Entry]
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        IllustrationStage(height: 128) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo").font(.system(size: 13))
                    Spacer()
                    Image(nsImage: .statusItemIcon(accessibilityDescription: nil) ?? NSImage())
                        .resizable().scaledToFit().frame(width: 16, height: 16)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100percent")
                    Image(systemName: "switch.2")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .frame(width: OnboardingColumn.width, height: 26)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.92))

                menu
                    .frame(width: 214)
                    .offset(x: OnboardingColumn.width - 214 - 12, y: 30)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("OhMyShot’s menu bar icon opens the capture menu.", bundle: .module))
    }

    private var menu: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            if let entry = entries.first {
                HStack(spacing: 10) {
                    Image(systemName: "viewfinder").font(.system(size: 23, weight: .light)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: entry.title).font(.system(size: 13, weight: .semibold))
                        if let keys = entry.keys {
                            Text(verbatim: keys).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 6) {
                ForEach(Array(entries.dropFirst().enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Image(systemName: index == 0 ? "macwindow" : "rectangle.inset.filled")
                        Text(verbatim: entry.title).font(.system(size: 10)).lineLimit(1)
                    }
                    .foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(5)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.1), lineWidth: contrast == .increased ? 1 : 0.5))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        // The menu goes on past the stage: its last entry fades out where the stage ends.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .black.opacity(0.15), location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// Where Screen Recording is turned on: System Settings' pane, titled as macOS titles it, with OhMyShot's row. Off,
/// its switch is ringed in the accent as the thing to turn on; on, the ring goes.
struct ScreenRecordingSettingsPreview: View {
    let isOn: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        IllustrationStage(height: 96) {
            let window = RoundedRectangle(cornerRadius: 10, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    Text("Screen & System Audio Recording", bundle: .module)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 32)
                HStack(spacing: 9) {
                    Image(nsImage: AppActivation.appIcon).resizable().interpolation(.high).frame(width: 22, height: 22)
                    Text(verbatim: AppIdentity.displayName).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    SwitchDrawing(isOn: isOn)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)
            }
            .frame(width: 400, height: 76, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor), in: window)
            .overlay(window.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.1), lineWidth: contrast == .increased ? 1 : 0.5))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            .offset(x: 20, y: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("In System Settings, turn on OhMyShot under Screen & System Audio Recording.", bundle: .module))
    }
}

/// A drawn switch, the system's shape, never a control: the guide's only switch is in System Settings.
private struct SwitchDrawing: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.14))
            Circle().fill(.white).shadow(color: .black.opacity(0.22), radius: 1, y: 0.5).padding(1.5)
        }
        .frame(width: 32, height: 18)
        .padding(3)
        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isOn ? 0 : 1))
    }
}

/// The practice in two frames: the area being chosen (the overlay's dim, white edge, size reading, and crosshair) and
/// then its Quick Access card in the corner it comes to. The capture's subject is the app's own mark.
struct FirstCapturePreview: View {
    let cardsOnLeft: Bool
    @Environment(\.colorScheme) private var scheme
    private static let screen = CGSize(width: 176, height: 110)

    var body: some View {
        IllustrationStage(height: 146) {
            HStack(spacing: 0) {
                choosing
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(width: 48)
                kept
            }
            .padding(.horizontal, 20)
            .frame(width: OnboardingColumn.width, height: 146)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Drag over part of the screen. When you let go, its Quick Access card appears in the corner.", bundle: .module))
    }

    private var icon: some View {
        Image(nsImage: AppActivation.appIcon).resizable().interpolation(.high).frame(width: 36, height: 36)
    }

    private var choosing: some View {
        MiniScreen(size: Self.screen) {
            let selection = CGRect(x: 58, y: 16, width: 60, height: 60)
            ZStack(alignment: .topLeading) {
                icon.position(x: selection.midX, y: selection.midY)
                Canvas { context, size in
                    var dim = Path(CGRect(origin: .zero, size: size))
                    dim.addRect(selection)
                    context.fill(dim, with: .color(.black.opacity(Theme.Overlay.dimming)), style: FillStyle(eoFill: true))
                    let edge = Path(selection)
                    context.stroke(edge, with: .color(.black.opacity(Theme.Overlay.outlineOpacity)), lineWidth: 2.5)
                    context.stroke(edge, with: .color(.white), lineWidth: 1.5)
                    // The crosshair, at the corner being dragged: white arms over the overlay's dark outline.
                    let center = CGPoint(x: selection.maxX, y: selection.maxY)
                    var cross = Path()
                    for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                        cross.move(to: CGPoint(x: center.x + dx * 3, y: center.y + dy * 3))
                        cross.addLine(to: CGPoint(x: center.x + dx * 9, y: center.y + dy * 9))
                    }
                    context.stroke(cross, with: .color(.black.opacity(Theme.Overlay.outlineOpacity)), lineWidth: 2.5)
                    context.stroke(cross, with: .color(.white), lineWidth: 1)
                }
                SizeReading(text: "512 × 512").position(x: selection.midX, y: selection.maxY + 15)
            }
        }
    }

    private var kept: some View {
        MiniScreen(size: Self.screen) {
            ZStack(alignment: .topLeading) {
                icon.position(x: 88, y: 46)
                let card = RoundedRectangle(cornerRadius: 5, style: .continuous)
                Image(nsImage: AppActivation.appIcon).resizable().interpolation(.high).frame(width: 20, height: 20)
                    .frame(width: 52, height: 36)
                    .background(Color(nsColor: .controlBackgroundColor), in: card)
                    // The card's picture border (white 0.16 / black 0.10), so it holds its edge on a dark screen too.
                    .overlay(card.strokeBorder(scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(Double(Theme.Shadow.opacity)), radius: 6, y: 3)
                    .position(x: cardsOnLeft ? 8 + 26 : Self.screen.width - 8 - 26, y: Self.screen.height - 8 - 18)
            }
        }
    }
}

/// A display in miniature: the window background, rounded, with a hairline.
private struct MiniScreen<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.12), lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

/// The reading capsule at the diagram's scale: the rounded reading face with fixed-width figures, the capsule's
/// surface and hairline, and a soft shadow.
private struct SizeReading: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        let increased = contrast == .increased
        Text(verbatim: text)
            .font(Font(Theme.Typeface.reading(size: 9) as CTFont))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Color(cgColor: Theme.Material.capsuleFill(dark: dark)), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(cgColor: Theme.Material.edge(dark: dark, contrast: increased)),
                                            lineWidth: Theme.Material.edgeWidth(contrast: increased)))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .fixedSize()
    }
}

/// Skip at the leading edge and the step's buttons at the trailing edge, in one row; when a language's labels don't
/// fit beside each other, the buttons keep the row and Skip goes under them. Each button is laid out once, so their
/// keyboard shortcuts are never registered twice.
struct GuideFooterLayout: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10

    private func measure(_ subviews: Subviews) -> (sizes: [CGSize], lead: CGFloat, trail: CGFloat, height: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let trailing = sizes.dropFirst()
        let trail = trailing.map(\.width).reduce(0, +) + spacing * CGFloat(max(trailing.count - 1, 0))
        return (sizes, sizes.first?.width ?? 0, trail, trailing.map(\.height).max() ?? 0)
    }

    private func fitsInOneRow(_ lead: CGFloat, _ trail: CGFloat, width: CGFloat?) -> Bool {
        guard let width else { return true }
        return lead + spacing * 2 + trail <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = measure(subviews)
        let width = proposal.width ?? (m.lead + spacing * 2 + m.trail)
        let leadHeight = m.sizes.first?.height ?? 0
        if fitsInOneRow(m.lead, m.trail, width: proposal.width) {
            return CGSize(width: width, height: max(leadHeight, m.height))
        }
        return CGSize(width: width, height: m.height + rowSpacing + leadHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let skip = subviews.first else { return }
        let m = measure(subviews)
        let oneRow = fitsInOneRow(m.lead, m.trail, width: bounds.width)
        let rowHeight = oneRow ? max(m.height, m.sizes[0].height) : m.height
        var x = bounds.maxX
        for index in subviews.indices.dropFirst().reversed() {
            let size = m.sizes[index]
            x -= size.width
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + (rowHeight - size.height) / 2), proposal: ProposedViewSize(size))
            x -= spacing
        }
        let skipY = oneRow ? bounds.minY + (rowHeight - m.sizes[0].height) / 2 : bounds.minY + m.height + rowSpacing
        skip.place(at: CGPoint(x: bounds.minX, y: skipY), proposal: ProposedViewSize(m.sizes[0]))
    }
}
