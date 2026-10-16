import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import OMSCore

struct UploaderMultipartTests {
    private struct Rig {
        let uploader: Uploader
        let secrets: InMemorySecretStore
        let resources: ActiveResources
        let temporary: URL
        let file: URL
        let content: Data
    }

    /// A file of 2,500 bytes uploaded in parts of 1,024: three parts, the last one short.
    private func rig(size: Int = 2500) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OMSMultipartTests-\(UUID().uuidString)")
        let temporary = directory.appending(path: "tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let content = Data((0..<size).map { UInt8(($0 * 7) % 251) })
        let file = directory.appending(path: "big.mov")
        try content.write(to: file)
        let secrets = InMemorySecretStore()
        let resources = ActiveResources()
        let uploader = Uploader(
            secrets: secrets, resources: resources, sessionConfiguration: StubURLProtocol.configuration, temporaryDirectory: temporary,
            multipartThreshold: 1000, multipartPartSize: 1024
        )
        return Rig(uploader: uploader, secrets: secrets, resources: resources, temporary: temporary, file: file, content: content)
    }

    private func s3(_ host: String, rig: Rig, settings: S3Settings? = nil) throws -> UploadDestination {
        let target = UploadDestination(
            name: "Test", fileNaming: .original,
            configuration: .s3(settings ?? S3Settings(endpoint: URL(string: "https://\(host)")!, bucket: "bk", keyPrefix: "videos", acl: "public-read"))
        )
        try rig.secrets.setSecret("AKIDEXAMPLE", field: SecretField.s3AccessKeyID, of: target.id)
        try rig.secrets.setSecret("secret", field: SecretField.s3SecretAccessKey, of: target.id)
        return target
    }

    private static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: Multipart

    @Test func aLargeFileGoesInPartsAndIsCompletedInOrder() async throws {
        let rig = try rig()
        let host = "mp-a.test"
        let target = try s3(host, rig: rig)
        StubURLProtocol.install(host: host) { seen in
            let query = seen.url.query() ?? ""
            switch (seen.method, query) {
            case ("POST", "uploads="):
                return (200, [:], "<InitiateMultipartUploadResult><Bucket>bk</Bucket><Key>k</Key><UploadId>up-1</UploadId></InitiateMultipartUploadResult>")
            case ("PUT", _):
                let number = query.split(separator: "&").first { $0.hasPrefix("partNumber=") }.map { String($0.dropFirst(11)) } ?? "?"
                return (200, ["ETag": "\"etag-\(number)\""], "")
            case ("POST", _):
                return (200, [:], "<CompleteMultipartUploadResult><Location>x</Location></CompleteMultipartUploadResult>")
            default:
                return (500, [:], "")
            }
        }

        let progress = Mutex<[Double]>([])
        let result = try await rig.uploader.upload(fileAt: rig.file, to: target, originalName: "big.mov") { fraction in
            progress.withLock { $0.append(fraction) }
        }

        let seen = StubURLProtocol.requests(host: host)
        #expect(seen.map(\.method) == ["POST", "PUT", "PUT", "PUT", "POST"])
        // Each part is the next piece of the file, and its signed hash is that piece's.
        let parts = seen.filter { $0.method == "PUT" }
        #expect(parts.reduce(Data()) { $0 + $1.body } == rig.content)
        #expect(parts.map(\.body.count) == [1024, 1024, 452])
        for part in parts { #expect(part.headers["x-amz-content-sha256"] == Self.hex(part.body)) }
        #expect(parts.allSatisfy { $0.url.query()?.contains("uploadId=up-1") == true })
        #expect(parts.allSatisfy { $0.headers["x-amz-acl"] == nil })
        // The object's type and ACL are asked for once, when it is created.
        #expect(seen[0].headers["x-amz-acl"] == "public-read")
        #expect(seen[0].headers["Content-Type"] == "video/quicktime")
        let complete = String(decoding: seen[4].body, as: UTF8.self)
        #expect(complete == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"etag-1\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"etag-2\"</ETag></Part><Part><PartNumber>3</PartNumber><ETag>\"etag-3\"</ETag></Part></CompleteMultipartUpload>")
        #expect(seen[4].headers["x-amz-content-sha256"] == Self.hex(seen[4].body))
        #expect(seen[4].headers["Authorization"]?.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date,") == true)

        #expect(result.link.absoluteString == "https://mp-a.test/bk/videos/big.mov")
        #expect(result.remoteKey == "videos/big.mov")
        #expect(progress.withLock { $0.last } == 1)
        #expect(progress.withLock { $0.count } <= 101)
        // Parts were copied to files and removed; the session and the lease are gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.temporary.path()).isEmpty)
        #expect(rig.resources.isIdle)
    }

    @Test func aFileUnderTheThresholdStillGoesInOneRequest() async throws {
        let rig = try rig(size: 900)
        let host = "mp-b.test"
        let target = try s3(host, rig: rig)
        StubURLProtocol.install(host: host) { _ in (200, [:], "") }
        _ = try await rig.uploader.upload(fileAt: rig.file, to: target)
        #expect(StubURLProtocol.requests(host: host).map(\.method) == ["PUT"])
    }

    @Test func aFailedPartAbortsTheUploadSoTheServerKeepsNothing() async throws {
        let rig = try rig()
        let host = "mp-c.test"
        let target = try s3(host, rig: rig)
        StubURLProtocol.install(host: host) { seen in
            let query = seen.url.query() ?? ""
            if seen.method == "POST", query == "uploads=" { return (200, [:], "<UploadId>up-2</UploadId>") }
            if seen.method == "PUT", query.contains("partNumber=2") { return (500, [:], "<Error><Code>InternalError</Code><Message>try later</Message></Error>") }
            if seen.method == "PUT" { return (200, ["ETag": "\"e\""], "") }
            return (204, [:], "")
        }
        await #expect(throws: UploadError.server(status: 500, message: "try later")) {
            try await rig.uploader.upload(fileAt: rig.file, to: target)
        }
        let seen = StubURLProtocol.requests(host: host)
        let abort = try #require(seen.last)
        #expect(abort.method == "DELETE")
        #expect(abort.url.query() == "uploadId=up-2")
        #expect(seen.filter { $0.method == "PUT" }.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.temporary.path()).isEmpty)
        #expect(rig.resources.isIdle)
    }

