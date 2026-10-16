import Foundation
import Testing
@testable import OMSCore

@MainActor
struct UploadCenterTests {
    private struct Rig {
        let center: UploadCenter
        let store: UploadDestinationStore
        let secrets: InMemorySecretStore
        let resources: ActiveResources
        let file: URL
        let host: String
        let cleanup: () -> Void
    }

    private func rig(host: String) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OMSCenterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "shot.png")
        try Data((0..<2048).map { UInt8($0 % 251) }).write(to: file)
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let secrets = InMemorySecretStore()
        let resources = ActiveResources()
        let store = UploadDestinationStore(defaults: defaults, secrets: secrets)
        let uploader = Uploader(secrets: secrets, resources: resources, sessionConfiguration: StubURLProtocol.configuration, temporaryDirectory: directory)
        return Rig(
            center: UploadCenter(store: store, uploader: uploader), store: store, secrets: secrets, resources: resources, file: file, host: host,
            cleanup: { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        )
    }

    private func addDestination(_ rig: Rig, name: String = "Home", public base: String = "https://img.example.com/") throws -> UploadDestination {
        let destination = UploadDestination(name: name, fileNaming: .original, configuration: .s3(S3Settings(
            endpoint: URL(string: "https://\(rig.host)")!, bucket: "bk", publicBaseURL: URL(string: base)
        )))
        try rig.store.save(destination, secrets: [SecretField.s3AccessKeyID: "a", SecretField.s3SecretAccessKey: "b"])
        return destination
    }

    /// Waits for `condition`, which the center's observer task makes true; the transfer itself runs elsewhere.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
    }

    @Test func aFinishedUploadHandsTheLinkToTheClosureGivenWithItAndKeepsItForTheCard() async throws {
        let rig = try rig(host: "center-a.test")
        defer { rig.cleanup() }
        _ = try addDestination(rig)
        StubURLProtocol.install(host: rig.host) { _ in (200, [:], "") }
        let id = UUID()
        var delivered: [URL] = []
        var seen: [UploadStatus?] = []
        rig.center.onChange = { _, status, _ in seen.append(status) }
        #expect(rig.center.start(captureID: id, fileURL: rig.file, originalName: "My shot.png") { result, _ in delivered.append(result.link) })
        #expect(rig.center.isUploading(id))
        #expect(rig.center.uploadingIDs == [id])

        // The job's own state is final a moment before the observer settles it and runs the closure.
        try await until { !delivered.isEmpty }
        #expect(delivered == [URL(string: "https://img.example.com/My%20shot.png")!])
        #expect(rig.center.link(for: id) == delivered.first)
        #expect(seen.first == .uploading(fraction: 0))
        #expect(seen.last == delivered.first.map { .finished(link: $0) })
        #expect(rig.center.isIdle)
        #expect(rig.resources.isIdle)

        rig.center.forget(captureID: id)
        #expect(rig.center.status(for: id) == nil)
    }

    @Test func aSecondUploadOfTheSameCaptureWhileOneRunsDoesNothing() async throws {
        let rig = try rig(host: "center-b.test")
        defer { rig.cleanup() }
        _ = try addDestination(rig)
        StubURLProtocol.install(host: rig.host) { _ in Thread.sleep(forTimeInterval: 0.3); return (200, [:], "") }
        let id = UUID()
        #expect(rig.center.start(captureID: id, fileURL: rig.file, originalName: nil) { _, _ in })
        #expect(!rig.center.start(captureID: id, fileURL: rig.file, originalName: nil) { _, _ in })
        try await until { rig.center.link(for: id) != nil }
    }

    @Test func noDestinationMeansNothingStarts() throws {
        let rig = try rig(host: "center-c.test")
        defer { rig.cleanup() }
        #expect(!rig.center.start(captureID: UUID(), fileURL: rig.file, originalName: nil) { _, _ in })
        #expect(rig.center.isIdle)
        #expect(!rig.center.start(captureID: UUID(), fileURL: rig.file, originalName: nil, destinationID: UUID()) { _, _ in })
    }

    @Test func aFailureIsKeptWithItsSentenceAndRetryRunsANewJobToTheSameDestination() async throws {
        let rig = try rig(host: "center-d.test")
        defer { rig.cleanup() }
        _ = try addDestination(rig)
        let attempts = Counter()
        StubURLProtocol.install(host: rig.host) { _ in
            attempts.increment() == 1
                ? (403, [:], "<Error><Code>SignatureDoesNotMatch</Code><Message>bad</Message></Error>")
                : (200, [:], "")
        }
        let id = UUID()
        var delivered = 0
        rig.center.start(captureID: id, fileURL: rig.file, originalName: nil) { _, _ in delivered += 1 }
        try await until { if case .failed = rig.center.status(for: id) { true } else { false } }
        guard case .failed(let message)? = rig.center.status(for: id) else { Issue.record("not failed"); return }
        #expect(message == UploadError.authRejected(detail: "bad").localizedDescription)
        #expect(delivered == 0)
        #expect(rig.center.isIdle)

        #expect(rig.center.retry(captureID: id))
        try await until { delivered == 1 }
        #expect(rig.center.link(for: id) != nil)
        // Only a failed upload can be retried.
        #expect(!rig.center.retry(captureID: id))
    }

    @Test func cancellingEndsTheUploadAndForgetsIt() async throws {
        let rig = try rig(host: "center-e.test")
        defer { rig.cleanup() }
        _ = try addDestination(rig)
        StubURLProtocol.install(host: rig.host) { _ in Thread.sleep(forTimeInterval: 0.6); return (200, [:], "") }
        let id = UUID()
        var delivered = 0
        var last: UploadStatus?? = .none
        rig.center.onChange = { _, status, _ in last = .some(status) }
        rig.center.start(captureID: id, fileURL: rig.file, originalName: nil) { _, _ in delivered += 1 }
        try await Task.sleep(for: .milliseconds(100))
        rig.center.cancel(captureID: id)
        try await until { rig.center.status(for: id) == nil }
        #expect(delivered == 0)
        #expect(last == .some(nil))
        #expect(rig.center.isIdle)
        #expect(rig.resources.isIdle)
    }

    @Test func cancellingAllWaitsUntilNothingIsLeft() async throws {
        let rig = try rig(host: "center-f.test")
        defer { rig.cleanup() }
        _ = try addDestination(rig)
        StubURLProtocol.install(host: rig.host) { _ in Thread.sleep(forTimeInterval: 0.6); return (200, [:], "") }
        rig.center.start(captureID: UUID(), fileURL: rig.file, originalName: nil) { _, _ in }
        rig.center.start(captureID: UUID(), fileURL: rig.file, originalName: nil) { _, _ in }
        try await Task.sleep(for: .milliseconds(100))
        await rig.center.cancelAll()
        #expect(rig.resources.isIdle)
        try await until { rig.center.isIdle }
    }

    @Test func aNamedDestinationIsUsedInsteadOfTheDefault() async throws {
        let rig = try rig(host: "center-g.test")
        defer { rig.cleanup() }
        _ = try addDestination(rig, name: "First", public: "https://one.example.com/")
        let second = try addDestination(rig, name: "Second", public: "https://two.example.com/")
        StubURLProtocol.install(host: rig.host) { _ in (200, [:], "") }
        let id = UUID()
        var link: URL?
        rig.center.start(captureID: id, fileURL: rig.file, originalName: "a.png", destinationID: second.id) { result, destination in
            link = result.link
            #expect(destination.id == second.id)
        }
        try await until { link != nil }
        #expect(link?.host() == "two.example.com")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

struct UploadMenuTests {
    private func target(_ name: String, isDefault: Bool = false) -> UploadTarget {
        UploadTarget(id: UUID(), name: name, isDefault: isDefault)
    }

    @Test func withNoDestinationNothingIsOffered() {
        #expect(UploadMenu(targets: []) == .hidden)
        #expect(UploadMenu(targets: []).isHidden)
    }

    @Test func oneDestinationOffersAPlainUpload() {
        #expect(UploadMenu(targets: [target("A", isDefault: true)]) == .upload)
    }

    @Test func severalDestinationsOfferTheChoiceInTheirOrder() {
        let targets = [target("A"), target("B", isDefault: true), target("C")]
        #expect(UploadMenu(targets: targets) == .uploadWithChoice(targets))
    }

    @MainActor
    @Test func theStoreListsItsDestinationsWithTheDefaultMarked() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UploadDestinationStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(store.menu == .hidden)
        let one = UploadDestination(name: "One", configuration: .webDAV(WebDAVSettings(baseURL: URL(string: "https://dav.example.com/")!, username: "u")))
        let two = UploadDestination(name: "Two", configuration: .webDAV(WebDAVSettings(baseURL: URL(string: "https://dav2.example.com/")!, username: "u")))
        try store.save(one, secrets: [SecretField.webDAVPassword: "p"])
        #expect(store.menu == .upload)
        try store.save(two, secrets: [SecretField.webDAVPassword: "p"])
        store.setDefault(id: two.id)
        #expect(store.targets.map(\.name) == ["One", "Two"])
        #expect(store.targets.map(\.isDefault) == [false, true])
        store.remove(id: one.id)
        store.remove(id: two.id)
        #expect(store.menu == .hidden)
    }
}

