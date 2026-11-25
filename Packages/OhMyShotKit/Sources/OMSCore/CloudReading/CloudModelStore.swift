import Foundation
import Observation

/// The cloud model the person reads with, kept in the app's defaults with its key in the Keychain, and where it reads
/// by itself (Docs/ocr.md › Cloud models).
///
/// One active model at a time: choosing a service in Settings › Text switches to it while preserving each service's
/// saved configuration and Keychain key, and choosing Off disables cloud reading without discarding saved keys.
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
    /// Saved configurations per service preset so switching services or turning Off preserves Keychain keys.
    @ObservationIgnored private var savedModels: [String: CloudModel] = [:]

    /// The one secret a model has.
    public nonisolated static let keyField = "apiKey"

    private enum Key {
        static let model = "cloudModel"
        static let savedModels = "cloudModelsByPreset"
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
        savedModels = defaults.data(forKey: Key.savedModels).flatMap { try? JSONDecoder().decode([String: CloudModel].self, from: $0) } ?? [:]
        model = defaults.data(forKey: Key.model).flatMap { try? JSONDecoder().decode(CloudModel.self, from: $0) }
        readsInPanel = defaults.bool(forKey: Key.readsInPanel)
        readsCaptureText = defaults.bool(forKey: Key.readsCaptureText)
        migrateFirstCut()
        if let model {
            savedModels[Self.presetKey(of: model)] = model
        }
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

    /// Switches to the saved or fresh model for `preset`, preserving the previous service's configuration and Keychain
    /// key. Passing nil turns cloud reading off without deleting saved keys.
    public func choose(_ preset: CloudModel.Preset?) {
        if let old = model {
            savedModels[Self.presetKey(of: old)] = old
        }
        if let preset {
            var next = savedModels[preset.rawValue] ?? preset.makeModel()
            next.preset = preset
            savedModels[preset.rawValue] = next
            model = next
            hasKey = secrets.secret(Self.keyField, of: next.id) != nil
        } else {
            model = nil
            hasKey = false
            readsInPanel = false
            readsCaptureText = false
        }
        persist()
    }

    /// Keeps the model's name, protocol, address, and model as edited (the same model: its key stays).
    public func update(_ edited: CloudModel) {
        guard let model, edited.id == model.id, edited != model else { return }
        self.model = edited
        savedModels[Self.presetKey(of: edited)] = edited
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

    /// Explicitly removes the active model's API key from the Keychain.
    public func clearKey() {
        guard let model else { return }
        secrets.removeSecret(Self.keyField, of: model.id)
        hasKey = false
    }

    /// The saved key, with `key` for this model as though saved: what Settings' Test reads with before it is stored.
    public func secrets(typing key: String?, for model: CloudModel) -> any SecretStore {
        let typed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DraftSecretStore(typed: typed.isEmpty ? [:] : [Self.keyField: typed], id: model.id, base: secrets)
    }

    private static func presetKey(of model: CloudModel) -> String {
        (model.preset ?? preset(of: model)).rawValue
    }

    private func persist() {
        if let model {
            defaults.set(try? JSONEncoder().encode(model), forKey: Key.model)
        } else {
            defaults.removeObject(forKey: Key.model)
        }
        if savedModels.isEmpty {
            defaults.removeObject(forKey: Key.savedModels)
        } else {
            defaults.set(try? JSONEncoder().encode(savedModels), forKey: Key.savedModels)
        }
    }
}
