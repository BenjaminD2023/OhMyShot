import Foundation
import SwiftUI

/// The narrowest a settings pane gets, in points: room for its rows in English. A translation whose rows run longer
/// gives a wider one in its catalog, so nothing in a pane is cut off.
let paneWidth = CGFloat(Double(String(
    localized: "SETTINGS_PANE_WIDTH",
    defaultValue: "520",
    bundle: .module,
    comment: "The narrowest a Settings pane gets, in points. Not words: raise the number if your language's rows are cut off."
)) ?? 520)

/// A settings pane in the classic two-column layout: short labels right-aligned in the first column,
/// controls in the second, and groups split by dividers. Explanations wait behind one help button for each
/// group, at the end of its first row, rather than sitting under every row. The pane fills the window beside the sidebar, its rows at the top, and
/// scrolls when they are taller than the window.
struct SettingsPane<Rows: View>: View {
    /// How a row's label lines up with its controls: on the first line of text by default, or centered
    /// for controls without text, such as shortcut recorders.
    var alignment: Alignment = .leadingFirstTextBaseline
    var spacing: CGFloat = 12
    @ViewBuilder var rows: Rows
    /// Where the sidebar's search sends the pane (absent in a pane shown on its own).
    @Environment(SettingsSearchTarget.self) private var target: SettingsSearchTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last request of the search this pane has landed.
    @State private var landed = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Grid(alignment: alignment, horizontalSpacing: 10, verticalSpacing: spacing) {
                    rows
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { land(proxy) }
            .onChange(of: target?.request) { land(proxy) }
        }
        .frame(minWidth: paneWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Scrolls the row a search opened the pane on into view and lights its title up for a moment, once per search.
    private func land(_ proxy: ScrollViewProxy) {
        guard let target, target.request != landed else { return }
        landed = target.request
        guard let row = target.row else { return }
        target.lit = row
        Task {
            // Once the pane is laid out, and again once what it loads as it appears (the model packs, say) has
            // taken its room: a pane opened for the first time grows under the first scroll.
            for delay in [50, 350] {
                try? await Task.sleep(for: .milliseconds(delay))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .center) }
            }
            try? await Task.sleep(for: .milliseconds(1600))
            if target.lit == row { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { target.lit = nil } }
        }
    }
}

/// A row of a settings pane: its label right-aligned in the first column, its controls in the second, and, on the
/// first row of a group with something to explain, the group's help button in a third.
struct SettingsRow<Content: View>: View {
    let label: Text?
    /// The row's title, which the sidebar's search lands on (`SettingsTab.searchRows`); nil for a row it doesn't.
    var anchor: String?
    /// A fixed width for the label column, so the fields of one form line up whatever its rows say.
    var labelWidth: CGFloat?
    /// What the group this row heads explains, row by row; empty for a row that heads none, or whose group has nothing
    /// to explain.
    var help: [HelpTopic] = []
    @ViewBuilder var content: Content
    @Environment(SettingsSearchTarget.self) private var target: SettingsSearchTarget?

    init(_ label: Text? = nil, labelWidth: CGFloat? = nil, help: [HelpTopic] = [], @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.help = help
        self.content = content()
    }

    /// A row titled `title`, already localized, which a search can land on.
    init(_ title: String, labelWidth: CGFloat? = nil, help: [HelpTopic] = [], @ViewBuilder content: () -> Content) {
        self.init(Text(title), labelWidth: labelWidth, help: help, content: content)
        anchor = title
    }

    var body: some View {
        GridRow {
            Group {
                if let labelWidth {
                    (label ?? Text(verbatim: "")).frame(width: labelWidth, alignment: .trailing)
                } else {
                    label ?? Text(verbatim: "")
                }
            }
            // The row a search opened the pane on says so in the accent for a moment, as a selection would.
            .foregroundStyle(anchor != nil && target?.lit == anchor ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .id(anchor)
            .gridColumnAlignment(.trailing)
            content
            if !help.isEmpty {
                GroupHelp(help)
            }
        }
    }
}

/// The line between groups of rows.
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .gridCellUnsizedAxes(.horizontal)
            .padding(.vertical, 4)
    }
}

/// A row's or a control's part of its group's help: its name as the pane shows it, then what it does.
struct HelpTopic {
    let title: String
    let text: Text

