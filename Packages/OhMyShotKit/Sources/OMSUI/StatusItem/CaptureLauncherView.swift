import AppKit
import KeyboardShortcuts
import OMSCore
import SwiftUI

/// Shares the original command entries, so every route keeps its validation and action.
struct CaptureLauncherModel {
    typealias Entry = StatusItemController.Entry
    let captureEntries: [Entry]
    let textEntries: [Entry]
    let pinEntries: [Entry]
    let historyEntries: [Entry]
    let priorityEntries: [Entry]
    let appEntries: [Entry]
    let debugEntries: [Entry]
    let openGuide: (() -> Void)?
    let openSettings: () -> Void
    let quit: () -> Void

    static let quickActions: [CaptureShortcut] = [
        .captureWindow, .captureFullscreen, .recordScreen, .scrollingCapture, .captureText, .pinArea,
    ]

    static func symbol(for shortcut: CaptureShortcut) -> String {
        switch shortcut {
        case .captureWindow: "macwindow"
        case .captureFullscreen: "rectangle.inset.filled"
        case .recordScreen: "record.circle"
        case .scrollingCapture: "arrow.down.document"
        case .captureText: "text.viewfinder"
        case .pinArea: "pin"
        default: "viewfinder"
        }
    }

    func entry(for shortcut: CaptureShortcut) -> Entry? {
        (captureEntries + historyEntries).first { $0.shortcut == shortcut && $0.isHidden?() != true }
    }

    /// An active timer or export must remain easy to cancel, even though its idle command lives in More.
    var activeEntries: [Entry] {
        captureEntries.filter { entry in
            guard entry.children == nil, entry.isHidden?() != true,
                  entry.shortcut != .captureArea,
                  !Self.quickActions.contains(where: { $0 == entry.shortcut }) else { return false }
            return (entry.shortcut == nil && entry.isHidden != nil) ||
                (entry.currentTitle?() != nil && entry.currentTitle?() != entry.title)
        }
    }

    var moreEntries: [Entry] {
        [
            .init(title: String(localized: "Capture & Record", bundle: .module)) { captureEntries },
            .init(title: String(localized: "Images & Pins", bundle: .module)) { textEntries + pinEntries },
            .init(title: String(localized: "Recent Captures", bundle: .module)) { historyEntries },
            .separator,
        ] + appEntries + (debugEntries.isEmpty ? [] : [
            .separator,
            .init(title: String(localized: "Debug", bundle: .module)) { debugEntries },
        ]) + [
            .separator,
            .init(title: String(localized: "Quit \(AppIdentity.displayName)", bundle: .module), keyEquivalent: "q", perform: quit),
        ]
    }
}

struct CaptureLauncherView: View {
    let model: CaptureLauncherModel
    let perform: (StatusItemController.Entry) -> Void

