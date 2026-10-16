import Foundation

/// A destination as its editor holds it while it is filled in: text fields for everything, secrets as typed.
///
/// The editor never reads a saved secret back: a secret field left empty means "keep the one stored", and
/// `isStored` says whether there is one. This holds the rules of the form (what is required, what must look
/// like an address) so they are tested without an interface.
public struct UploadDestinationDraft: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case amazonS3
        case s3Compatible
        case webDAV
        case customHTTP

        public var id: String { rawValue }
    }

    /// One query parameter, header or form field of a custom uploader. Its value is a secret.
    public struct Row: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var name: String
        /// What was typed; empty keeps the stored value when `isStored`.
        public var value: String
        /// A value for this name is in the Keychain already.
        public var isStored: Bool

        public init(name: String = "", value: String = "", isStored: Bool = false) {
            self.name = name
            self.value = value
            self.isStored = isStored
        }
    }

    public let id: UUID
    public var kind: Kind
    public var name: String
    public var fileNaming: FileNaming

    // S3
    public var endpoint = ""
    public var region = "us-east-1"
    public var bucket = ""
    public var usesPathStyle = true
    public var keyPrefix = ""
    public var acl = ""
    public var publicBaseURL = ""
    public var linkStyle = S3Settings.LinkStyle.publicURL
    public var presignedDays = 7
    public var accessKeyID = ""
    public var secretAccessKey = ""

    // WebDAV
    public var davURL = ""
    public var username = ""
    public var password = ""

    // Custom HTTP
    public var method = CustomHTTPSettings.Method.post
    public var requestURL = ""
    public var bodyType = CustomHTTPSettings.BodyType.multipartFormData
    public var fileFormName = "file"
    public var urlTemplate = ""
    public var deletionURLTemplate = ""
    public var thumbnailURLTemplate = ""
    public var errorMessageTemplate = ""
    public var parameters: [Row] = []
    public var headers: [Row] = []
    public var arguments: [Row] = []

    /// Secrets already in the Keychain for the destination being edited, by field name.
    private var stored: Set<String> = []

    /// Whether this edits a destination that is saved.
    public let isExisting: Bool

    public init(kind: Kind) {
        id = UUID()
        self.kind = kind
        name = Self.defaultName(for: kind)
        fileNaming = .random
        isExisting = false
        switch kind {
        case .amazonS3:
            usesPathStyle = false
        case .s3Compatible:
            usesPathStyle = true
            region = "auto"
        case .webDAV, .customHTTP:
            break
        }
    }

    /// A draft of a saved destination. `storedSecrets` names the fields whose secrets are in the Keychain.
    public init(destination: UploadDestination, storedSecrets: Set<String>) {
        id = destination.id
        name = destination.name
        fileNaming = destination.fileNaming
        isExisting = true
        stored = storedSecrets
        switch destination.configuration {
        case .s3(let settings):
            let isAWS = !settings.usesPathStyle && settings.endpoint == S3Settings.aws(region: settings.region, bucket: settings.bucket).endpoint
            kind = isAWS ? .amazonS3 : .s3Compatible
            endpoint = settings.endpoint.absoluteString
            region = settings.region
            bucket = settings.bucket
            usesPathStyle = settings.usesPathStyle
            keyPrefix = settings.keyPrefix
            acl = settings.acl ?? ""
            publicBaseURL = settings.publicBaseURL?.absoluteString ?? ""
            linkStyle = settings.linkStyle
            presignedDays = max(1, min(7, Int((settings.presignedExpiry / 86_400).rounded())))
        case .webDAV(let settings):
            kind = .webDAV
            davURL = settings.baseURL.absoluteString
            username = settings.username
            publicBaseURL = settings.publicBaseURL?.absoluteString ?? ""
            keyPrefix = settings.keyPrefix
        case .customHTTP(let settings):
            kind = .customHTTP
            method = settings.method
            requestURL = settings.requestURL
            bodyType = settings.bodyType
            fileFormName = settings.fileFormName
            urlTemplate = settings.urlTemplate
            deletionURLTemplate = settings.deletionURLTemplate
            thumbnailURLTemplate = settings.thumbnailURLTemplate
            errorMessageTemplate = settings.errorMessageTemplate
            parameters = settings.parameterNames.map { Row(name: $0, isStored: storedSecrets.contains(SecretField.parameter($0))) }
            headers = settings.headerNames.map { Row(name: $0, isStored: storedSecrets.contains(SecretField.header($0))) }
            arguments = settings.argumentNames.map { Row(name: $0, isStored: storedSecrets.contains(SecretField.argument($0))) }
        }
    }

    /// The kind as the editor's title says it.
    public static func title(for kind: Kind) -> String {
        switch kind {
        case .amazonS3: String(localized: "Amazon S3")
        case .s3Compatible: String(localized: "S3-compatible storage")
        case .webDAV: String(localized: "WebDAV")
        case .customHTTP: String(localized: "Custom HTTP")
        }
    }

    public static func defaultName(for kind: Kind) -> String {
        switch kind {
        case .amazonS3: String(localized: "Amazon S3")
        case .s3Compatible: String(localized: "S3-compatible storage")
        case .webDAV: String(localized: "WebDAV")
        case .customHTTP: String(localized: "Custom server")
        }
    }

    /// A secret of the plain kinds is saved already and need not be typed again.
    public func isStored(_ field: String) -> Bool { stored.contains(field) }

    // MARK: Checking

    /// The first thing wrong with the form, as a sentence for the person; nil when it can be saved.
    public func firstIssue() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Give the destination a name.")
        }
        switch kind {
        case .amazonS3, .s3Compatible:
            return s3Issue()
        case .webDAV:
            return webDAVIssue()
        case .customHTTP:
            return customIssue()
        }
    }

    private func s3Issue() -> String? {
        if kind == .s3Compatible, Self.httpURL(endpoint) == nil {
            return String(localized: "Enter the endpoint, such as https://s3.example.com.")
        }
        if region.trimmed.isEmpty { return String(localized: "Enter the region.") }
        if bucket.trimmed.isEmpty { return String(localized: "Enter the bucket name.") }
        if accessKeyID.trimmed.isEmpty, !isStored(SecretField.s3AccessKeyID) { return String(localized: "Enter the access key ID.") }
        if secretAccessKey.isEmpty, !isStored(SecretField.s3SecretAccessKey) { return String(localized: "Enter the secret access key.") }
        if !publicBaseURL.trimmed.isEmpty, Self.httpURL(publicBaseURL) == nil {
            return String(localized: "The public address must start with http:// or https://.")
        }
        return nil
    }

    private func webDAVIssue() -> String? {
        if Self.httpURL(davURL) == nil { return String(localized: "Enter the folder’s address, starting with http:// or https://.") }
        if username.trimmed.isEmpty { return String(localized: "Enter the user name.") }
        if password.isEmpty, !isStored(SecretField.webDAVPassword) { return String(localized: "Enter the password.") }
        if !publicBaseURL.trimmed.isEmpty, Self.httpURL(publicBaseURL) == nil {
            return String(localized: "The public address must start with http:// or https://.")
        }
        return nil
    }

    private func customIssue() -> String? {
        let address = requestURL.trimmed
        if !(address.lowercased().hasPrefix("http://") || address.lowercased().hasPrefix("https://")) || address.count < 9 {
            return String(localized: "Enter the upload address, starting with http:// or https://.")
        }
        if fileFormName.trimmed.isEmpty, bodyType == .multipartFormData { return String(localized: "Enter the name of the form field the file goes in.") }
        for rows in [parameters, headers, arguments] {
            let names = rows.map { $0.name.trimmed }
            if names.contains("") { return String(localized: "Fill in or remove the empty row.") }
            if Set(names).count != names.count { return String(localized: "Two rows have the same name.") }
            for row in rows where row.value.isEmpty && !row.isStored {
                return String(localized: "Enter a value for \(row.name.trimmed).")
            }
        }
        return nil
    }

    /// An address with a scheme of http or https and a host.
    public static func httpURL(_ text: String) -> URL? {
        let trimmed = text.trimmed
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    // MARK: Building

    /// The destination and the secrets to store with it; nil while `firstIssue()` has something to say.
    ///
    /// A secret left empty is left out, which keeps the stored one (`UploadDestinationStore.save`).
    public func build() -> (destination: UploadDestination, secrets: [String: String])? {
        guard firstIssue() == nil else { return nil }
        let title = name.trimmed
        let prefix = keyPrefix.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch kind {
        case .amazonS3, .s3Compatible:
            let aws = S3Settings.aws(region: region.trimmed, bucket: bucket.trimmed)
            var settings = S3Settings(
                endpoint: kind == .amazonS3 ? aws.endpoint : Self.httpURL(endpoint)!,
                region: region.trimmed,
                bucket: bucket.trimmed,
                usesPathStyle: kind == .amazonS3 ? false : usesPathStyle,
                keyPrefix: prefix,
                acl: acl.trimmed.isEmpty ? nil : acl.trimmed,
                publicBaseURL: publicBaseURL.trimmed.isEmpty ? nil : Self.httpURL(publicBaseURL),
                linkStyle: linkStyle
            )
            settings.presignedExpiry = TimeInterval(max(1, min(7, presignedDays))) * 86_400
            var secrets: [String: String] = [:]
            if !accessKeyID.trimmed.isEmpty { secrets[SecretField.s3AccessKeyID] = accessKeyID.trimmed }
            if !secretAccessKey.isEmpty { secrets[SecretField.s3SecretAccessKey] = secretAccessKey }
            return (UploadDestination(id: id, name: title, fileNaming: fileNaming, configuration: .s3(settings)), secrets)
        case .webDAV:
            let settings = WebDAVSettings(
                baseURL: Self.httpURL(davURL)!,
                username: username.trimmed,
                publicBaseURL: publicBaseURL.trimmed.isEmpty ? nil : Self.httpURL(publicBaseURL),
                keyPrefix: prefix
            )
            let secrets = password.isEmpty ? [:] : [SecretField.webDAVPassword: password]
            return (UploadDestination(id: id, name: title, fileNaming: fileNaming, configuration: .webDAV(settings)), secrets)
        case .customHTTP:
            let settings = CustomHTTPSettings(
                method: method,
                requestURL: requestURL.trimmed,
                parameterNames: parameters.map { $0.name.trimmed },
                headerNames: headers.map { $0.name.trimmed },
                bodyType: bodyType,
                fileFormName: fileFormName.trimmed,
                argumentNames: arguments.map { $0.name.trimmed },
                urlTemplate: urlTemplate.trimmed,
                deletionURLTemplate: deletionURLTemplate.trimmed,
                thumbnailURLTemplate: thumbnailURLTemplate.trimmed,
                errorMessageTemplate: errorMessageTemplate.trimmed
            )
            var secrets: [String: String] = [:]
            for row in parameters where !row.value.isEmpty { secrets[SecretField.parameter(row.name.trimmed)] = row.value }
            for row in headers where !row.value.isEmpty { secrets[SecretField.header(row.name.trimmed)] = row.value }
            for row in arguments where !row.value.isEmpty { secrets[SecretField.argument(row.name.trimmed)] = row.value }
            return (UploadDestination(id: id, name: title, fileNaming: fileNaming, configuration: .customHTTP(settings)), secrets)
        }
    }

    /// The secrets the draft would store, as a `SecretStore` over the Keychain's: what was typed first, the
    /// stored value for what was not. A test upload from an unsaved form reads from it, so nothing is
    /// written to the Keychain before Save.
    public func secretStore(over base: any SecretStore) -> any SecretStore {
        DraftSecretStore(typed: build()?.secrets ?? [:], id: id, base: base)
    }
}

/// Secrets typed in a form over the saved ones. Writing is not supported: it exists to be read.
struct DraftSecretStore: SecretStore {
    let typed: [String: String]
    let id: UUID
    let base: any SecretStore

    func secret(_ field: String, of destinationID: UUID) -> String? {
        typed[field] ?? base.secret(field, of: destinationID)
    }

    func setSecret(_ value: String, field: String, of destinationID: UUID) throws {}
    func removeSecret(_ field: String, of destinationID: UUID) {}
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
