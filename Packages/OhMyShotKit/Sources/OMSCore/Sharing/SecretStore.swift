import Foundation
import Security
import Synchronization

/// Where the secrets of upload destinations are kept: access keys, passwords, and the values of headers and
/// form fields that carry API tokens.
///
/// Secrets never go in the defaults the destinations are saved in, and never in a log. Reads are
/// synchronous and may take a moment (the Keychain), so the uploader reads them off the main actor.
public protocol SecretStore: Sendable {
    func secret(_ field: String, of destinationID: UUID) -> String?
    /// Stores a secret, replacing the one there. Throws only when the store itself refuses.
    func setSecret(_ value: String, field: String, of destinationID: UUID) throws
    func removeSecret(_ field: String, of destinationID: UUID)
}

public extension SecretStore {
    /// Removes every secret named, for a destination that is deleted or whose fields changed.
    func removeSecrets(_ fields: [String], of destinationID: UUID) {
        for field in fields { removeSecret(field, of: destinationID) }
    }
}

public struct SecretStoreError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return String(localized: "The Keychain wouldn’t keep the secret: \(text)", bundle: .module)
    }
}

/// Secrets in the user's login Keychain, one generic password each: the service is this app's, the account
/// is the destination's id and the field.
///
/// This is the file-based keychain rather than the data protection one, which needs a provisioning profile
/// the app does not have. A build signed differently from the one that stored an item asks the user to allow
/// access, which is why a development build prompts after each rebuild.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "OhMyShot Uploads (\(Log.subsystem))") {
        self.service = service
    }

    private func query(_ field: String, of destinationID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "\(destinationID.uuidString)/\(field)",
        ]
    }

    public func secret(_ field: String, of destinationID: UUID) -> String? {
        var request = query(field, of: destinationID)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String, field: String, of destinationID: UUID) throws {
        let data = Data(value.utf8)
        let key = query(field, of: destinationID)
        var status = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = key
            add[kSecValueData] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func removeSecret(_ field: String, of destinationID: UUID) {
        SecItemDelete(query(field, of: destinationID) as CFDictionary)
    }
}

/// Secrets in memory, for tests: real Keychain calls would put dialogs in front of the person running them.
public final class InMemorySecretStore: SecretStore {
    private struct Key: Hashable {
        let destinationID: UUID
        let field: String
    }

    private let values = Mutex<[Key: String]>([:])

    public init() {}

    public func secret(_ field: String, of destinationID: UUID) -> String? {
        values.withLock { $0[Key(destinationID: destinationID, field: field)] }
    }

    public func setSecret(_ value: String, field: String, of destinationID: UUID) throws {
        values.withLock { $0[Key(destinationID: destinationID, field: field)] = value }
    }

    public func removeSecret(_ field: String, of destinationID: UUID) {
        values.withLock { $0[Key(destinationID: destinationID, field: field)] = nil }
    }

    /// How many secrets are held, so a test can see a removal leave none behind.
    public var count: Int { values.withLock { $0.count } }
}
