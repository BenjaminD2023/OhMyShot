import AppKit
import KeyboardShortcuts
import OMSCore
import SwiftUI

/// The status menu's own entries, laid out for the launcher. One rule throughout: a command that takes a global
/// shortcut is a tile, its keys a button that changes them in Settings; every other command is a row. Every
/// route keeps its validation and action.
struct CaptureLauncherModel {
    typealias Entry = StatusItemController.Entry
    let captureEntries: [Entry]
    let toolEntries: [Entry]
    let imageEntries: [Entry]
    let historyEntries: [Entry]
    let priorityEntries: [Entry]
    let appEntries: [Entry]
    let debugEntries: [Entry]
    let openSettings: () -> Void
    /// Opens Settings › Shortcuts on a shortcut's row, or on the pane for none.
    let editShortcut: (CaptureShortcut?) -> Void
    let quit: () -> Void

    /// The ways to take a capture, first, in reading order; every other command with a shortcut follows them
    /// under Tools, in the status menu's order.
    static let captureShortcuts: [CaptureShortcut] = [
        .captureArea, .captureWindow, .captureFullscreen, .scrollingCapture,
        .recordScreen, .allInOne, .selfTimer, .pinArea,
    ]

    private var commands: [Entry] { visible(captureEntries + toolEntries + historyEntries) }

    var captureTiles: [Entry] {
        Self.captureShortcuts.compactMap { shortcut in commands.first { $0.shortcut == shortcut } }
    }

    var toolTiles: [Entry] {
        commands.filter { entry in entry.shortcut.map { !Self.captureShortcuts.contains($0) } ?? false }
    }

    /// Commands that exist only while something runs (a waiting update, cancelling a scrolling capture or a
    /// Studio export): they lead the launcher, so they are one click away.
    var activeEntries: [Entry] {
        visible(priorityEntries) + commands.filter(Self.isStatus)
    }

    /// Commands without a shortcut: menus of their own, switches, and Restore Recently Closed.
    var moreRows: [Entry] {
        commands.filter { $0.shortcut == nil && !Self.isStatus($0) }
    }

    var imageRows: [Entry] { visible(imageEntries) }

    var appRows: [Entry] {
        visible(appEntries) + [
            // Every shortcut, those without a tile too (Capture Previous Area, Copy Latest Capture, and the rest).
            .init(title: String(localized: "Keyboard Shortcuts…", bundle: .module), systemImage: "command") { editShortcut(nil) },
        ] + (debugEntries.isEmpty ? [] : [
            .init(title: String(localized: "Debug", bundle: .module), systemImage: "ladybug") { debugEntries },
        ]) + [
            .init(title: String(localized: "Quit \(AppIdentity.displayName)", bundle: .module), systemImage: "power",
                  keyEquivalent: "q", perform: quit),
        ]
    }

    private static func isStatus(_ entry: Entry) -> Bool {
        entry.shortcut == nil && entry.children == nil && entry.isHidden != nil
    }

    private func visible(_ entries: [Entry]) -> [Entry] {
        entries.filter { $0.kind == .item && $0.isHidden?() != true }
    }
}

struct CaptureLauncherView: View {
    typealias Entry = StatusItemController.Entry
    /// The launcher's coordinate space, origin at its top left: where a row's menu is placed from.
    static let space = "CaptureLauncher"

    let model: CaptureLauncherModel
    let perform: (Entry) -> Void
    /// Opens a row's submenu under the row, whose frame is given in `space`.
    let showMenu: (Entry, CGRect) -> Void

    var body: some View {
        // Only alive while the popover is open. Re-read countdowns, cancellations, and menu availability.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                header
                let active = model.activeEntries
                if !active.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(active.enumerated()), id: \.offset) { _, entry in
                            LauncherRow(entry: entry, emphasized: true, perform: perform, showMenu: showMenu)
                        }
                    }
                    .padding(.bottom, 8)
                }
                tiles(model.captureTiles)
                if !model.toolTiles.isEmpty {
                    sectionTitle(Text("Tools", bundle: .module))
                    tiles(model.toolTiles)
                }
                section(Text("More", bundle: .module), model.moreRows)
                section(Text("Images & Pins", bundle: .module), model.imageRows)
                section(nil, model.appRows)
            }
            .padding(8)
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(.named(Self.space))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppActivation.appIcon).resizable().interpolation(.high).frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(verbatim: AppIdentity.displayName).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                perform(.init(title: String(localized: "Settings…", bundle: .module), perform: model.openSettings))
            } label: {
                Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(LauncherButtonStyle(cornerRadius: 6))
            .help(Text("Settings…", bundle: .module))
            .accessibilityLabel(Text("Settings…", bundle: .module))
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.leading, 6)
        .padding(.bottom, 8)
    }

    private func tiles(_ entries: [Entry]) -> some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(entries.chunked(4).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, entry in
                        LauncherTile(entry: entry, perform: perform) { shortcut in
                            perform(.init(title: String(localized: "Keyboard Shortcuts…", bundle: .module)) {
                                model.editShortcut(shortcut)
                            })
                        }
                    }
                    // A short row keeps four columns, so its tiles are as wide as the rest.
                    ForEach(row.count ..< 4, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
    }

    private func sectionTitle(_ title: Text) -> some View {
        title.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    /// A group of rows in two columns under a separator, with its title when it has one.
    @ViewBuilder
    private func section(_ title: Text?, _ entries: [Entry]) -> some View {
        if !entries.isEmpty {
            Divider().padding(.horizontal, 8).padding(.top, 8).padding(.bottom, title == nil ? 4 : 6)
            if let title {
                title.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            // Eager pairs, not a lazy grid: the popover takes this view's ideal height, which must be exact.
            VStack(spacing: 0) {
                ForEach(Array(entries.chunked(2).enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 4) {
                        ForEach(Array(pair.enumerated()), id: \.offset) { _, entry in
                            LauncherRow(entry: entry, perform: perform, showMenu: showMenu).frame(maxWidth: .infinity)
                        }
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                    }
                }
            }
        }
    }
}

/// A command with a global shortcut: its symbol and name, and under them its keys as a button of their own that
/// opens Settings › Shortcuts on its row, or Set Shortcut while it has none. Everything stays in its place
/// whatever the name's length.
private struct LauncherTile: View {
    let entry: StatusItemController.Entry
    let perform: (StatusItemController.Entry) -> Void
    let editShortcut: (CaptureShortcut) -> Void

    var body: some View {
        let title = entry.currentTitle?() ?? entry.title
        ZStack(alignment: .bottom) {
            Button { perform(entry) } label: {
                VStack(spacing: 4) {
                    Image(systemName: entry.systemImage ?? "viewfinder").font(.system(size: 18))
                        .frame(height: 24)
                    Text(verbatim: title).font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center).lineLimit(2)
                        .frame(height: 28, alignment: .top)
                    // The room the keys' button takes, over the tile.
                    Color.clear.frame(height: 18)
                }
                .padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 7)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(LauncherButtonStyle(cornerRadius: 10, filled: true))
            .disabled(entry.isEnabled?() == false)
            .help(title)
            .accessibilityLabel(Text(verbatim: title))
            if let shortcut = entry.shortcut {
                ShortcutButton(shortcut: shortcut, title: title) { editShortcut(shortcut) }
                    .padding(.horizontal, 6).padding(.bottom, 7)
            }
        }
    }
}

