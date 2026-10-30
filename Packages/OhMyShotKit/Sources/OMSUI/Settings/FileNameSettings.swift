import OMSCore
import SwiftUI
import UniformTypeIdentifiers

/// The controls of Settings › General › File name: the pattern laid out as bricks in a tray, the box of bricks that
/// can go in it, the name the next file would take, and whether saving asks for a name.
///
/// A brick is a token, a word, or a separator. Clicking a brick in the box puts it at the end of the tray, and
/// dragging one puts it where it is dropped; bricks in the tray are dragged to reorder them, and dragged back to the
/// box, or closed with their ×, to take them out. A token is in the tray or in the box, never both: while it is in the
/// name, the box keeps its outline. A word is changed by clicking it.
struct FileNameSettings: View {
    @Bindable var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// Where the brick being dragged came from; nil while nothing of this view's is dragged (text dragged in from
    /// another app goes into the name as typed).
    @State private var dragged: BrickSource?
    /// The gap between bricks a drop would land in, while something is dragged over the tray.
    @State private var dropGap: Int?
    /// Where each brick of the tray is, by its place in the pattern, in the tray's coordinates.
    @State private var brickFrames: [Int: CGRect] = [:]
    @State private var boxTargeted = false
    @State private var hoveredBrick: String?
    @State private var editing: WordEdit?
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @State private var editsAsText = false

    private nonisolated static let traySpace = "FileNameTray"
    static let width: CGFloat = 300

    /// Their part of their group's help, which the File name row holds.
    static var help: [HelpTopic] {
        [
            HelpTopic(String(localized: "File name", bundle: .module), Text("A name is built from the bricks in the tray for each capture and each file saved. Click a brick below to add it, or drag it in; drag bricks to reorder them, and drag one back down, or click its ×, to take it out. Click a word to change it. {date} and {time} are when it was taken; {app} is the app in front; {window} is the window’s title, or the front window’s for an area; {counter} is a number that goes up by one with each file saved.", bundle: .module)),
            HelpTopic(String(localized: "Ask for a name when saving", bundle: .module), Text("Save, and saving after a capture, ask for the file’s name first, offering the one above. Return saves; Escape doesn’t save. A save started by a URL command or a shortcut never asks, nor does Save All or a card that saves itself as it closes.", bundle: .module)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editsAsText {
                patternField
            } else {
                tray
            }
            box
            // The time moves on, so the preview is read again every second while the pane is open. It always takes
            // three lines' room, so the rows under it stay put as the name grows and shrinks.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Next: \(preview(at: context.date))", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.width, alignment: .topLeading)
                    .help(preview(at: context.date))
            }
            Toggle(isOn: $settings.asksForFileName) {
                Text("Ask for a name when saving", bundle: .module)
            }
        }
        // A drag that ends anywhere, dropped or not, puts the lifted brick down again.
        .onDragSessionUpdated { session in
            if case .ended = session.phase { endDrag() }
        }
    }

    // MARK: The tray

    private var pieces: [FilenameTemplate.Piece] { settings.fileNameTemplate.pieces }

    private var bricks: [Brick] {
        var seen: [FilenameTemplate.Piece: Int] = [:]
        return pieces.enumerated().map { index, piece in
            let copy = seen[piece, default: 0]
            seen[piece] = copy + 1
            // The same brick keeps its identity as it moves, so it slides to its new place.
            return Brick(id: "\(piece.text)#\(copy)", index: index, piece: piece)
        }
    }

    /// The tray's contents: its bricks, and the word being started where it was dropped.
    private var trayItems: [TrayItem] {
        var items = bricks.map(TrayItem.brick)
        if case .new(let gap) = editing { items.insert(.newWord, at: min(gap, items.count)) }
        return items
    }

