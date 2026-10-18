import AppKit
import OMSCore
import SwiftUI

/// Settings › Tools › Cloud models: the models at services the person has an account with, which the OCR panel's
/// Read with… sends a picture to. Nothing is sent from here but Test's own small picture.
struct CloudModelsRow: View {
    let store: CloudModelStore
    @State private var editing: CloudModelDraft?
    @State private var removing: CloudModel?

    var body: some View {
        SettingsRow(Text("Cloud models", bundle: .module)) {
            VStack(alignment: .leading, spacing: 10) {
                if store.models.isEmpty {
                    Text("No cloud models", bundle: .module)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider() }
                            CloudModelRow(
                                model: model,
                                edit: { editing = CloudModelDraft(model: model, hasKey: store.hasKey(model)) },
                                remove: { removing = model }
                            )
                        }
                    }
                    .frame(width: 360)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                }
                HStack(spacing: 6) {
                    Menu {
                        ForEach(CloudModel.Preset.allCases.filter { $0 != .other }) { preset in
                            Button { editing = CloudModelDraft(preset: preset) } label: { Text("\(preset.title)…", bundle: .module) }
                        }
                        Divider()
                        Button { editing = CloudModelDraft(preset: .other) } label: { Text("\(CloudModel.Preset.other.title)…", bundle: .module) }
                    } label: {
                        Label { Text("Add Model", bundle: .module) } icon: { Image(systemName: "plus") }
                    }
                    .fixedSize()
                    InfoButton(Text("Read a picture with a model you have an account with, such as Claude, GPT, or Qwen, where this Mac reads it poorly: handwriting, dense tables, complex layouts. Nothing is sent until you choose Read with… in the Recognized Text window; then the picture goes from this Mac straight to the service, which may charge for it. Keys stay in the Keychain.", bundle: .module))
                }
            }
        }
        .sheet(item: $editing) { draft in
            CloudModelEditor(initial: draft, store: store) { editing = nil }
                .id(draft.id)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenCloudModelEditor)) { note in
            if let name = note.userInfo?["name"] as? String, let model = store.models.first(where: { $0.name == name }) {
                editing = CloudModelDraft(model: model, hasKey: store.hasKey(model))
            } else if let preset = (note.userInfo?["preset"] as? String).flatMap(CloudModel.Preset.init(rawValue:)) {
                editing = CloudModelDraft(preset: preset)
            } else {
                editing = nil
            }
        }
        #endif
        .confirmationDialog(
            removing.map { Text("Remove “\($0.name)”?", bundle: .module) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { model in
            Button(role: .destructive) {
                store.remove(id: model.id)
            } label: {
                Text("Remove", bundle: .module)
            }
        } message: { _ in
            Text("Its API key is deleted from the Keychain.", bundle: .module)
        }
    }
}

