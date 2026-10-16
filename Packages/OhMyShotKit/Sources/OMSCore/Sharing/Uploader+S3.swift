import Foundation

/// Where an S3 object is, as the pieces both the request and the link are made from.
struct S3ObjectAddress: Equatable {
    var scheme: String
    /// Host and port as signed.
    var host: String
    /// The path as sent, already percent-encoded.
    var path: String
    var key: String

    var url: URL? { URL(string: "\(scheme)://\(host)\(path)") }

    init(settings: S3Settings, name: String) throws {
        guard let scheme = settings.endpoint.scheme?.lowercased(), scheme == "http" || scheme == "https",
              settings.endpoint.host() != nil
        else { throw UploadError.invalidConfiguration(String(localized: "the endpoint isn’t an http or https address")) }
        guard !settings.bucket.isEmpty else { throw UploadError.invalidConfiguration(String(localized: "the bucket name is empty")) }
        let folder = Uploader.normalizedFolder(settings.keyPrefix)
        key = folder.isEmpty ? name : "\(folder)/\(name)"
        self.scheme = scheme
        let base = Uploader.hostWithPort(of: settings.endpoint)
        let endpointPath = Uploader.normalizedFolder(settings.endpoint.path(percentEncoded: false))
        let prefix = endpointPath.isEmpty ? "" : "/" + SigV4Signer.encodePath(endpointPath)
        if settings.usesPathStyle {
            host = base
            path = "\(prefix)/\(SigV4Signer.encode(settings.bucket))/\(SigV4Signer.encodePath(key))"
        } else {
            host = "\(settings.bucket).\(base)"
            path = "\(prefix)/\(SigV4Signer.encodePath(key))"
        }
    }
}

extension Uploader {
    func uploadToS3(
        _ fileURL: URL,
        size: Int64,
        name: String,
        destination: UploadDestination,
        settings: S3Settings,
        transport: Transport
    ) async throws -> UploadResult {
        if size > 5 * 1024 * 1024 * 1024 { throw UploadError.fileTooLarge(limit: 5 * 1024 * 1024 * 1024) }
        let address = try S3ObjectAddress(settings: settings, name: name)
        guard let url = address.url else { throw UploadError.invalidConfiguration(String(localized: "the endpoint and bucket don’t make an address")) }
        let signer = SigV4Signer(
            accessKeyID: try secret(SecretField.s3AccessKeyID, of: destination),
            secretAccessKey: try secret(SecretField.s3SecretAccessKey, of: destination),
            region: settings.region.isEmpty ? "us-east-1" : settings.region
        )

        // The payload is signed rather than sent unsigned, so a server can tell a damaged upload from a good one.
        let payloadHash = try await SigV4Signer.sha256(ofFileAt: fileURL)
        let now = Date()
        var signed = [
            "host": address.host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": SigV4Signer.timestamp(now),
        ]
        if let acl = settings.acl, !acl.isEmpty { signed["x-amz-acl"] = acl }
        let signature = signer.sign(method: "PUT", canonicalPath: address.path, headers: signed, payloadHash: payloadHash, date: now)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (header, value) in signed where header != "host" { request.setValue(value, forHTTPHeaderField: header) }
        request.setValue(signature.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(Self.mimeType(of: fileURL), forHTTPHeaderField: "Content-Type")

        let response = try await transport.send(request, body: fileURL)
        guard (200..<300).contains(response.status) else {
            let (code, message) = Self.s3Error(in: response.text)
            switch code {
            case "SignatureDoesNotMatch", "InvalidAccessKeyId", "AccessDenied", "InvalidSecurity":
                throw UploadError.authRejected(detail: message)
            case "NoSuchBucket":
                throw UploadError.notFound(detail: message)
            case "RequestTimeTooSkewed":
                throw UploadError.clockSkew
            case "EntityTooLarge":
                throw UploadError.fileTooLarge(limit: nil)
            default:
                throw Self.failure(status: response.status, message: message ?? code)
            }
        }

        switch settings.linkStyle {
        case .presigned:
            let seconds = Int(min(max(settings.presignedExpiry, 1), S3Settings.maximumPresignedExpiry))
            let presigned = signer.presignedQuery(canonicalPath: address.path, host: address.host, expires: seconds, date: now)
            guard let link = URL(string: "\(address.scheme)://\(address.host)\(address.path)?\(presigned.query)") else { throw UploadError.linkMissing }
            return UploadResult(link: link, fileName: name, expiresAt: now.addingTimeInterval(TimeInterval(seconds)))
        case .publicURL:
            return UploadResult(link: try Self.publicLink(base: settings.publicBaseURL, key: address.key, fallback: url), fileName: name)
        }
    }

    /// The public base URL and the key encoded as the object was stored; without a base, the object's own address.
    static func publicLink(base: URL?, key: String, fallback: URL) throws -> URL {
        guard let base else { return fallback }
        let text = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        guard let link = URL(string: "\(text)/\(SigV4Signer.encodePath(key))") else {
            throw UploadError.invalidConfiguration(String(localized: "the public URL isn’t an address"))
        }
        return link
    }
}
