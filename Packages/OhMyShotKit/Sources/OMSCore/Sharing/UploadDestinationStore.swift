import Foundation
import Observation

/// The destinations the user set up and which one is chosen by default, kept in the app's defaults.
///
/// Only what is not secret is saved there, as JSON. Secrets go to the `SecretStore` under the destination's
/// id, and are removed with the destination.
@MainActor
@Observable
public final class UploadDestinationStore {
    public private(set) var destinations: [UploadDestination]

    /// The destination used when a share does not name one. Always one of `destinations`, or nil when empty.
    public private(set) var defaultDestinationID: UUID? {
        didSet { defaults.set(defaultDestinationID?.uuidString, forKey: Key.defaultDestinationID) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public let secrets: any SecretStore

    private enum Key {
        static let destinations = "uploadDestinations"
        static let defaultDestinationID = "uploadDefaultDestinationID"
    }

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        let saved = defaults.data(forKey: Key.destinations)
            .flatMap { try? JSONDecoder().decode([UploadDestination].self, from: $0) } ?? []
        destinations = saved
        let chosen = defaults.string(forKey: Key.defaultDestinationID).flatMap(UUID.init(uuidString:))
        defaultDestinationID = saved.contains { $0.id == chosen } ? chosen : saved.first?.id
    }

    public var defaultDestination: UploadDestination? {
        destinations.first { $0.id == defaultDestinationID }
    }

    public func destination(id: UUID) -> UploadDestination? {
        destinations.first { $0.id == id }
    }

    /// Adds a destination, or replaces the one with the same id, and stores its secrets.
    ///
    /// - Parameter secrets: Field name to value (see `SecretField`). A field left out keeps the value it
    ///   has, so a form that shows saved secrets as dots need not send them back; one that no longer
    ///   belongs to the destination is removed. The first destination becomes the default.
    /// - Throws: `SecretStoreError` if the Keychain refuses; the destination is then not saved.
    public func save(_ destination: UploadDestination, secrets values: [String: String] = [:]) throws {
        let kept = Set(destination.secretFields)
        for (field, value) in values where kept.contains(field) {
            try secrets.setSecret(value, field: field, of: destination.id)
        }
        if let old = self.destination(id: destination.id) {
            secrets.removeSecrets(old.secretFields.filter { !kept.contains($0) }, of: destination.id)
        }
        if let index = destinations.firstIndex(where: { $0.id == destination.id }) {
            destinations[index] = destination
        } else {
            destinations.append(destination)
        }
        if defaultDestinationID == nil { defaultDestinationID = destination.id }
        persist()
    }

    /// Adds a destination read from a ShareX file, with the secrets that came with it.
    public func add(_ imported: ImportedUploader) throws {
        try save(imported.destination, secrets: imported.secrets)
    }

    public func remove(id: UUID) {
        guard let destination = destination(id: id) else { return }
        secrets.removeSecrets(destination.secretFields, of: id)
        destinations.removeAll { $0.id == id }
        if defaultDestinationID == id { defaultDestinationID = destinations.first?.id }
        persist()
    }

    public func setDefault(id: UUID) {
        guard destinations.contains(where: { $0.id == id }) else { return }
        defaultDestinationID = id
    }

    public func move(fromOffsets source: IndexSet, toOffset target: Int) {
        var list = destinations
        let moving = source.sorted().map { list[$0] }
        for index in source.sorted(by: >) { list.remove(at: index) }
        let shift = source.filter { $0 < target }.count
        list.insert(contentsOf: moving, at: max(0, min(list.count, target - shift)))
        destinations = list
        persist()
    }

    /// Whether a secret is saved, without reading its value into the interface.
    public func hasSecret(_ field: String, of destination: UploadDestination) -> Bool {
        secrets.secret(field, of: destination.id) != nil
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(destinations), forKey: Key.destinations)
    }
}