    /// `title` is already localized: the row's or the control's own name.
    init(_ title: String, _ text: Text) {
        self.title = title
        self.text = text
    }
}

/// The round help button of a group of rows, at the trailing end of its first row: a popover explaining the group's
/// rows one by one, each under its name in semibold, scrolling when it is taller than `maxHeight`.
struct GroupHelp: View {
    let topics: [HelpTopic]
    @State private var isShown = false
    static let width: CGFloat = 320
    static let maxHeight: CGFloat = 440

    init(_ topics: [HelpTopic]) {
        self.topics = topics
    }

    var body: some View {
        HelpLink { isShown.toggle() }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                Self.content(topics)
            }
            .accessibilityLabel(Text("Help: \(topics.map(\.title).formatted(.list(type: .and)))", bundle: .module))
    }

    /// The popover's content: the topics in a column, in a scroll view as tall as they are, up to `maxHeight`.
    static func content(_ topics: [HelpTopic]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(topics.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(topics[index].title)
                            .fontWeight(.semibold)
                        topics[index].text
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
    }
}

/// The round help button beside a control, with a short explanation in a popover: in a destination's editor, where
/// each field has its own.
struct InfoButton: View {
    let text: Text
    @State private var isShown = false

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        HelpLink { isShown.toggle() }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                text
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                    .padding(14)
            }
            .accessibilityHint(text)
    }
}

/// A secure field for a secret, which says "Saved" instead of showing what the Keychain holds.
struct SecretInput: View {
    @Binding var text: String
    let isStored: Bool
    let label: Text
    /// A secret the form can do without, such as the key of a service on this Mac.
    var isOptional = false

    var body: some View {
        HStack(spacing: 6) {
            SecureField(text: $text, prompt: isStored ? Text("Saved in Keychain", bundle: .module) : isOptional ? Text("Optional", bundle: .module) : Text("Required", bundle: .module)) { label }
                .labelsHidden()
            // The lock takes the help button's place, so this field ends where the others do.
            ZStack {
                if isStored {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help(Text("Saved in the Keychain. Type a new value to replace it.", bundle: .module))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 24, height: 1)
        }
    }
}

/// Where a form's Test stands: Sharing's Test Upload in a destination's editor, and Cloud reading's Test.
enum SettingsTestState: Equatable {
    case idle
    case running
    /// What came back: the test upload's link, or a sentence saying how it went.
    case succeeded(String)
    case failed(String)
}

/// A form's Test: the button, a spinner while it runs, and under them what it found, a green check or the orange
/// triangle with the failure's sentence, which can be selected for a bug report or a server's owner.
struct SettingsTestRow: View {
    let state: SettingsTestState
    let title: Text
    /// What the test does, as the button's tooltip and in a round help button beside it; nil for neither.
    var help: Text?
    /// Whether a success is a link, which can be selected and is cut in the middle when long; else a sentence.
    var succeedsWithLink = false
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let help {
                    button
                        .help(help)
                    InfoButton(help)
                } else {
                    button
                }
                if state == .running {
                    ProgressView().controlSize(.small)
                }
            }
            switch state {
            case .idle, .running:
                EmptyView()
            case .succeeded(let message):
                Label {
                    if succeedsWithLink {
                        Text(message)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    } else {
                        Text(message).lineLimit(3)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
            case .failed(let message):
                Label {
                    Text(message)
                        .textSelection(.enabled)
                        .lineLimit(4)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var button: some View {
        Button(action: run) { title }
            .disabled(state == .running)
    }
}

/// A warning under a setting: the orange triangle, then what goes wrong or is missing, in the secondary callout ink.
struct SettingsWarning: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// The "…" button at the end of a row of a settings list, with the row's less used actions.
struct SettingsMoreMenu<Items: View>: View {
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(Text("More", bundle: .module))
    }
}

extension View {
    /// The well a settings list or document sits in: a faint fill under rounded corners and a hairline edge.
    /// `clipped`, the content is cut to the corners too, for one that scrolls under them.
    func settingsWell(clipped: Bool = false) -> some View {
        modifier(SettingsWell(clipped: clipped))
    }
}

private struct SettingsWell: ViewModifier {
    let clipped: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let filled = content.background(.quaternary.opacity(0.5), in: shape)
        Group {
            if clipped {
                filled.clipShape(shape)
            } else {
                filled
            }
        }
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}