struct UploadDestinationDraftTests {
    @Test func aNewFormOfEachKindStartsIncompleteAndNamed() {
        for kind in UploadDestinationDraft.Kind.allCases {
            let draft = UploadDestinationDraft(kind: kind)
            #expect(!draft.name.isEmpty)
            #expect(draft.firstIssue() != nil)
            #expect(draft.build() == nil)
        }
    }

    @Test func anAmazonBucketNeedsARegionABucketAndKeys() throws {
        var draft = UploadDestinationDraft(kind: .amazonS3)
        draft.bucket = "shots"
        #expect(draft.firstIssue() == "Enter the access key ID.")
        draft.accessKeyID = "AKID"
        #expect(draft.firstIssue() == "Enter the secret access key.")
        draft.secretAccessKey = "secret"
        draft.keyPrefix = "/captures/"
        let built = try #require(draft.build())
        guard case .s3(let settings) = built.destination.configuration else { Issue.record("not S3"); return }
        #expect(settings.endpoint.absoluteString == "https://s3.us-east-1.amazonaws.com")
        #expect(!settings.usesPathStyle)
        #expect(settings.keyPrefix == "captures")
        #expect(built.secrets == [SecretField.s3AccessKeyID: "AKID", SecretField.s3SecretAccessKey: "secret"])
    }

