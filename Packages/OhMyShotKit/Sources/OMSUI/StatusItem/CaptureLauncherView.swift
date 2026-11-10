import AppKit
import KeyboardShortcuts
import OMSCore
import OMSDesign
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

    // MARK: The arrow keys' path

    /// A place in the launcher as it is laid out: a row from the top, and a place in that row from the leading edge.
    struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    enum Direction {
        case up, down, left, right
    }

    /// One row of the layout: its commands, and how many a full row holds (a last row can hold fewer).
    struct Row {
        let entries: [Entry]
        let columns: Int
    }

    static let tileColumns = 4
    static let rowColumns = 2

    /// Every command in the order the launcher lays them out: what is running now one to a row, the tiles four to a
    /// row, and the rest two to a row.
    var rows: [Row] {
        activeEntries.map { Row(entries: [$0], columns: 1) }
            + [captureTiles, toolTiles].flatMap { $0.chunked(Self.tileColumns).map { Row(entries: Array($0), columns: Self.tileColumns) } }
            + [moreRows, imageRows, appRows].flatMap { $0.chunked(Self.rowColumns).map { Row(entries: Array($0), columns: Self.rowColumns) } }
    }

    /// Where an arrow key takes the highlight from `cell`, in rows of `counts` commands laid out `columns` wide,
    /// passing over what is dimmed. From nothing, Down and Right start at the first command and Up and Left in the
    /// last row. At an edge it stays where it is; between rows of different widths it keeps its side.
    static func move(from cell: Cell?, _ direction: Direction, rows: [(count: Int, columns: Int)],
                     isEnabled: (Cell) -> Bool = { _ in true }) -> Cell? {
        func first(in row: Int, nearest column: Int = 0) -> Cell? {
            (0 ..< rows[row].count)
                .sorted { (abs($0 - column), $0) < (abs($1 - column), $1) }
                .map { Cell(row: row, column: $0) }
                .first(where: isEnabled)
        }
        guard let cell, rows.indices.contains(cell.row), cell.column < rows[cell.row].count else {
            let order = direction == .down || direction == .right ? Array(rows.indices) : Array(rows.indices.reversed())
            for row in order {
                if let found = first(in: row) { return found }
            }
            return nil
        }
        switch direction {
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var column = cell.column + step
            while (0 ..< rows[cell.row].count).contains(column) {
                let next = Cell(row: cell.row, column: column)
                if isEnabled(next) { return next }
                column += step
            }
            return cell
        case .up, .down:
            let step = direction == .up ? -1 : 1
            var row = cell.row + step
            while rows.indices.contains(row) {
                // The same side of the launcher: a tile's column over the row's two, and back.
                let column = min(cell.column * rows[row].columns / max(rows[cell.row].columns, 1), rows[row].count - 1)
                if let next = first(in: row, nearest: column) { return next }
                row += step
            }
            return cell
        }
    }

    private static func isStatus(_ entry: Entry) -> Bool {
        entry.shortcut == nil && entry.children == nil && entry.isHidden != nil
    }

    private func visible(_ entries: [Entry]) -> [Entry] {
        entries.filter { $0.kind == .item && $0.isHidden?() != true }
    }
}

/// The one command the launcher lights: the one under the pointer, or the one the arrow keys reached, never both, as
/// a menu has it.
@Observable
final class LauncherHighlight {
    var cell: CaptureLauncherModel.Cell?
    /// Whether the arrow keys put the highlight there. Return and Space then press it, and it is ringed in the accent.
    var fromKeys = false
    /// Counts Return and Space on the highlighted command; the command's own button answers each.
    var presses = 0
}

struct CaptureLauncherView: View {
    typealias Entry = StatusItemController.Entry
    typealias Cell = CaptureLauncherModel.Cell
    /// The launcher's coordinate space, origin at its top left: where a row's menu is placed from.
    static let space = "CaptureLauncher"

    let model: CaptureLauncherModel
    var highlight = LauncherHighlight()
    let perform: (Entry) -> Void
    /// Opens a row's submenu under the row, whose frame is given in `space`.
    let showMenu: (Entry, CGRect) -> Void