    private var tray: some View {
        FlowLayout(spacing: 4) {
            ForEach(trayItems) { item in
                switch item {
                case .brick(let brick): trayBrick(brick)
                case .newWord: wordField
                }
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .frame(minHeight: 36)
        .overlay {
            if pieces.isEmpty, editing == nil {
                Text("Drag bricks here", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if let caret = dropGap.flatMap({ Self.caret(forGap: $0, frames: orderedFrames) }) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: caret.height)
                    .offset(x: caret.minX - 1, y: caret.minY)
                    .allowsHitTesting(false)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropGap != nil ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: dropGap != nil ? 1.5 : (contrast == .increased ? 1 : 0.5))
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named(Self.traySpace))
        .onDrop(of: [.plainText], delegate: TrayDrop(
            gap: { Self.gap(at: $0, frames: orderedFrames) },
            dropGap: $dropGap,
            operation: { dragged.map { if case .tray = $0 { .move } else { .copy } } ?? .copy },
            perform: drop
        ))
        .contextMenu {
            Button { editsAsText = true } label: { Text("Edit as Text", bundle: .module) }
            Button { change { $0 = FilenameTemplate.standard.pieces } } label: { Text("Restore Default", bundle: .module) }
                .disabled(settings.fileNamePattern == FilenameTemplate.standard.pattern)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("File name", bundle: .module))
    }

    /// The frames of the tray's bricks in their order, as far as they are known.
    private var orderedFrames: [CGRect] {
        (0..<pieces.count).compactMap { brickFrames[$0] }
    }

    @ViewBuilder
    private func trayBrick(_ brick: Brick) -> some View {
        if editing == .existing(brick.index) {
            wordField
        } else {
            let lifted = dragged == .tray(brick.index)
            BrickView(piece: brick.piece)
                .opacity(lifted ? 0.3 : 1)
                .overlay(alignment: .topTrailing) {
                    if hoveredBrick == brick.id, dragged == nil {
                        Button { remove(brick.index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color(nsColor: .secondaryLabelColor))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help(Text("Remove", bundle: .module))
                        .transition(.opacity)
                    }
                }
                .onHover { inside in
                    if inside { hoveredBrick = brick.id } else if hoveredBrick == brick.id { hoveredBrick = nil }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.traySpace)) } action: { frame in
                    brickFrames[brick.index] = frame
                }
                .onTapGesture {
                    if case .word(let word) = brick.piece { beginEditing(.existing(brick.index), text: word) }
                }
                .onDrag {
                    commitEdit()
                    hoveredBrick = nil
                    dragged = .tray(brick.index)
                    return NSItemProvider(object: brick.piece.text as NSString)
                }
                .help(tooltip(brick.piece))
                .contextMenu { brickActions(brick) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(brick.piece.spokenName)
                .accessibilityActions { brickActions(brick) }
        }
    }

    @ViewBuilder
    private func brickActions(_ brick: Brick) -> some View {
        if case .word(let word) = brick.piece {
            Button { beginEditing(.existing(brick.index), text: word) } label: { Text("Edit", bundle: .module) }
        }
        Button { move(brick.index, toGap: brick.index - 1) } label: { Text("Move Left", bundle: .module) }
            .disabled(brick.index == 0)
        Button { move(brick.index, toGap: brick.index + 2) } label: { Text("Move Right", bundle: .module) }
            .disabled(brick.index == pieces.count - 1)
        Button { remove(brick.index) } label: { Text("Remove", bundle: .module) }
    }

    /// The word being typed, as a brick that grows with it.
    private var wordField: some View {
        // The text sets the width; spaces in it are drawn as spaces that don't collapse at its end.
        Text(verbatim: draft.isEmpty ? String(localized: "Text", bundle: .module) : draft.replacingOccurrences(of: " ", with: "\u{00A0}"))
            .font(BrickView.font)
            .hidden()
            .padding(.trailing, 2)
            .overlay {
                TextField(text: $draft, prompt: Text("Text", bundle: .module)) { Text("Text", bundle: .module) }
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(BrickView.font)
                    .focused($draftFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .onAppear { Task { draftFocused = true } }
            }
            .modifier(BrickShape(fill: Color.primary.opacity(0.07), stroke: Color.accentColor, lineWidth: 1.5))
            .onChange(of: draftFocused) { _, focused in
                if !focused { commitEdit() }
            }
    }

    private var patternField: some View {
        HStack(spacing: 6) {
            TextField(text: $settings.fileNamePattern, prompt: Text(verbatim: FilenameTemplate.standard.pattern)) {
                Text("File name", bundle: .module)
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit { editsAsText = false }
            Button { editsAsText = false } label: { Text("Done", bundle: .module) }
                .controlSize(.small)
        }
        .frame(width: Self.width)
    }

    // MARK: The box

    private var usedTokens: Set<FilenameTemplate.Token> {
        Set(pieces.compactMap { if case .token(let token) = $0 { token } else { nil } })
    }

    private static let boxSeparators: [Character] = [" ", "-", "_", "."]

    private var box: some View {
        FlowLayout(spacing: 4) {
            ForEach(FilenameTemplate.Token.allCases, id: \.self) { token in
                if usedTokens.contains(token) {
                    // Its place in the box, empty while it is in the name: a click takes it out again.
                    Button { removeAll(token) } label: { BrickView(piece: .token(token), isOutline: true) }
                        .buttonStyle(.plain)
                        .help(Text("Remove \(token.title)", bundle: .module))
                        .accessibilityLabel(Text("Remove \(token.title)", bundle: .module))
                } else {
                    boxBrick(.token(token))
                }
            }
            boxBrick(nil)
            ForEach(Self.boxSeparators, id: \.self) { boxBrick(.separator($0)) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: Self.width, alignment: .leading)
        .background {
            // Somewhere to put a brick back, while one from the tray is dragged over it.
            if boxTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .onDrop(of: [.plainText], delegate: BoxDrop(isTargeted: $boxTargeted, accepts: { isFromTray }) {
            if case .tray(let index) = dragged { remove(index) }
            endDrag()
        })
    }

    private var isFromTray: Bool {
        if case .tray = dragged { true } else { false }
    }

    /// A brick in the box that never runs out: a token not in the name, a separator, or (nil) a new word.
    private func boxBrick(_ piece: FilenameTemplate.Piece?) -> some View {
        let title = piece?.spokenName ?? String(localized: "Text", bundle: .module)
        return Button {
            if let piece { append(piece) } else { beginEditing(.new(pieces.count), text: "") }
        } label: {
            if let piece { BrickView(piece: piece) } else { BrickView.textBrick }
        }
        .buttonStyle(.plain)
        .onDrag {
            commitEdit()
            dragged = piece.map(BrickSource.box) ?? .newWord
            return NSItemProvider(object: (piece?.text ?? "") as NSString)
        }
        .help(piece.map(tooltip) ?? Text("Add \(title)", bundle: .module))
        .accessibilityLabel(Text("Add \(title)", bundle: .module))
    }

    // MARK: Changes

    private func change(_ edit: (inout [FilenameTemplate.Piece]) -> Void) {
        var updated = pieces
        edit(&updated)
        let pattern = FilenameTemplate(pieces: updated).pattern
        guard pattern != settings.fileNamePattern else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            settings.fileNamePattern = pattern
        }
    }

    private func append(_ piece: FilenameTemplate.Piece) {
        change { $0.append(piece) }
    }

    private func remove(_ index: Int) {
        if hoveredBrick != nil { hoveredBrick = nil }
        change { if $0.indices.contains(index) { $0.remove(at: index) } }
    }

    private func removeAll(_ token: FilenameTemplate.Token) {
        change { $0.removeAll { $0 == .token(token) } }
    }

    /// Moves the brick at `index` into the gap before the brick now at `gap` (the end, past the last).
    private func move(_ index: Int, toGap gap: Int) {
        change { pieces in
            guard pieces.indices.contains(index) else { return }
            let gap = max(0, min(gap, pieces.count))
            let piece = pieces.remove(at: index)
            pieces.insert(piece, at: gap > index ? gap - 1 : gap)
        }
    }

    private func drop(at gap: Int, providers: [NSItemProvider]) -> Bool {
        defer { endDrag() }
        switch dragged {
        case .tray(let index):
            move(index, toGap: gap)
        case .box(let piece):
            change { $0.insert(piece, at: min(gap, $0.count)) }
        case .newWord:
            beginEditing(.new(gap), text: "")
        case nil:
            // Text from another app goes in as typed, its tokens as tokens, on one line.
            guard let provider = providers.first else { return false }
            let settings = settings
            let animation: Animation? = reduceMotion ? nil : .snappy(duration: 0.22)
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = (object as? NSString).map({ String($0) }) else { return }
                let line = text.components(separatedBy: .newlines).joined(separator: " ")
                Task { @MainActor in
                    var pieces = settings.fileNameTemplate.pieces
                    pieces.insert(contentsOf: FilenameTemplate.pieces(of: line), at: min(gap, pieces.count))
                    withAnimation(animation) { settings.fileNamePattern = FilenameTemplate(pieces: pieces).pattern }
                }
            }
        }
        return true
    }

    private func endDrag() {
        dragged = nil
        dropGap = nil
        boxTargeted = false
    }

    private func beginEditing(_ edit: WordEdit, text: String) {
        commitEdit()
        draft = text
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { editing = edit }
    }

    /// Puts what was typed into the name: a word, or several bricks if it holds separators or tokens; nothing
    /// typed takes the word out.
    private func commitEdit() {
        guard let edit = editing else { return }
        editing = nil
        let typed = FilenameTemplate.pieces(of: draft)
        change { pieces in
            switch edit {
            case .existing(let index):
                guard pieces.indices.contains(index) else { return }
                pieces.replaceSubrange(index...index, with: typed)
            case .new(let gap):
                pieces.insert(contentsOf: typed, at: min(gap, pieces.count))
            }
        }
    }

    private func cancelEdit() {
        editing = nil
    }

    // MARK: Reading

    /// A brick's tooltip: how it is written, and for a token what it gives now.
    private func tooltip(_ piece: FilenameTemplate.Piece) -> Text {
        guard case .token(let token) = piece else { return Text(piece.spokenName) }
        let sample = FilenameTemplate(pattern: token.placeholder)
            .name(date: .now, appName: "Safari", windowTitle: "Welcome", counter: settings.nextFileNumber)
        return Text(verbatim: "\(token.placeholder) → \(sample)")
    }

    /// The next file as it would be named, for an app and a window made up, since no capture has them yet.
    private func preview(at date: Date) -> String {
        let name = settings.nextFileName(date: date, appName: "Safari", windowTitle: "Welcome")
        return name + "." + settings.screenshotFormat.fileExtension
    }

    // MARK: Geometry

    /// The gap a drop at `point` lands in: before the brick nearest it if the point is on that brick's leading half,
    /// else after it. Rows are found by height first, so a point in the margin of a wrapped row lands in that row.
    static func gap(at point: CGPoint, frames: [CGRect]) -> Int {
        guard !frames.isEmpty else { return 0 }
        func rowDistance(_ frame: CGRect) -> CGFloat {
            point.y < frame.minY ? frame.minY - point.y : max(0, point.y - frame.maxY)
        }
        let nearestRow = frames.map(rowDistance).min() ?? 0
        let row = frames.indices.filter { rowDistance(frames[$0]) <= nearestRow + 0.5 }
        if let next = row.first(where: { frames[$0].midX > point.x }) { return next }
        return (row.last ?? frames.count - 1) + 1
    }

    /// Where the caret for a gap stands: just before the brick after it, or just after the brick before it when the
    /// gap ends a row or the tray.
    static func caret(forGap gap: Int, frames: [CGRect]) -> CGRect? {
        guard !frames.isEmpty else { return nil }
        let before = gap > 0 && gap <= frames.count ? frames[gap - 1] : nil
        let after = gap < frames.count ? frames[gap] : nil
        if let after, before == nil || before!.minY == after.minY {
            let x = before.map { ($0.maxX + after.minX) / 2 } ?? after.minX - 2
            return CGRect(x: x, y: after.minY, width: 0, height: after.height)
        }
        guard let before else { return nil }
        return CGRect(x: before.maxX + 2, y: before.minY, width: 0, height: before.height)
    }
}

// MARK: - Bricks

private enum BrickSource: Equatable {
    case tray(Int)
    case box(FilenameTemplate.Piece)
    case newWord
}

private enum WordEdit: Equatable {
    case existing(Int)
    case new(Int)
}

private struct Brick: Identifiable {
    let id: String
    let index: Int
    let piece: FilenameTemplate.Piece
}

private enum TrayItem: Identifiable {
    case brick(Brick)
    case newWord

    var id: String {
        switch self {
        case .brick(let brick): brick.id
        case .newWord: "\u{0}new"
        }
    }
}

/// A brick: a token tinted with the accent and named with its symbol, a word in plain ink, or a separator, narrower,
/// a space drawn as ␣. An outline is the place a token left in the box.
private struct BrickView: View {
    let piece: FilenameTemplate.Piece
    var isOutline = false

    static let font = Font.callout

    static var textBrick: some View {
        Label {
            Text("Text", bundle: .module)
        } icon: {
            Image(systemName: "character.cursor.ibeam")
                .foregroundStyle(.secondary)
        }
        .labelStyle(BrickLabelStyle())
        .modifier(BrickShape(fill: Color.primary.opacity(0.07), stroke: Color(nsColor: .separatorColor)))
    }

    var body: some View {
        switch piece {
        case .token(let token):
            Label {
                Text(token.title)
            } icon: {
                Image(systemName: token.symbol)
                    .foregroundStyle(isOutline ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            }
            .labelStyle(BrickLabelStyle())
            .foregroundStyle(isOutline ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .modifier(isOutline
                ? BrickShape(fill: .clear, stroke: Color.secondary.opacity(0.5), dash: [3, 2])
                : BrickShape(fill: Color.accentColor.opacity(0.16), stroke: Color.accentColor.opacity(0.45)))
        case .word(let word):
            Text(verbatim: word)
                .font(Self.font)
                .lineLimit(1)
                .modifier(BrickShape(fill: Color.primary.opacity(0.07), stroke: Color(nsColor: .separatorColor)))
        case .separator(let character):
            Text(verbatim: character == " " ? "␣" : String(character))
                .font(Self.font.monospaced())
                .foregroundStyle(character == " " ? .secondary : .primary)
                .frame(minWidth: 10)
                .modifier(BrickShape(fill: Color.primary.opacity(0.04), stroke: Color(nsColor: .separatorColor),
                                     horizontalPadding: 5))
        }
    }
}

private struct BrickLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.caption.weight(.semibold))
            configuration.title.font(BrickView.font)
        }
        .lineLimit(1)
    }
}

/// A brick's capsule, 22 pt tall.
private struct BrickShape: ViewModifier {
    var fill: Color
    var stroke: Color
    var lineWidth: CGFloat = 0.5
    var dash: [CGFloat] = []
    var horizontalPadding: CGFloat = 8
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(height: 22)
            .background(Capsule().fill(fill))
            .overlay {
                Capsule().strokeBorder(stroke, style: StrokeStyle(
                    lineWidth: contrast == .increased ? max(lineWidth, 1) : lineWidth, dash: dash))
            }
            .contentShape(Capsule())
    }
}

/// Lays its views out in rows as wide as it is given, wrapping as text does, each row's views centered on it.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let places = arrange(subviews, width: bounds.width).places
        for (subview, place) in zip(subviews, places) {
            subview.place(at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y), anchor: .leading,
                          proposal: .unspecified)
        }
    }

    /// Each view's leading middle, and the size of the whole.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (places: [CGPoint], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if !rows[rows.count - 1].isEmpty, x + spacing + size.width > width {
                rows.append([])
                x = 0
            }
            x += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(index)
        }
        var places = Array(repeating: CGPoint.zero, count: sizes.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for row in rows where !row.isEmpty {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in row {
                places[index] = CGPoint(x: x, y: y + height / 2)
                x += sizes[index].width + spacing
            }
            widest = max(widest, x - spacing)
            y += height + spacing
        }
        let height = max(0, y - spacing)
        return (places, CGSize(width: width.isFinite ? width : widest, height: height))
    }
}

