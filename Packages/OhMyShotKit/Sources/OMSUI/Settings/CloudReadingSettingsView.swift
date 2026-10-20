import AppKit
import OMSCore
import SwiftUI

/// Settings › Tools › Cloud reading: the service whose model reads pictures this Mac reads poorly, set up in place
/// (model, address, key), where it reads by itself, and a Test. Off by default; Off again removes the model and its key.
struct CloudReadingRow: View {
    let store: CloudModelStore
    @State private var draft: CloudModel?
    @State private var key = ""
    @State private var problem: String?
    @State private var test = TestState.idle
    @State private var testTask: Task<Void, Never>?
    /// A service chosen in place of one whose key is saved, until the person says to delete the key.
    @State private var pending: Pending?
    @FocusState private var keyFocused: Bool

    struct Pending: Identifiable {
        let id = UUID()
        let preset: CloudModel.Preset?
    }

    enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    /// The fields' width, so they end at one edge.
    private static let fieldWidth: CGFloat = 260

    var body: some View {
        SettingsRow(Text("Cloud reading", bundle: .module)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Picker(selection: Binding(get: { store.model?.preset ?? (store.model == nil ? nil : .other) }, set: choose)) {
                        Text("Off", bundle: .module).tag(CloudModel.Preset?.none)
                        Divider()
                        ForEach(CloudModel.Preset.allCases) { preset in
                            Text(verbatim: preset.title).tag(CloudModel.Preset?.some(preset))
                        }
                    } label: {
                        Text("Cloud reading", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("Reads pictures with a model you have an account with, such as Claude, GPT, or Qwen, or one on this Mac with Ollama, where this Mac reads them poorly: handwriting, dense tables, complex layouts. The picture goes from this Mac straight to the service, which may charge for it: when you press Read with in the Recognized Text window, and by itself where you turn that on below. Keys stay in the Keychain.", bundle: .module))
                }
                if let model = draft {
                    fields(model)
                }
            }
        }
        .onAppear { draft = store.model }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenCloudSwitch)) { _ in
            if store.model != nil { pending = Pending(preset: nil) }
        }
        #endif
        .onChange(of: store.model?.id) {
            draft = store.model
            key = ""
            problem = nil
            test = .idle
        }
        .onChange(of: draft) {
            if let draft { store.update(draft) }
            if test != .running { test = .idle }
        }
        .onChange(of: keyFocused) { if !keyFocused { saveKey() } }
        .confirmationDialog(
            pending.map { pending in
                pending.preset.map { Text("Switch to \($0.title)?", bundle: .module) } ?? Text("Turn off cloud reading?", bundle: .module)
            } ?? Text(verbatim: ""),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            Button(role: .destructive) {
                store.choose(pending.preset)
            } label: {
                pending.preset == nil ? Text("Turn Off", bundle: .module) : Text("Switch", bundle: .module)
            }
        } message: { _ in
            Text("The API key saved for \(store.model?.displayName ?? "") is deleted from the Keychain.", bundle: .module)
        }
        .onDisappear {
            saveKey()
            testTask?.cancel()
        }
    }

    /// Another service, or Off, deletes the saved key: the person is asked first.
    private func choose(_ preset: CloudModel.Preset?) {
        guard preset != store.model?.preset || (preset == nil) != (store.model == nil) else { return }
        if store.hasKey {
            pending = Pending(preset: preset)
        } else {
            store.choose(preset)
        }
    }

    @ViewBuilder private func fields(_ model: CloudModel) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            if model.preset == .other || model.preset == nil {
                field(Text("Name", bundle: .module)) {
                    TextField(text: binding(\.name), prompt: Text(verbatim: model.host ?? "")) { Text("Name", bundle: .module) }
                        .labelsHidden()
                        .help(Text("What the Read with button calls it.", bundle: .module))
                }
            }
            field(Text("Model", bundle: .module)) {
                TextField(text: binding(\.model), prompt: Text("Required", bundle: .module)) { Text("Model", bundle: .module) }
                    .labelsHidden()
                    .help(Text("The name of a model that reads pictures, as the service lists it.", bundle: .module))
            }
            field(Text("Base URL", bundle: .module)) {
                TextField(text: binding(\.address), prompt: Text(verbatim: model.kind == .anthropic ? "https://api.anthropic.com" : "https://api.example.com/v1")) { Text("Base URL", bundle: .module) }
                    .labelsHidden()
                    .help(Text("The service’s address with its version, as its documentation gives it. Plain http:// works only on this Mac or your local network.", bundle: .module))
            }
            field(Text("API key", bundle: .module)) {
                HStack(spacing: 6) {
                    SecureField(
                        text: $key,
                        prompt: store.hasKey ? Text("Saved in Keychain", bundle: .module) : model.needsKey ? Text("Required", bundle: .module) : Text("Optional", bundle: .module)
                    ) { Text("API key", bundle: .module) }
                        .labelsHidden()
                        .focused($keyFocused)
                        .onSubmit(saveKey)
                    if store.hasKey {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help(Text("Saved in the Keychain. Type a new key to replace it.", bundle: .module))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(width: Self.fieldWidth + 70, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
            Text("Read by itself in", bundle: .module)
                .foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { store.readsInPanel }, set: { store.readsInPanel = $0 })) {
                Text("Every picture in the Recognized Text window", bundle: .module)
            }
            .help(Text("Without it, the window’s Read with button sends a picture when you press it.", bundle: .module))
            Toggle(isOn: Binding(get: { store.readsCaptureText }, set: { store.readsCaptureText = $0 })) {
                Text("Capture Text", bundle: .module)
            }
            .help(Text("Capture Text waits for the model’s reading before it copies, and copies this Mac’s reading when the model can’t read it.", bundle: .module))
        }

        if let issue = problem ?? model.issue(hasKey: store.hasKey || !key.trimmingCharacters(in: .whitespaces).isEmpty) {
            Label { Text(issue) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        testRow(model)
    }

    private func field<Content: View>(_ label: Text, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            label
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
                .frame(width: Self.fieldWidth)
        }
    }

    private func binding(_ path: WritableKeyPath<CloudModel, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: path] ?? "" }, set: { draft?[keyPath: path] = $0 })
    }

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try store.setKey(key)
            key = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func testRow(_ model: CloudModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { runTest(model) } label: { Text("Test", bundle: .module) }
                    .disabled(test == .running)
                    .help(Text("Sends a small picture of the words “\(CloudReader.testText)” to the service and checks that the model reads them back. The service may charge for it, as for any request.", bundle: .module))
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

    private func runTest(_ model: CloudModel) {
        if let issue = model.issue(hasKey: store.hasKey || !key.trimmingCharacters(in: .whitespaces).isEmpty) {
            test = .failed(issue)
            return
        }
        guard let picture = CloudReader.testPicture() else { return }
        test = .running
        let reader = CloudReader(secrets: store.secrets(typing: key, for: model))
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
                    // It works: the key typed is the one to keep.
                    saveKey()
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
