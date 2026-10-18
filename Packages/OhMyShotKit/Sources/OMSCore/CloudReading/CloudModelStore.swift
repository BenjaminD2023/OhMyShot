import Foundation
import Observation

/// The cloud models the person set up, kept in the app's defaults, with each one's key in the Keychain.
///
/// Also remembers which model the OCR panel offered last, and which services the person agreed to send pictures to:
/// a model's first picture is sent only after it asks, and asks again once the model points to another host.
@MainActor
@Observable
public final class CloudModelStore {
    public private(set) var models: [CloudModel]

    /// The model the OCR panel offers first: the one used last, while it exists.
    public private(set) var preferredID: UUID? {
        didSet { defaults.set(preferredID?.uuidString, forKey: Key.preferred) }
    }

    /// "id host" for each model the person agreed to send pictures to, at the host it had then.
    private var agreed: Set<String> {
        didSet { defaults.set(agreed.sorted(), forKey: Key.agreed) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public let secrets: any SecretStore

    /// The one secret a model has.
    public nonisolated static let keyField = "apiKey"

    private enum Key {
        static let models = "cloudModels"
        static let preferred = "cloudModelPreferred"
        static let agreed = "cloudModelsAgreed"
    }

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        let saved = defaults.data(forKey: Key.models)
            .flatMap { try? JSONDecoder().decode([CloudModel].self, from: $0) } ?? []
        models = saved
        let preferred = defaults.string(forKey: Key.preferred).flatMap(UUID.init(uuidString:))
        preferredID = saved.contains { $0.id == preferred } ? preferred : saved.first?.id
        agreed = Set(defaults.stringArray(forKey: Key.agreed) ?? [])
    }

    public func model(id: UUID) -> CloudModel? {
        models.first { $0.id == id }
    }

    /// The model the panel offers first.
    public var preferred: CloudModel? {
        preferredID.flatMap(model(id:)) ?? models.first
    }

    /// Adds a model, or replaces the one with the same id, and stores its key.
    ///
    /// - Parameter key: The new key; nil or empty keeps the one saved, so a form that shows a saved key as dots need
    ///   not send it back.
    /// - Throws: `SecretStoreError` if the Keychain refuses; the model is then not saved.
    public func save(_ model: CloudModel, key: String? = nil) throws {
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            try secrets.setSecret(key, field: Self.keyField, of: model.id)
        }
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index] = model
        } else {
            models.append(model)
        }
        if preferredID == nil { preferredID = model.id }
        persist()
    }

    public func remove(id: UUID) {
        guard model(id: id) != nil else { return }
        secrets.removeSecret(Self.keyField, of: id)
        models.removeAll { $0.id == id }
        agreed = agreed.filter { !$0.hasPrefix(id.uuidString) }
        if preferredID == id { preferredID = models.first?.id }
        persist()
    }

    public func move(fromOffsets source: IndexSet, toOffset target: Int) {
        var list = models
        let moving = source.sorted().map { list[$0] }
        for index in source.sorted(by: >) { list.remove(at: index) }
        let shift = source.filter { $0 < target }.count
        list.insert(contentsOf: moving, at: max(0, min(list.count, target - shift)))
        models = list
        persist()
    }

    /// Whether a key is saved, without bringing its value into the interface.
    public func hasKey(_ model: CloudModel) -> Bool {
        secrets.secret(Self.keyField, of: model.id) != nil
    }

    /// The saved keys, with `key` for this model as though saved: what Settings' Test reads with before Save.
    public func secrets(typing key: String?, for model: CloudModel) -> any SecretStore {
        let typed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DraftSecretStore(typed: typed.isEmpty ? [:] : [Self.keyField: typed], id: model.id, base: secrets)
    }

    /// The panel used this model.
    public func markUsed(_ model: CloudModel) {
        guard self.model(id: model.id) != nil else { return }
        preferredID = model.id
    }

    /// Whether the person agreed to send pictures to this model's host.
    public func isAgreed(_ model: CloudModel) -> Bool {
        agreed.contains(Self.agreement(model))
    }

    public func agree(_ model: CloudModel) {
        agreed.insert(Self.agreement(model))
    }

    private static func agreement(_ model: CloudModel) -> String {
        "\(model.id.uuidString) \(model.host ?? "")"
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(models), forKey: Key.models)
    }
}
