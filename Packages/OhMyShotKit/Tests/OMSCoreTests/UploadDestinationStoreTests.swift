import Foundation
import Testing
@testable import OMSCore

@MainActor
struct UploadDestinationStoreTests {
    private func makeStore(_ secrets: InMemorySecretStore = InMemorySecretStore()) throws -> (UploadDestinationStore, UserDefaults, InMemorySecretStore, () -> Void) {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (UploadDestinationStore(defaults: defaults, secrets: secrets), defaults, secrets, { defaults.removePersistentDomain(forName: suite) })
    }

    private func s3(_ name: String) -> UploadDestination {
        UploadDestination(name: name, configuration: .s3(S3Settings(endpoint: URL(string: "http://127.0.0.1:9000")!, bucket: "b")))
    }

    @Test func destinationsAreKeptWithoutTheirSecrets() throws {
        let (store, defaults, secrets, cleanup) = try makeStore()
        defer { cleanup() }
        let one = s3("Home")
        try store.save(one, secrets: [SecretField.s3AccessKeyID: "AKIDEXAMPLE", SecretField.s3SecretAccessKey: "very-secret"])
        #expect(store.defaultDestinationID == one.id)

        let saved = try #require(defaults.data(forKey: "uploadDestinations"))
        let text = String(decoding: saved, as: UTF8.self)
        #expect(text.contains("Home"))
        #expect(!text.contains("AKIDEXAMPLE") && !text.contains("very-secret"))

        let reopened = UploadDestinationStore(defaults: defaults, secrets: secrets)
        #expect(reopened.destinations == [one])
        #expect(reopened.defaultDestinationID == one.id)
        #expect(reopened.secrets.secret(SecretField.s3SecretAccessKey, of: one.id) == "very-secret")
    }

    @Test func removingADestinationRemovesItsSecretsAndMovesTheDefault() throws {
        let (store, _, secrets, cleanup) = try makeStore()
        defer { cleanup() }
        let one = s3("One"), two = s3("Two")
        try store.save(one, secrets: [SecretField.s3AccessKeyID: "a", SecretField.s3SecretAccessKey: "b"])
        try store.save(two, secrets: [SecretField.s3AccessKeyID: "c", SecretField.s3SecretAccessKey: "d"])
        store.setDefault(id: two.id)
        #expect(secrets.count == 4)
        store.remove(id: two.id)
        #expect(secrets.count == 2)
        #expect(store.defaultDestinationID == one.id)
        store.remove(id: one.id)
        #expect(secrets.count == 0)
        #expect(store.defaultDestination == nil)
    }

    @Test func savingWithoutASecretKeepsItAndDroppedFieldsGoAway() throws {
        let (store, _, secrets, cleanup) = try makeStore()
        defer { cleanup() }
        var custom = CustomHTTPSettings(requestURL: "https://h/up", headerNames: ["A", "B"])
        var destination = UploadDestination(name: "C", configuration: .customHTTP(custom))
        try store.save(destination, secrets: [SecretField.header("A"): "1", SecretField.header("B"): "2"])
        custom.headerNames = ["A"]
        destination.configuration = .customHTTP(custom)
        try store.save(destination)
        #expect(secrets.secret(SecretField.header("A"), of: destination.id) == "1")
        #expect(secrets.secret(SecretField.header("B"), of: destination.id) == nil)
    }

    @Test func anImportedUploaderIsAddedWithItsSecrets() throws {
        let (store, _, secrets, cleanup) = try makeStore()
        defer { cleanup() }
        let imported = try ShareXImporter.importUploader(from: Data(ShareXImporterTests.imgur.utf8))
        try store.add(imported)
        #expect(secrets.secret(SecretField.header("Authorization"), of: imported.destination.id) == "Client-ID 0123456789")
        #expect(store.hasSecret(SecretField.parameter("album"), of: imported.destination))
    }

    @Test func destinationsReorder() throws {
        let (store, _, _, cleanup) = try makeStore()
        defer { cleanup() }
        let list = ["A", "B", "C"].map(s3)
        for item in list { try store.save(item) }
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.destinations.map(\.name) == ["B", "C", "A"])
    }
}
