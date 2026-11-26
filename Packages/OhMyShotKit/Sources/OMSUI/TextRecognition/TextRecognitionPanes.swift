import AppKit
import Foundation
import OMSCore
import OMSDesign
import OMSOCR
import SwiftUI
// The framework predates strict concurrency; its sessions are handed to the view that asked for them.
@preconcurrency import Translation

/// The image as a picture card (12 pt corners, a hairline, the in-window shadow), fitted to the pane
/// and zoomable/scrollable for tall or high-resolution screenshots, with each line that was read outlined
/// on hover and filled like selected text when its text is selected. Translated, it shows the translation
/// drawn over the text instead, and nothing over it.
struct RecognizedImagePane: View {
    let model: TextRecognitionModel
    @State private var customFactor: CGFloat?
    @State private var gestureStartFactor: CGFloat?
    @State private var selectingArea = false
    @State private var dragStart: CGPoint?
    @State private var selectionRect: CGRect?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            if let original = model.image {
                let translated = model.translatedImage
                let size = CGSize(width: original.width, height: original.height)
                let area = geometry.size
                let actualFactor = 1 / max(model.scale, 1)
                let fitFactor = max(min((area.width - 48) / size.width, (area.height - 48) / size.height, actualFactor), 0.01)
                let minFactor = min(fitFactor, actualFactor * 0.25)
                let maxFactor = max(actualFactor * 4, fitFactor * 8)
                let effectiveFactor = min(max(customFactor ?? fitFactor, minFactor), maxFactor)
                let isFit = customFactor == nil
                let isActual = abs(effectiveFactor - actualFactor) / max(actualFactor, 0.001) < 0.02
                let percent = max(1, Int((effectiveFactor / actualFactor * 100).rounded()))
                // Whole points, so the boxes on it land on whole points too.
                let displayed = CGSize(
                    width: max(1, (size.width * effectiveFactor).rounded(.down)),
                    height: max(1, (size.height * effectiveFactor).rounded(.down))
                )
                let toView = CGAffineTransform(scaleX: displayed.width / size.width, y: displayed.height / size.height)
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)

                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Image(decorative: original, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: displayed.width, height: displayed.height)
                        // The page changing language: the translation fades in over the original.
                        if let translated {
                            Image(decorative: translated, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: displayed.width, height: displayed.height)
                                .transition(.opacity)
                        }
                        if model.phase == .ready, !model.translates, !selectingArea {
                            overlays(toView)
                        }
                        if let selectionRect {
                            selectionOverlay(rect: selectionRect, in: displayed)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: translated != nil)
                    .frame(width: displayed.width, height: displayed.height)
                    .contentShape(Rectangle())
                    .gesture(areaSelectionGesture(displayed: displayed, pixelSize: size))
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(
                            Color(cgColor: Theme.PictureBorder.color(dark: colorScheme == .dark, contrast: contrast == .increased)),
                            lineWidth: Theme.PictureBorder.width(contrast: contrast == .increased)
                        )
                    }
                    .background { shape.fill(.background).shadow(color: .black.opacity(0.12), radius: 10, y: 4) }
                    .contextMenu {
                        if translated != nil {
                            Button { model.copyTranslatedImage() } label: {
                                Text("Copy Translated Image", bundle: .module)
                            }
                            Button { model.saveTranslatedImage() } label: {
                                Text("Save Translated Image…", bundle: .module)
                            }
                            if model.canPinImage {
                                Button { model.pinTranslatedImage() } label: {
                                    Text("Pin Translated Image", bundle: .module)
                                }
                            }
                            Divider()
                        }
                        Button { model.rotateImage(clockwise: false) } label: {
                            Text("Rotate Left (90°)", bundle: .module)
                        }
                        Button { model.rotateImage(clockwise: true) } label: {
                            Text("Rotate Right (90°)", bundle: .module)
                        }
                        if !model.translates {
                            Button { selectingArea.toggle() } label: {
                                selectingArea
                                    ? Text("Cancel Select Area", bundle: .module)
                                    : Text("Select Area", bundle: .module)
                            }
                        }
                        if model.isCropped {
                            Button { model.restoreFullImage() } label: {
                                Text("Full Image", bundle: .module)
                            }
                        }
                        Divider()
                        Button { model.pasteImage() } label: {
                            Text("Paste Image", bundle: .module)
                        }
                    }
                    .padding(24)
                    .frame(minWidth: area.width, minHeight: area.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(translated == nil
                        ? Text("The image being read", bundle: .module)
                        : Text("The image, with the translation over its text", bundle: .module))
                    .accessibilityValue(model.phase == .ready ? Text("\(model.lines.count) lines of text", bundle: .module) : Text(verbatim: ""))
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = gestureStartFactor ?? effectiveFactor
                            if gestureStartFactor == nil { gestureStartFactor = base }
                            customFactor = min(max(base * value.magnification, minFactor), maxFactor)
                        }
                        .onEnded { _ in
                            if let current = customFactor, abs(current - fitFactor) / max(fitFactor, 0.001) < 0.04 {
                                customFactor = nil
                            }
                            gestureStartFactor = nil
                        }
                )
                .overlay(alignment: .bottomLeading) {
                    imageTools
                        .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    zoomControls(
                        percent: percent,
                        isFit: isFit,
                        isActual: isActual,
                        canZoomOut: effectiveFactor > minFactor * 1.02,
                        canZoomIn: effectiveFactor < maxFactor * 0.98,
                        zoomOut: {
                            let next = effectiveFactor / 1.25
                            customFactor = (next <= fitFactor * 1.02 && fitFactor >= minFactor) ? nil : max(next, minFactor)
                        },
                        zoomIn: {
                            customFactor = min(effectiveFactor * 1.25, maxFactor)
                        },
                        zoomFit: {
                            customFactor = nil
                        },
                        zoomActual: {
                            customFactor = abs(actualFactor - fitFactor) / max(actualFactor, 0.001) < 0.02 ? nil : actualFactor
                        }
                    )
                    .padding(12)
                }
            }
        }
        .background(.background.secondary)
        .onChange(of: model.image.map(ObjectIdentifier.init)) { _, _ in
            customFactor = nil
            gestureStartFactor = nil
            selectingArea = false
            dragStart = nil
            selectionRect = nil
        }
    }

    private func areaSelectionGesture(displayed: CGSize, pixelSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard !model.translates else { return }
                if dragStart == nil {
                    guard selectingArea || NSEvent.modifierFlags.contains(.option) else { return }
                    dragStart = Self.clamped(value.startLocation, in: displayed)
                }
                guard let start = dragStart else { return }
                let end = Self.clamped(value.location, in: displayed)
                selectionRect = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )
            }
            .onEnded { _ in
                defer {
                    dragStart = nil
                    selectionRect = nil
                }
                guard let rect = selectionRect, rect.width >= 6, rect.height >= 6 else { return }
                selectingArea = false
                let scaleX = pixelSize.width / max(displayed.width, 1)
                let scaleY = pixelSize.height / max(displayed.height, 1)
                let pixelRect = CGRect(
                    x: rect.minX * scaleX,
                    y: rect.minY * scaleY,
                    width: rect.width * scaleX,
                    height: rect.height * scaleY
                )
                model.cropImage(to: pixelRect)
            }
    }

    private static func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }

    @ViewBuilder
    private func selectionOverlay(rect: CGRect, in size: CGSize) -> some View {
        let lineWidth: CGFloat = contrast == .increased ? 2 : 1.5
        ZStack(alignment: .topLeading) {
            // Subtle dim outside the selection so the chosen crop area stands out clearly.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(contrast == .increased ? 0.45 : 0.26), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: lineWidth + 1.5)
                .frame(width: max(rect.width, 2), height: max(rect.height, 2))
                .offset(x: rect.minX, y: rect.minY)
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: lineWidth)
                .frame(width: max(rect.width, 2), height: max(rect.height, 2))
                .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }

    private var imageTools: some View {
        HStack(spacing: 4) {
            Button {
                model.rotateImage(clockwise: false)
            } label: {
                Image(systemName: "rotate.left")
                    .frame(width: 20, height: 20)
            }
            .disabled(model.phase == .loading)
            .accessibilityLabel(Text("Rotate Left", bundle: .module))
            .help(Text("Rotate 90° counterclockwise and re-recognize", bundle: .module))

            Button {
                model.rotateImage(clockwise: true)
            } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 20, height: 20)
            }
            .disabled(model.phase == .loading)
            .accessibilityLabel(Text("Rotate Right", bundle: .module))
            .help(Text("Rotate 90° clockwise and re-recognize", bundle: .module))

            if !model.translates {
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)

                Button {
                    selectingArea.toggle()
                } label: {
                    Image(systemName: "crop")
                        .foregroundStyle(selectingArea ? Color.accentColor : Color.primary)
                        .frame(width: 20, height: 20)
                }
                .disabled(model.phase == .loading)
                .accessibilityLabel(Text("Select Area", bundle: .module))
                .accessibilityValue(selectingArea ? Text("On", bundle: .module) : Text("Off", bundle: .module))
                .help(Text("Drag over part of the image to recognize only that area (or Option-drag)", bundle: .module))
            }

            if model.isCropped {
                Button {
                    model.restoreFullImage()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Full Image", bundle: .module)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .frame(minHeight: 20)
                }
                .accessibilityLabel(Text("Full Image", bundle: .module))
                .help(Text("Restore the full image and re-recognize", bundle: .module))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay {
            Capsule().strokeBorder(
                Color(cgColor: Theme.PictureBorder.color(dark: colorScheme == .dark, contrast: contrast == .increased)),
                lineWidth: Theme.PictureBorder.width(contrast: contrast == .increased)
            )
        }
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }

    private func zoomControls(
        percent: Int,
        isFit: Bool,
        isActual: Bool,
        canZoomOut: Bool,
        canZoomIn: Bool,
        zoomOut: @escaping () -> Void,
        zoomIn: @escaping () -> Void,
        zoomFit: @escaping () -> Void,
        zoomActual: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: zoomOut) {
                Image(systemName: "minus")
                    .frame(width: 20, height: 20)
            }
            .disabled(!canZoomOut)
            .keyboardShortcut("-", modifiers: .command)
            .accessibilityLabel(Text("Zoom Out", bundle: .module))
            .help(Text("Zoom Out (⌘-)", bundle: .module))

            Button(action: isFit ? zoomActual : zoomFit) {
                Text(verbatim: isFit ? String(localized: "Fit", bundle: .module) : "\(percent)%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38, minHeight: 20)
            }
            .keyboardShortcut("0", modifiers: .command)
            .accessibilityLabel(isFit ? Text("Actual Size", bundle: .module) : Text("Zoom to Fit", bundle: .module))
            .help(isFit ? Text("Actual Size (100%)", bundle: .module) : Text("Zoom to Fit (⌘0)", bundle: .module))

            if !isActual {
                Button(action: zoomActual) {
                    Text(verbatim: "100%")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 4)
                        .frame(minHeight: 20)
                }
                .accessibilityLabel(Text("Actual Size", bundle: .module))
                .help(Text("Show image at actual size", bundle: .module))
            }

            Button(action: zoomIn) {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .disabled(!canZoomIn)
            .keyboardShortcut("+", modifiers: .command)
            .accessibilityLabel(Text("Zoom In", bundle: .module))
            .help(Text("Zoom In (⌘+)", bundle: .module))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay {
            Capsule().strokeBorder(
                Color(cgColor: Theme.PictureBorder.color(dark: colorScheme == .dark, contrast: contrast == .increased)),
                lineWidth: Theme.PictureBorder.width(contrast: contrast == .increased)
            )
        }
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }

    /// Lines in the text pane (once the text is edited they no longer match, so they stop reacting) and
    /// codes, which light up while hovered here or in the Found list.
    @ViewBuilder private func overlays(_ toView: CGAffineTransform) -> some View {
        // Snapshots: the closures below run lazily, after a new image may have emptied the model's arrays.
        let lines = model.lines
        let codes = model.codes
        // The cloud model's text has no boxes on the picture.
        if model.pane == .text, model.source == .device {
            let selected = model.selectedLines
            let linked = !model.edited
            ForEach(lines.indices, id: \.self) { index in
                LineBox(
                    rect: lines[index].box.applying(toView).integral,
                    isSelected: selected.contains(index),
                    isHovered: linked && model.hoveredLine == index,
                    isActive: model.editorIsActive
                )
                .onHover { inside in
                    if inside { model.hoveredLine = index } else if model.hoveredLine == index { model.hoveredLine = nil }
                }
                .onTapGesture { model.selectLine(index) }
            }
        }
        ForEach(codes.indices, id: \.self) { index in
            LineBox(rect: codes[index].box.applying(toView).integral, isSelected: false, isHovered: model.hoveredCode == index, isActive: true)
                .onHover { inside in
                    if inside { model.hoveredCode = index } else if model.hoveredCode == index { model.hoveredCode = nil }
                }
        }
    }
}