/// A shortcut's keys as a capsule button, or Set Shortcut in the accent while it has none.
private struct ShortcutButton: View {
    let shortcut: CaptureShortcut
    /// The command's name, for the tooltip and VoiceOver.
    let title: String
    let action: () -> Void

    var body: some View {
        let keys = KeyboardShortcuts.getShortcut(for: shortcut.name)?.description
        Button(action: action) {
            Group {
                if let keys {
                    Text(verbatim: keys).foregroundStyle(.secondary)
                } else {
                    Label { Text("Set Shortcut", bundle: .module) } icon: { Image(systemName: "plus") }
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.tint)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(ShortcutButtonStyle(unset: keys == nil))
        .help(keys == nil
            ? Text("Set a shortcut for \(title) in Settings", bundle: .module)
            : Text("Change the shortcut for \(title) in Settings", bundle: .module))
        .accessibilityLabel(keys == nil
            ? Text("Set a shortcut for \(title) in Settings", bundle: .module)
            : Text("Change the shortcut for \(title) in Settings", bundle: .module))
        .accessibilityValue(Text(verbatim: keys ?? ""))
    }
}

/// A capsule that reads as a button at rest: a neutral fill for keys, an accent wash for Set Shortcut, both
/// deepening under the pointer and while pressed.
private struct ShortcutButtonStyle: ButtonStyle {
    let unset: Bool

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, unset: unset)
    }

    private struct Highlight: View {
        let configuration: Configuration
        let unset: Bool
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        var body: some View {
            let level = configuration.isPressed ? 2.0 : hovered ? 1.5 : 1
            let fill = unset ? Color.accentColor.opacity(0.12 * level) : Color.primary.opacity(0.07 * level)
            configuration.label
                .background(fill, in: Capsule())
                .overlay {
                    if contrast == .increased { Capsule().strokeBorder(Color.primary.opacity(0.45), lineWidth: 1) }
                }
                .onHover { hovered = $0 }
        }
    }
}

/// A command as a menu item looks: symbol, name, and a chevron when it opens a menu of its own.
private struct LauncherRow: View {
    let entry: StatusItemController.Entry
    var emphasized = false
    let perform: (StatusItemController.Entry) -> Void
    let showMenu: (StatusItemController.Entry, CGRect) -> Void
    @State private var frame = CGRect.zero

    var body: some View {
        let title = entry.currentTitle?() ?? entry.title
        Button {
            if entry.children != nil { showMenu(entry, frame) } else { perform(entry) }
        } label: {
            HStack(spacing: 7) {
                if let symbol = entry.systemImage {
                    Image(systemName: symbol).font(.system(size: 13))
                        .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                }
                Text(verbatim: title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                if entry.children != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                } else if entry.isChecked?() == true {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherButtonStyle(cornerRadius: 6, filled: emphasized))
        .disabled(entry.isEnabled?() == false)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CaptureLauncherView.space)) } action: { frame = $0 }
        .help(title)
        .commandKey(entry.keyEquivalent)
    }
}

/// Real buttons keep keyboard focus and VoiceOver actions. Hover and press change only a neutral fill, as a
/// menu's highlight does; nothing moves.
private struct LauncherButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    /// A fill at rest too, for tiles and for rows that need noticing.
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, cornerRadius: cornerRadius, filled: filled)
    }

    private struct Highlight: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let filled: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let fill = configuration.isPressed ? 0.16 : hovered ? 0.1 : filled ? 0.06 : 0
            configuration.label
                .background(Color.primary.opacity(fill), in: shape)
                .overlay {
                    if filled, contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1) }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = isEnabled && $0 }
        }
    }
}

private extension View {
    /// ⌘ and the entry's key, when it has one (⌘Q for Quit).
    @ViewBuilder
    func commandKey(_ key: String) -> some View {
        if let character = key.first {
            keyboardShortcut(KeyEquivalent(character), modifiers: .command)
        } else {
            self
        }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}
