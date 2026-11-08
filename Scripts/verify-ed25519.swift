// Public-key-only verification for check-distribution.py; never reads a signing key or the Keychain.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]) else {
    fputs("Usage: verify-ed25519 <public-key-base64> <signature-base64> <file>\n", stderr)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        fputs("Ed25519 signature verification failed\n", stderr)
        exit(1)
    }
} catch {
    fputs("Signature verification failed: \(error)\n", stderr)
    exit(1)
}