    @Test func cancellingAbortsTheUploadToo() async throws {
        let rig = try rig()
        let host = "mp-d.test"
        let target = try s3(host, rig: rig)
        // The second part is answered only once the test has cancelled, however slowly the test runs.
        let secondPart = Arrival(), answer = DispatchSemaphore(value: 0)
        StubURLProtocol.install(host: host) { seen in
            let query = seen.url.query() ?? ""
            if seen.method == "POST", query == "uploads=" { return (200, [:], "<UploadId>up-3</UploadId>") }
            if seen.method == "PUT", query.contains("partNumber=2") {
                secondPart.mark()
                _ = answer.wait(timeout: .now() + 5)
                return (200, ["ETag": "\"e\""], "")
            }
            if seen.method == "PUT" { return (200, ["ETag": "\"e\""], "") }
            return (204, [:], "")
        }
        let task = Task { try await rig.uploader.upload(fileAt: rig.file, to: target) }
        for _ in 0..<1000 where !secondPart.isMarked { try await Task.sleep(for: .milliseconds(10)) }
        #expect(secondPart.isMarked)
        task.cancel()
        // The stub answers one request at a time: let it go on to the abort, and the other tests' requests.
        answer.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        let abort = try #require(StubURLProtocol.requests(host: host).last)
        #expect(abort.method == "DELETE")
        #expect(abort.url.query() == "uploadId=up-3")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.temporary.path()).isEmpty)
        #expect(rig.resources.isIdle)
    }

