import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3, with nothing in it that touches the network.
///
/// S3 differs from the other services in one way that matters here: the canonical URI is the path as it is
/// sent, encoded once. (The general SigV4 suite encodes it a second time.) A key with a space, a `+`, a `#`
/// or CJK characters is therefore signed in the exact form it travels in.
public struct SigV4Signer: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let region: String
    public let service: String

    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public init(accessKeyID: String, secretAccessKey: String, region: String, service: String = "s3") {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.service = service
    }

    /// Everything a signature is made of, so tests can compare each step with AWS's worked examples.
    public struct Signed: Equatable, Sendable {
        public let canonicalRequest: String
        public let stringToSign: String
        public let signature: String
        public let signedHeaders: String
        /// The value of the `Authorization` header.
        public let authorization: String
    }

    /// Signs a request for the `Authorization` header.
    ///
    /// - Parameters:
    ///   - canonicalPath: The path already percent-encoded as it will be sent; see `SigV4Signer.encode`.
    ///   - query: Name and value pairs, not yet encoded.
    ///   - headers: Every header that is signed. Names are lowercased and values trimmed here; `host` and
    ///     `x-amz-date` have to be among them, with the port in `host` when it is not the scheme's own.
    ///   - payloadHash: The hex SHA-256 of the body, or `unsignedPayload`.
    public func sign(
        method: String,
        canonicalPath: String,
        query: [(name: String, value: String)] = [],
        headers: [String: String],
        payloadHash: String,
        date: Date
    ) -> Signed {
        let stamp = Self.timestamp(date)
        let canonical = Self.normalizedHeaders(headers)
        let signedHeaders = canonical.map(\.name).joined(separator: ";")
        let request = [
            method,
            canonicalPath,
            Self.canonicalQuery(query),
            canonical.map { "\($0.name):\($0.value)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let (stringToSign, signature) = finish(canonicalRequest: request, stamp: stamp)
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope(stamp)),SignedHeaders=\(signedHeaders),Signature=\(signature)"
        return Signed(
            canonicalRequest: request,
            stringToSign: stringToSign,
            signature: signature,
            signedHeaders: signedHeaders,
            authorization: authorization
        )
    }

    /// A presigned address: the query string, signature included, to put after the path of a GET.
    ///
    /// Only `host` is signed and the payload is `UNSIGNED-PAYLOAD`, which is how S3 reads a link that
    /// someone else will fetch.
    public func presignedQuery(
        method: String = "GET",
        canonicalPath: String,
        host: String,
        extraQuery: [(name: String, value: String)] = [],
        expires: Int,
        date: Date
    ) -> (query: String, signature: String, canonicalRequest: String, stringToSign: String) {
        let stamp = Self.timestamp(date)
        let query = extraQuery + [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKeyID)/\(scope(stamp))"),
            ("X-Amz-Date", stamp),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let canonicalQuery = Self.canonicalQuery(query)
        let request = [
            method,
            canonicalPath,
            canonicalQuery,
            "host:\(host)\n",
            "host",
            Self.unsignedPayload,
        ].joined(separator: "\n")
        let (stringToSign, signature) = finish(canonicalRequest: request, stamp: stamp)
        return (canonicalQuery + "&X-Amz-Signature=" + signature, signature, request, stringToSign)
    }

    // MARK: Steps

    private func scope(_ stamp: String) -> String {
        "\(stamp.prefix(8))/\(region)/\(service)/aws4_request"
    }

    private func finish(canonicalRequest: String, stamp: String) -> (stringToSign: String, signature: String) {
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            stamp,
            scope(stamp),
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")
        let key = signingKey(day: String(stamp.prefix(8)))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return (stringToSign, Self.hex(mac))
    }

    func signingKey(day: String) -> SymmetricKey {
        func mac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        let seed = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        return mac(mac(mac(mac(seed, day), region), service), "aws4_request")
    }

    // MARK: Encoding

    /// `20130524T000000Z`, in UTC whatever the Mac's time zone is.
    public static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

    /// AWS's UriEncode: every byte but the unreserved characters becomes `%XX` in capitals, so a space is
    /// `%20` and never `+`. A slash is encoded unless `keepSlash` is set, which is how an object key's path
    /// is written.
    public static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if unreserved.contains(byte) || (keepSlash && byte == UInt8(ascii: "/")) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// An object key as it is written in a path: each segment encoded, the slashes between them kept.
    public static func encodePath(_ key: String) -> String {
        encode(key, keepSlash: true)
    }

    static func canonicalQuery(_ query: [(name: String, value: String)]) -> String {
        var pairs: [(name: String, value: String)] = []
        for item in query { pairs.append((name: encode(item.name), value: encode(item.value))) }
        pairs.sort { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static func normalizedHeaders(_ headers: [String: String]) -> [(name: String, value: String)] {
        var list: [(name: String, value: String)] = []
        for (name, value) in headers {
            let collapsed = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            list.append((name: name.lowercased(), value: collapsed))
        }
        return list.sorted { $0.name < $1.name }
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The hex SHA-256 of a file, read in chunks so a recording of hundreds of megabytes is never in memory.
    /// Checks for cancellation between chunks; the progress callback gets the fraction read.
    @concurrent
    public static func sha256(ofFileAt url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var read: UInt64 = 0
        var finished = false
        while !finished {
            try Task.checkCancellation()
            // Each chunk is an autoreleased object; without a pool per turn they all stay alive until the loop
            // ends, which is the whole file in memory.
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { finished = true; return }
                hasher.update(data: chunk)
                read += UInt64(chunk.count)
                if total > 0 { progress?(Double(read) / Double(total)) }
            }
        }
        return hex(hasher.finalize())
    }
}
