import Foundation

/// Why a cloud model gave no reading. Every case has a sentence fit to show a person; a cancelled reading is not one
/// of these, it throws `CancellationError` like any cancelled task.
public enum CloudReadingError: Error, LocalizedError, Equatable, Sendable {
    /// The model isn't filled in, or what is in it can't work; the sentence says what to fix.
    case notSetUp(String)
    /// The key isn't in the Keychain, such as after the item was deleted there.
    case keyMissing
    /// The service didn't accept the key (401 or 403).
    case keyRejected(String?)
    /// The address or the model's name is wrong (404).
    case notFound(String?)
    /// Too many requests, or the account's credit ran out (429).
    case rateLimited(String?)
    /// The service is busy (503, 529, or an `overloaded_error` in the answer).
    case overloaded(String?)
    /// The service answered with an error of its own; the message is the service's.
    case service(status: Int, message: String?)
    /// The model declined to read the picture.
    case refused(String?)
    case unreachable(host: String)
    case certificateRejected(host: String)
    /// macOS refused a plain `http://` address that isn't on this Mac or the local network.
    case insecureConnectionBlocked(host: String)
    /// The picture couldn't be made into what the service takes.
    case pictureUnusable
    /// The answer wasn't one the service's protocol gives.
    case unexpectedAnswer

    public var errorDescription: String? {
        switch self {
        case .notSetUp(let reason):
            String(localized: "This model isn’t set up yet: \(reason)", bundle: .module)
        case .keyMissing:
            String(localized: "The API key is missing from the Keychain. Open the model in Settings › Tools and enter it again.", bundle: .module)
        case .keyRejected(let detail):
            Self.withDetail(String(localized: "The service didn’t accept the API key.", bundle: .module), detail)
        case .notFound(let detail):
            Self.withDetail(String(localized: "The service doesn’t know this address or model. Check both in Settings › Tools.", bundle: .module), detail)
        case .rateLimited(let detail):
            Self.withDetail(String(localized: "The service is turning requests away for now: too many, or the account’s limit or credit ran out.", bundle: .module), detail)
        case .overloaded(let detail):
            Self.withDetail(String(localized: "The service is busy. Try again in a moment.", bundle: .module), detail)
        case .service(let status, let message):
            if let message, !message.isEmpty {
                String(localized: "The service answered \(status): \(message)", bundle: .module)
            } else {
                String(localized: "The service answered with an error (\(status)).", bundle: .module)
            }
        case .refused(let detail):
            Self.withDetail(String(localized: "The model declined to read this picture.", bundle: .module), detail)
        case .unreachable(let host):
            String(localized: "Couldn’t reach \(host). Check the address and your network connection.", bundle: .module)
        case .certificateRejected(let host):
            String(localized: "The certificate of \(host) isn’t trusted.", bundle: .module)
        case .insecureConnectionBlocked(let host):
            String(localized: "macOS blocks the unencrypted connection to \(host). Use https, or a service on your local network.", bundle: .module)
        case .pictureUnusable:
            String(localized: "The picture couldn’t be prepared for sending.", bundle: .module)
        case .unexpectedAnswer:
            String(localized: "The service’s answer couldn’t be read. Check that the address is the service’s own.", bundle: .module)
        }
    }

    /// A sentence of ours, then the service's own words set apart from it, when it gave any.
    private static func withDetail(_ sentence: String, _ detail: String?) -> String {
        guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return sentence }
        return String(localized: "\(sentence) It said: “\(detail)”", bundle: .module)
    }

    /// What the log says: the case and the status, never the service's own words, which can quote part of the key
    /// ("Incorrect API key provided: sk-…abcd").
    var logDescription: String {
        switch self {
        case .notSetUp: "notSetUp"
        case .keyMissing: "keyMissing"
        case .keyRejected: "keyRejected"
        case .notFound: "notFound"
        case .rateLimited: "rateLimited"
        case .overloaded: "overloaded"
        case .service(let status, _): "service(\(status))"
        case .refused: "refused"
        case .unreachable: "unreachable"
        case .certificateRejected: "certificateRejected"
        case .insecureConnectionBlocked: "insecureConnectionBlocked"
        case .pictureUnusable: "pictureUnusable"
        case .unexpectedAnswer: "unexpectedAnswer"
        }
    }

    /// Whether reading again may help: a busy service or a lost connection may answer next time; a wrong key won't.
    public var isWorthRetrying: Bool {
        switch self {
        case .rateLimited, .overloaded, .unreachable, .service, .unexpectedAnswer: true
        default: false
        }
    }

    /// The error for an HTTP status the service answered with, and the message in its body.
    static func from(status: Int, body: Data) -> CloudReadingError {
        let message = serviceMessage(in: body)
        switch status {
        case 401, 403: return .keyRejected(message)
        case 404: return .notFound(message)
        case 429: return .rateLimited(message)
        case 503, 529: return .overloaded(message)
        default: return .service(status: status, message: message)
        }
    }

    /// The message in an error body: `{"error": {"message": …}}` (OpenAI, Anthropic, and most others), or
    /// `{"error": "…"}` (Ollama); the body itself when it is short text.
    static func serviceMessage(in body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
            if let message = object["message"] as? String { return message }
            return nil
        }
        guard let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= 300, !text.hasPrefix("<")
        else { return nil }
        return text
    }

    /// Turns what URLSession throws into the sentence for the person. A cancelled task stays a cancellation.
    static func from(_ error: Error, host: String) -> Error {
        if error is CancellationError || error is CloudReadingError { return error }
        guard let url = error as? URLError else { return error }
        switch url.code {
        case .cancelled:
            return CancellationError()
        case .appTransportSecurityRequiresSecureConnection:
            return CloudReadingError.insecureConnectionBlocked(host: host)
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return CloudReadingError.certificateRejected(host: host)
        default:
            return CloudReadingError.unreachable(host: host)
        }
    }
}
