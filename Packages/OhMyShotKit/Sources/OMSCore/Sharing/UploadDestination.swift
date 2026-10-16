import Foundation

/// Which file name a capture is uploaded under.
public enum FileNaming: String, Codable, CaseIterable, Sendable {
    /// Ten random lowercase letters and digits and the file's extension. Capture names carry the date, the
    /// time and often the app a capture came from, which are not for a stranger holding a link to read, and a
    /// random name cannot be guessed from the one before it.
    case random
    /// The name the capture has on the user's Mac.
    case original
}

/// A place the user shares captures to: storage they own, with a name they gave it.
///
/// This holds everything that is not secret. Passwords, keys and the values of headers and form fields
/// (which carry API tokens) live in the Keychain under the destination's id; see `SecretStore`.
public struct UploadDestination: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var fileNaming: FileNaming
    public var configuration: Configuration

    public enum Configuration: Codable, Equatable, Sendable {
        case s3(S3Settings)
        case webDAV(WebDAVSettings)
        case customHTTP(CustomHTTPSettings)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        fileNaming: FileNaming = .random,
        configuration: Configuration
    ) {
        self.id = id
        self.name = name
        self.fileNaming = fileNaming
        self.configuration = configuration
    }

    /// The names of this destination's secrets, so they can be written, shown as set, and all removed when
    /// the destination is.
    public var secretFields: [String] {
        switch configuration {
        case .s3:
            [SecretField.s3AccessKeyID, SecretField.s3SecretAccessKey]
        case .webDAV:
            [SecretField.webDAVPassword]
        case .customHTTP(let settings):
            settings.parameterNames.map(SecretField.parameter)
                + settings.headerNames.map(SecretField.header)
                + settings.argumentNames.map(SecretField.argument)
        }
    }

    /// What kind of server this is, for a list row's subtitle and icon.
    public var kindName: String {
        switch configuration {
        case .s3: "S3"
        case .webDAV: "WebDAV"
        case .customHTTP: "Custom HTTP"
        }
    }
}

/// Names of the secrets a destination keeps in the Keychain.
public enum SecretField {
    public static let s3AccessKeyID = "s3.accessKeyID"
    public static let s3SecretAccessKey = "s3.secretAccessKey"
    public static let webDAVPassword = "webdav.password"

    public static func header(_ name: String) -> String { "header:\(name)" }
    public static func argument(_ name: String) -> String { "argument:\(name)" }
    public static func parameter(_ name: String) -> String { "parameter:\(name)" }
}

// MARK: S3

/// An S3-compatible bucket: AWS S3, Cloudflare R2, MinIO, Backblaze B2 and the like.
public struct S3Settings: Codable, Equatable, Sendable {
    /// How the link a share produces is made. S3 never returns one.
    public enum LinkStyle: String, Codable, CaseIterable, Sendable {
        /// The public base URL and the object's key, or the object's own address when there is no base URL
        /// (a bucket that allows anonymous reads).
        case publicURL
        /// A signed address that works without credentials until it expires, for a private bucket.
        case presigned
    }

    /// The service address without the bucket, as `https://s3.us-east-1.amazonaws.com`,
    /// `https://<account>.r2.cloudflarestorage.com` or `http://127.0.0.1:9000`.
    public var endpoint: URL
    /// The region requests are signed for. R2 uses `auto`.
    public var region: String
    public var bucket: String
    /// The bucket in the path (`host/bucket/key`) rather than the host name (`bucket.host/key`). Custom
    /// endpoints and addresses of the form 127.0.0.1 only work this way; AWS also accepts the other.
    public var usesPathStyle: Bool
    /// A folder inside the bucket, without a leading or trailing slash; empty for the top.
    public var keyPrefix: String
    /// A canned ACL sent as `x-amz-acl`, such as `public-read`; nil sends none. R2 rejects ACLs.
    public var acl: String?
    /// Where the objects are served from for people with the link: a custom domain or `https://pub-xxx.r2.dev`.
    public var publicBaseURL: URL?
    public var linkStyle: LinkStyle
    /// How long a presigned link works, in seconds. SigV4 allows at most 7 days.
    public var presignedExpiry: TimeInterval

    public static let maximumPresignedExpiry: TimeInterval = 7 * 86_400
    public static let defaultPresignedExpiry: TimeInterval = 7 * 86_400

    public init(
        endpoint: URL,
        region: String = "us-east-1",
        bucket: String,
        usesPathStyle: Bool = true,
        keyPrefix: String = "",
        acl: String? = nil,
        publicBaseURL: URL? = nil,
        linkStyle: LinkStyle = .publicURL,
        presignedExpiry: TimeInterval = S3Settings.defaultPresignedExpiry
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.usesPathStyle = usesPathStyle
        self.keyPrefix = keyPrefix
        self.acl = acl
        self.publicBaseURL = publicBaseURL
        self.linkStyle = linkStyle
        self.presignedExpiry = presignedExpiry
    }