/// A region read from the image, drawn like selected text (DESIGN.md › Text Selection): the selection
/// color at 0.35 (0.45 in Dark) edged with a 1 pt accent line, 2 pt under Increase Contrast. Hovered,
/// it is only outlined: the accent never fills behind text. When the editor is not active, the box
/// takes the inactive selection color, as the text does.
struct LineBox: View {
    let rect: CGRect
    let isSelected: Bool
    let isHovered: Bool
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let selection = Color(nsColor: isActive ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
        Rectangle()
            .fill(isSelected ? selection.opacity(colorScheme == .dark ? 0.45 : 0.35) : Color.clear)
            .overlay {
                if isSelected || isHovered {
                    Rectangle().strokeBorder(isActive || isHovered ? Color.accentColor : Color.secondary, lineWidth: contrast == .increased ? 2 : 1)
                }
            }
            .frame(width: max(rect.width, 2), height: max(rect.height, 2))
            .contentShape(Rectangle())
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// The right side: the text (or a table), then what can be acted on.
struct TextPane: View {
    @Bindable var model: TextRecognitionModel

    var body: some View {
        phaseContent
            .background(.background)
    }

    @ViewBuilder private var phaseContent: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Recognizing text…", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.readsInCloud, let cloud = model.cloudModel {
                    CloudStatus(model: model, cloud: cloud)
                }
            case .empty:
                if let counts = model.beingRead {
                    // No text, but formulas or tables: the text is what they read as.
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        ElementsReading(counts: counts)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let cloud = model.cloudModel {
                    // Handwriting and faint text are what a cloud model may still read.
                    CloudEmptyState(model: model, cloud: cloud)
                } else {
                    PanelPlaceholder(
                        symbol: "text.magnifyingglass",
                        title: Text("No text found", bundle: .module),
                        message: Text("Try an image with larger text or more contrast.", bundle: .module)
                    )
                }
            case .failed(let title, let message, let canRetry):
                PanelPlaceholder(symbol: "exclamationmark.triangle", title: Text(verbatim: title), message: Text(verbatim: message)) {
                    if canRetry {
                        Button { model.retry() } label: { Text("Try Again", bundle: .module) }
                            .padding(.top, 6)
                    }
                }
                if model.readsInCloud, let cloud = model.cloudModel {
                    CloudStatus(model: model, cloud: cloud)
                }
            case .ready:
                if model.translates {
                    TranslationPane(model: model)
                } else if model.pane == .table, let table = model.currentTable {
                    TablePreview(model: model, table: table)
                } else {
                    RecognizedTextEditor(model: model)
                    if model.edited {
                        EditedNotice(model: model)
                    }
                    if let counts = model.beingRead, model.source == .device {
                        FormulaNotice(counts: counts)
                    }
                }
                if model.readsInCloud, let cloud = model.cloudModel {
                    CloudStatus(model: model, cloud: cloud)
                }
                if !model.items.isEmpty || !model.codes.isEmpty || !model.formulas.isEmpty {
                    Divider()
                    FoundList(model: model)
                }
            }
        }
    }
}

