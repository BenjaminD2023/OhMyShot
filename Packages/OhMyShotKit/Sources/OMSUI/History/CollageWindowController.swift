import AppKit
import CoreGraphics
import Foundation
import Observation
import OMSCore
import OMSDesign
import SwiftUI
import UniformTypeIdentifiers

/// Combine into Collage, from History: the selected screenshots laid out together, reordered or reversed as needed,
/// previewed as the choices change, and copied, saved, or opened in the annotation editor.
public final class CollageWindowController: NSWindowController, NSWindowDelegate {
    /// What the Collage window's output buttons do with the rendered image and its scale.
    public struct Actions {
        /// Renders the collage, keeps it in History, and copies it to the clipboard. Returns true on success.
        public var copy: (CGImage, CGFloat) async -> Bool
        /// Saves the collage directly. Returns true when saved (false if cancelled or failed).
        public var save: (CGImage, CGFloat) async -> Bool
        /// Keeps the collage in History and opens it in the annotation editor.
        public var edit: (CGImage, CGFloat) -> Void

        public init(
            copy: @escaping (CGImage, CGFloat) async -> Bool,
            save: @escaping (CGImage, CGFloat) async -> Bool,
            edit: @escaping (CGImage, CGFloat) -> Void
        ) {
            self.copy = copy
            self.save = save
            self.edit = edit
        }
    }

    public var onClose: (() -> Void)?

    private var windowLease: ActiveResources.Lease?
    private let model: CollageModel