    /// The settings for a bucket on AWS itself: its regional endpoint and the host-name form of the address.
    public static func aws(region: String, bucket: String) -> S3Settings {
        S3Settings(
            endpoint: URL(string: "https://s3.\(region).amazonaws.com")!,
            region: region,
            bucket: bucket,
            usesPathStyle: false
        )
    }
}

// MARK: WebDAV

/// A WebDAV folder (Nextcloud, a NAS, `rclone serve webdav`).
public struct WebDAVSettings: Codable, Equatable, Sendable {
    /// The folder uploads go into, as `https://cloud.example.com/remote.php/dav/files/me/Screenshots`.
    public var baseURL: URL
    public var username: String
    /// Where the folder is served to people with the link. Without it the link is the WebDAV address itself,
    /// which only works for someone who can sign in.
    public var publicBaseURL: URL?
    /// A folder below the base URL, created when it is missing; empty for none.
    public var keyPrefix: String

    public init(baseURL: URL, username: String, publicBaseURL: URL? = nil, keyPrefix: String = "") {
        self.baseURL = baseURL
        self.username = username
        self.publicBaseURL = publicBaseURL
        self.keyPrefix = keyPrefix
    }
}

// MARK: Custom HTTP

/// A ShareX custom uploader: a request built from templates and a link read out of the response.
///
/// The templates are kept as written in the `.sxcu` file, in the current `{json:data.link}` syntax (older
/// files are converted on import). Only the *names* of query parameters, headers and form arguments are kept
/// here; their values go in the Keychain because they usually carry an API token.
public struct CustomHTTPSettings: Codable, Equatable, Sendable {
    public enum Method: String, Codable, CaseIterable, Sendable {
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
    }

    /// The bodies a file can be sent in. ShareX has three more (none, URL-encoded form, JSON and XML) that
    /// carry text rather than a file; importing a file that uses one is refused.
    public enum BodyType: String, Codable, CaseIterable, Sendable {
        case multipartFormData = "MultipartFormData"
        case binary = "Binary"
    }

    public var method: Method
    /// The address, a template; it holds no query string, which is kept in `parameterNames`.
    public var requestURL: String
    public var parameterNames: [String]
    public var headerNames: [String]
    public var bodyType: BodyType
    /// The form field the file goes in, for a multipart body.
    public var fileFormName: String
    public var argumentNames: [String]
    /// A template for the link; empty means the whole response is the link.
    public var urlTemplate: String
    public var deletionURLTemplate: String
    public var thumbnailURLTemplate: String
    /// A template for a message to show when the server answers with an error.
    public var errorMessageTemplate: String

    public init(
        method: Method = .post,
        requestURL: String,
        parameterNames: [String] = [],
        headerNames: [String] = [],
        bodyType: BodyType = .multipartFormData,
        fileFormName: String = "file",
        argumentNames: [String] = [],
        urlTemplate: String = "",
        deletionURLTemplate: String = "",
        thumbnailURLTemplate: String = "",
        errorMessageTemplate: String = ""
    ) {
        self.method = method
        self.requestURL = requestURL
        self.parameterNames = parameterNames
        self.headerNames = headerNames
        self.bodyType = bodyType
        self.fileFormName = fileFormName
        self.argumentNames = argumentNames
        self.urlTemplate = urlTemplate
        self.deletionURLTemplate = deletionURLTemplate
        self.thumbnailURLTemplate = thumbnailURLTemplate
        self.errorMessageTemplate = errorMessageTemplate
    }
}

/// What a finished upload gives back.
public struct UploadResult: Equatable, Sendable {
    /// The address to share.
    public var link: URL
    public var deletionURL: URL?
    public var thumbnailURL: URL?
    /// The name the file was uploaded under.
    public var fileName: String
    /// When a presigned link stops working; nil for a link that does not expire.
    public var expiresAt: Date?
    /// Where the file is in the storage, for the kinds that can delete it with a signed request.
    public var remoteKey: String?

    public init(link: URL, deletionURL: URL? = nil, thumbnailURL: URL? = nil, fileName: String, expiresAt: Date? = nil, remoteKey: String? = nil) {
        self.link = link
        self.deletionURL = deletionURL
        self.thumbnailURL = thumbnailURL
        self.fileName = fileName
        self.expiresAt = expiresAt
        self.remoteKey = remoteKey
    }
}