    @Test func aCompatibleServiceNeedsAnAddressWithASchemeAndAHost() {
        var draft = UploadDestinationDraft(kind: .s3Compatible)
        draft.bucket = "b"
        draft.accessKeyID = "a"
        draft.secretAccessKey = "s"
        draft.endpoint = "s3.example.com"
        #expect(draft.firstIssue() == "Enter the endpoint, such as https://s3.example.com.")
        draft.endpoint = "ftp://s3.example.com"
        #expect(draft.firstIssue() != nil)
        draft.endpoint = "http://127.0.0.1:9000"
        #expect(draft.firstIssue() == nil)
        draft.publicBaseURL = "cdn.example.com"
        #expect(draft.firstIssue() == "The public address must start with http:// or https://.")
        draft.publicBaseURL = "https://cdn.example.com"
        #expect(draft.build() != nil)
    }

    @Test func aSavedSecretNeedNotBeTypedAgainAndIsLeftOutOfWhatIsStored() throws {
        let original = UploadDestination(name: "Home", configuration: .webDAV(WebDAVSettings(baseURL: URL(string: "https://dav.example.com/dav")!, username: "me")))
        var draft = UploadDestinationDraft(destination: original, storedSecrets: [SecretField.webDAVPassword])
        #expect(draft.isExisting)
        #expect(draft.firstIssue() == nil)
        let kept = try #require(draft.build())
        #expect(kept.destination == original)
        #expect(kept.secrets.isEmpty)
        draft.password = "new"
        #expect(draft.build()?.secrets == [SecretField.webDAVPassword: "new"])
    }

    @Test func aSavedAmazonDestinationOpensAsAmazonAndOthersAsCompatible() {
        let aws = UploadDestination(name: "A", configuration: .s3(.aws(region: "eu-west-1", bucket: "b")))
        #expect(UploadDestinationDraft(destination: aws, storedSecrets: []).kind == .amazonS3)
        let minio = UploadDestination(name: "M", configuration: .s3(S3Settings(endpoint: URL(string: "http://127.0.0.1:9000")!, bucket: "b")))
        #expect(UploadDestinationDraft(destination: minio, storedSecrets: []).kind == .s3Compatible)
    }

    @Test func customRowsNeedUniqueNamesAndValuesUnlessSaved() throws {
        var draft = UploadDestinationDraft(kind: .customHTTP)
        draft.requestURL = "ftp://x"
        #expect(draft.firstIssue() != nil)
        draft.requestURL = "https://up.example.com/api/upload"
        #expect(draft.firstIssue() == nil)
        draft.headers = [.init(name: "Authorization", value: "")]
        #expect(draft.firstIssue() == "Enter a value for Authorization.")
        draft.headers = [.init(name: "Authorization", value: "", isStored: true)]
        #expect(draft.firstIssue() == nil)
        draft.arguments = [.init(name: "", value: "x")]
        #expect(draft.firstIssue() == "Fill in or remove the empty row.")
        draft.arguments = [.init(name: "k", value: "1"), .init(name: "k", value: "2")]
        #expect(draft.firstIssue() == "Two rows have the same name.")
        draft.arguments = [.init(name: "k", value: "1")]
        let built = try #require(draft.build())
        #expect(built.secrets == [SecretField.argument("k"): "1"])
        guard case .customHTTP(let settings) = built.destination.configuration else { Issue.record("not custom"); return }
        #expect(settings.headerNames == ["Authorization"] && settings.argumentNames == ["k"])
    }

    @Test func aTestUploadReadsWhatWasTypedThenWhatIsSaved() throws {
        let base = InMemorySecretStore()
        let id = UUID()
        try base.setSecret("saved-secret", field: SecretField.s3SecretAccessKey, of: id)
        var draft = UploadDestinationDraft(destination: UploadDestination(
            id: id, name: "S", configuration: .s3(S3Settings(endpoint: URL(string: "http://127.0.0.1:9000")!, bucket: "b"))
        ), storedSecrets: [SecretField.s3AccessKeyID, SecretField.s3SecretAccessKey])
        draft.accessKeyID = "typed-key"
        let layered = draft.secretStore(over: base)
        #expect(layered.secret(SecretField.s3AccessKeyID, of: id) == "typed-key")
        #expect(layered.secret(SecretField.s3SecretAccessKey, of: id) == "saved-secret")
        #expect(base.secret(SecretField.s3AccessKeyID, of: id) == nil)
    }
}
