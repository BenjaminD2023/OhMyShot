import OMSCore
import OMSDesign
import OMSOCR
import SwiftUI
// The framework predates strict concurrency; its sessions are handed to the view that asked for them.
@preconcurrency import Translation

/// The image as a picture card (12 pt corners, a hairline, the in-window shadow), fitted to the pane
/// and never drawn larger than it appeared on screen, with each line that was read outlined on hover
/// and filled like selected text when its text is selected. Translated, it shows the translation drawn
/// over the text instead, and nothing over it.
struct RecognizedImagePane: View {
    let model: TextRecognitionModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let original = model.image {
                let translated = model.translates ? model.translation?.image : nil
                let image = original
                let size = CGSize(width: image.width, height: image.height)
                let area = geometry.size
                let factor = max(min((area.width - 48) / size.width, (area.height - 48) / size.height, 1 / model.scale), 0.01)
                // Whole points, so the boxes on it land on whole points too.
                let fitted = CGSize(width: max(1, (size.width * factor).rounded(.down)), height: max(1, (size.height * factor).rounded(.down)))
                let toView = CGAffineTransform(scaleX: fitted.width / size.width, y: fitted.height / size.height)
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                    // The page changing language: the translation fades in over the original.
                    if let translated {
                        Image(decorative: translated, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width, height: fitted.height)
                            .transition(.opacity)
                    }
                    if model.phase == .ready, !model.translates {
                        overlays(toView)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: translated != nil)
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(
                        Color(cgColor: Theme.PictureBorder.color(dark: colorScheme == .dark, contrast: contrast == .increased)),
                        lineWidth: Theme.PictureBorder.width(contrast: contrast == .increased)
                    )
                }
                .background { shape.fill(.background).shadow(color: .black.opacity(0.12), radius: 10, y: 4) }
                .offset(x: ((area.width - fitted.width) / 2).rounded(), y: ((area.height - fitted.height) / 2).rounded())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(translated == nil
                    ? Text("The image being read", bundle: .module)
                    : Text("The image, with the translation over its text", bundle: .module))
                .accessibilityValue(model.phase == .ready ? Text("\(model.lines.count) lines of text", bundle: .module) : Text(verbatim: ""))
            }
        }
        .background(.background.secondary)
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
                if !model.items.isEmpty || !model.codes.isEmpty {
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

    @ViewBuilder private func nothing(_ translation: TextRecognitionModel.Translation) -> some View {
        let outcome = translation.outcome
        let target = Translator.name(of: outcome.target)
        if let language = outcome.unsupported.first {
            PanelPlaceholder(
                symbol: "character.bubble",
                title: Text("\(Translator.name(of: language)) can’t be translated into \(target)", bundle: .module),
                message: Text("Choose another language in the toolbar.", bundle: .module)
            )
        } else if !outcome.inTarget.isEmpty {
            PanelPlaceholder(
                symbol: "checkmark.circle",
                title: Text("Already in \(target)", bundle: .module),
                message: Text("Choose another language in the toolbar to translate into.", bundle: .module)
            )
        } else if !translation.units.isEmpty, translation.units.allSatisfy({ $0.skip == .code }) {
            PanelPlaceholder(
                symbol: "chevron.left.forwardslash.chevron.right",
                title: Text("Code isn’t translated", bundle: .module),
                message: Text("Code stays exactly as it was read.", bundle: .module)
            )
        } else {
            PanelPlaceholder(
                symbol: "text.magnifyingglass",
                title: Text("Nothing to translate", bundle: .module),
                message: Text("Links, numbers, and code stay as they are.", bundle: .module)
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
