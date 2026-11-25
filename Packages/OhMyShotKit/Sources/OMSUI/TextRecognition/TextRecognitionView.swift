import AppKit
import Foundation
import OMSCore
import OMSDesign
import OMSOCR
import SwiftUI
import UniformTypeIdentifiers

struct TextRecognitionView: View {
    @Bindable var model: TextRecognitionModel
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.image == nil {
                // Nothing to show on the left (a file that is no image): the message takes the window.
                TextPane(model: model)
            } else {
                HSplitView {
                    RecognizedImagePane(model: model)
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    TextPane(model: model)
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 560, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .toolbar { toolbar }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let model = model
        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = if let data = item as? Data {
                    URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    direct
                } else if let nsurl = item as? NSURL {
                    nsurl as URL
                } else {
                    nil
                }
                guard let url else { return }
                Task { @MainActor in
                    _ = model.openDroppedFile(at: url)
                }
            }
            return true
        }
        if let imageProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            let source = String(localized: "Dropped Image", bundle: .module)
            imageProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    model.openDroppedImageData(data, source: source)
                }
            }
            return true
        }
        return false
    }

    /// The text side's controls, together over it: what to show, how lines break (text only), Translate
    /// and the language it goes into, and one Copy that is always last.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                if !model.pasteImage() {
                    NSSound.beep()
                }
            } label: {
                Label {
                    Text("Paste Image", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
                .labelStyle(.iconOnly)
            }
            .help(Text("Paste an image from the clipboard to recognize its text", bundle: .module))
        }
        let panes = model.panes
        if !panes.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Picker(selection: $model.pane) {
                    ForEach(panes, id: \.self) { pane in
                        switch pane {
                        case .text: Text("Text", bundle: .module).tag(pane)
                        case .table: Text("Table", bundle: .module).tag(pane)
                        }
                    }
                } label: {
                    Text("Show", bundle: .module)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(Text("Show the text, or the table found in the image", bundle: .module))
            }
        }
        if model.phase == .ready, model.pane == .text, !model.translates, model.source == .device {
            ToolbarItem(placement: .primaryAction) {
                // Code always keeps its line breaks, whatever was chosen for the last image.
                Picker(selection: Binding(get: { model.joinLines && !model.isCode }, set: { model.joinLines = $0 })) {
                    Text("Keep Line Breaks", bundle: .module).tag(false)
                    Text("Join Lines", bundle: .module).tag(true)
                } label: {
                    Text("Line Breaks", bundle: .module)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(model.isCode
                    ? Text("Code keeps its line breaks", bundle: .module)
                    : Text("Keep the lines as they are in the image, or join the lines of each paragraph", bundle: .module))
                .disabled(model.isCode)
            }
        }
        // Modes, not actions: the symbols alone, so Copy stays the one titled, filled control.
        ToolbarItemGroup(placement: .primaryAction) {
            if model.phase == .ready, model.pane == .text || model.translates {
                Toggle(isOn: $model.wrapsText) {
                    Label {
                        Text("Wrap Text", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.turn.down.left")
                    }
                    .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .help(Text("Wrap long lines in this window without changing the text you copy", bundle: .module))
            }
            if let cloud = model.cloudModel {
                CloudToggle(model: model, cloud: cloud)
            }
            Toggle(isOn: $model.translates) {
                Label {
                    Text("Translate", bundle: .module)
                } icon: {
                    Image(systemName: "translate")
                }
                .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.phase != .ready && model.phase != .loading)
            .help(model.translates
                ? Text("Show the text as read (⇧⌘T)", bundle: .module)
                : Text("Translate the text, and show the translation in the image (⇧⌘T)", bundle: .module))
            if model.translates, model.phase == .ready {
                // A short label that never changes under the pointer; the menu names what Automatic chose.
                Menu {
                    TranslationTargetPicker(selection: $model.translationChoice, targets: model.targets) {
                        automaticTarget
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    model.translationLanguage.map { Text(verbatim: Translator.name(of: $0)) } ?? Text("Automatic", bundle: .module)
                }
                .fixedSize()
                .help(Text("The language to translate into", bundle: .module))
                .accessibilityLabel(Text("Translate Into", bundle: .module))
                if model.translatedImage != nil {
                    Menu {
                        Button { model.copyTranslatedImage() } label: {
                            Label { Text("Copy Translated Image", bundle: .module) } icon: { Image(systemName: "doc.on.doc") }
                        }
                        Button { model.saveTranslatedImage() } label: {
                            Label { Text("Save Translated Image…", bundle: .module) } icon: { Image(systemName: "square.and.arrow.down") }
                        }
                        if model.canPinImage {
                            Button { model.pinTranslatedImage() } label: {
                                Label { Text("Pin Translated Image", bundle: .module) } icon: { Image(systemName: "pin") }
                            }
                        }
                    } label: {
                        Label {
                            Text("Translated Image", bundle: .module)
                        } icon: {
                            Image(systemName: "photo")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .help(Text("Copy, save, or pin the translated image", bundle: .module))
                }
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            copyControl
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canCopy)
        }
    }

    /// Automatic, with the language it chose once there is a translation.
    private var automaticTarget: Text {
        if let translation = model.translation, translation.choice.isEmpty {
            Text("Automatic: \(Translator.name(of: translation.outcome.target))", bundle: .module)
        } else {
            Text("Automatic", bundle: .module)
        }
    }

    private var copyLabel: some View {
        Label {
            model.copied ? Text("Copied", bundle: .module) : Text("Copy", bundle: .module)
        } icon: {
            Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
        }
        .labelStyle(.titleAndIcon)
    }

    /// One prominent Copy for every pane; the table's other formats sit with the table.
    private var copyControl: some View {
        Button {
            model.copyShown()
        } label: {
            copyLabel
        }
        .buttonStyle(.glassProminent)
        .help(copyHelp)
    }

    private var copyHelp: Text {
        if model.translates {
            Text("Copy the translation (⇧⌘C)", bundle: .module)
        } else if model.pane == .table {
            Text("Copy the table; it pastes into Numbers and Excel as cells (⇧⌘C)", bundle: .module)
        } else {
            Text("Copy all the text (⇧⌘C)", bundle: .module)
        }
    }
}
