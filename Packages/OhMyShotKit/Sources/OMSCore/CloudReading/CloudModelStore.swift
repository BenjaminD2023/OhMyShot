import Foundation
import Observation

/// The cloud model the person reads with, kept in the app's defaults with its key in the Keychain, and where it reads
/// by itself (Docs/ocr.md › Cloud models).
///
/// One model: choosing a service in Settings › Text sets it up, and choosing Off removes it and its key. Choosing it
/// is the person's yes to sending pictures there: from the Recognized Text window's Read with button whenever they
/// press it, and on its own wherever they turn that on (every picture in that window, or Capture Text).
@MainActor
@Observable
public final class CloudModelStore {
    /// The model, or nil while cloud reading is off.
    public private(set) var model: CloudModel?

    /// Whether every picture in the Recognized Text window is read with the model too, without its button.
    public var readsInPanel: Bool {
        didSet { defaults.set(readsInPanel, forKey: Key.readsInPanel) }
    }

    /// Whether Capture Text reads with the model (and copies this Mac's reading when it can't).
    public var readsCaptureText: Bool {
        didSet { defaults.set(readsCaptureText, forKey: Key.readsCaptureText) }
    }

    /// Whether a key is saved, without bringing its value into the interface: looked up once, then kept as keys are
    /// stored and removed here, so the interface never asks the Keychain again (a development build's Keychain asks
    /// the person each time after a rebuild).
    public private(set) var hasKey = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public let secrets: any SecretStore

    /// The one secret a model has.
    public nonisolated static let keyField = "apiKey"

    private enum Key {
        static let model = "cloudModel"
        static let readsInPanel = "cloudReadsInPanel"
        static let readsCaptureText = "cloudReadsCaptureText"
        /// The first cut's list of models, the one used last, and the hosts agreed to (34f042b).
        static let firstCutModels = "cloudModels"
        static let firstCutPreferred = "cloudModelPreferred"
        static let firstCutAgreed = "cloudModelsAgreed"
    }

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        model = defaults.data(forKey: Key.model).flatMap { try? JSONDecoder().decode(CloudModel.self, from: $0) }
        readsInPanel = defaults.bool(forKey: Key.readsInPanel)
        readsCaptureText = defaults.bool(forKey: Key.readsCaptureText)
        migrateFirstCut()
        hasKey = model.map { secrets.secret(Self.keyField, of: $0.id) != nil } ?? false
    }

    /// The first cut kept a list of models: the one used last (or the first) becomes the model, with its id, so its key
    /// in the Keychain still belongs to it; the others' keys go, and so do the list's defaults.
    private func migrateFirstCut() {
        guard let data = defaults.data(forKey: Key.firstCutModels) else { return }
        let listed = (try? JSONDecoder().decode([CloudModel].self, from: data)) ?? []
        let preferred = defaults.string(forKey: Key.firstCutPreferred).flatMap(UUID.init(uuidString:))
        if model == nil, var kept = listed.first(where: { $0.id == preferred }) ?? listed.first {
            kept.preset = kept.preset ?? Self.preset(of: kept)
            model = kept
            persist()
        }
        for other in listed where other.id != model?.id {
            secrets.removeSecret(Self.keyField, of: other.id)
        }
        defaults.removeObject(forKey: Key.firstCutModels)
        defaults.removeObject(forKey: Key.firstCutPreferred)
        defaults.removeObject(forKey: Key.firstCutAgreed)
    }

    /// The service a model was set up from, by its protocol and address.
    static func preset(of model: CloudModel) -> CloudModel.Preset {
        if model.kind == .anthropic { return .anthropic }
        let host = model.host
        return [CloudModel.Preset.openAI, .qwen, .ollama].first { preset in
            preset.makeModel().host == host
        } ?? .other
    }

    /// The model, when it can read: set up, with a key where it needs one.
    public var usableModel: CloudModel? {
        guard let model, model.issue(hasKey: hasKey) == nil else { return nil }
        return model
    }

    /// The model Capture Text reads with, while that is on.
    public var captureTextModel: CloudModel? {
        readsCaptureText ? usableModel : nil
    }

    /// Sets up the model a preset starts, in place of the one there (whose key goes); nil turns cloud reading off,
    /// removing the model and its key, and where it read by itself.
    public func choose(_ preset: CloudModel.Preset?) {
        if let old = model { secrets.removeSecret(Self.keyField, of: old.id) }
        model = preset?.makeModel()
        hasKey = false
        if model == nil {
            readsInPanel = false
            readsCaptureText = false
        }
        persist()
    }

    /// Keeps the model's name, protocol, address, and model as edited (the same model: its key stays).
    public func update(_ edited: CloudModel) {
        guard let model, edited.id == model.id, edited != model else { return }
        self.model = edited
        persist()
    }

    /// Stores the model's key, replacing the one there. Empty keeps it.
    /// - Throws: `SecretStoreError` if the Keychain refuses.
    public func setKey(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !key.isEmpty else { return }
        try secrets.setSecret(key, field: Self.keyField, of: model.id)
        hasKey = true
    }

    /// The saved key, with `key` for this model as though saved: what Settings' Test reads with before it is stored.
    public func secrets(typing key: String?, for model: CloudModel) -> any SecretStore {
        let typed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DraftSecretStore(typed: typed.isEmpty ? [:] : [Self.keyField: typed], id: model.id, base: secrets)
    }

    private func persist() {
        if let model {
            defaults.set(try? JSONEncoder().encode(model), forKey: Key.model)
        } else {
            defaults.removeObject(forKey: Key.model)
        }
    }
}
