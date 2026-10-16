import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// Answers requests to a test's own host name, so tests that run in parallel do not meet each other's.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    typealias Handler = @Sendable (Seen) -> (status: Int, headers: [String: String], body: String)

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let log = Mutex<[String: [Seen]]>([:])

    static func install(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
        log.withLock { $0[host] = [] }
    }

    static func requests(host: String) -> [Seen] { log.withLock { $0[host] ?? [] } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { handlers.withLock { $0[request.url?.host() ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        } else if let data = request.httpBody {
            body = data
        }
        let url = request.url!
        let seen = Seen(method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let host = url.host() ?? ""
        Self.log.withLock { $0[host, default: []].append(seen) }
        guard let handler = Self.handlers.withLock({ $0[host] }) else { return }
        let answer = handler(seen)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct UploaderTests {
    private struct Rig {
        let uploader: Uploader
        let secrets: InMemorySecretStore
        let resources: ActiveResources
        let temporary: URL
        let file: URL
        let content: Data
    }

    private func rig(fileName: String = "shot.png") throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OMSUploadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        let file = directory.appending(path: fileName)
        try content.write(to: file)
        let temporary = directory.appending(path: "tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let secrets = InMemorySecretStore()
        let resources = ActiveResources()
        let uploader = Uploader(secrets: secrets, resources: resources, sessionConfiguration: StubURLProtocol.configuration, temporaryDirectory: temporary)
        return Rig(uploader: uploader, secrets: secrets, resources: resources, temporary: temporary, file: file, content: content)
    }

    private func destination(_ configuration: UploadDestination.Configuration, naming: FileNaming = .original) -> UploadDestination {
        UploadDestination(name: "Test", fileNaming: naming, configuration: configuration)
    }

    // MARK: S3

    @Test func s3SignsTheBodyAndTheKeyAsItIsSent() async throws {
        let rig = try rig()
        let host = "s3-a.test"
        var settings = S3Settings(endpoint: URL(string: "https://\(host)")!, region: "auto", bucket: "my-bucket", keyPrefix: "/shots/2026/", publicBaseURL: URL(string: "https://img.example.com/"))
        settings.acl = "public-read"
        let target = destination(.s3(settings))
        try rig.secrets.setSecret("AKIDEXAMPLE", field: SecretField.s3AccessKeyID, of: target.id)
        try rig.secrets.setSecret("secret", field: SecretField.s3SecretAccessKey, of: target.id)
        StubURLProtocol.install(host: host) { _ in (200, [:], "") }

        let name = "CleanShot 2026-10-16 at 14.02.11 微信+a#b.png"
        let result = try await rig.uploader.upload(fileAt: rig.file, to: target, originalName: name)

        let seen = try #require(StubURLProtocol.requests(host: host).first)
        #expect(seen.method == "PUT")
        #expect(seen.body == rig.content)
        let absolute = seen.url.absoluteString
        #expect(absolute == "https://s3-a.test/my-bucket/shots/2026/CleanShot%202026-10-16%20at%2014.02.11%20%E5%BE%AE%E4%BF%A1%2Ba%23b.png")
        #expect(seen.headers["x-amz-content-sha256"]?.count == 64)
        #expect(seen.headers["x-amz-acl"] == "public-read")
        let authorization = try #require(seen.headers["Authorization"])
        #expect(authorization.contains("Credential=AKIDEXAMPLE/"))
        #expect(authorization.contains("/auto/s3/aws4_request"))
        #expect(authorization.contains("SignedHeaders=host;x-amz-acl;x-amz-content-sha256;x-amz-date,"))
        #expect(seen.headers["Content-Type"] == "image/png")

        // The link encodes the key the way it was stored, under the public base.
        #expect(result.link.absoluteString == "https://img.example.com/shots/2026/CleanShot%202026-10-16%20at%2014.02.11%20%E5%BE%AE%E4%BF%A1%2Ba%23b.png")
        #expect(result.fileName == name)
        #expect(rig.resources.isIdle)
    }

    @Test func s3VirtualHostedAddressAndRandomNames() async throws {
        let rig = try rig()
        let host = "s3-b.test"
        let target = destination(.s3(S3Settings(endpoint: URL(string: "https://\(host)")!, bucket: "bk", usesPathStyle: false)), naming: .random)
        try rig.secrets.setSecret("a", field: SecretField.s3AccessKeyID, of: target.id)
        try rig.secrets.setSecret("b", field: SecretField.s3SecretAccessKey, of: target.id)
        StubURLProtocol.install(host: "bk.\(host)") { _ in (200, [:], "") }
        let result = try await rig.uploader.upload(fileAt: rig.file, to: target, originalName: "Private name.png")
        #expect(!result.fileName.contains("Private"))
        #expect(result.fileName.hasSuffix(".png"))
        #expect(result.fileName.count == 14)
        #expect(result.link.host() == "bk.\(host)")
        #expect(result.link.path() == "/\(result.fileName)")
    }

    @Test func s3PresignedLinkExpiresAndIsCappedAtSevenDays() async throws {
        let rig = try rig()
        let host = "s3-c.test"
        var settings = S3Settings(endpoint: URL(string: "https://\(host)")!, bucket: "bk", linkStyle: .presigned, presignedExpiry: 30 * 86_400)
        settings.region = "us-east-1"
        let target = destination(.s3(settings))
        try rig.secrets.setSecret("a", field: SecretField.s3AccessKeyID, of: target.id)
        try rig.secrets.setSecret("b", field: SecretField.s3SecretAccessKey, of: target.id)
        StubURLProtocol.install(host: host) { _ in (200, [:], "") }
        let result = try await rig.uploader.upload(fileAt: rig.file, to: target)
        let query = try #require(result.link.query())
        #expect(query.contains("X-Amz-Expires=604800"))
        #expect(query.contains("X-Amz-Signature="))
        #expect(result.expiresAt != nil)
    }

    @Test func s3ErrorsBecomeTheRightSentences() async throws {
        let rig = try rig()
        let host = "s3-d.test"
        let target = destination(.s3(S3Settings(endpoint: URL(string: "https://\(host)")!, bucket: "bk")))
        try rig.secrets.setSecret("a", field: SecretField.s3AccessKeyID, of: target.id)
        try rig.secrets.setSecret("b", field: SecretField.s3SecretAccessKey, of: target.id)
        for (status, code, expected) in [
            (403, "SignatureDoesNotMatch", UploadError.authRejected(detail: "bad")),
            (404, "NoSuchBucket", UploadError.notFound(detail: "bad")),
            (403, "RequestTimeTooSkewed", UploadError.clockSkew),
            (500, "InternalError", UploadError.server(status: 500, message: "bad")),
        ] {
            StubURLProtocol.install(host: host) { _ in (status, [:], "<Error><Code>\(code)</Code><Message>bad</Message></Error>") }
            await #expect(throws: expected) { try await rig.uploader.upload(fileAt: rig.file, to: target) }
        }
        #expect(rig.resources.isIdle)
    }

    @Test func aMissingSecretIsReportedBeforeAnythingIsSent() async throws {
        let rig = try rig()
        let host = "s3-e.test"
        StubURLProtocol.install(host: host) { _ in (200, [:], "") }
        let target = destination(.s3(S3Settings(endpoint: URL(string: "https://\(host)")!, bucket: "bk")))
        await #expect(throws: UploadError.secretMissing(field: SecretField.s3AccessKeyID)) {
            try await rig.uploader.upload(fileAt: rig.file, to: target)
        }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }

    // MARK: WebDAV

    @Test func webDAVMakesMissingFoldersOnAConflictAndTriesAgain() async throws {
        let rig = try rig()
        let host = "dav-a.test"
        let settings = WebDAVSettings(baseURL: URL(string: "https://\(host)/dav/me")!, username: "u", publicBaseURL: URL(string: "https://pub.example.com/s"), keyPrefix: "a/b c")
        let target = destination(.webDAV(settings))
        try rig.secrets.setSecret("pw", field: SecretField.webDAVPassword, of: target.id)
        let puts = Mutex(0)
        StubURLProtocol.install(host: host) { seen in
            if seen.method == "PUT" {
                let attempt = puts.withLock { $0 += 1; return $0 }
                return attempt == 1 ? (409, [:], "") : (201, [:], "")
            }
            return (201, [:], "")
        }
        let result = try await rig.uploader.upload(fileAt: rig.file, to: target, originalName: "x y.png")
        let seen = StubURLProtocol.requests(host: host)
        #expect(seen.map(\.method) == ["PUT", "MKCOL", "MKCOL", "PUT"])
        #expect(seen[1].url.path(percentEncoded: true) == "/dav/me/a/")
        #expect(seen[2].url.path(percentEncoded: true) == "/dav/me/a/b%20c/")
        #expect(seen[3].url.path(percentEncoded: true) == "/dav/me/a/b%20c/x%20y.png")
        #expect(seen[3].body == rig.content)
        #expect(seen[0].headers["Authorization"] == "Basic " + Data("u:pw".utf8).base64EncodedString())
        #expect(result.link.absoluteString == "https://pub.example.com/s/a/b%20c/x%20y.png")
    }

    @Test func webDAVLinkFallsBackToTheFileAddressAndWrongPasswordsAreRejected() async throws {
        let rig = try rig()
        let host = "dav-b.test"
        let target = destination(.webDAV(WebDAVSettings(baseURL: URL(string: "http://\(host):8080/dav/")!, username: "u")))
        StubURLProtocol.install(host: host) { _ in (204, [:], "") }
        let result = try await rig.uploader.upload(fileAt: rig.file, to: target, originalName: "p.png")
        #expect(result.link.absoluteString == "http://\(host):8080/dav/p.png")
        StubURLProtocol.install(host: host) { _ in (401, [:], "") }
        await #expect(throws: UploadError.authRejected(detail: nil)) { try await rig.uploader.upload(fileAt: rig.file, to: target) }
    }

    // MARK: Custom HTTP

    @Test func multipartUploadSendsTheArgumentsThenTheFileAndReadsTheLink() async throws {
        let rig = try rig()
        let host = "http-a.test"
        let json = #"""
        {"Version":"16.1.0","RequestURL":"https://http-a.test/up/{filename}?x=1","Headers":{"Authorization":"Bearer TOK"},
         "Body":"MultipartFormData","FileFormName":"image","Arguments":{"album":"A {random:one|two}"},
         "URL":"{json:data.link}","ThumbnailURL":"{json:data.thumb}","DeletionURL":"https://http-a.test/del/{json:data.id}","ErrorMessage":"{json:error}"}
        """#
        let imported = try ShareXImporter.importUploader(from: Data(json.utf8))
        for (field, value) in imported.secrets { try rig.secrets.setSecret(value, field: field, of: imported.destination.id) }
        var target = imported.destination
        target.fileNaming = .original
        StubURLProtocol.install(host: host) { _ in (200, [:], #"{"data":{"link":"https://i.example.com/a.png","thumb":"https://i.example.com/at.png","id":"d9"}}"#) }

        let result = try await rig.uploader.upload(fileAt: rig.file, to: target, originalName: "my shot.png")
        let seen = try #require(StubURLProtocol.requests(host: host).first)
        #expect(seen.url.absoluteString == "https://http-a.test/up/my%20shot.png?x=1")
        #expect(seen.headers["Authorization"] == "Bearer TOK")
        let contentType = try #require(seen.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = seen.body
        let text = String(decoding: body, as: UTF8.self)
        let albumAt = try #require(text.range(of: "name=\"album\""))
        let fileAt = try #require(text.range(of: "name=\"image\"; filename=\"my shot.png\""))
        #expect(albumAt.lowerBound < fileAt.lowerBound)
        #expect(text.contains("Content-Type: image/png"))
        #expect(text.hasSuffix("\r\n--\(boundary)--\r\n"))
        #expect(body.range(of: rig.content) != nil)
        #expect(result.link.absoluteString == "https://i.example.com/a.png")
        #expect(result.thumbnailURL?.absoluteString == "https://i.example.com/at.png")
        #expect(result.deletionURL?.absoluteString == "https://http-a.test/del/d9")
        // The form's temporary copy is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.temporary.path()).isEmpty)
    }

    @Test func binaryPutSendsTheFileAsIsAndTheWholeAnswerIsTheLink() async throws {
        let rig = try rig()
        let host = "http-b.test"
        let json = #"{"Version":"16.1.0","RequestMethod":"PUT","RequestURL":"https://http-b.test/f/{filename}","Body":"Binary","Headers":{"X-Token":"t"}}"#
        let imported = try ShareXImporter.importUploader(from: Data(json.utf8))
        for (field, value) in imported.secrets { try rig.secrets.setSecret(value, field: field, of: imported.destination.id) }
        StubURLProtocol.install(host: host) { _ in (200, [:], "https://http-b.test/view/1\n") }
        let result = try await rig.uploader.upload(fileAt: rig.file, to: imported.destination)
        let seen = try #require(StubURLProtocol.requests(host: host).first)
        #expect(seen.method == "PUT")
        #expect(seen.body == rig.content)
        #expect(seen.headers["Content-Type"] == "image/png")
        #expect(result.link.absoluteString == "https://http-b.test/view/1")
    }

    @Test func aServerErrorShowsTheUploadersOwnMessageAndAnAnswerWithoutALinkIsReported() async throws {
        let rig = try rig()
        let host = "http-c.test"
        let json = #"{"Version":"16.1.0","RequestURL":"https://http-c.test/up","Body":"MultipartFormData","FileFormName":"f","URL":"{json:data.link}","ErrorMessage":"{json:error.message}"}"#
        let imported = try ShareXImporter.importUploader(from: Data(json.utf8))
        StubURLProtocol.install(host: host) { _ in (400, [:], #"{"error":{"message":"Invalid image"}}"#) }
        await #expect(throws: UploadError.server(status: 400, message: "Invalid image")) {
            try await rig.uploader.upload(fileAt: rig.file, to: imported.destination)
        }
        StubURLProtocol.install(host: host) { _ in (200, [:], #"{"data":{}}"#) }
        await #expect(throws: UploadError.linkMissing) { try await rig.uploader.upload(fileAt: rig.file, to: imported.destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.temporary.path()).isEmpty)
    }

    // MARK: Names, cancellation, jobs

    @Test func namesAreRandomUnlessAskedForTheOriginal() {
        let url = URL(fileURLWithPath: "/tmp/UUID-1234.PNG")
        let random = UploadNaming.name(for: url, originalName: "CleanShot 2026-10-16 at 14.02.11.png", naming: .random)
        #expect(random.count == 14 && random.hasSuffix(".png"))
        #expect(random.dropLast(4).allSatisfy { $0.isLowercase || $0.isNumber })
        #expect(UploadNaming.name(for: url, originalName: "a/b:c.png", naming: .original) == "a-b:c.png")
        #expect(UploadNaming.name(for: url, originalName: nil, naming: .original) == "UUID-1234.PNG")
        var generator = SystemRandomNumberGenerator()
        #expect(UploadNaming.randomName(extension: "", using: &generator).count == 10)
    }

    @Test func cancellingStopsTheUploadAndLeavesNothingBehind() async throws {
        let rig = try rig()
        let host = "http-d.test"
        let json = #"{"Version":"16.1.0","RequestURL":"https://http-d.test/up","Body":"MultipartFormData","FileFormName":"f"}"#
        let imported = try ShareXImporter.importUploader(from: Data(json.utf8))
        StubURLProtocol.install(host: host) { _ in (200, [:], "https://http-d.test/x") }
        let task = Task { try await rig.uploader.upload(fileAt: rig.file, to: imported.destination) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.temporary.path()).isEmpty)
        #expect(rig.resources.isIdle)
    }

    @MainActor
    @Test func aJobReportsItsOutcome() async throws {
        let rig = try rig()
        let host = "s3-f.test"
        let target = destination(.s3(S3Settings(endpoint: URL(string: "https://\(host)")!, bucket: "bk")))
        try rig.secrets.setSecret("a", field: SecretField.s3AccessKeyID, of: target.id)
        try rig.secrets.setSecret("b", field: SecretField.s3SecretAccessKey, of: target.id)
        StubURLProtocol.install(host: host) { _ in (200, [:], "") }
        let job = UploadJob(fileURL: rig.file, destination: target, uploader: rig.uploader)
        #expect(job.state == .waiting)
        job.start()
        let state = await job.finish()
        guard case .finished(let result) = state else { Issue.record("state \(state)"); return }
        #expect(result.link.host() == host)

        let failing = UploadJob(fileURL: rig.file, destination: destination(.s3(S3Settings(endpoint: URL(string: "https://\(host)")!, bucket: "bk"))), uploader: rig.uploader)
        failing.start()
        let failed = await failing.finish()
        #expect(failed == .failed(.secretMissing(field: SecretField.s3AccessKeyID)))
    }

    @Test func plainMetadataNeverLeaksSecretsIntoTheDescriptionOfAnError() {
        let error = UploadError.secretMissing(field: "header:Authorization")
        #expect(!(error.errorDescription ?? "").contains("Bearer"))
        #expect(UploadError.fileTooLarge(limit: 5_000_000).errorDescription?.contains("MB") == true)
    }
}
