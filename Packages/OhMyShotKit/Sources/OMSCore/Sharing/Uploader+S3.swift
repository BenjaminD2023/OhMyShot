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
        let folder = Uploader.normalizedFolder(settings.keyPrefix)
        try self.init(settings: settings, key: folder.isEmpty ? name : "\(folder)/\(name)")
    }

    /// An object whose whole key is known, such as one a record remembers.
    init(settings: S3Settings, key: String) throws {
        guard let scheme = settings.endpoint.scheme?.lowercased(), scheme == "http" || scheme == "https",
              settings.endpoint.host() != nil
        else { throw UploadError.invalidConfiguration(String(localized: "the endpoint isn’t an http or https address")) }
        guard !settings.bucket.isEmpty else { throw UploadError.invalidConfiguration(String(localized: "the bucket name is empty")) }
        self.key = key
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
        let address = try S3ObjectAddress(settings: settings, name: name)
        let signer = try s3Signer(for: destination, settings: settings)
        let multipart = size > multipartThreshold
        if !multipart, size > 5 * 1024 * 1024 * 1024 { throw UploadError.fileTooLarge(limit: 5 * 1024 * 1024 * 1024) }

        if multipart {
            try await uploadToS3InParts(fileURL, size: size, address: address, signer: signer, settings: settings, transport: transport)
        } else {
            // The payload is signed rather than sent unsigned, so a server can tell a damaged upload from a good one.
            let payloadHash = try await SigV4Signer.sha256(ofFileAt: fileURL)
            var request = try s3Request("PUT", address, signer: signer, settings: settings, payloadHash: payloadHash)
            request.setValue(Self.mimeType(of: fileURL), forHTTPHeaderField: "Content-Type")
            try Self.requireS3Success(try await transport.send(request, body: fileURL))
        }

        switch settings.linkStyle {
        case .presigned:
            let now = Date()
            let seconds = Int(min(max(settings.presignedExpiry, 1), S3Settings.maximumPresignedExpiry))
            let presigned = signer.presignedQuery(canonicalPath: address.path, host: address.host, expires: seconds, date: now)
            guard let link = URL(string: "\(address.scheme)://\(address.host)\(address.path)?\(presigned.query)") else { throw UploadError.linkMissing }
            return UploadResult(link: link, fileName: name, expiresAt: now.addingTimeInterval(TimeInterval(seconds)), remoteKey: address.key)
        case .publicURL:
            guard let url = address.url else { throw UploadError.invalidConfiguration(String(localized: "the endpoint and bucket don’t make an address")) }
            return UploadResult(link: try Self.publicLink(base: settings.publicBaseURL, key: address.key, fallback: url), fileName: name, remoteKey: address.key)
        }
    }

    // MARK: Requests

    func s3Signer(for destination: UploadDestination, settings: S3Settings) throws -> SigV4Signer {
        SigV4Signer(
            accessKeyID: try secret(SecretField.s3AccessKeyID, of: destination),
            secretAccessKey: try secret(SecretField.s3SecretAccessKey, of: destination),
            region: settings.region.isEmpty ? "us-east-1" : settings.region
        )
    }

    /// A signed request to an object, with the sub-resource `query` (such as `uploads` or `partNumber`). The
    /// ACL is sent only with the request that creates the object.
    func s3Request(
        _ method: String,
        _ address: S3ObjectAddress,
        query: [(name: String, value: String)] = [],
        sendsACL: Bool = true,
        signer: SigV4Signer,
        settings: S3Settings,
        payloadHash: String
    ) throws -> URLRequest {
        let queryText = SigV4Signer.canonicalQuery(query)
        guard let url = URL(string: "\(address.scheme)://\(address.host)\(address.path)" + (query.isEmpty ? "" : "?\(queryText)")) else {
            throw UploadError.invalidConfiguration(String(localized: "the endpoint and bucket don’t make an address"))
        }
        let now = Date()
        var signed = [
            "host": address.host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": SigV4Signer.timestamp(now),
        ]
        if sendsACL, let acl = settings.acl, !acl.isEmpty { signed["x-amz-acl"] = acl }
        let signature = signer.sign(method: method, canonicalPath: address.path, query: query, headers: signed, payloadHash: payloadHash, date: now)
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (header, value) in signed where header != "host" { request.setValue(value, forHTTPHeaderField: header) }
        request.setValue(signature.authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Throws the error an S3 answer stands for, unless it is a success.
    static func requireS3Success(_ response: UploadResponse) throws {
        guard (200..<300).contains(response.status) else { throw s3Failure(response) }
    }

    static func s3Failure(_ response: UploadResponse) -> UploadError {
        let (code, message) = s3Error(in: response.text)
        switch code {
        case "SignatureDoesNotMatch", "InvalidAccessKeyId", "AccessDenied", "InvalidSecurity":
            return .authRejected(detail: message)
        case "NoSuchBucket":
            return .notFound(detail: message)
        case "RequestTimeTooSkewed":
            return .clockSkew
        case "EntityTooLarge":
            return .fileTooLarge(limit: nil)
        default:
            return failure(status: response.status, message: message ?? code)
        }
    }

    // MARK: Delete

    /// Removes a file from the storage with a signed DELETE. A file that is already gone counts as removed.
    func deleteFromS3(key: String, destination: UploadDestination, settings: S3Settings, transport: Transport) async throws {
        let address = try S3ObjectAddress(settings: settings, key: key)
        let signer = try s3Signer(for: destination, settings: settings)
        let request = try s3Request("DELETE", address, sendsACL: false, signer: signer, settings: settings, payloadHash: SigV4Signer.emptyPayloadHash)
        let response = try await transport.send(request)
        if response.status == 404, Self.s3Error(in: response.text).code == "NoSuchKey" { return }
        try Self.requireS3Success(response)
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