    @Test func anErrorInsideAnOkCompleteIsAFailure() async throws {
        let rig = try rig()
        let host = "mp-e.test"
        let target = try s3(host, rig: rig)
        StubURLProtocol.install(host: host) { seen in
            let query = seen.url.query() ?? ""
            if seen.method == "POST", query == "uploads=" { return (200, [:], "<UploadId>up-4</UploadId>") }
            if seen.method == "PUT" { return (200, ["ETag": "\"e\""], "") }
            if seen.method == "POST" { return (200, [:], "<Error><Code>InternalError</Code><Message>no luck</Message></Error>") }
            return (204, [:], "")
        }
        await #expect(throws: UploadError.server(status: 500, message: "no luck")) {
            try await rig.uploader.upload(fileAt: rig.file, to: target)
        }
        #expect(StubURLProtocol.requests(host: host).last?.method == "DELETE")
    }

    @Test func partsGrowSoAHugeFileStaysUnderTenThousand() {
        // The rule the uploader uses: at least the configured size, and a multiple of a megabyte that fits.
        let size: Int64 = 400 * 1024 * 1024 * 1024
        let partSize = max(Int64(16 * 1024 * 1024), (size / 9_000 + 1_048_575) / 1_048_576 * 1_048_576)
        #expect((size + partSize - 1) / partSize <= 10_000)
        #expect(partSize % 1_048_576 == 0)
    }

    // MARK: Delete

    @Test func s3DeleteIsASignedDeleteOfTheStoredKey() async throws {
        let rig = try rig()
        let host = "del-a.test"
        let target = try s3(host, rig: rig)
        StubURLProtocol.install(host: host) { _ in (204, [:], "") }
        let record = UploadRecord(
            captureID: nil, date: .now, fileName: "a b.png", destination: target,
            result: UploadResult(link: URL(string: "https://x.test/a")!, fileName: "a b.png", remoteKey: "videos/a b+c.png")
        )
        try await rig.uploader.delete(record, from: target)
        let seen = try #require(StubURLProtocol.requests(host: host).first)
        #expect(seen.method == "DELETE")
        #expect(seen.url.absoluteString == "https://del-a.test/bk/videos/a%20b%2Bc.png")
        #expect(seen.headers["x-amz-content-sha256"] == SigV4Signer.emptyPayloadHash)
        #expect(seen.headers["x-amz-acl"] == nil)
        #expect(seen.headers["Authorization"]?.contains("Credential=AKIDEXAMPLE/") == true)
        #expect(rig.resources.isIdle)
    }

    @Test func aFileAlreadyGoneCountsAsDeletedButAWrongKeyDoesNot() async throws {
        let rig = try rig()
        let host = "del-b.test"
        let target = try s3(host, rig: rig)
        let record = UploadRecord(
            captureID: nil, date: .now, fileName: "a.png", destination: target,
            result: UploadResult(link: URL(string: "https://x.test/a")!, fileName: "a.png", remoteKey: "a.png")
        )
        StubURLProtocol.install(host: host) { _ in (404, [:], "<Error><Code>NoSuchKey</Code><Message>gone</Message></Error>") }
        try await rig.uploader.delete(record, from: target)
        StubURLProtocol.install(host: host) { _ in (403, [:], "<Error><Code>AccessDenied</Code><Message>no</Message></Error>") }
        await #expect(throws: UploadError.authRejected(detail: "no")) { try await rig.uploader.delete(record, from: target) }
        StubURLProtocol.install(host: host) { _ in (404, [:], "<Error><Code>NoSuchBucket</Code><Message>none</Message></Error>") }
        await #expect(throws: UploadError.notFound(detail: "none")) { try await rig.uploader.delete(record, from: target) }
    }

    @Test func webDAVDeleteSendsBasicAuthToTheStoredPath() async throws {
        let rig = try rig()
        let host = "del-c.test"
        let target = UploadDestination(name: "Dav", configuration: .webDAV(WebDAVSettings(baseURL: URL(string: "https://\(host)/dav/me")!, username: "u", keyPrefix: "a/b c")))
        try rig.secrets.setSecret("pw", field: SecretField.webDAVPassword, of: target.id)
        let record = UploadRecord(
            captureID: nil, date: .now, fileName: "x.png", destination: target,
            result: UploadResult(link: URL(string: "https://x.test/a")!, fileName: "x.png", remoteKey: "a/b c/x.png")
        )
        StubURLProtocol.install(host: host) { _ in (204, [:], "") }
        try await rig.uploader.delete(record, from: target)
        let seen = try #require(StubURLProtocol.requests(host: host).first)
        #expect(seen.method == "DELETE")
        #expect(seen.url.absoluteString == "https://del-c.test/dav/me/a/b%20c/x.png")
        #expect(seen.headers["Authorization"] == "Basic " + Data("u:pw".utf8).base64EncodedString())
        // Gone already is fine; a refusal is not.
        StubURLProtocol.install(host: host) { _ in (404, [:], "") }
        try await rig.uploader.delete(record, from: target)
        StubURLProtocol.install(host: host) { _ in (401, [:], "") }
        await #expect(throws: UploadError.authRejected(detail: nil)) { try await rig.uploader.delete(record, from: target) }
    }

    @Test func recordsWithoutAStoredKeyCantBeDeletedByRequest() async throws {
        let rig = try rig()
        let target = UploadDestination(name: "Custom", configuration: .customHTTP(CustomHTTPSettings(requestURL: "https://c.test/up")))
        let record = UploadRecord(
            captureID: nil, date: .now, fileName: "x.png", destination: target,
            result: UploadResult(link: URL(string: "https://x.test/a")!, deletionURL: URL(string: "https://x.test/del"), fileName: "x.png")
        )
        await #expect(throws: UploadError.self) { try await rig.uploader.delete(record, from: target) }
        #expect(record.removal == .openAddress(URL(string: "https://x.test/del")!))
    }
}

/// Whether a request has reached the stub storage, as the stub's thread marks it.
private final class Arrival: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.withLock { marked = true } }
    var isMarked: Bool { lock.withLock { marked } }
}