/// The panel's empty, failed, and translation states, as in Capture History: a 40 pt light tertiary
/// symbol, a title3 title, a callout message at most 360 pt wide, then any actions.
struct PanelPlaceholder<Actions: View>: View {
    let symbol: String
    let title: Text
    let message: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            message
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PanelPlaceholder where Actions == EmptyView {
    init(symbol: String, title: Text, message: Text) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// The translated text and where it came from, or why there is none: translating, nothing to
/// translate, a language still to download, or a failure.
struct TranslationPane: View {
    @Bindable var model: TextRecognitionModel

    var body: some View {
        VStack(spacing: 0) {
            if model.translationFailed {
                PanelPlaceholder(
                    symbol: "exclamationmark.triangle",
                    title: Text("Couldn’t translate", bundle: .module),
                    message: Text("Translation isn’t available right now.", bundle: .module)
                ) {
                    Button { model.translate() } label: { Text("Try Again", bundle: .module) }
                        .padding(.top, 6)
                }
            } else if let translation = model.translation {
                if !translation.outcome.translations.isEmpty {
                    TranslatedTextView(
                        text: translation.text, translated: translation.translated,
                        language: Translator.identifier(of: translation.outcome.target), wrapsText: model.wrapsText
                    )
                    TranslationStatus(model: model)
                } else if let language = translation.outcome.needsDownload.first {
                    // The pair is what is missing; the system's sheet names the languages it downloads.
                    PanelPlaceholder(
                        symbol: "arrow.down.circle",
                        title: Text("Translating into \(Translator.name(of: translation.outcome.target)) needs a download", bundle: .module),
                        message: Text("Languages are downloaded once. After that, translation runs on this Mac without a connection.", bundle: .module)
                    ) {
                        Button { model.requestDownload(language) } label: { Text("Download…", bundle: .module) }
                            .padding(.top, 6)
                    }
                } else {
                    nothing(translation)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Translating…", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The system's sheet for a download, asked for by a Download button in this window.
        .translationTask(model.download) { session in
            await model.prepare(session)
        }
    }

    enum EmptyReason: Equatable {
        case unsupported(Locale.Language)
        case alreadyInTarget
        case code
        case formula
        case table
        case vertical
        case other
    }

    static func emptyReason(for translation: TextRecognitionModel.Translation) -> EmptyReason {
        let outcome = translation.outcome
        if let language = outcome.unsupported.first { return .unsupported(language) }
        if !outcome.inTarget.isEmpty { return .alreadyInTarget }
        if !translation.units.isEmpty, translation.units.allSatisfy({ $0.skip != nil }) {
            let skips = Set(translation.units.compactMap(\.skip))
            if skips == [.code] { return .code }
            if skips.contains(.formula), skips.isSubset(of: [.formula, .figures]) { return .formula }
            if skips.contains(.table), skips.isSubset(of: [.table, .figures]) { return .table }
            if skips.contains(.vertical), skips.isSubset(of: [.vertical, .figures]) { return .vertical }
        }
        return .other
    }

    @ViewBuilder private func nothing(_ translation: TextRecognitionModel.Translation) -> some View {
        let target = Translator.name(of: translation.outcome.target)
        switch Self.emptyReason(for: translation) {
        case .unsupported(let language):
            PanelPlaceholder(
                symbol: "character.bubble",
                title: Text("\(Translator.name(of: language)) can’t be translated into \(target)", bundle: .module),
                message: Text("Choose another language in the toolbar.", bundle: .module)
            )
        case .alreadyInTarget:
            PanelPlaceholder(
                symbol: "checkmark.circle",
                title: Text("Already in \(target)", bundle: .module),
                message: Text("Choose another language in the toolbar to translate into.", bundle: .module)
            )
        case .code:
            PanelPlaceholder(
                symbol: "chevron.left.forwardslash.chevron.right",
                title: Text("Code isn’t translated", bundle: .module),
                message: Text("Code stays exactly as it was read.", bundle: .module)
            )
        case .formula:
            PanelPlaceholder(
                symbol: "function",
                title: Text("Formulas aren’t translated", bundle: .module),
                message: Text("Mathematical notation stays as it was read.", bundle: .module)
            )
        case .table:
            PanelPlaceholder(
                symbol: "tablecells",
                title: Text("Tables aren’t translated in place", bundle: .module),
                message: Text("Turn off Translate to view or copy the table.", bundle: .module)
            )
        case .vertical:
            PanelPlaceholder(
                symbol: "arrow.up.and.down",
                title: Text("Vertical text isn’t translated", bundle: .module),
                message: Text("Vertical lines stay as they were read.", bundle: .module)
            )
        case .other:
            PanelPlaceholder(
                symbol: "text.magnifyingglass",
                title: Text("Nothing to translate", bundle: .module),
                message: Text("Links, numbers, code, and formulas stay as they are.", bundle: .module)
            )
        }
    }
}

/// Under the translation: the languages it went between, and a language still to download.
struct TranslationStatus: View {
    let model: TextRecognitionModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let summary = model.translationSummary {
                    Text(verbatim: summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(verbatim: model.spokenTranslationSummary ?? summary))
                }
                if model.translation?.isTextOnly == true {
                    Text("Text-only translation", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let language = model.translation?.outcome.needsDownload.first {
                    Button { model.requestDownload(language) } label: {
                        Text("Download Languages…", bundle: .module)
                    }
                    .controlSize(.small)
                    .help(Text("Text in \(Translator.name(of: language)) is shown as read until its languages are downloaded", bundle: .module))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

/// Once the text is edited, lines on the image no longer select it; this says so and offers the text as
/// read again.
struct EditedNotice: View {
    let model: TextRecognitionModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text("Edited, no longer linked to the image", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { model.revert() } label: { Text("Revert", bundle: .module) }
                    .controlSize(.small)
                    .help(Text("Replace your edits with the text as read (⌘Z undoes it)", bundle: .module))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

/// Under the text while the formulas found in the image are read: each comes into the text as LaTeX once read.
struct FormulaNotice: View {
    let counts: TextRecognitionWindowController.Elements.Counts

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                ElementsReading(counts: counts)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

/// What the packs are reading, under the text or in its place.
struct ElementsReading: View {
    let counts: TextRecognitionWindowController.Elements.Counts

    var body: some View {
        Group {
            if counts.tables == 0 {
                Text("Reading formulas…", bundle: .module)
            } else if counts.formulas == 0 {
                Text("Reading tables…", bundle: .module)
            } else {
                Text("Reading formulas and tables…", bundle: .module)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