// MARK: - Dropping

private struct TrayDrop: DropDelegate {
    let gap: (CGPoint) -> Int
    @Binding var dropGap: Int?
    let operation: () -> DropOperation
    let perform: (Int, [NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { dropGap = gap(info.location) }
    func dropExited(info: DropInfo) { dropGap = nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let newGap = gap(info.location)
        if newGap != dropGap { dropGap = newGap }
        return DropProposal(operation: operation())
    }

    func performDrop(info: DropInfo) -> Bool {
        let at = dropGap ?? gap(info.location)
        return perform(at, info.itemProviders(for: [.plainText]))
    }
}

private struct BoxDrop: DropDelegate {
    @Binding var isTargeted: Bool
    let accepts: () -> Bool
    let perform: () -> Void

    func validateDrop(info: DropInfo) -> Bool { accepts() }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        perform()
        return true
    }
}

// MARK: - Names

extension FilenameTemplate.Token {
    /// The token's name on its brick.
    var title: String {
        switch self {
        case .date: String(localized: "Date", bundle: .module)
        case .time: String(localized: "Time", bundle: .module)
        case .app: String(localized: "App", bundle: .module)
        case .window: String(localized: "Window", bundle: .module)
        case .counter: String(localized: "Counter", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .date: "calendar"
        case .time: "clock"
        case .app: "app.dashed"
        case .window: "macwindow"
        case .counter: "number"
        }
    }
}

extension FilenameTemplate.Piece {
    /// What VoiceOver and a tooltip call the brick.
    var spokenName: String {
        switch self {
        case .token(let token): token.title
        case .word(let word): word
        case .separator(" "): String(localized: "Space", bundle: .module)
        case .separator("-"): String(localized: "Hyphen", bundle: .module)
        case .separator("_"): String(localized: "Underscore", bundle: .module)
        case .separator("."): String(localized: "Period", bundle: .module)
        case .separator(let character): String(character)
        }
    }
}
