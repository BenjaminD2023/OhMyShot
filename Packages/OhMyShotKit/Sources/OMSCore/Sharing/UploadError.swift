import Foundation

/// Why an upload did not finish. Every case has a sentence fit to show a person; a cancelled upload is not
/// one of these, it throws `CancellationError` like any cancelled task.
public enum UploadError: Error, LocalizedError, Equatable, Sendable {
    /// The destination is not filled in, or what is in it cannot work.
    case invalidConfiguration(String)
    /// A secret the destination needs is not in the Keychain, such as after the item was deleted there.
    case secretMissing(field: String)
    case fileUnreadable
    /// Too large for the server or for the protocol; `limit` is in bytes when known.
    case fileTooLarge(limit: Int64?)
    /// The server did not accept the credentials (401 or 403, or S3's signature errors).
    case authRejected(detail: String?)
    /// The bucket, folder or address does not exist (404).
    case notFound(detail: String?)
    /// The Mac could not reach the server.
    case unreachable(host: String)
    /// The server's certificate could not be trusted.
    case certificateRejected(host: String)
    /// macOS refused a plain `http://` address that is not on the local network.
    case insecureConnectionBlocked(host: String)
    /// The server answered with an error of its own. The message is the server's, or a custom uploader's
    /// error template evaluated.
    case server(status: Int, message: String?)
    /// The upload went through but no link could be made from the answer.
    case linkMissing
    /// The server's clock and the Mac's differ by too much for a signature to be accepted.
    case clockSkew

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            String(localized: "This destination isn’t set up correctly: \(reason)", bundle: .module)
        case .secretMissing(let field):
            String(localized: "A saved secret (\(field)) is missing from the Keychain. Open the destination and enter it again.", bundle: .module)
        case .fileUnreadable:
            String(localized: "Couldn’t read the file.", bundle: .module)
        case .fileTooLarge(let limit):
            if let limit {
                String(localized: "The file is too large for this server. It accepts files up to \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)).", bundle: .module)
            } else {
                String(localized: "The file is too large for this server.", bundle: .module)
            }
        case .authRejected(let detail):
            [String(localized: "The server didn’t accept the credentials.", bundle: .module), detail].compactMap { $0 }.joined(separator: " ")
        case .notFound(let detail):
            [String(localized: "Couldn’t find the bucket or folder.", bundle: .module), detail].compactMap { $0 }.joined(separator: " ")
        case .unreachable(let host):
            String(localized: "Couldn’t reach \(host). Check the address and your network connection.", bundle: .module)
        case .certificateRejected(let host):
            String(localized: "The certificate of \(host) isn’t trusted.", bundle: .module)
        case .insecureConnectionBlocked(let host):
            String(localized: "macOS blocks the unencrypted connection to \(host). Use https, or a server on your local network.", bundle: .module)
        case .server(let status, let message):
            if let message, !message.isEmpty {
                String(localized: "The server answered \(status): \(message)", bundle: .module)
            } else {
                String(localized: "The server answered with an error (\(status)).", bundle: .module)
            }
        case .linkMissing:
            String(localized: "The file was uploaded, but the server’s answer has no link to it.", bundle: .module)
        case .clockSkew:
            String(localized: "The server says this Mac’s clock is too far off. Check Date & Time in System Settings.", bundle: .module)
        }
    }

    /// Turns what URLSession throws into the sentence for the person. A cancelled task stays a cancellation.
    static func from(_ error: Error, host: String) -> Error {
        if error is CancellationError || error is UploadError { return error }
        guard let url = error as? URLError else { return error }
        switch url.code {
        case .cancelled:
            return CancellationError()
        case .appTransportSecurityRequiresSecureConnection:
            return UploadError.insecureConnectionBlocked(host: host)
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return UploadError.certificateRejected(host: host)
        case .fileDoesNotExist, .noPermissionsToReadFile:
            return UploadError.fileUnreadable
        default:
            return UploadError.unreachable(host: host)
        }
    }
}