    var body: some View {
        // Only alive while the popover is open. Re-read countdowns, cancellations, and menu availability.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            // Each group's first row, as `CaptureLauncherModel.rows` counts them.
            let active = model.activeEntries, capture = model.captureTiles, tools = model.toolTiles
            let more = model.moreRows, images = model.imageRows
            let toolRow = active.count + capture.chunked(CaptureLauncherModel.tileColumns).count
            let moreRow = toolRow + tools.chunked(CaptureLauncherModel.tileColumns).count
            let imageRow = moreRow + more.chunked(CaptureLauncherModel.rowColumns).count
            let appRow = imageRow + images.chunked(CaptureLauncherModel.rowColumns).count
            VStack(alignment: .leading, spacing: 0) {
                header
                if !active.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(Array(active.enumerated()), id: \.offset) { index, entry in
                            row(entry, at: Cell(row: index, column: 0), emphasized: true)
                        }
                    }
                    .padding(.bottom, 8)
                }
                tiles(capture, firstRow: active.count)
                if !tools.isEmpty {
                    sectionTitle(Text("Tools", bundle: .module))
                    tiles(tools, firstRow: toolRow)
                }
                section(Text("More", bundle: .module), more, firstRow: moreRow)
                section(Text("Images & Pins", bundle: .module), images, firstRow: imageRow)
                section(nil, model.appRows, firstRow: appRow)
            }
            .padding(8)
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(.named(Self.space))
        }
    }

    /// The pointer lights the command it is over and lets go of it on leaving, unless the arrow keys have moved on.
    private func hover(_ cell: Cell, _ inside: Bool) {
        if inside {
            highlight.cell = cell
            highlight.fromKeys = false
        } else if highlight.cell == cell, !highlight.fromKeys {
            highlight.cell = nil
        }
    }

    private func row(_ entry: Entry, at cell: Cell, emphasized: Bool = false) -> some View {
        LauncherRow(entry: entry, emphasized: emphasized, isHighlighted: highlight.cell == cell,
                    isRinged: highlight.cell == cell && highlight.fromKeys, presses: highlight.presses,
                    hover: { hover(cell, $0) }, perform: perform, showMenu: showMenu)
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

    private func tiles(_ entries: [Entry], firstRow: Int) -> some View {
        let columns = CaptureLauncherModel.tileColumns
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(entries.chunked(columns).enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, entry in
                        let cell = Cell(row: firstRow + rowIndex, column: column)
                        LauncherTile(entry: entry, isHighlighted: highlight.cell == cell,
                                     isRinged: highlight.cell == cell && highlight.fromKeys, presses: highlight.presses,
                                     hover: { hover(cell, $0) }, perform: perform) { shortcut in
                            perform(.init(title: String(localized: "Keyboard Shortcuts…", bundle: .module)) {
                                model.editShortcut(shortcut)
                            })
                        }
                    }
                    // A short row keeps four columns, so its tiles are as wide as the rest.
                    ForEach(row.count ..< columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
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
    private func section(_ title: Text?, _ entries: [Entry], firstRow: Int) -> some View {
        if !entries.isEmpty {
            Divider().padding(.horizontal, 8).padding(.top, 8).padding(.bottom, title == nil ? 4 : 6)
            if let title {
                title.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            // Eager pairs, not a lazy grid: the popover takes this view's ideal height, which must be exact.
            VStack(spacing: 0) {
                ForEach(Array(entries.chunked(CaptureLauncherModel.rowColumns).enumerated()), id: \.offset) { rowIndex, pair in
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(Array(pair.enumerated()), id: \.offset) { column, entry in
                            row(entry, at: Cell(row: firstRow + rowIndex, column: column)).frame(maxWidth: .infinity)
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
    let isHighlighted: Bool
    let isRinged: Bool
    let presses: Int
    let hover: (Bool) -> Void
    let perform: (StatusItemController.Entry) -> Void
    let editShortcut: (CaptureShortcut) -> Void

    var body: some View {
        let title = entry.currentTitle?() ?? entry.title
        let isEnabled = entry.isEnabled?() != false
        ZStack(alignment: .bottom) {
            Button { perform(entry) } label: {
                VStack(spacing: 4) {
                    Image(systemName: entry.systemImage ?? "viewfinder").font(.system(size: 18))
                        .frame(height: 24)
                    // A long name in another language is drawn a little smaller before it is cut short.
                    Text(verbatim: title).font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                        .frame(height: 28, alignment: .top)
                    // The room the keys' button takes, over the tile.
                    Color.clear.frame(height: 18)
                }
                .padding(.horizontal, 2).padding(.top, 10).padding(.bottom, 7)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(LauncherButtonStyle(cornerRadius: 10, filled: true, highlighted: isHighlighted, ringed: isRinged))
            .disabled(!isEnabled)
            .help(title)
            .accessibilityLabel(Text(verbatim: title))
            if let shortcut = entry.shortcut {
                ShortcutButton(shortcut: shortcut, title: title) { editShortcut(shortcut) }
                    .padding(.horizontal, 4).padding(.bottom, 7)
            }
        }
        .onHover { hover($0 && isEnabled) }
        .onChange(of: presses) { if isHighlighted, isEnabled { perform(entry) } }
    }
}

/// A shortcut's keys as a capsule button, or Set Shortcut in the accent's ink while it has none.
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
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                        Text("Set Shortcut", bundle: .module)
                    }
                    .foregroundStyle(.tint)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(ShortcutButtonStyle())
        .help(keys == nil
            ? Text("Set a shortcut for \(title) in Settings", bundle: .module)
            : Text("Change the shortcut for \(title) in Settings", bundle: .module))
        .accessibilityLabel(keys == nil
            ? Text("Set a shortcut for \(title) in Settings", bundle: .module)
            : Text("Change the shortcut for \(title) in Settings", bundle: .module))
        .accessibilityValue(Text(verbatim: keys ?? ""))
    }
}

/// A capsule that reads as a button at rest: the chip fills, a step deeper under the pointer and another while
/// pressed, the same for keys and for Set Shortcut. The accent is ink there and never a fill behind it.
private struct ShortcutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var scheme
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        var body: some View {
            let fills = LauncherFills(dark: scheme == .dark, increased: contrast == .increased)
            configuration.label
                .background(fills.color(filled: true, lit: hovered, pressed: configuration.isPressed), in: Capsule())
                .overlay {
                    if contrast == .increased { Capsule().strokeBorder(fills.contrastEdge, lineWidth: fills.contrastEdgeWidth) }
                }
                .onHover { hovered = $0 }
        }
    }
}

/// The launcher's fills, from the chip steps every bar and rail uses: black in Light and white in Dark at the hover
/// and selected opacities, about doubled under Increase Contrast. A row is clear until lit; a tile or a capsule is
/// filled at rest and goes a step deeper each time.
private struct LauncherFills {
    let dark: Bool
    let increased: Bool

    func color(filled: Bool, lit: Bool, pressed: Bool) -> Color {
        let hover = Theme.ChipFill.hover(dark: dark, contrast: increased)
        let selected = Theme.ChipFill.selected(dark: dark, contrast: increased)
        let opacity = filled
            ? (pressed ? selected + hover : lit ? selected : hover)
            : (pressed ? selected : lit ? hover : 0)
        return Color(white: dark ? 1 : 0, opacity: opacity)
    }

    /// The outline a filled shape takes under Increase Contrast: the contrast hairline.
    var contrastEdge: Color { Color(cgColor: Theme.Material.edge(dark: dark, contrast: true)) }
    var contrastEdgeWidth: CGFloat { Theme.Material.edgeWidth(contrast: true) }
}

/// A command as a menu item looks: symbol, name, and a chevron when it opens a menu of its own.
private struct LauncherRow: View {
    let entry: StatusItemController.Entry
    var emphasized = false
    let isHighlighted: Bool
    let isRinged: Bool
    let presses: Int
    let hover: (Bool) -> Void
    let perform: (StatusItemController.Entry) -> Void
    let showMenu: (StatusItemController.Entry, CGRect) -> Void
    @State private var frame = CGRect.zero

    private func press() {
        if entry.children != nil { showMenu(entry, frame) } else { perform(entry) }
    }

    var body: some View {
        let title = entry.currentTitle?() ?? entry.title
        let isEnabled = entry.isEnabled?() != false
        Button(action: press) {
            HStack(spacing: 7) {
                if let symbol = entry.systemImage {
                    Image(systemName: symbol).font(.system(size: 13))
                        .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                }
                // A long name in another language takes a second line; a command is never cut short.
                Text(verbatim: title).font(.system(size: 12)).lineLimit(2)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if entry.children != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                } else if entry.isChecked?() == true {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherButtonStyle(cornerRadius: 6, filled: emphasized, highlighted: isHighlighted, ringed: isRinged))
        .disabled(!isEnabled)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CaptureLauncherView.space)) } action: { frame = $0 }
        .onHover { hover($0 && isEnabled) }
        .onChange(of: presses) { if isHighlighted, isEnabled { press() } }
        .help(title)
        .commandKey(entry.keyEquivalent)
    }
}

/// Real buttons keep keyboard focus and VoiceOver actions. The highlight and a press change only a neutral fill, as
/// a menu's highlight does; nothing moves. A command the arrow keys reached is also ringed in the accent, since the
/// pointer is not there to say which one it is.
private struct LauncherButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    /// A fill at rest too, for tiles and for rows that need noticing.
    var filled = false
    /// Whether this is the launcher's highlighted command; nil for a button off the arrow keys' path (Settings),
    /// which lights under the pointer by itself.
    var highlighted: Bool?
    var ringed = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, cornerRadius: cornerRadius, filled: filled, highlighted: highlighted, ringed: ringed)
    }

    private struct Highlight: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let filled: Bool
        let highlighted: Bool?
        let ringed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let fills = LauncherFills(dark: scheme == .dark, increased: contrast == .increased)
            let lit = isEnabled && (highlighted ?? hovered)
            configuration.label
                .background(fills.color(filled: filled, lit: lit, pressed: configuration.isPressed), in: shape)
                .overlay {
                    if ringed, isEnabled {
                        shape.strokeBorder(Color.accentColor, lineWidth: 2)
                    } else if filled, contrast == .increased {
                        shape.strokeBorder(fills.contrastEdge, lineWidth: fills.contrastEdgeWidth)
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
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