    /// `pictures` in the order they are laid out; `scale` is the pixels per point the collage is made at.
    public init(pictures: [CollageRenderer.Picture], scale: CGFloat, actions: Actions) {
        model = CollageModel(pictures: pictures, scale: scale)
        let window = CollageWindow(
            contentRect: CGRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = String(localized: "Combine into Collage", bundle: .module)
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 740, height: 500)
        window.tabbingMode = .disallowed
        super.init(window: window)
        let model = model
        let controller = NSHostingController(rootView: CollageView(
            model: model,
            onCopy: { [weak self] in
                guard let self, !model.isBusy else { return }
                model.isExporting = true
                Task {
                    defer { model.isExporting = false }
                    guard let image = await model.render() else { return NSSound.beep() }
                    if await actions.copy(image, model.scale) {
                        VoiceOver.announce(String(localized: "Copied", bundle: .module), from: self.window)
                        self.close()
                    }
                }
            },
            onSave: { [weak self] in
                guard let self, !model.isBusy else { return }
                model.isExporting = true
                Task {
                    defer { model.isExporting = false }
                    guard let image = await model.render() else { return NSSound.beep() }
                    if await actions.save(image, model.scale) {
                        self.close()
                    }
                }
            },
            onEdit: { [weak self] in
                guard let self, !model.isBusy else { return }
                model.isExporting = true
                Task {
                    defer { model.isExporting = false }
                    guard let image = await model.render() else { return NSSound.beep() }
                    actions.edit(image, model.scale)
                    self.close()
                }
            },
            cancel: { [weak self] in self?.close() }
        ))
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 880, height: 620))
        window.delegate = self
    }

    /// Convenience initializer when only the open-in-editor flow is provided.
    public convenience init(pictures: [CollageRenderer.Picture], scale: CGFloat, combine: @escaping (CGImage, CGFloat) -> Void) {
        self.init(
            pictures: pictures,
            scale: scale,
            actions: Actions(
                copy: { image, scale in
                    combine(image, scale)
                    return true
                },
                save: { image, scale in
                    combine(image, scale)
                    return true
                },
                edit: combine
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func show() {
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        window?.center()
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    public func windowWillClose(_ notification: Notification) {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }
}

/// Closes on Escape when no control takes it.
private final class CollageWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// The colors a collage can be laid on: five presets or any custom color (sRGB or Display P3).
enum CollageBackground: Equatable, Hashable {
    case white
    case light
    case dark
    case black
    case clear
    case custom(CollageColor)

    static let presets: [CollageBackground] = [.white, .light, .dark, .black, .clear]

    var color: CGColor? {
        switch self {
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .light: CGColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)
        case .dark: CGColor(srgbRed: 0.17, green: 0.18, blue: 0.2, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .clear: nil
        case .custom(let custom): custom.cgColor
        }
    }

    var isCustom: Bool {
        if case .custom = self { true } else { false }
    }

    var kind: CollagePreferences.BackgroundKind {
        switch self {
        case .white: .white
        case .light: .light
        case .dark: .dark
        case .black: .black
        case .clear: .clear
        case .custom: .custom
        }
    }

    var title: String {
        switch self {
        case .white: String(localized: "White", bundle: .module)
        case .light: String(localized: "Light Gray", bundle: .module)
        case .dark: String(localized: "Dark Gray", bundle: .module)
        case .black: String(localized: "Black", bundle: .module)
        case .clear: String(localized: "None", bundle: .module)
        case .custom: String(localized: "Custom Color", bundle: .module)
        }
    }
}

/// Remembered Collage options persisted in `UserDefaults`.
struct CollagePreferences: Codable, Equatable {
    enum BackgroundKind: String, Codable {
        case white, light, dark, black, clear, custom
    }

    var arrangement: CollageLayout.Arrangement?
    var fitting: CollageLayout.Fitting
    var spacing: CGFloat
    var margin: CGFloat
    var cornerRadius: CGFloat
    var gridColumns: Int?
    var backgroundKind: BackgroundKind
    var customColor: CollageColor

    static let defaultsKey = "historyCollagePreferences"
    static let standardCustomColor = CollageColor(red: 0.37, green: 0.61, blue: 0.96, alpha: 1, isDisplayP3: false)
}

@MainActor
@Observable
final class CollageModel {
    struct Entry: Identifiable {
        let id = UUID()
        let picture: CollageRenderer.Picture
        let preview: CollageRenderer.Picture
    }

    private(set) var entries: [Entry]
    private(set) var orderRevision: UInt64 = 0
    let scale: CGFloat
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var hasChosenArrangement = false

    var arrangement: CollageLayout.Arrangement {
        didSet {
            guard isInitialized, arrangement != oldValue else { return }
            hasChosenArrangement = true
            savePreferences()
        }
    }
    var fitting: CollageLayout.Fitting {
        didSet {
            guard isInitialized, fitting != oldValue else { return }
            savePreferences()
        }
    }
    var width: CGFloat
    var spacing: CGFloat {
        didSet {
            guard isInitialized, spacing != oldValue else { return }
            savePreferences()
        }
    }
    var margin: CGFloat {
        didSet {
            guard isInitialized, margin != oldValue else { return }
            savePreferences()
        }
    }
    var cornerRadius: CGFloat {
        didSet {
            guard isInitialized, cornerRadius != oldValue else { return }
            savePreferences()
        }
    }
    /// Explicit grid column count when `arrangement == .grid`; nil uses automatic layout nearest 4:3.
    var gridColumns: Int? {
        didSet {
            guard isInitialized, gridColumns != oldValue else { return }
            savePreferences()
        }
    }
    var customColor: CollageColor {
        didSet {
            guard isInitialized, customColor != oldValue else { return }
            savePreferences()
        }
    }
    var background: CollageBackground {
        didSet {
            guard isInitialized, background != oldValue else { return }
            savePreferences()
        }
    }
    private(set) var preview: CGImage?
    private(set) var isRendering = false
    var isExporting = false
    var isBusy: Bool { isRendering || isExporting }

    static let widthRange: ClosedRange<CGFloat> = CollageLayout.leastWidth...3200

    init(pictures: [CollageRenderer.Picture], scale: CGFloat, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scale = max(scale, 1)
        let saved: CollagePreferences? = defaults.data(forKey: CollagePreferences.defaultsKey)
            .flatMap { try? JSONDecoder().decode(CollagePreferences.self, from: $0) }
        let sizes = pictures.map(\.size)
        let initialArrangement = saved?.arrangement ?? CollageLayout.suggested(for: sizes)
        let initialColumns = saved?.gridColumns.flatMap { $0 >= 1 ? $0 : nil }
        let initialCustom = saved?.customColor ?? CollagePreferences.standardCustomColor
        let initialBackground: CollageBackground = switch saved?.backgroundKind {
        case .white, nil: .white
        case .light: .light
        case .dark: .dark
        case .black: .black
        case .clear: .clear
        case .custom: .custom(initialCustom)
        }
        entries = pictures.map { picture in
            let preview = CollageRenderer.Picture(image: Self.thumbnail(of: picture.image, longest: 700) ?? picture.image, size: picture.size)
            return Entry(picture: picture, preview: preview)
        }
        arrangement = initialArrangement
        fitting = saved?.fitting ?? .fit
        spacing = min(max(saved?.spacing ?? 16, 0), 64)
        margin = min(max(saved?.margin ?? 24, 0), 96)
        cornerRadius = min(max(saved?.cornerRadius ?? 8, 0), 32)
        gridColumns = initialColumns
        customColor = initialCustom
        background = initialBackground
        width = min(
            max(CollageLayout.suggestedWidth(for: sizes, arrangement: initialArrangement, columns: initialColumns), Self.widthRange.lowerBound),
            Self.widthRange.upperBound
        )
        hasChosenArrangement = saved?.arrangement != nil
        isInitialized = true
    }

    var pictures: [CollageRenderer.Picture] { entries.map(\.picture) }
    private var previews: [CollageRenderer.Picture] { entries.map(\.preview) }

    /// The automatic column count for the current pictures.
    var autoColumns: Int { CollageLayout.columns(for: entries.map(\.picture.size)) }

    /// The grid column count actually applied (clamped to the picture count).
    var effectiveGridColumns: Int {
        let limit = max(entries.count, 1)
        return gridColumns.map { min(max($0, 1), limit) } ?? autoColumns
    }

    var options: CollageLayout.Options {
        CollageLayout.Options(
            arrangement: arrangement, width: width, spacing: spacing, margin: margin, fitting: fitting,
            columns: arrangement == .grid ? gridColumns : nil
        )
    }

    var layout: CollageLayout { CollageLayout.layout(entries.map(\.picture.size), options: options) }

    /// Whether the fitting choice changes anything: rows and columns are made of cells of the pictures' shapes.
    var fittingMatters: Bool { arrangement == .grid || arrangement == .featured }

    /// What the collage will be, in pixels.
    var pixelSize: CGSize {
        let size = layout.size
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Reverses the order of the pictures (useful because Capture History lists newest first).
    func reverseOrder() {
        guard entries.count > 1 else { return }
        entries.reverse()
        orderRevision &+= 1
    }

    /// Moves the picture at `index` by `offset` positions (-1 earlier, +1 later).
    func moveEntry(at index: Int, by offset: Int) {
        let target = index + offset
        guard entries.indices.contains(index), entries.indices.contains(target), index != target else { return }
        entries.swapAt(index, target)
        orderRevision &+= 1
    }

    /// Moves `sourceID` to the slot currently occupied by `targetID`.
    func moveEntry(id sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let from = entries.firstIndex(where: { $0.id == sourceID }),
              let to = entries.firstIndex(where: { $0.id == targetID })
        else { return }
        let moved = entries.remove(at: from)
        entries.insert(moved, at: to)
        orderRevision &+= 1
    }

    /// The preview again, about 900 pixels wide, from the small pictures.
    func updatePreview() {
        let layout = layout
        let previewScale = min(900 / max(layout.size.width, 1), 2)
        preview = CollageRenderer.render(
            previews, layout: layout, fitting: fitting, cornerRadius: cornerRadius, background: background.color, scale: previewScale
        )
    }

    /// The collage at full size, made off the main actor.
    func render() async -> CGImage? {
        isRendering = true
        defer { isRendering = false }
        let pictures = pictures, layout = layout, fitting = fitting, radius = cornerRadius, color = background.color, scale = scale
        return await Task.detached(priority: .userInitiated) {
            CollageRenderer.render(pictures, layout: layout, fitting: fitting, cornerRadius: radius, background: color, scale: scale)
        }.value
    }

    private func savePreferences() {
        let preferences = CollagePreferences(
            arrangement: hasChosenArrangement ? arrangement : nil,
            fitting: fitting,
            spacing: spacing,
            margin: margin,
            cornerRadius: cornerRadius,
            gridColumns: gridColumns,
            backgroundKind: background.kind,
            customColor: customColor
        )
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: CollagePreferences.defaultsKey)
        }
    }

    private static func thumbnail(of image: CGImage, longest: Int) -> CGImage? {
        let longestSide = max(image.width, image.height)
        guard longestSide > longest else { return image }
        let factor = CGFloat(longest) / CGFloat(longestSide)
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        let space = image.colorSpace?.isWideGamutRGB == true
            ? (CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB))
            : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

struct CollageView: View {
    @Bindable var model: CollageModel
    let onCopy: () -> Void
    let onSave: () -> Void
    let onEdit: () -> Void
    let cancel: () -> Void

    @State private var selectedEntryID: UUID?
    @State private var draggingEntryID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    previewArea
                    Divider()
                    orderStrip
                }
                Divider()
                controls
                    .frame(width: 320)
            }
            Divider()
            footer
        }
        .task(id: PreviewKey(model)) { model.updatePreview() }
        .onAppear {
            if selectedEntryID == nil { selectedEntryID = model.entries.first?.id }
        }
    }

    private var previewArea: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background(Checkerboard().opacity(model.background == .clear ? 1 : 0))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                    .padding(28)
                    .accessibilityLabel(Text("Collage preview", bundle: .module))
            }
        }
    }

    private var selectedIndex: Int? {
        guard let selectedEntryID else { return nil }
        return model.entries.firstIndex(where: { $0.id == selectedEntryID })
    }

    /// Compact thumbnail strip beneath the preview for dragging, stepping, or reversing picture order.
    private var orderStrip: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        orderThumbnail(entry: entry, index: index)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }

            HStack(spacing: 4) {
                Button {
                    guard let index = selectedIndex, index > 0 else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade)) {
                        model.moveEntry(at: index, by: -1)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedIndex == nil || selectedIndex == 0)
                .help(Text("Move Earlier", bundle: .module))
                .accessibilityLabel(Text("Move Earlier", bundle: .module))

                Button {
                    guard let index = selectedIndex, index < model.entries.count - 1 else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade)) {
                        model.moveEntry(at: index, by: 1)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedIndex == nil || selectedIndex == model.entries.count - 1)
                .help(Text("Move Later", bundle: .module))
                .accessibilityLabel(Text("Move Later", bundle: .module))

                Button {
                    draggingEntryID = nil
                    withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade)) {
                        model.reverseOrder()
                    }
                } label: {
                    Label {
                        Text("Reverse Order", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.entries.count < 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.background)
    }

    private func orderThumbnail(entry: CollageModel.Entry, index: Int) -> some View {
        let isSelected = selectedEntryID == entry.id
        return ZStack(alignment: .topLeading) {
            Color.clear
                .background(.background.secondary)
                .overlay {
                    Image(decorative: entry.preview.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: 48, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-2)
                    }
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture {
            draggingEntryID = nil
            selectedEntryID = entry.id
        }
        .onDrag {
            draggingEntryID = entry.id
            selectedEntryID = entry.id
            return NSItemProvider(object: entry.id.uuidString as NSString)
        }
        .onDrop(of: [.plainText], delegate: ThumbnailReorderDrop(
            targetID: entry.id,
            draggingID: $draggingEntryID,
            move: { sourceID, targetID in
                withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.fade)) {
                    model.moveEntry(id: sourceID, to: targetID)
                }
            }
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Picture \(index + 1) of \(model.entries.count)", bundle: .module))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectedEntryID = entry.id }
        .accessibilityAction(named: Text("Move Earlier", bundle: .module)) {
            if index > 0 { model.moveEntry(at: index, by: -1) }
        }
        .accessibilityAction(named: Text("Move Later", bundle: .module)) {
            if index < model.entries.count - 1 { model.moveEntry(at: index, by: 1) }
        }
    }

    private var controls: some View {
        Form {
            Section {
                Picker(selection: $model.arrangement) {
                    ForEach(CollageLayout.Arrangement.allCases) { arrangement in
                        Text(title(of: arrangement)).tag(arrangement)
                    }
                } label: {
                    Text("Arrangement", bundle: .module)
                }
                if model.arrangement == .grid {
                    LabeledContent {
                        HStack(spacing: 6) {
                            if model.gridColumns == nil {
                                Text("Auto (\(model.autoColumns))", bundle: .module)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: "\(model.effectiveGridColumns)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button {
                                    model.gridColumns = nil
                                } label: {
                                    Text("Auto", bundle: .module)
                                }
                                .buttonStyle(.link)
                                .controlSize(.small)
                            }
                            Stepper(
                                value: Binding(
                                    get: { model.effectiveGridColumns },
                                    set: { model.gridColumns = $0 }
                                ),
                                in: 1...max(model.entries.count, 1)
                            ) {
                                Text("Columns", bundle: .module)
                            }
                            .labelsHidden()
                        }
                    } label: {
                        Text("Columns", bundle: .module)
                    }
                }
                Picker(selection: $model.fitting) {
                    Text("Whole Pictures", bundle: .module).tag(CollageLayout.Fitting.fit)
                    Text("Fill the Cells", bundle: .module).tag(CollageLayout.Fitting.fill)
                } label: {
                    Text("Pictures", bundle: .module)
                }
                .disabled(!model.fittingMatters)
            }
            Section {
                slider(Text("Width", bundle: .module), value: $model.width, in: CollageModel.widthRange, step: 50)
                slider(Text("Spacing", bundle: .module), value: $model.spacing, in: 0...64, step: 2)
                slider(Text("Margin", bundle: .module), value: $model.margin, in: 0...96, step: 2)
                slider(Text("Corners", bundle: .module), value: $model.cornerRadius, in: 0...32, step: 1)
            }
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        ForEach(CollageBackground.presets, id: \.self) { background in
                            swatch(background)
                        }
                    }
                } label: {
                    Text("Background", bundle: .module)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        swatch(.custom(model.customColor))
                        ColorPicker(selection: customColorBinding, supportsOpacity: false) {
                            Text("Custom Color", bundle: .module)
                        }
                        .labelsHidden()
                    }
                } label: {
                    Text("Custom Color", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(sizeDescription)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Spacer()
            Button(role: .cancel, action: cancel) { Text("Cancel", bundle: .module) }
                .keyboardShortcut(.cancelAction)
            Button(action: onEdit) { Text("Open in Editor", bundle: .module) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.isBusy)
            Button(action: onSave) { Text("Save…", bundle: .module) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isBusy)
            Button(action: onCopy) { Text("Copy", bundle: .module) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background)
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(cgColor: model.customColor.cgColor) },
            set: { newValue in
                if let parsed = CollageColor(cgColor: NSColor(newValue).cgColor) {
                    model.customColor = parsed
                    model.background = .custom(parsed)
                }
            }
        )
    }

    private var sizeDescription: String {
        let size = model.pixelSize
        return String(localized: "\(Int(size.width)) × \(Int(size.height)) pixels", bundle: .module)
    }

    /// A slider in steps of `step`, rounded as it moves: a stepped slider would draw a tick at every step.
    private func slider(_ label: Text, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>, step: CGFloat) -> some View {
        let stepped = Binding<CGFloat>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound) }
        )
        return LabeledContent {
            HStack(spacing: 8) {
                Slider(value: stepped, in: range) { label }
                    .labelsHidden()
                Text(String(localized: "\(Int(value.wrappedValue)) pt", bundle: .module))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        } label: {
            label
        }
    }

    private func swatch(_ background: CollageBackground) -> some View {
        let selected = model.background == background
        return Button {
            model.background = background
        } label: {
            ZStack {
                if let color = background.color {
                    Circle().fill(Color(cgColor: color))
                } else {
                    Checkerboard().clipShape(Circle())
                }
                Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1)
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0) }
        }
        .buttonStyle(.plain)
        .help(background.title)
        .accessibilityLabel(background.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func title(of arrangement: CollageLayout.Arrangement) -> String {
        switch arrangement {
        case .row: String(localized: "Side by Side", bundle: .module)
        case .column: String(localized: "One Under Another", bundle: .module)
        case .grid: String(localized: "Grid", bundle: .module)
        case .featured: String(localized: "One Beside the Rest", bundle: .module)
        }
    }
}

/// Live drag-to-reorder delegate for the collage thumbnail strip.
private struct ThumbnailReorderDrop: DropDelegate {
    let targetID: UUID
    @Binding var draggingID: UUID?
    let move: (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingID != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggingID, sourceID != targetID else { return }
        move(sourceID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

/// What the preview is drawn from: it is drawn again when any of it changes.
private struct PreviewKey: Equatable {
    var options: CollageLayout.Options
    var cornerRadius: CGFloat
    var background: CollageBackground
    var orderRevision: UInt64

    @MainActor init(_ model: CollageModel) {
        options = model.options
        cornerRadius = model.cornerRadius
        background = model.background
        orderRevision = model.orderRevision
    }
}

/// Gray and white squares, where a clear background shows through.
private struct Checkerboard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let colors = Theme.Checkerboard.colors(dark: colorScheme == .dark, increasedContrast: contrast == .increased)
        Canvas { context, size in
            let side = Theme.Checkerboard.square
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(cgColor: colors.light)))
            for row in 0..<Int((size.height / side).rounded(.up)) {
                for column in 0..<Int((size.width / side).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)),
                        with: .color(Color(cgColor: colors.dark))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