    var body: some View {
        // Only alive while the popover is open. Re-read countdowns, cancellations, and menu availability.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ForEach(Array(model.priorityEntries.enumerated()), id: \.offset) { _, entry in
                        if entry.isHidden?() != true { statusAction(entry, symbol: "arrow.down.circle") }
                    }
                    if let entry = model.entry(for: .captureArea) {
                        Button { perform(entry) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "viewfinder")
                                    .font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
                                    .frame(width: 44, height: 48)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(verbatim: entry.title).font(.system(size: 17, weight: .semibold))
                                    Text("Drag to capture any part of your screen.", bundle: .module)
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let keys = keys(for: entry) {
                                        Text(verbatim: keys).font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(LauncherCardStyle(prominent: true))
                        .disabled(entry.isEnabled?() == false)
                        .accessibilityHint(Text("Drag to capture any part of your screen.", bundle: .module))
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(CaptureLauncherModel.quickActions, id: \.self) { shortcut in
                            if let entry = model.entry(for: shortcut) { tile(entry, shortcut: shortcut) }
                        }
                    }
                    ForEach(Array(model.activeEntries.enumerated()), id: \.offset) { _, entry in
                        statusAction(entry, symbol: "stop.circle")
                    }
                    Divider()
                    HStack(spacing: 8) {
                        if let history = model.entry(for: .openHistory) {
                            Button { perform(history) } label: {
                                Label(String(localized: "Capture History", bundle: .module), systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(LauncherCardStyle())
                        }
                        Menu {
                            LauncherMenuEntries(entries: model.moreEntries, perform: perform)
                        } label: {
                            Label(String(localized: "More Tools", bundle: .module), systemImage: "ellipsis.circle")
                                .padding(9)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    .font(.system(size: 12, weight: .medium))
                    if let openGuide = model.openGuide {
                        Button { perform(.init(title: String(localized: "Getting Started…", bundle: .module), perform: openGuide)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Your first screenshot", bundle: .module).font(.system(size: 12, weight: .medium))
                                    Text("A quick guide to capturing and sharing.", bundle: .module)
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LauncherCardStyle())
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 368, height: 568)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: AppActivation.appIcon).resizable().interpolation(.high).frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "OhMyShot").font(.system(size: 14, weight: .semibold))
                Text("Capture something great.", bundle: .module).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                perform(.init(title: String(localized: "Settings…", bundle: .module), perform: model.openSettings))
            } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(LauncherCardStyle())
            .help(Text("Settings…", bundle: .module))
            .accessibilityLabel(Text("Settings…", bundle: .module))
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func tile(_ entry: StatusItemController.Entry, shortcut: CaptureShortcut) -> some View {
        let title = entry.currentTitle?() ?? entry.title
        return Button { perform(entry) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: CaptureLauncherModel.symbol(for: shortcut)).font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let keys = keys(for: entry) {
                        Text(verbatim: keys).font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary)
                    }
                }
                Text(verbatim: title).font(.system(size: 12, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(LauncherCardStyle())
        .disabled(entry.isEnabled?() == false)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: keys(for: entry) ?? ""))
        .help([title, keys(for: entry)].compactMap { $0 }.joined(separator: " · "))
    }

    private func statusAction(_ entry: StatusItemController.Entry, symbol: String) -> some View {
        Button { perform(entry) } label: {
            Label(entry.currentTitle?() ?? entry.title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .buttonStyle(LauncherCardStyle()).disabled(entry.isEnabled?() == false)
    }

    private func keys(for entry: StatusItemController.Entry) -> String? {
        entry.shortcut.flatMap { KeyboardShortcuts.getShortcut(for: $0.name)?.description }
    }


}

/// Real buttons retain keyboard focus and VoiceOver actions; hover never changes the layout.
private struct LauncherCardStyle: ButtonStyle {
    var prominent = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        LauncherCardBody(configuration: configuration, prominent: prominent, increasedContrast: contrast == .increased)
            .opacity(isEnabled ? 1 : 0.45)
    }

    private struct LauncherCardBody: View {
        let configuration: Configuration
        let prominent: Bool
        let increasedContrast: Bool
        @State private var hovered = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.08 : prominent ? 0.055 : 0.025), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(increasedContrast ? 0.5 : prominent ? 0.13 : 0.07), lineWidth: increasedContrast ? 1 : 0.5))
                .onHover { hovered = $0 }
        }
    }
}

/// Native menus keep the less common commands compact, including dynamic, nested submenus.
private struct LauncherMenuEntries: View {
    let entries: [StatusItemController.Entry]
    let perform: (StatusItemController.Entry) -> Void
    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            if entry.isHidden?() != true {
                switch entry.kind {
                case .separator: Divider()
                case .header: Text(verbatim: entry.title)
                case .item:
                    if let children = entry.children {
                        Menu(entry.currentTitle?() ?? entry.title) {
                            AnyView(LauncherMenuEntries(entries: children(), perform: perform))
                        }
                    } else if let isChecked = entry.isChecked {
                        Toggle(isOn: Binding(get: { isChecked() }, set: { _ in perform(entry) })) {
                            menuLabel(entry)
                        }
                        .disabled(entry.isEnabled?() == false)
                    } else {
                        Button { perform(entry) } label: { menuLabel(entry) }
                            .disabled(entry.isEnabled?() == false)
                    }
                }
            }
        }
    }

    private func menuLabel(_ entry: StatusItemController.Entry) -> some View {
        HStack {
            Text(verbatim: entry.currentTitle?() ?? entry.title)
            if let shortcut = entry.shortcut,
               let keys = KeyboardShortcuts.getShortcut(for: shortcut.name)?.description {
                Text(verbatim: keys)
            }
        }
    }
}