/// One model in the list: its name, the model it reads with and where, Edit…, and More.
private struct CloudModelRow: View {
    let model: CloudModel
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isLocal ? "desktopcomputer" : "cloud")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(verbatim: "\(model.model) · \(model.host ?? model.address)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: edit) { Text("Edit…", bundle: .module) }
                .controlSize(.small)
            Menu {
                Button(role: .destructive, action: remove) { Text("Remove…", bundle: .module) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(Text("More", bundle: .module))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

/// What the editor holds: the model as typed, and a key typed over the saved one.
struct CloudModelDraft: Identifiable, Equatable {
    var id: UUID { model.id }
    var model: CloudModel
    var key = ""
    /// Whether the Keychain holds a key for it.
    let hasKey: Bool
    /// Whether it is a new model, from a preset.
    let isNew: Bool

    init(model: CloudModel, hasKey: Bool) {
        self.model = model
        self.hasKey = hasKey
        isNew = false
    }

    init(preset: CloudModel.Preset) {
        model = preset.makeModel()
        hasKey = false
        isNew = true
    }

    var issue: String? {
        model.issue(hasKey: hasKey || !key.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

/// The sheet that adds or changes a model: its name, protocol, address, model, and key, and a Test that reads a small
/// picture of known words with it.
private struct CloudModelEditor: View {
    @State var draft: CloudModelDraft
    let store: CloudModelStore
    let close: () -> Void
    @State private var problem: String?
    @State private var test = TestState.idle
    @State private var testTask: Task<Void, Never>?

    init(initial: CloudModelDraft, store: CloudModelStore, close: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.store = store
        self.close = close
    }

    enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.isNew ? String(localized: "Add Cloud Model", bundle: .module) : draft.model.name)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            SettingsPane(spacing: 10) {
                EditorRow(Text("Name", bundle: .module), info: Text("What the Recognized Text window’s button calls it: Read with Claude.", bundle: .module)) {
                    TextField(text: $draft.model.name, prompt: Text("Required", bundle: .module)) { Text("Name", bundle: .module) }
                        .labelsHidden()
                }
                EditorRow(
                    Text("Protocol", bundle: .module),
                    info: Text("How the service is spoken to. Most services, and Ollama and LM Studio on this Mac, take OpenAI’s Chat Completions; Claude takes Anthropic’s Messages.", bundle: .module),
                    fills: false
                ) {
                    Picker(selection: $draft.model.kind) {
                        Text("OpenAI-compatible", bundle: .module).tag(CloudModel.Kind.openAICompatible)
                        Text("Anthropic", bundle: .module).tag(CloudModel.Kind.anthropic)
                    } label: {
                        Text("Protocol", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                EditorRow(
                    Text("Base URL", bundle: .module),
                    info: Text("The service’s address with its version, as its documentation gives it, such as https://api.openai.com/v1. Plain http:// works only on this Mac or your local network.", bundle: .module)
                ) {
                    TextField(text: $draft.model.address, prompt: Text(verbatim: draft.model.kind == .anthropic ? "https://api.anthropic.com" : "https://api.example.com/v1")) { Text("Base URL", bundle: .module) }
                        .labelsHidden()
                }
                EditorRow(
                    Text("Model", bundle: .module),
                    info: Text("The name of a model that reads pictures, as the service lists it.", bundle: .module)
                ) {
                    TextField(text: $draft.model.model, prompt: Text("Required", bundle: .module)) { Text("Model", bundle: .module) }
                        .labelsHidden()
                }
                EditorRow(Text("API key", bundle: .module), fills: false) {
                    SecretInput(
                        text: $draft.key, isStored: draft.hasKey, label: Text("API key", bundle: .module),
                        isOptional: !draft.model.needsKey
                    )
                }
                SettingsDivider()
                EditorRow(Text("Test", bundle: .module), fills: false) { testRow }
            }
            Divider()
            HStack {
                if let problem {
                    Label { Text(problem) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(role: .cancel, action: close) { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                Button(action: save) { Text("Save", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: paneWidth)
        .onDisappear { testTask?.cancel() }
        .onChange(of: draft) {
            problem = nil
            if test != .running { test = .idle }
        }
    }

    private func save() {
        if let issue = draft.issue {
            problem = issue
            return
        }
        do {
            var model = draft.model
            model.name = model.name.trimmingCharacters(in: .whitespaces)
            model.address = model.address.trimmingCharacters(in: .whitespacesAndNewlines)
            model.model = model.model.trimmingCharacters(in: .whitespaces)
            try store.save(model, key: draft.key)
            close()
        } catch {
            problem = error.localizedDescription
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: runTest) { Text("Test", bundle: .module) }
                    .disabled(test == .running)
                    .help(Text("Reads a small picture of a few words with this model, to check the address, the model, and the key.", bundle: .module))
                InfoButton(Text("Sends a small picture of the words “\(CloudReader.testText)” to the service and checks that the model reads them back. The service may charge for it, as for any request.", bundle: .module))
                if test == .running {
                    ProgressView().controlSize(.small)
                }
            }
            switch test {
            case .idle, .running:
                EmptyView()
            case .succeeded(let message):
                Label {
                    Text(message).lineLimit(3)
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

    private func runTest() {
        if let issue = draft.issue {
            test = .failed(issue)
            return
        }
        guard let picture = CloudReader.testPicture() else { return }
        test = .running
        let model = draft.model
        let reader = CloudReader(secrets: store.secrets(typing: draft.key, for: model))
        testTask?.cancel()
        testTask = Task {
            let started = ContinuousClock.now
            do {
                let reading = try await reader.read(picture, with: model)
                guard !Task.isCancelled else { return }
                let seconds = (ContinuousClock.now - started).components
                let elapsed = (Double(seconds.seconds) + Double(seconds.attoseconds) / 1e18).formatted(.number.precision(.fractionLength(1)))
                if CloudReader.answersTest(reading.text) {
                    test = .succeeded(String(localized: "\(reading.model) read the test picture in \(elapsed) s.", bundle: .module))
                } else {
                    let answer = reading.text.isEmpty ? "—" : String(reading.text.prefix(120))
                    test = .failed(String(localized: "The model answered, but not with the words in the picture: “\(answer)”. Check that it reads pictures.", bundle: .module))
                }
            } catch is CancellationError {
                test = .idle
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}

#if DEBUG
public extension Notification.Name {
    /// Opens the cloud model editor in Settings › Tools for scripted checks: `preset` for a new model, `name` for a
    /// saved one.
    static let debugOpenCloudModelEditor = Notification.Name("io.github.fzlzjerry.ohmyshot.debug.openCloudModelEditor")
}
#endif
